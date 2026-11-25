import Foundation
import Metal
import PeekabooCore

/// `peekaboo-bench picks [folder] [--files N]`
///
/// The cost of the picks (#76) on a folder: reading which files carry the Pick tag (off the main thread, at the
/// utility QoS the viewer reads them at; first and warm reads, and the re-read after a rescan, which reads only new and
/// changed files), the main-thread cost of entering and leaving the picks-only view (finding the picks, the pipeline's
/// `setFiles`, putting the view back into the folder) and of dropping a replaced listing, and, on a folder of photos,
/// how long after the view ends the photo next to the one on screen is sharp again (the view's browsing set is the
/// picks: the pipeline let the others go), after a short and a long look at the photo. Without a folder, `--files N`
/// (default 5000) empty files in a temporary directory, one in 50 tagged Pick. A folder is only read: its tags are
/// never written.
func runPicksBench(_ args: ArraySlice<String>) throws {
    var folder: URL?
    var count = 5000
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--files": count = Int(it.next() ?? "") ?? count
        default: folder = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, isDirectory: true)
        }
    }
    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    if folder == nil {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-picks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tag = try PropertyListSerialization.data(fromPropertyList: ["Pick\n0"], format: .binary, options: 0)
        for i in 0..<count {
            let path = directory.appendingPathComponent(String(format: "IMG_%05d.JPG", i)).path
            FileManager.default.createFile(atPath: path, contents: nil)
            if i % 50 == 0 { _ = tag.withUnsafeBytes { setxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, tag.count, 0, 0) } }
        }
        temporary = directory
        folder = directory
    }
    guard let folder else { return }
    /// Run `body` on a utility-QoS thread, as the viewer lists the folder and reads the tags, and time it there.
    func onUtility<T>(_ body: @escaping @Sendable () -> T) -> (T, Double) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (T, Double)?
        DispatchQueue.global(qos: .utility).async {
            let started = Trace.now()
            let value = body()
            result = (value, Trace.ms(since: started))
            done.signal()
        }
        done.wait()
        return result!
    }
    let (scanned, _) = onUtility { try? FolderScanner.scan(folder) }
    guard let files = scanned else {
        throw NSError(domain: "picks", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot list \(folder.path)"])
    }
    print("picks bench: \(files.count) files in \(temporary == nil ? folder.lastPathComponent : "a temporary folder")")

    let (first, firstMs) = onUtility { FileOperations.readPicks(of: files) }
    var warm: [Double] = []
    for _ in 0..<5 { warm.append(onUtility { FileOperations.readPicks(of: files) }.1) }
    let (_, rescanMs) = onUtility { FileOperations.readPicks(of: files, previous: first.listing, known: first.picks) }
    print(String(format: "read (utility QoS): first %.1f ms, warm median %.1f ms (min %.1f), %d picks; after a rescan "
                 + "(nothing changed) %.2f ms", firstMs, median(warm), warm.min() ?? .nan, first.picks.count, rescanMs))

    var picks = PickSet()
    picks.beginRead()
    picks.finishRead(first)
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    var config = PipelineConfig()
    config.monitorsMemoryPressure = false
    config.sweepLanes = 0
    config.tuning.sweepEnabled = false
    let pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: PixelBufferPool(device: device), config: config)
    let all = picks.filter(files)
    guard !all.isEmpty else { return }
    // On a pick in the middle of the folder (its neighbours decoded, on a folder of photos: as after browsing there).
    let pick = all[all.count / 2]
    let k = files.firstIndex(of: pick)!
    pipeline.setFiles(files, index: k)

    // Entering the view: the picks found by hashing every file (`filter`, what a refresh of the view does) or through
    // the pipeline's lookup by name (`view(of:)`, what the toggle does).
    var filterTimes: [Double] = [], lookupTimes: [Double] = []
    var view: [ImageFile] = []
    for _ in 0..<7 {
        var started = Trace.now()
        view = picks.filter(files, keeping: files.first)
        filterTimes.append(Trace.ms(since: started))
        started = Trace.now()
        view = picks.view(of: files, keeping: files.first) { pipeline.index(of: $0) }
        lookupTimes.append(Trace.ms(since: started))
    }
    print(String(format: "main thread: the picks of %d files, hashing every file (PickSet.filter) %.2f ms, through the "
                 + "pipeline's lookup (PickSet.view) %.3f ms (medians)",
                 files.count, median(filterTimes), median(lookupTimes)))
    view = picks.view(of: files, keeping: nil) { pipeline.index(of: $0) }

    // A replaced listing dropped on the main thread (its last reference: what an open or a rescan did before the
    // lists moved off it), vs. handing it to a utility queue.
    var dropTimes: [Double] = [], handTimes: [Double] = []
    for _ in 0..<5 {
        var (listing, _) = onUtility { (try? FolderScanner.scan(folder)) ?? [] }
        var started = Trace.now()
        listing = []
        dropTimes.append(Trace.ms(since: started))
        (listing, _) = onUtility { (try? FolderScanner.scan(folder)) ?? [] }
        started = Trace.now()
        let box = ListingBox(listing)
        listing = []
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { box.drop() }
        handTimes.append(Trace.ms(since: started))
        _ = listing
    }
    print(String(format: "main thread: dropping a replaced listing of %d files %.2f ms; handing it to a utility queue "
                 + "%.3f ms (medians)", files.count, median(dropTimes), median(handTimes)))

    func sharp(_ file: ImageFile) -> Bool { pipeline.cachedTiers(for: file).contains(.screen) }
    func spin(_ seconds: Double, until done: () -> Bool) -> Double? {
        let started = Trace.now()
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return nil }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        return Trace.ms(since: started)
    }
    let neighbour = files[min(k + 1, files.count - 1)]
    let decodes = spin(5) { sharp(pick) && sharp(neighbour) } != nil
    var enter: [Double] = [], leave: [Double] = []
    for _ in 0..<7 {
        var started = Trace.now()
        pipeline.setFiles(view, index: view.firstIndex(of: pick)!)
        enter.append(Trace.ms(since: started))
        _ = spin(0.1) { false }
        var whole = files
        started = Trace.now()
        let positions = PickSet.merge(pipeline.files, into: &whole)
        pipeline.setFiles(whole, index: positions[pipeline.index])
        leave.append(Trace.ms(since: started))
        _ = spin(0.1) { false }
    }
    print(String(format: "main thread: pipeline.setFiles %d → %d files (enter the view) %.2f ms; merge + setFiles "
                 + "%d → %d (leave it) %.2f ms (medians)",
                 files.count, view.count, median(enter), view.count, files.count, median(leave)))
    guard decodes else { return }

    // After a look of `dwell` at a pick, `v` into the view and, after the same look there, `v` out of it: how long
    // until the photo the next key press shows is sharp, the next pick (a cold one, further on in the folder) and then
    // the next photo of the folder (the view had dropped it from the cache). Prefetch for them starts at the toggle
    // only if the pipeline's navigation clock restarts, as the viewer does; with the clock kept, a look longer than the
    // 2.5 s prefetch horizon leaves them cold until the key press. Each setting starts with an empty cache, and each
    // round on another pick, 6 picks further on (beyond what the round before prefetched).
    let rounds = min(3, view.count / 6)
    for restart in [false, true] {
        for dwell in [0.3, 3.0] {
            let pool = PixelBufferPool(device: device)
            let pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: pool, config: config)
            func sharp(_ file: ImageFile) -> Bool { pipeline.cachedTiers(for: file).contains(.screen) }
            var intoView: [Double] = [], outOfView: [Double] = []
            var timeouts = 0
            for round in 0..<rounds {
                let v = round * 6
                let k = files.firstIndex(of: view[v])!
                let next = files[min(k + 1, files.count - 1)]
                pipeline.setFiles(files, index: k)
                pipeline.navigate(to: k, isRepeat: false)
                _ = spin(5) { sharp(view[v]) && sharp(next) }
                _ = spin(dwell) { false }
                pipeline.setFiles(view, index: v)
                if restart { pipeline.navigate(to: v, isRepeat: false) }
                if let ms = spin(4, until: { sharp(view[v + 1]) }) { intoView.append(ms) } else { timeouts += 1 }
                _ = spin(dwell) { false }
                pipeline.setFiles(files, index: k)
                if restart { pipeline.navigate(to: k, isRepeat: false) }
                if let ms = spin(4, until: { sharp(next) }) { outOfView.append(ms) } else { timeouts += 1 }
            }
            func describe(_ times: [Double]) -> String {
                times.isEmpty ? "never" : String(format: "%.0f ms (median of %d)", median(times), times.count)
            }
            print(String(format: "toggle after a %.1f s look (%@): next pick sharp in %@, next photo after leaving in %@%@",
                         dwell, restart ? "prefetch clock restarted" : "clock kept", describe(intoView), describe(outOfView),
                         timeouts > 0 ? "; \(timeouts) of \(2 * rounds) not sharp within 4 s" : ""))
        }
    }
}

/// Keeps a listing until a utility queue drops it (as the viewer's `Retired`).
private final class ListingBox: @unchecked Sendable {
    private var files: [ImageFile]
    init(_ files: [ImageFile]) { self.files = files }
    func drop() { files.removeAll() }
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    return values.sorted()[values.count / 2]
}

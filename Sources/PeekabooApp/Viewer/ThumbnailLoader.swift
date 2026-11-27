import CoreGraphics
import Foundation
import PeekabooCore

/// Thumbnails for the image list, made off the main thread and kept for the files' versions.
///
/// - Made on a utility-QoS queue (efficiency cores), two at a time, never on the main thread. A file the viewer holds a
///   preview of (`preview`: the pipeline's cached `.preview` tier, which its background sweep makes around the image on
///   screen) is drawn smaller from it, without reading the file; any other from its embedded preview where it has one
///   (`Thumbnail.make`). Which of the two is decided when the job starts, so a preview that landed meanwhile counts.
/// - Never beside the decode of the image on screen: while it runs (`isPaused`) no job starts; one running finishes.
/// - Asked for only by the rows on screen; a row that leaves takes its waiting job with it.
/// - Cached by file version (`NSCache`, 32 MB: about 1,200 rows), so a file saved anew gets a new one; a file without a
///   thumbnail is remembered too and not tried again. Small images only: at most `maxPixelSize` on their long side, in
///   the layout Core Animation shows as it is.
///
/// Main thread only, except the jobs.
final class ThumbnailLoader {
    /// Makes one thumbnail, blocking (on the queue), from the viewer's preview of the file when there is one: the
    /// standard one, or a test's.
    typealias Make = @Sendable (_ url: URL, _ preview: DecodedImage?, _ maxPixelSize: Int) -> CGImage?

    static let standardMake: Make = { url, preview, size in
        if let preview, let image = Thumbnail.make(from: preview, maxPixelSize: size) { return image }
        return Thumbnail.make(url, maxPixelSize: size)?.image
    }

    /// Jobs running at once.
    static let lanes = 2

    /// A thumbnail looked up or made: its image, or nil when the file has none (unreadable, a RAW without preview).
    final class Entry {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    let maxPixelSize: Int
    /// Main thread: `file`'s thumbnail was made.
    var onLoaded: ((ImageFile, Entry) -> Void)?
    /// The viewer's cached preview of a file, asked when its job starts (main thread).
    var preview: (ImageFile) -> DecodedImage? = { _ in nil }
    /// While the viewer decodes the image on screen no job starts (one already running finishes).
    var isPaused = false {
        didSet { if isPaused != oldValue, !isPaused { startJobs() } }
    }
    /// Thumbnails made, those of them made from the viewer's preview, and requests dropped before they started.
    private(set) var made = 0
    private(set) var madeFromPreviews = 0
    private(set) var cancelled = 0
    /// Jobs asked for and not finished.
    var pendingCount: Int { waiting.count + running.count }
    /// Thumbnails the cache let go of: `NSCache` evicts on its own under memory pressure (a row on screen keeps its
    /// thumbnail in its layer; one configured again makes it again).
    var evicted: Int { evictions.count }

    private let make: Make
    private let queue = DispatchQueue(label: "peekaboo.thumbnails", qos: .utility, attributes: .concurrent)
    private let cache = NSCache<NSString, Entry>()
    /// The cache's delegate (`NSCache` does not retain it).
    private let evictions = Evictions()
    private var waiting: [(file: ImageFile, key: NSString)] = []
    private var running: Set<NSString> = []

    init(maxPixelSize: Int, make: @escaping Make = ThumbnailLoader.standardMake) {
        self.maxPixelSize = maxPixelSize
        self.make = make
        cache.totalCostLimit = 32 << 20
        cache.delegate = evictions
    }

    /// The cache key of `file` as it is now: its path and version.
    static func key(_ file: ImageFile) -> NSString { "\(file.url.path)|\(file.version)" as NSString }

    func cached(_ key: NSString) -> Entry? { cache.object(forKey: key) }

    /// Make the thumbnail of `file` (whose key is `key`) unless it is cached or on its way; `onLoaded` delivers it.
    func request(_ file: ImageFile, key: NSString) {
        guard !running.contains(key), cache.object(forKey: key) == nil,
              !waiting.contains(where: { $0.key == key }) else { return }
        waiting.append((file, key))
        startJobs()
    }

    /// The row of `key` left the screen: its job does not start (one running finishes, and is kept).
    func cancel(_ key: NSString) {
        guard let i = waiting.firstIndex(where: { $0.key == key }) else { return }
        waiting.remove(at: i)
        cancelled += 1
    }

    /// The list closed: nothing more starts.
    func cancelAll() {
        cancelled += waiting.count
        waiting.removeAll()
    }

    private func startJobs() {
        while !isPaused, running.count < Self.lanes, !waiting.isEmpty {
            let (file, key) = waiting.removeFirst()
            running.insert(key)
            let preview = preview(file)
            let url = file.url, size = maxPixelSize, make = make
            queue.async { [weak self] in
                let started = Trace.now()
                let delivery = Delivery(make(url, preview, size))
                let ms = Trace.ms(since: started)
                DispatchQueue.main.async {
                    self?.finish(file, key: key, image: delivery.image, fromPreview: preview != nil, ms: ms)
                }
            }
        }
    }

    private func finish(_ file: ImageFile, key: NSString, image: CGImage?, fromPreview: Bool, ms: Double) {
        running.remove(key)
        made += 1
        if fromPreview { madeFromPreviews += 1 }
        let entry = Entry(image)
        cache.setObject(entry, forKey: key, cost: image.map { $0.bytesPerRow * $0.height } ?? 64)
        if Trace.enabled {
            Trace.log(String(format: "list thumbnail %@: %@ %@ in %.2f ms", file.name, image.map { "\($0.width)x\($0.height)" } ?? "none",
                             fromPreview ? "from the viewer's preview" : "from the file", ms))
        }
        onLoaded?(file, entry)
        startJobs()
    }

    /// Carries a thumbnail from the queue to the main thread (a `CGImage` is immutable).
    private struct Delivery: @unchecked Sendable {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    /// Counts the cache's evictions, which it reports from any thread.
    private final class Evictions: NSObject, NSCacheDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }
}

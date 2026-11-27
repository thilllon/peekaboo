import Foundation
import PeekabooCore

/// `peekaboo-bench config [--runs N] [full | comments | dump | <file>] …`
///
/// config.toml is read at launch: `AppDelegate.launchViewer` loads it on the main thread before the first frame. For
/// each text, on the main thread as there: the process's first load (cold: the static tables are built then; only the
/// first text of a run is cold), then the median of N warm parses (`AppConfig.parse`) and loads (`ConfigStore.load`:
/// read, parse and apply). `full` is the file Peekaboo writes (every setting and the whole keymap), `comments` the same
/// text commented out (the shape of the starter file of earlier versions), a path any file (copied first: the bench
/// reads only its temporary copies). `dump` prints the full file. Default: `full comments`.
func runConfigBench(_ args: ArraySlice<String>) throws {
    var runs = 500
    var names: [String] = []
    var it = args.makeIterator()
    while let arg = it.next() {
        if arg == "--runs" { runs = max(1, Int(it.next() ?? "") ?? runs) } else { names.append(arg) }
    }
    if names == ["dump"] { return print(ConfigFile.defaultText, terminator: "") }
    if names.isEmpty { names = ["full", "comments"] }
    precondition(Thread.isMainThread)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-config-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (index, name) in names.enumerated() {
        let text: String
        switch name {
        case "full": text = ConfigFile.defaultText
        case "comments":
            text = ConfigFile.defaultText.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty || $0.hasPrefix("#") ? String($0) : "# " + $0 }.joined(separator: "\n")
        default: text = try String(contentsOf: URL(fileURLWithPath: (name as NSString).expandingTildeInPath), encoding: .utf8)
        }
        let url = directory.appendingPathComponent("config-\(index).toml")
        try Data(text.utf8).write(to: url)
        let store = ConfigStore(url: url)
        let coldStarted = Trace.now()
        store.load()
        let cold = Trace.ms(since: coldStarted)
        guard store.lastError == nil else { throw NSError(domain: "config", code: 1, userInfo: [NSLocalizedDescriptionKey: store.lastError!]) }
        var parse: [Double] = [], load: [Double] = []
        for _ in 0..<runs {
            let parseStarted = Trace.now()
            _ = try AppConfig.parse(toml: text)
            parse.append(Trace.ms(since: parseStarted))
            let loadStarted = Trace.now()
            store.load()
            load.append(Trace.ms(since: loadStarted))
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let label = ["full", "comments"].contains(name) ? name : (name as NSString).lastPathComponent
        print(String(format: "%@ (%d B, %d lines): %@ load %.4f ms; parse %.4f ms; load %.4f ms (median of %d)", label,
                     text.utf8.count, text.split(separator: "\n", omittingEmptySubsequences: false).count - 1,
                     index == 0 ? "cold" : "first", cold, median(parse), median(load), runs))
    }
}

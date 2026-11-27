import Foundation
import PeekabooCore

/// `peekaboo-bench config [--runs N] [--processes P] [full | comments | dump | <file>] …`, `peekaboo-bench config --cold <file>`
///
/// config.toml is read at launch, on the main thread before the first frame: `AppDelegate` builds its `ConfigStore`
/// (which builds `AppConfig.default`, so `Keymap.default`), and `launchViewer` loads the file. Both steps are timed
/// cold, as there, in P fresh processes per text, interleaved across the texts: the bench starts itself with `--cold`,
/// since rendering or parsing a text in the measuring process would build the tables the first load builds at launch.
/// Then the median of N warm parses (`AppConfig.parse`) and loads (`ConfigStore.load`: read, parse and apply) in this
/// process. `full` is the file Peekaboo writes (every setting and the whole keymap), `comments` the same text commented
/// out (the shape of the starter file of earlier versions), a path any file (copied first: the bench reads only its
/// temporary copies). `dump` prints the full file.
///
/// The first step of a fresh process is slower when the bench starts it than when a shell does (about 0.3 ms more for
/// `ConfigStore()` on an M4 Pro; the first load is the same): compare builds within one run, or start `--cold <file>`,
/// which prints the two times in ms, from a shell loop that interleaves them.
func runConfigBench(_ args: ArraySlice<String>) throws {
    var runs = 500
    var processes = 20
    var names: [String] = []
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--runs": runs = max(1, Int(it.next() ?? "") ?? runs)
        case "--processes": processes = max(1, Int(it.next() ?? "") ?? processes)
        case "--cold": return try coldLoad(it.next() ?? "")
        default: names.append(arg)
        }
    }
    if names == ["dump"] { return print(ConfigFile.defaultText, terminator: "") }
    if names.isEmpty { names = ["full", "comments"] }
    precondition(Thread.isMainThread)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-config-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var texts: [(label: String, text: String, url: URL)] = []
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
        texts.append((["full", "comments"].contains(name) ? name : (name as NSString).lastPathComponent, text, url))
    }
    var cold = [[(store: Double, load: Double)]](repeating: [], count: texts.count)
    for _ in 0..<processes {
        for (index, text) in texts.enumerated() { cold[index].append(try runCold(text.url)) }
    }
    for (index, text) in texts.enumerated() {
        let store = ConfigStore(url: text.url)
        store.load()
        guard store.lastError == nil else { throw benchError(store.lastError!) }
        var parse: [Double] = [], load: [Double] = []
        for _ in 0..<runs {
            let parseStarted = Trace.now()
            _ = try AppConfig.parse(toml: text.text)
            parse.append(Trace.ms(since: parseStarted))
            let loadStarted = Trace.now()
            store.load()
            load.append(Trace.ms(since: loadStarted))
        }
        func spread(_ values: [Double]) -> String {
            String(format: "%.3f ms (%.3f–%.3f)", percentile(values, 0.5), percentile(values, 0.1), percentile(values, 0.9))
        }
        let times = cold[index]
        print(String(format: "%@ (%d B, %d lines): cold, median and p10–p90 of %d processes: ConfigStore() %@, first load %@, both %@; warm: parse %.4f ms, load %.4f ms (median of %d)",
                     text.label, text.text.utf8.count, text.text.split(separator: "\n", omittingEmptySubsequences: false).count - 1,
                     processes, spread(times.map(\.store)), spread(times.map(\.load)), spread(times.map { $0.store + $0.load }),
                     percentile(parse, 0.5), percentile(load, 0.5), runs))
    }
}

/// `--cold`: what launch does with the file at `path`, on the main thread of a fresh process (at the app's main-thread
/// QoS), timed; prints the two times in ms.
private func coldLoad(_ path: String) throws {
    precondition(Thread.isMainThread)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    _ = Trace.enabled  // read first at launch, by main.swift
    let url = URL(fileURLWithPath: path)
    let started = Trace.now()
    let store = ConfigStore(url: url)
    let built = Trace.ms(since: started)
    let loadStarted = Trace.now()
    store.load()
    let loaded = Trace.ms(since: loadStarted)
    guard store.lastError == nil else { throw benchError(store.lastError!) }
    print(built, loaded)
}

/// Start this bench with `--cold` on `url` in a fresh process: (`ConfigStore()`, first load) in ms.
private func runCold(_ url: URL) throws -> (store: Double, load: Double) {
    guard let executable = Bundle.main.executableURL?.path else { throw benchError("no executable path") }
    var pipe: [Int32] = [0, 0]
    guard Darwin.pipe(&pipe) == 0 else { throw benchError("pipe failed") }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, pipe[0])
    posix_spawn_file_actions_addclose(&actions, pipe[1])
    let argv = [executable, "config", "--cold", url.path].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, nil, argv, environ)
    close(pipe[1])
    let output = FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true)
    guard spawned == 0 else { throw benchError("posix_spawn failed: \(spawned)") }
    let data = output.readDataToEndOfFile()
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    let times = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
    guard status == 0, times.count == 2 else { throw benchError("--cold \(url.lastPathComponent) failed") }
    return (times[0], times[1])
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int((Double(sorted.count - 1) * p).rounded())]
}

private func benchError(_ message: String) -> NSError {
    NSError(domain: "config", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

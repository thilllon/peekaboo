import Foundation

// peekaboo-bench <suite> [options]
// Each workstream owns one suite file in this directory and registers it here.
let suites: [String: (ArraySlice<String>) throws -> Void] = [
    "anim": runAnimBench,
    "decode": runDecodeBench,
    "picks": runPicksBench,
    "pipeline": runPipelineBench,
    "render": runRenderBench,
]

let args = CommandLine.arguments.dropFirst()
guard let name = args.first, let suite = suites[name] else {
    print("usage: peekaboo-bench <\(suites.keys.sorted().joined(separator: "|"))> [options]")
    exit(2)
}
do { try suite(args.dropFirst()) } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

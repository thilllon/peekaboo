import Foundation
import os

/// Latency tracing. Always emits os_signpost intervals (visible in Instruments);
/// set `PEEKABOO_TRACE=1` (or `[debug] trace = true`) to also print timestamped lines
/// to stderr, which the perf self-tests parse.
public enum Trace {
    /// `PEEKABOO_TRACE` is set: on from the first line, whatever the config says. (`getenv`: read on the main thread
    /// before the first frame, where `ProcessInfo.environment` would copy the whole environment, 20–100 µs.)
    public static let forcedByEnvironment = getenv("PEEKABOO_TRACE") != nil
    /// Print trace lines. Set from `[debug] trace` when the config is applied (main thread; a plain flag, read on every
    /// thread like the `static let` it replaces).
    nonisolated(unsafe) public static var enabled = forcedByEnvironment
    public static let signposter = OSSignposter(subsystem: "com.thilllon.Peekaboo", category: .pointsOfInterest)

    /// Monotonic nanoseconds (does not advance during sleep).
    @inline(__always) public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Milliseconds elapsed since `start` (a value from `now()`).
    @inline(__always) public static func ms(since start: UInt64) -> Double { Double(now() &- start) / 1e6 }

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[pb \(String(format: "%.3f", Double(now()) / 1e6))] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

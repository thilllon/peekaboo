import Foundation
import os

/// Latency tracing. Always emits os_signpost intervals (visible in Instruments);
/// set `PEEKABOO_TRACE=1` to also print timestamped lines to stderr, which the
/// perf self-tests parse.
public enum Trace {
    public static let enabled = ProcessInfo.processInfo.environment["PEEKABOO_TRACE"] != nil
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

import Foundation

/// A Peekaboo version. Releases are named after their day, `YYYYMMDD`; a further release on the same day adds
/// `.N` (`20261125`, `20261125.1`, `20261125.2`). Versions from before date versions (`0.1.0`, also spelled
/// `v0.1.0`) are older than every date version.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    private enum Rank: Hashable, Sendable {
        /// Semantic version components without trailing zeros (`0.1.0` = `0.1`).
        case legacy([Int])
        /// `YYYYMMDD` and the release number of that day (0 for the bare date).
        case date(day: Int, release: Int)
    }

    private let rank: Rank
    /// Canonical spelling: `20261125`, `20261125.1`, `0.1.0` (no leading `v`).
    public let description: String

    /// Parses a date version or a legacy semantic version; nil for anything else (`2026-11-25`, `abc`,
    /// `20261340`, `20261125.1.2`).
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
              parts.allSatisfy({ (1...9).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        let numbers = parts.map { Int($0)! }
        if parts[0].count == 8 {
            guard parts.count <= 2, Self.isCalendarDay(numbers[0]) else { return nil }
            let release = parts.count == 2 ? numbers[1] : 0
            rank = .date(day: numbers[0], release: release)
            description = release == 0 ? String(numbers[0]) : "\(numbers[0]).\(release)"
        } else {
            var components = numbers
            while components.count > 1, components.last == 0 { components.removeLast() }
            rank = .legacy(components)
            description = numbers.map(String.init).joined(separator: ".")
        }
    }

    /// A date version (`YYYYMMDD[.N]`), as every release since date versions.
    public var isDateVersion: Bool {
        if case .date = rank { return true }
        return false
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        switch (a.rank, b.rank) {
        case (.legacy, .date): return true
        case (.date, .legacy): return false
        case let (.date(d1, r1), .date(d2, r2)): return (d1, r1) < (d2, r2)
        case let (.legacy(x), .legacy(y)):
            for i in 0..<max(x.count, y.count) {
                let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
                if l != r { return l < r }
            }
            return false
        }
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.rank == b.rank }
    public func hash(into hasher: inout Hasher) { hasher.combine(rank) }

    /// `YYYYMMDD` is a real day of the Gregorian calendar (years 2000–2999).
    private static func isCalendarDay(_ value: Int) -> Bool {
        let year = value / 10000, month = value / 100 % 100, day = value % 100
        guard (2000...2999).contains(year), (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }
}

/// What the running build says about itself (`Info.plist`): shown in the About panel, Settings and
/// `peekaboo --version`.
public enum BuildInfo {
    /// `CFBundleShortVersionString`, e.g. `20261125`; nil outside an app bundle (`swift run`, tests).
    public static var version: String? { string("CFBundleShortVersionString") }
    /// Short commit the release was built from (`PeekabooCommit`, written by `mise run app`).
    public static var commit: String? { string("PeekabooCommit") }
    /// `20261125 (1a2b3c4)`, or just the version when the commit is unknown.
    public static var versionLine: String {
        let version = version ?? "development build"
        guard let commit else { return version }
        return "\(version) (\(commit))"
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }
}

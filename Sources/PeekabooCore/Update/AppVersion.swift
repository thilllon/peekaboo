import Foundation

/// A Peekaboo release. `name` is `YYYYMMDD-<sha6>`: the committer day of the release commit in Asia/Seoul and the
/// first six hex digits of its SHA (`20261125-ab2342`), shown everywhere (About, Settings, `peekaboo --version`, the
/// disk image `Peekaboo-20261125-ab2342.dmg`, the tag `v20261125-ab2342`). A SHA does not order releases, so `build`
/// does: `CFBundleVersion`, the number of commits on main up to the release (`git rev-list --count HEAD`), which
/// grows with every release. The updater compares builds; an update must also carry the build its manifest names, so
/// an older signed release cannot be passed off as a newer one.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// `20261125-ab2342`.
    public let name: String
    /// `CFBundleVersion`, e.g. `35`.
    public let build: Int

    /// nil unless `name` is `YYYYMMDD-<6 lowercase hex digits>` of a real day and `build` is positive.
    public init?(name: String, build: Int) {
        guard build > 0, Self.isName(name) else { return nil }
        self.name = name
        self.build = build
    }

    /// From a bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
    public init?(shortVersion: Any?, bundleVersion: Any?) {
        guard let name = shortVersion as? String, let text = bundleVersion as? String,
              text.allSatisfy({ ("0"..."9").contains($0) }), let build = Int(text) else { return nil }
        self.init(name: name, build: build)
    }

    /// Parses `token` (`20261125-ab2342+35`).
    public init?(_ token: String) {
        let parts = token.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...9).contains(parts[1].count), parts[1].allSatisfy({ ("0"..."9").contains($0) }),
              let build = Int(parts[1]) else { return nil }
        self.init(name: String(parts[0]), build: build)
    }

    /// `20261125-ab2342+35`: names a release in file names, records and the install helper's arguments.
    public var token: String { "\(name)+\(build)" }

    public var description: String { name }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { (a.build, a.name) < (b.build, b.name) }

    /// `YYYYMMDD-xxxxxx`: a real day of the Gregorian calendar (years 2000–2999), then six lowercase hex digits.
    private static func isName(_ name: String) -> Bool {
        let utf8 = Array(name.utf8)
        guard utf8.count == 15, utf8[8] == UInt8(ascii: "-"),
              utf8[..<8].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              utf8[9...].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }),
              let value = Int(String(decoding: utf8[..<8], as: UTF8.self))
        else { return false }
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
    /// `CFBundleShortVersionString`, e.g. `20261125-ab2342`; nil outside an app bundle (`swift run`, tests).
    public static var version: String? { string("CFBundleShortVersionString") }
    /// `CFBundleVersion`, the build number, e.g. `35`.
    public static var build: String? { string("CFBundleVersion") }
    /// `20261125-ab2342 (35)`, or `development build` outside an app bundle.
    public static var versionLine: String {
        guard let version else { return "development build" }
        guard let build else { return version }
        return "\(version) (\(build))"
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }
}

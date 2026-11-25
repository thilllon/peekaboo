import Foundation

/// `latest.json`, an asset of every release (written by `mise run release`), fetched from
/// `https://github.com/thilllon/peekaboo/releases/latest/download/latest.json`:
///
/// ```json
/// {"version": "20261125-ab2342", "build": 35, "minimumSystemVersion": "14.0",
///  "url": "https://github.com/thilllon/peekaboo/releases/download/v20261125-ab2342/Peekaboo-20261125-ab2342.zip",
///  "sha256": "…64 hex digits…", "size": 2412345,
///  "dmg": "https://github.com/thilllon/peekaboo/releases/download/v20261125-ab2342/Peekaboo-20261125-ab2342.dmg",
///  "notes": "https://github.com/thilllon/peekaboo/releases/tag/v20261125-ab2342", "published": "2026-11-25T09:30:00Z"}
/// ```
///
/// `version` is the name shown to the user, `build` the `CFBundleVersion` that orders releases (see `AppVersion`).
public struct UpdateManifest: Equatable, Sendable {
    public let version: AppVersion
    /// `LSMinimumSystemVersion` of the release, e.g. `26.0`.
    public let minimumSystemVersion: String
    /// The zipped app (the updater's payload).
    public let url: URL
    /// SHA-256 of the zip, lowercase hex.
    public let sha256: String
    /// Size of the zip in bytes.
    public let size: Int
    /// The disk image, for a manual download.
    public let dmg: URL?
    /// The release page.
    public let notes: URL?
    public let published: String?

    /// Zips larger than this are refused (the app is ~3 MB).
    public static let maximumSize = 512 << 20

    private struct Fields: Decodable {
        let version: String
        let build: Int
        let minimumSystemVersion: String
        let url: String
        let sha256: String
        let size: Int
        let dmg: String?
        let notes: String?
        let published: String?
    }

    /// Parses and validates the manifest. Only `https` URLs are accepted unless `allowInsecureURLs`
    /// (a local test server or a file, see `PEEKABOO_UPDATE_URL`).
    public init(data: Data, allowInsecureURLs: Bool = false) throws {
        let fields: Fields
        do {
            fields = try JSONDecoder().decode(Fields.self, from: data)
        } catch {
            throw UpdateError.invalidManifest("not a release manifest")
        }
        guard let version = AppVersion(name: fields.version, build: fields.build) else {
            throw UpdateError.invalidManifest("bad version \"\(fields.version)\" (build \(fields.build))")
        }
        guard Self.systemVersion(fields.minimumSystemVersion) != nil else {
            throw UpdateError.invalidManifest("bad minimumSystemVersion \"\(fields.minimumSystemVersion)\"")
        }
        let sha = fields.sha256.lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw UpdateError.invalidManifest("bad sha256") }
        guard (1...Self.maximumSize).contains(fields.size) else { throw UpdateError.invalidManifest("bad size \(fields.size)") }
        func link(_ text: String?) throws -> URL? {
            guard let text else { return nil }
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || (allowInsecureURLs && (scheme == "http" || scheme == "file"))
            else { throw UpdateError.invalidManifest("bad URL \"\(text)\"") }
            return url
        }
        guard let zip = try link(fields.url) else { throw UpdateError.invalidManifest("no url") }
        self.version = version
        minimumSystemVersion = fields.minimumSystemVersion
        url = zip
        sha256 = sha
        size = fields.size
        dmg = try link(fields.dmg)
        notes = try link(fields.notes)
        published = fields.published
    }

    /// The release runs on `system` (its `minimumSystemVersion` is not newer).
    public func runs(on system: OperatingSystemVersion) -> Bool {
        guard let minimum = Self.systemVersion(minimumSystemVersion) else { return false }
        let have = [system.majorVersion, system.minorVersion, system.patchVersion]
        return !have.lexicographicallyPrecedes(minimum)
    }

    /// The page to send the user to when the app cannot install the update itself.
    public var downloadPage: URL { notes ?? dmg ?? url }

    /// `26`, `26.0`, `14.2.1` → three components; nil if not a dotted number.
    static func systemVersion(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...4).contains(part.count), let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

/// Why an update check, download or install did not go through (the message is shown as is).
public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case invalidManifest(String)
    case download(String)
    case verification(String)
    case install(String)

    public var description: String {
        switch self {
        case .invalidManifest(let detail): return "invalid update manifest: \(detail)"
        case .download(let detail): return detail
        case .verification(let detail): return "the download failed verification: \(detail)"
        case .install(let detail): return "cannot install the update: \(detail)"
        }
    }
}

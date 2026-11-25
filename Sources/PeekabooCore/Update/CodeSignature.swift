import Foundation
import Security

/// Code-signature checks for updates (Security framework; nothing here runs on the launch path).
public enum CodeSignature {
    /// `CFBundleIdentifier` of Peekaboo; an update must carry it.
    public static let bundleIdentifier = "com.thilllon.Peekaboo"

    /// Team identifier of the running process's signature; nil when it is ad-hoc signed or unsigned.
    public static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(staticCode)
    }

    /// Team identifier of the bundle at `url`; nil when it is ad-hoc signed or unsigned.
    public static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(code)
    }

    private static func teamIdentifier(_ code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The requirement an update must meet, given the team of the running app.
    ///
    /// - Developer ID signed (`teamIdentifier` set): Apple-anchored Developer ID Application certificate of the
    ///   same team, and Peekaboo's identifier.
    /// - Ad-hoc signed (nil): a valid signature with Peekaboo's identifier; the SHA-256 from the manifest is what
    ///   vouches for the download then.
    ///
    /// Returns nil for a malformed team identifier (it is spliced into the requirement text).
    public static func updateRequirement(teamIdentifier: String?) -> String? {
        let identifier = "identifier \"\(bundleIdentifier)\""
        guard let team = teamIdentifier else { return identifier }
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        // 1.2.840.113635.100.6.2.6: Developer ID CA; 1.2.840.113635.100.6.1.13: Developer ID Application leaf.
        return "anchor apple generic and \(identifier)"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The requirement for updates of the running app; nil when its team identifier is malformed.
    public static func updateRequirementForRunningApp() -> String? {
        updateRequirement(teamIdentifier: runningTeamIdentifier())
    }

    /// Validate the signature of the bundle at `url` (every architecture, nested code, strict) and `requirement`.
    public static func check(_ url: URL, requirement: String) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.verification(message(status, nil)) }
        var compiled: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { throw UpdateError.verification("bad requirement (\(status))") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, &error)
        guard status == errSecSuccess else { throw UpdateError.verification(message(status, error?.takeRetainedValue())) }
    }

    private static func message(_ status: OSStatus, _ error: CFError?) -> String {
        if let error, let description = CFErrorCopyDescription(error) as String? { return description }
        return (SecCopyErrorMessageString(status, nil) as String?) ?? "code signature error \(status)"
    }
}

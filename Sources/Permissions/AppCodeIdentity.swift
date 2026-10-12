import Foundation

#if os(macOS)
import Security

/// Identity of the running code, used to detect when macOS privacy grants were
/// invalidated because the app binary changed.
///
/// The public builds are ad-hoc signed with no Team ID, so their designated
/// requirement is a bare `cdhash` pin. TCC stores Screen Recording and
/// Accessibility approvals against that hash, and every rebuild produces a new
/// one. macOS then treats the updated app as a different program: the old entry
/// stays visible and enabled in System Settings while the new binary is denied.
public enum AppCodeIdentity {
    /// Hex-encoded code directory hash of the running process.
    ///
    /// Falls back to the bundle version when the signing information cannot be
    /// read, so callers still get a value that changes on a normal app update.
    public static func current() -> String {
        codeDirectoryHash() ?? bundleVersionIdentity()
    }

    private static func codeDirectoryHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess,
            let info = information as? [String: Any],
            let hash = info[kSecCodeInfoUnique as String] as? Data
        else {
            return nil
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func bundleVersionIdentity() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "bundle-\(short)-\(build)"
    }
}
#endif

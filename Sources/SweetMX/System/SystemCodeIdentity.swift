import Foundation
import Security

/// Production code-signing reader built on the Security framework.
///
/// Strict validation (all architectures, nested code) is used so a bundle with a tampered inner
/// part reads as unsigned and uninstall never trusts its identifier.
public nonisolated struct SystemCodeIdentity: CodeIdentityProtocol {
    private static let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)

    public init() {}

    public func signedIdentifier(at bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, Self.validityFlags, nil) == errSecSuccess
        else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }
}

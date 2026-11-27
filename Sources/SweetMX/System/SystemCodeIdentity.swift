import Foundation
import Security

/// Production code-signing reader built on the Security framework.
///
/// Strict validation (all architectures, nested code) is used so a bundle with a tampered inner
/// part reads as unsigned. A valid signature, even an ad-hoc one, carries an identifier anyone can
/// choose, so the identifier only shows that the bundle's Info.plist ID and its signature agree.
/// It does not show who the vendor is.
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

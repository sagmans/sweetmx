import Foundation
import Security

/// Production code-signing reader built on the Security framework.
///
/// The check proves only that the executable's signature is valid for every architecture and that
/// it binds the bundle's Info.plist, so the Info.plist ID and the signed identifier agree. Resource
/// files are not hashed: uninstall only needs the identifier, and hashing every sealed file of a
/// large bundle can take minutes while the sheet cannot be cancelled. A tampered resource file
/// therefore still reads as signed. A valid signature, even an ad-hoc one, carries an identifier
/// anyone can choose, so it does not show who the vendor is.
public nonisolated struct SystemCodeIdentity: CodeIdentityProtocol {
    private static let validityFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSDoNotValidateResources
    )

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

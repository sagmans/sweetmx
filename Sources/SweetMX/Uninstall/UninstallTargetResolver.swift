import Foundation

/// Decides whether an app may be removed and gathers the facts the later steps need.
///
/// It exists as one decision point so the refusal rules cannot be skipped by a caller: nothing
/// downstream accepts a path, only the `UninstallTarget` this returns. It reads only through the
/// injected seams, so tests never touch a real app.
nonisolated struct UninstallTargetResolver: Sendable {
    /// The system volume holds apps that macOS needs; the symlink-resolved path is compared so a
    /// path that merely looks like a user app cannot hide one.
    private static let systemPathPrefix = "/System/"
    private static let applePrefix = "com.apple."
    /// Apple apps a person installed on purpose and may remove. Entries ending in a dot are prefixes.
    /// Only IDs confirmed on a real install or long public are listed; an unknown `com.apple.*`
    /// app stays protected because removing a required one can break the system.
    private static let removableAppleIDs: [String] = [
        "com.apple.dt.",
        "com.apple.garageband10",
        "com.apple.iMovieApp",
        "com.apple.iWork.Keynote",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Pages",
    ]
    private static let infoPlistComponents = ["Contents", "Info.plist"]
    private static let displayNameKeys = ["CFBundleDisplayName", "CFBundleName"]
    private static let bundleIDKey = "CFBundleIdentifier"
    private static let bundleExtension = "app"
    /// Real Info.plist files are a few KB; the bound stops a crafted bundle from exhausting memory.
    private static let infoPlistMaxBytes = 1_048_576
    private static let bundleIDSeparator: Character = "."
    private static let minimumBundleIDParts = 2
    private static let bundleIDPartCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    private let fileSystem: FileSystemProtocol
    private let codeIdentity: CodeIdentityProtocol
    private let ownBundleID: String?

    /// `ownBundleID` is nil when SweetMX runs without a bundle (tests, `swift run`); then no app
    /// matches it.
    init(fileSystem: FileSystemProtocol, codeIdentity: CodeIdentityProtocol, ownBundleID: String?) {
        self.fileSystem = fileSystem
        self.codeIdentity = codeIdentity
        self.ownBundleID = ownBundleID
    }

    /// The link check runs first because every later check reads the path; a link could make them
    /// all look at a different app than the one the Trash move would hit.
    func resolve(bundlePath: String) -> Result<UninstallTarget, UninstallRefusal> {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        if fileSystem.isSymbolicLink(at: bundleURL) {
            return .failure(.symlinkedApp)
        }
        if fileSystem.resolvingSymlinks(bundleURL).path.hasPrefix(Self.systemPathPrefix) {
            return .failure(.systemApp)
        }
        guard let info = readInfo(of: bundleURL),
              let bundleID = info[Self.bundleIDKey] as? String,
              Self.isWellFormed(bundleID: bundleID)
        else { return .failure(.unreadableBundleID) }
        if let ownBundleID, bundleID == ownBundleID {
            return .failure(.sweetMXItself)
        }
        if isRequiredAppleApp(bundleID) {
            return .failure(.requiredAppleApp)
        }

        return .success(UninstallTarget(
            bundleURL: bundleURL,
            displayName: displayName(from: info, bundleURL: bundleURL),
            bundleID: bundleID,
            identityConfirmed: codeIdentity.signedIdentifier(at: bundleURL) == bundleID,
            needsFinder: !fileSystem.isWritableDirectory(at: bundleURL.deletingLastPathComponent())
        ))
    }

    /// A bundle ID becomes part of file names and match keys later, so only plain dotted
    /// identifiers pass; anything else could widen a match or escape a folder.
    static func isWellFormed(bundleID: String) -> Bool {
        let parts = bundleID.split(separator: bundleIDSeparator, omittingEmptySubsequences: false)
        guard parts.count >= minimumBundleIDParts else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(bundleIDPartCharacters.contains)
        }
    }

    private func readInfo(of bundleURL: URL) -> [String: Any]? {
        let plistURL = Self.infoPlistComponents.reduce(bundleURL) { $0.appendingPathComponent($1) }
        guard let data = fileSystem.readData(at: plistURL, maxBytes: Self.infoPlistMaxBytes) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private func isRequiredAppleApp(_ bundleID: String) -> Bool {
        guard bundleID.hasPrefix(Self.applePrefix) else { return false }
        return !Self.removableAppleIDs.contains { entry in
            entry.hasSuffix(String(Self.bundleIDSeparator)) ? bundleID.hasPrefix(entry) : bundleID == entry
        }
    }

    private func displayName(from info: [String: Any], bundleURL: URL) -> String {
        for key in Self.displayNameKeys {
            if let name = info[key] as? String, !name.isEmpty {
                return name
            }
        }
        let fileName = bundleURL.lastPathComponent
        return bundleURL.pathExtension == Self.bundleExtension ? bundleURL.deletingPathExtension().lastPathComponent : fileName
    }
}

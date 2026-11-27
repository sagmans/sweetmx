import Foundation

/// Decides whether an app may be removed and gathers the facts the later steps need.
///
/// It exists as one decision point so the refusal rules cannot be skipped by a caller: nothing
/// downstream accepts a path, only the `UninstallTarget` this returns. It reads only through the
/// injected seams, so tests never touch a real app.
nonisolated struct UninstallTargetResolver: Sendable {
    /// The system volume holds apps that macOS needs; the symlink-resolved path is compared so a
    /// path that merely looks like a user app cannot hide one. The match ignores case because the
    /// default volume format does. `/System/Volumes/Data/...` is refused on purpose: it is a safe
    /// false positive, since user apps never live there.
    private static let systemPathPrefix = "/system/"
    private static let applePrefix = "com.apple."
    /// Apple apps a person installed on purpose and may remove. Entries ending in a dot are prefixes.
    /// Only IDs confirmed on a real install or long public are listed; an unknown `com.apple.*`
    /// app stays protected because removing a required one can break the system. A listed ID is not
    /// tied to a signature, and that is acceptable: the removal only moves the user's own item to the
    /// Trash, and an unsigned or mismatching app gets every related file locked (`identityConfirmed`).
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
    private static let contentsFolder = "Contents"
    private static let rootPath = "/"
    /// The name appears in a confirmation prompt; the cap keeps a hostile name from filling it.
    private static let displayNameMaxLength = 120
    private static let nameSeparator: Character = " "
    /// Characters that can hide or reorder text (controls, bidi overrides, zero-width marks, line breaks).
    private static let strippedCategories: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator,
    ]
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

    /// The path is normalized first so `..` or a trailing slash cannot hide a link, and the link
    /// check runs before any read because a link could make later checks look at a different app
    /// than the one the Trash move would hit.
    func resolve(bundlePath: String) -> Result<UninstallTarget, UninstallRefusal> {
        guard bundlePath.hasPrefix(Self.rootPath) else { return .failure(.notAnApplication) }
        let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        if fileSystem.isSymbolicLink(at: bundleURL) {
            return .failure(.symlinkedApp)
        }
        if fileSystem.resolvingSymlinks(bundleURL).path.lowercased().hasPrefix(Self.systemPathPrefix) {
            return .failure(.systemApp)
        }
        guard bundleURL.pathExtension.lowercased() == Self.bundleExtension, isDirectory(bundleURL) else {
            return .failure(.notAnApplication)
        }
        // A link inside the bundle could borrow another app's Info.plist and so its identity.
        let contentsURL = bundleURL.appendingPathComponent(Self.contentsFolder)
        let plistURL = Self.infoPlistComponents.reduce(bundleURL) { $0.appendingPathComponent($1) }
        if fileSystem.isSymbolicLink(at: contentsURL) || fileSystem.isSymbolicLink(at: plistURL) {
            return .failure(.symlinkedApp)
        }
        guard let info = Self.readInfo(of: bundleURL, fileSystem: fileSystem),
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

    /// The related-item scan reads the bundle ID of a second app with the same name; sharing this
    /// reader keeps one rule for what counts as a readable, well formed ID.
    static func bundleID(ofBundleAt bundleURL: URL, fileSystem: FileSystemProtocol) -> String? {
        guard let id = readInfo(of: bundleURL, fileSystem: fileSystem)?[bundleIDKey] as? String,
              isWellFormed(bundleID: id)
        else { return nil }
        return id
    }

    private static func readInfo(of bundleURL: URL, fileSystem: FileSystemProtocol) -> [String: Any]? {
        let plistURL = Self.infoPlistComponents.reduce(bundleURL) { $0.appendingPathComponent($1) }
        guard let data = fileSystem.readData(at: plistURL, maxBytes: infoPlistMaxBytes) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private func isRequiredAppleApp(_ bundleID: String) -> Bool {
        guard bundleID.lowercased().hasPrefix(Self.applePrefix) else { return false }
        return !Self.removableAppleIDs.contains { entry in
            entry.hasSuffix(String(Self.bundleIDSeparator)) ? bundleID.hasPrefix(entry) : bundleID == entry
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileSystem.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func displayName(from info: [String: Any], bundleURL: URL) -> String {
        let candidates = Self.displayNameKeys.compactMap { info[$0] as? String }
            + [bundleURL.deletingPathExtension().lastPathComponent]
        for candidate in candidates {
            let name = Self.sanitized(candidate)
            if !name.isEmpty {
                return name
            }
        }
        return Self.sanitized(bundleURL.lastPathComponent)
    }

    /// One short, visible line: the name is shown where a person decides to remove an app.
    private static func sanitized(_ name: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                line.append(Unicode.Scalar(String(nameSeparator))!)
            } else if !strippedCategories.contains(scalar.properties.generalCategory) {
                line.append(scalar)
            }
        }
        let words = String(line).split(separator: nameSeparator, omittingEmptySubsequences: true)
        return String(words.joined(separator: String(nameSeparator)).prefix(displayNameMaxLength))
    }
}

import Foundation

/// Finds the files an app leaves in the user's Library and decides which ones the person may tick.
///
/// A wrong match would let someone trash another app's data, so the scan lists only exact bundle ID
/// names, a few certain name matches and Homebrew's own cleanup list, and it locks every row it is
/// not sure about. It reads only through the injected seams, so tests never touch a real Library.
nonisolated struct RelatedItemScanner: Sendable {
    /// One place in the Library where an app leaves data under its bundle ID.
    private struct Rule {
        let folder: String
        let suffix: String
        let kind: RelatedItem.Kind
    }

    /// A row that passed the file checks and waits for its lock and size.
    private struct Candidate {
        let url: URL
        let kind: RelatedItem.Kind
        let match: RelatedItem.Match
        let isNameMatch: Bool
    }

    private static let libraryFolder = "Library"
    private static let preferencesFolder = "Preferences"
    private static let containersFolder = "Containers"
    private static let scriptsFolder = "Application Scripts"
    private static let supportFolder = "Application Support"
    private static let cachesFolder = "Caches"
    private static let logsFolder = "Logs"
    private static let webKitFolder = "WebKit"
    private static let httpStoragesFolder = "HTTPStorages"

    private static let bundleIDRules = [
        Rule(folder: preferencesFolder, suffix: ".plist", kind: .settings),
        Rule(folder: cachesFolder, suffix: "", kind: .cache),
        Rule(folder: httpStoragesFolder, suffix: "", kind: .webData),
        Rule(folder: httpStoragesFolder, suffix: ".binarycookies", kind: .webData),
        Rule(folder: webKitFolder, suffix: "", kind: .webData),
        Rule(folder: logsFolder, suffix: "", kind: .logs),
        Rule(folder: supportFolder, suffix: "", kind: .appData),
    ]
    /// macOS guards these folders; the scan lists them so the person knows they exist but never opens them.
    private static let protectedRules = [
        Rule(folder: containersFolder, suffix: "", kind: .container),
        Rule(folder: scriptsFolder, suffix: "", kind: .container),
    ]
    private static let nameRules = [
        Rule(folder: supportFolder, suffix: "", kind: .appData),
        Rule(folder: cachesFolder, suffix: "", kind: .cache),
        Rule(folder: logsFolder, suffix: "", kind: .logs),
    ]
    private static let protectedFolders: Set<String> = [containersFolder, scriptsFolder]
    private static let kindsByFolder: [String: RelatedItem.Kind] = [
        preferencesFolder: .settings,
        cachesFolder: .cache,
        httpStoragesFolder: .webData,
        webKitFolder: .webData,
        logsFolder: .logs,
        containersFolder: .container,
        scriptsFolder: .container,
    ]
    /// Short names such as "Go" match too many unrelated folders to trust.
    private static let minimumNameLength = 4
    /// Stops a crafted Library folder from stalling the scan.
    private static let folderListLimit = 10000
    /// Entry budget for sizing one item, so a huge cache shows "size unknown" instead of blocking.
    private static let sizeEntryLimit = 20000
    private static let bundleExtension = "app"
    private static let pathSeparator = "/"

    private let fileSystem: FileSystemProtocol

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem
    }

    /// `otherApps` is the rest of the index, to detect a shared name or bundle ID.
    func scan(_ target: UninstallTarget, otherApps: [ApplicationInfo], homebrew: HomebrewReceipt?) -> [RelatedItem] {
        guard UninstallTargetResolver.isWellFormed(bundleID: target.bundleID) else { return [] }
        let library = URL(fileURLWithPath: fileSystem.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(Self.libraryFolder)
        let others = otherApps.filter { $0.bundlePath != target.bundleURL.path }
        let secondCopy = hasSecondCopy(of: target, among: others)
        let nameIsCertain = target.displayName.count >= Self.minimumNameLength
            && !others.contains { $0.name.caseInsensitiveCompare(target.displayName) == .orderedSame }

        var candidates = bundleIDCandidates(target, library: library)
        candidates += nameCandidates(target, library: library)
        candidates += homebrewCandidates(homebrew, library: library)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.path).inserted }.map { candidate in
            let isProtected = Self.isProtected(candidate.url, library: library)
            return RelatedItem(
                url: candidate.url,
                kind: candidate.kind,
                match: candidate.match,
                sizeBytes: isProtected ? nil : fileSystem.allocatedSize(at: candidate.url, limit: Self.sizeEntryLimit),
                lock: lock(
                    identityConfirmed: target.identityConfirmed,
                    secondCopy: secondCopy,
                    isProtected: isProtected,
                    nameNotCertain: candidate.isNameMatch && !nameIsCertain
                )
            )
        }
    }

    /// Precedence is fixed so the reason a row shows never depends on dictionary or scan order.
    private func lock(identityConfirmed: Bool, secondCopy: Bool, isProtected: Bool, nameNotCertain: Bool) -> RelatedItem.Lock? {
        if !identityConfirmed {
            return .identityNotConfirmed
        }
        if secondCopy {
            return .secondCopyInstalled
        }
        if isProtected {
            return .protectedByMacOS
        }
        if nameNotCertain {
            return .nameNotCertain
        }
        return nil
    }

    private static func isProtected(_ url: URL, library: URL) -> Bool {
        firstComponent(of: url, in: library).map(protectedFolders.contains) ?? false
    }

    private static func firstComponent(of url: URL, in library: URL) -> String? {
        let prefix = library.path + pathSeparator
        guard url.path.hasPrefix(prefix) else { return nil }
        return url.path.dropFirst(prefix.count).split(separator: Character(pathSeparator)).first.map(String.init)
    }

    /// A second install with the same bundle ID shares every file, so removing one app's data would
    /// break the other; only apps that look alike are read, because nothing else can share the ID.
    private func hasSecondCopy(of target: UninstallTarget, among others: [ApplicationInfo]) -> Bool {
        let fileName = target.bundleURL.lastPathComponent
        return others.contains { app in
            let sameName = app.name.caseInsensitiveCompare(target.displayName) == .orderedSame
            let sameFile = (app.bundlePath as NSString).lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame
            guard sameName || sameFile else { return false }
            return UninstallTargetResolver.bundleID(
                ofBundleAt: URL(fileURLWithPath: app.bundlePath), fileSystem: fileSystem
            ) == target.bundleID
        }
    }

    private func bundleIDCandidates(_ target: UninstallTarget, library: URL) -> [Candidate] {
        (Self.bundleIDRules + Self.protectedRules).compactMap { rule in
            let folder = library.appendingPathComponent(rule.folder)
            return accepted(folder: folder, name: target.bundleID + rule.suffix).map {
                Candidate(url: $0, kind: rule.kind, match: .bundleID, isNameMatch: false)
            }
        }
    }

    private func nameCandidates(_ target: UninstallTarget, library: URL) -> [Candidate] {
        Self.nameRules.flatMap { rule -> [Candidate] in
            let folder = library.appendingPathComponent(rule.folder)
            let entries = (try? fileSystem.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [], limit: Self.folderListLimit
            )) ?? []
            return entries.compactMap { entry in
                let name = entry.lastPathComponent
                guard name.caseInsensitiveCompare(target.displayName) == .orderedSame else { return nil }
                return accepted(folder: folder, name: name).map {
                    Candidate(url: $0, kind: rule.kind, match: .name, isNameMatch: true)
                }
            }
        }
    }

    private func homebrewCandidates(_ receipt: HomebrewReceipt?, library: URL) -> [Candidate] {
        guard let receipt else { return [] }
        return receipt.cleanupPaths.compactMap { url in
            guard let first = Self.firstComponent(of: url, in: library) else { return nil }
            let folder = url.deletingLastPathComponent()
            guard !hasLinkedAncestor(of: folder, below: library),
                  let checked = accepted(folder: folder, name: url.lastPathComponent, library: library) else { return nil }
            return Candidate(url: checked, kind: Self.kindsByFolder[first] ?? .appData, match: .homebrew, isNameMatch: false)
        }
    }

    /// A nested Homebrew path can cross a linked folder that still resolves inside the Library, into
    /// another app's data; every folder between the Library and the item must be a real one.
    private func hasLinkedAncestor(of folder: URL, below library: URL) -> Bool {
        var current = folder
        while current.path.count > library.path.count {
            if fileSystem.isSymbolicLink(at: current) {
                return true
            }
            current = current.deletingLastPathComponent()
        }
        return false
    }

    /// The one gate every row passes: a link or an item that really lives elsewhere could point the
    /// Trash move at someone else's data. With `library` set (Homebrew paths, which may be nested)
    /// the item must resolve inside the Library; in every case the folder must not be a link and the
    /// item must sit directly in it.
    private func accepted(folder: URL, name: String, library: URL? = nil) -> URL? {
        let url = folder.appendingPathComponent(name)
        guard !name.contains(Self.pathSeparator),
              !fileSystem.isSymbolicLink(at: folder),
              !fileSystem.isSymbolicLink(at: url),
              fileSystem.fileExists(atPath: url.path)
        else { return nil }
        let resolved = fileSystem.resolvingSymlinks(url)
        let resolvedFolder = fileSystem.resolvingSymlinks(folder)
        guard resolved.deletingLastPathComponent().path == resolvedFolder.path else { return nil }
        if let library {
            let resolvedLibrary = fileSystem.resolvingSymlinks(library).path + Self.pathSeparator
            guard resolved.path.hasPrefix(resolvedLibrary) else { return nil }
        }
        return url
    }
}

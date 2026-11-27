import Foundation

/// Finds the files an app leaves in the user's Library and decides which ones the person may tick.
///
/// A wrong match would let someone trash another app's data, so the scan lists only exact bundle ID
/// names, a few certain name matches and Homebrew's own cleanup list, and it locks every row it is
/// not sure about. It reads only through the injected seams, so tests never touch a real Library.
nonisolated struct RelatedItemScanner: Sendable {
    /// What the scan knows about the other installed apps. An index that has not loaded, or that does
    /// not list the target yet, cannot rule out a second copy or a same-named app, so the scan must
    /// lock as if both exist instead of reading an empty list as "no other apps".
    enum InstalledApps: Sendable {
        /// The index is loaded and lists the target; the array is every indexed app.
        case listed([ApplicationInfo])
        /// The index is missing or stale; every row is locked.
        case unknown
    }

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
        /// True when the scan is not sure the item belongs to this app; the row is then locked.
        let isUncertain: Bool
    }

    /// Shared with `HomebrewReceipt`, which expands `~/Library/` paths, so one place owns the name.
    static let libraryFolder = "Library"
    private static let preferencesFolder = "Preferences"
    private static let containersFolder = "Containers"
    private static let scriptsFolder = "Application Scripts"
    private static let groupContainersFolder = "Group Containers"
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
        Rule(folder: groupContainersFolder, suffix: "", kind: .container),
    ]
    private static let nameRules = [
        Rule(folder: supportFolder, suffix: "", kind: .appData),
        Rule(folder: cachesFolder, suffix: "", kind: .cache),
        Rule(folder: logsFolder, suffix: "", kind: .logs),
    ]
    private static let protectedFolders: Set<String> = [containersFolder, scriptsFolder, groupContainersFolder]
    private static let kindsByFolder: [String: RelatedItem.Kind] = [
        preferencesFolder: .settings,
        cachesFolder: .cache,
        httpStoragesFolder: .webData,
        webKitFolder: .webData,
        logsFolder: .logs,
        supportFolder: .appData,
    ]
    /// Homebrew rows are selectable only one level inside these folders, the same places the
    /// bundle ID rules look, so a cleanup list cannot reach Keychains, shared data or other apps.
    private static let selectableFolders: Set<String> = Set(kindsByFolder.keys)
    /// Endings a Library item may add to a bundle ID or name.
    private static let knownSuffixes = [".plist", ".binarycookies", ".savedState"]
    private static let bundleIDSeparator = "."
    private static let homebrewSelectableDepth = 2
    private static let protectedDepth = 2
    /// Short names such as "Go" match too many unrelated folders to trust.
    private static let minimumNameLength = 4
    /// Stops a crafted Library folder from stalling the scan.
    private static let folderListLimit = 10000
    /// Entry budget for sizing one item, so a huge cache shows "size unknown" instead of blocking.
    static let sizeEntryLimit = 20000
    private static let bundleExtension = "app"
    private static let pathSeparator = "/"

    private let fileSystem: FileSystemProtocol

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem
    }

    /// `installedApps` is the app index, to detect a shared name or bundle ID; when it is unknown, the
    /// scan fails closed and locks every row it would otherwise offer.
    func scan(_ target: UninstallTarget, installedApps: InstalledApps, homebrew: HomebrewReceipt?) -> [RelatedItem] {
        guard UninstallTargetResolver.isWellFormed(bundleID: target.bundleID) else { return [] }
        let library = URL(fileURLWithPath: fileSystem.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(Self.libraryFolder)
        let secondCopy: Bool
        let nameIsCertain: Bool
        let listIsReady: Bool
        switch installedApps {
        case .unknown:
            secondCopy = false
            nameIsCertain = false
            listIsReady = false
        case let .listed(apps):
            listIsReady = true
            let ownPath = Self.standardPath(target.bundleURL.path)
            let others = apps.filter { Self.standardPath($0.bundlePath) != ownPath }
            secondCopy = hasSecondCopy(of: target, among: others)
            nameIsCertain = target.displayName.count >= Self.minimumNameLength
                && !others.contains { $0.name.caseInsensitiveCompare(target.displayName) == .orderedSame }
        }

        var candidates = bundleIDCandidates(target, library: library)
        candidates += nameCandidates(target, library: library, isCertain: nameIsCertain)
        candidates += homebrewCandidates(homebrew, target: target, library: library, nameIsCertain: nameIsCertain)

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
                    listIsReady: listIsReady,
                    nameNotCertain: candidate.isUncertain
                )
            )
        }
    }

    /// Precedence is fixed so the reason a row shows never depends on dictionary or scan order.
    private func lock(
        identityConfirmed: Bool, secondCopy: Bool, isProtected: Bool, listIsReady: Bool, nameNotCertain: Bool
    ) -> RelatedItem.Lock? {
        if !identityConfirmed {
            return .identityNotConfirmed
        }
        if secondCopy {
            return .secondCopyInstalled
        }
        if isProtected {
            return .protectedByMacOS
        }
        if !listIsReady {
            return .appListNotReady
        }
        if nameNotCertain {
            return .nameNotCertain
        }
        return nil
    }

    /// One spelling per bundle path, so `/Applications/./X.app` and `/Applications/X.app` count as the
    /// same app. Shared with the sheet, which checks that the index lists the target.
    static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
    /// Fails closed when the other app's ID cannot be read.
    private func hasSecondCopy(of target: UninstallTarget, among others: [ApplicationInfo]) -> Bool {
        let fileName = target.bundleURL.lastPathComponent
        return others.contains { app in
            let sameName = app.name.caseInsensitiveCompare(target.displayName) == .orderedSame
            let sameFile = (app.bundlePath as NSString).lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame
            guard sameName || sameFile else { return false }
            // An unreadable ID cannot be ruled out, so it counts as shared.
            let otherID = UninstallTargetResolver.bundleID(
                ofBundleAt: URL(fileURLWithPath: app.bundlePath), fileSystem: fileSystem
            )
            return otherID == nil || otherID == target.bundleID
        }
    }

    /// Folders that macOS guards are checked by name only and never listed; every other folder is
    /// listed so the on-disk name must match exactly, because a case-insensitive volume would
    /// otherwise answer "exists" for `Com.X.App`.
    private func bundleIDCandidates(_ target: UninstallTarget, library: URL) -> [Candidate] {
        let listed = Self.bundleIDRules.compactMap { rule -> Candidate? in
            let folder = library.appendingPathComponent(rule.folder)
            let wanted = target.bundleID + rule.suffix
            guard entries(of: folder).contains(where: { $0.lastPathComponent == wanted }) else { return nil }
            return accepted(folder: folder, name: wanted).map {
                Candidate(url: $0, kind: rule.kind, match: .bundleID, isUncertain: false)
            }
        }
        let guarded = Self.protectedRules.compactMap { rule -> Candidate? in
            accepted(folder: library.appendingPathComponent(rule.folder), name: target.bundleID + rule.suffix).map {
                Candidate(url: $0, kind: rule.kind, match: .bundleID, isUncertain: false)
            }
        }
        return listed + guarded
    }

    private func entries(of folder: URL) -> [URL] {
        (try? fileSystem.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [], limit: Self.folderListLimit
        )) ?? []
    }

    private func nameCandidates(_ target: UninstallTarget, library: URL, isCertain: Bool) -> [Candidate] {
        Self.nameRules.flatMap { rule -> [Candidate] in
            let folder = library.appendingPathComponent(rule.folder)
            return entries(of: folder).compactMap { entry in
                let name = entry.lastPathComponent
                guard name.caseInsensitiveCompare(target.displayName) == .orderedSame else { return nil }
                return accepted(folder: folder, name: name).map {
                    Candidate(url: $0, kind: rule.kind, match: .name, isUncertain: !isCertain)
                }
            }
        }
    }

    /// The receipt only says where the cask's own data may be, so a row is ticked by default only when
    /// its name also ties it to this app; anything else is shown locked.
    private func homebrewCandidates(
        _ receipt: HomebrewReceipt?, target: UninstallTarget, library: URL, nameIsCertain: Bool
    ) -> [Candidate] {
        guard let receipt else { return [] }
        return receipt.cleanupPaths.compactMap { url in
            guard let first = Self.firstComponent(of: url, in: library) else { return nil }
            let depth = url.path.dropFirst(library.path.count + 1).split(separator: Character(Self.pathSeparator)).count
            if Self.protectedFolders.contains(first) {
                // Never stat-ed: the row exists only to tell the person the item is there.
                guard depth == Self.protectedDepth else { return nil }
                return Candidate(url: url, kind: .container, match: .homebrew, isUncertain: false)
            }
            guard Self.selectableFolders.contains(first), depth == Self.homebrewSelectableDepth,
                  let checked = accepted(folder: url.deletingLastPathComponent(), name: url.lastPathComponent)
            else { return nil }
            let tied = Self.tiesToApp(url.lastPathComponent, target: target, nameIsCertain: nameIsCertain)
            return Candidate(url: checked, kind: Self.kindsByFolder[first] ?? .appData, match: .homebrew, isUncertain: !tied)
        }
    }

    /// The name must be the bundle ID (or the ID plus a dotted part, as helper apps use) or the
    /// app's own display name; a shared vendor folder or another app's ID does not qualify.
    private static func tiesToApp(_ name: String, target: UninstallTarget, nameIsCertain: Bool) -> Bool {
        var base = name
        if let suffix = knownSuffixes.first(where: { name.hasSuffix($0) && name.count > $0.count }) {
            base = String(name.dropLast(suffix.count))
        }
        if base == target.bundleID || base.hasPrefix(target.bundleID + bundleIDSeparator) {
            return true
        }
        return nameIsCertain && base.caseInsensitiveCompare(target.displayName) == .orderedSame
    }

    /// The one gate every row passes: a link or an item that really lives elsewhere could point the
    /// Trash move at someone else's data. The folder must not be a link and the item must not be a
    /// link and must sit directly in the folder.
    private func accepted(folder: URL, name: String) -> URL? {
        let url = folder.appendingPathComponent(name)
        guard !name.contains(Self.pathSeparator),
              !fileSystem.isSymbolicLink(at: folder),
              !fileSystem.isSymbolicLink(at: url),
              fileSystem.fileExists(atPath: url.path)
        else { return nil }
        let resolved = fileSystem.resolvingSymlinks(url)
        let resolvedFolder = fileSystem.resolvingSymlinks(folder)
        guard resolved.deletingLastPathComponent().path == resolvedFolder.path else { return nil }
        return url
    }
}

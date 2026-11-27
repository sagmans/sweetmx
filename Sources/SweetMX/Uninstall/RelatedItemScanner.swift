import Foundation

/// Finds the files an app leaves in the user's Library and decides which ones the person may tick.
///
/// A wrong match would let someone trash another app's data, so the scan lists only exact bundle ID
/// names, a few certain name matches and Homebrew's own cleanup list, and it locks every row it is
/// not sure about. It reads only through the injected seams, so tests never touch a real Library.
nonisolated struct RelatedItemScanner: Sendable {
    /// What the scan knows about the other installed apps. An index that has not loaded, or that does
    /// not list the target yet, cannot rule out a second copy or a same-named app, so the scan must
    /// lock as if both exist instead of reading an empty list as "no other apps". Built only here, from
    /// the raw index, so no caller can hand the scan a list that skipped that rule.
    private struct InstalledApps {
        /// Every indexed app but the target; nil when the index is missing or does not list the target.
        let others: [ApplicationInfo]?

        init(apps: [ApplicationInfo]?, target: UninstallTarget) {
            let ownPath = RelatedItemScanner.standardPath(target.bundleURL.path)
            guard let apps, apps.contains(where: { RelatedItemScanner.standardPath($0.bundlePath) == ownPath }) else {
                others = nil
                return
            }
            others = apps.filter { RelatedItemScanner.standardPath($0.bundlePath) != ownPath }
        }
    }

    /// One place in the Library where an app leaves data under its bundle ID.
    private struct Rule {
        let folder: String
        let suffix: String
        let kind: RelatedItem.Kind

        /// A rule in a folder macOS guards lists its item by name only and always locks it.
        var isProtected: Bool {
            RelatedItemScanner.guardedFolders.contains(folder)
        }
    }

    /// A row that passed the file checks and waits for its lock and size.
    private struct Candidate {
        let url: URL
        let kind: RelatedItem.Kind
        let match: RelatedItem.Match
        /// True when the scan is not sure the item belongs to this app; the row is then locked.
        let isUncertain: Bool
        /// Set where the candidate is made, from the folder it was found in, so the lock and the size
        /// read never have to work it out again from the path.
        let isProtected: Bool
    }

    private static let preferencesFolder = "Preferences"
    private static let containersFolder = "Containers"
    private static let scriptsFolder = "Application Scripts"
    private static let groupContainersFolder = "Group Containers"
    private static let supportFolder = "Application Support"
    private static let cachesFolder = "Caches"
    private static let logsFolder = "Logs"
    private static let webKitFolder = "WebKit"
    private static let httpStoragesFolder = "HTTPStorages"

    /// macOS guards these folders; the scan lists their items so the person knows they exist but never
    /// opens them. A Homebrew row in any of them is shown locked and never read.
    private static let guardedFolders: Set<String> = [containersFolder, scriptsFolder, groupContainersFolder]
    /// Every place the scan looks for the exact bundle ID. `Group Containers` has no rule: its folders
    /// are named after group IDs, which are almost never the bundle ID, and looking there may raise a
    /// privacy prompt. The guarded rules come last, so the rows read "what can move" first.
    private static let bundleIDRules = [
        Rule(folder: preferencesFolder, suffix: ".plist", kind: .settings),
        Rule(folder: cachesFolder, suffix: "", kind: .cache),
        Rule(folder: httpStoragesFolder, suffix: "", kind: .webData),
        Rule(folder: httpStoragesFolder, suffix: ".binarycookies", kind: .webData),
        Rule(folder: webKitFolder, suffix: "", kind: .webData),
        Rule(folder: logsFolder, suffix: "", kind: .logs),
        Rule(folder: supportFolder, suffix: "", kind: .appData),
        Rule(folder: containersFolder, suffix: "", kind: .container),
        Rule(folder: scriptsFolder, suffix: "", kind: .container),
    ]
    private static let nameRules = [
        Rule(folder: supportFolder, suffix: "", kind: .appData),
        Rule(folder: cachesFolder, suffix: "", kind: .cache),
        Rule(folder: logsFolder, suffix: "", kind: .logs),
    ]
    /// Homebrew rows are selectable only one level inside the folders the unguarded bundle ID rules
    /// read, and take their kind from those rules, so a cleanup list cannot reach Keychains, shared
    /// data or other apps.
    private static let kindsByFolder: [String: RelatedItem.Kind] = Dictionary(
        bundleIDRules.filter { !$0.isProtected }.map { ($0.folder, $0.kind) },
        uniquingKeysWith: { first, _ in first }
    )
    /// Endings a Library item may add to a bundle ID or name.
    private static let knownSuffixes = [".plist", ".binarycookies", ".savedState"]
    /// Short names such as "Go" match too many unrelated folders to trust.
    private static let minimumNameLength = 4
    /// Stops a crafted Library folder from stalling the scan.
    private static let folderListLimit = 10000
    /// Entry budget for sizing one item, so a huge cache shows "size unknown" instead of blocking.
    static let sizeEntryLimit = 20000
    private static let pathSeparator = "/"

    private let fileSystem: FileSystemProtocol
    private let library: UserLibrary

    /// `library` is the value the executor checks against, so every path the scan builds passes the
    /// move check unless the disk really changed.
    init(fileSystem: FileSystemProtocol, library: UserLibrary) {
        self.fileSystem = fileSystem
        self.library = library
    }

    /// `installedApps` is the raw app index, to detect a shared name or bundle ID; when it is missing
    /// or does not list the target, the scan fails closed and locks every row it would otherwise offer.
    /// `registeredCopies` is what the system knows under the target's bundle ID, which also covers
    /// copies the index never sees (Downloads, an external disk).
    func scan(
        _ target: UninstallTarget, installedApps: [ApplicationInfo]?, registeredCopies: [URL], homebrew: HomebrewReceipt?
    ) -> [RelatedItem] {
        guard UninstallTargetResolver.isWellFormed(bundleID: target.bundleID) else { return [] }
        let ownPath = Self.standardPath(target.bundleURL.path)
        let registeredSecondCopy = registeredCopies.contains { Self.standardPath($0.path) != ownPath }
        let others = InstalledApps(apps: installedApps, target: target).others
        let listIsReady = others != nil
        let secondCopy = registeredSecondCopy || others.map { hasSecondCopy(of: target, among: $0) } == true
        let nameIsCertain = others.map { others in
            target.displayName.count >= Self.minimumNameLength
                && !others.contains { Self.sharesName($0, with: target.displayName) }
        } ?? false

        var candidates = bundleIDCandidates(target)
        candidates += nameCandidates(target, isCertain: nameIsCertain)
        candidates += homebrewCandidates(homebrew, target: target, nameIsCertain: nameIsCertain)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.path).inserted }.map { candidate in
            RelatedItem(
                url: candidate.url,
                kind: candidate.kind,
                match: candidate.match,
                sizeBytes: candidate.isProtected
                    ? nil : fileSystem.allocatedSize(at: candidate.url, limit: Self.sizeEntryLimit),
                lock: lock(
                    identityConfirmed: target.identityConfirmed,
                    secondCopy: secondCopy,
                    isProtected: candidate.isProtected,
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
    /// same app, in the index and in the system's answer alike.
    private static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// A second install with the same bundle ID shares every file, so removing one app's data would
    /// break the other. Every other indexed app is read, because a copy can carry any file name and
    /// any Finder name (`Xcode-beta.app` beside `Xcode.app`). Fails closed when an ID cannot be read.
    private func hasSecondCopy(of target: UninstallTarget, among others: [ApplicationInfo]) -> Bool {
        others.contains { app in
            // An unreadable ID cannot be ruled out, so it counts as shared.
            let otherID = UninstallTargetResolver.bundleID(
                ofBundleAt: URL(fileURLWithPath: app.bundlePath), fileSystem: fileSystem
            )
            return otherID == nil || otherID == target.bundleID
        }
    }

    /// The target's name comes from its Info.plist, while the index lists Finder's name, which usually
    /// follows the file name; either one matching makes a name row uncertain.
    private static func sharesName(_ app: ApplicationInfo, with name: String) -> Bool {
        let fileName = URL(fileURLWithPath: app.bundlePath).deletingPathExtension().lastPathComponent
        return [app.name, fileName].contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Folders that macOS guards are checked by name only and never listed; every other folder is
    /// listed so the on-disk name must match exactly, because a case-insensitive volume would
    /// otherwise answer "exists" for `Com.X.App`.
    private func bundleIDCandidates(_ target: UninstallTarget) -> [Candidate] {
        Self.bundleIDRules.compactMap { rule -> Candidate? in
            let folder = folderURL(rule.folder)
            let wanted = target.bundleID + rule.suffix
            let found: URL?
            if rule.isProtected {
                found = guardedItem(in: folder, name: wanted)
            } else {
                guard entries(of: folder).contains(where: { $0.lastPathComponent == wanted }) else { return nil }
                found = accepted(folder: folder, name: wanted)
            }
            return found.map {
                Candidate(url: $0, kind: rule.kind, match: .bundleID, isUncertain: false, isProtected: rule.isProtected)
            }
        }
    }

    /// A top-level Library folder the rules name; every row's path starts from the shared root.
    private func folderURL(_ name: String) -> URL {
        library.root.appendingPathComponent(name)
    }

    /// A guarded row is only ever shown locked, so it needs no more than one look at the item itself,
    /// without following it. Every further read inside a folder macOS guards (a stat, a link
    /// resolution, a listing) could raise a privacy prompt for another app's data. A link, a missing
    /// item or an unreadable one gives no row.
    private func guardedItem(in folder: URL, name: String) -> URL? {
        guard !name.contains(Self.pathSeparator) else { return nil }
        // The hint keeps URL building from reading the item; the one look below is the only read.
        let url = folder.appendingPathComponent(name, isDirectory: false)
        switch try? fileSystem.itemKind(at: url) {
        case .directory, .other:
            return url
        case .symbolicLink, .missing, nil:
            return nil
        }
    }

    private func entries(of folder: URL) -> [URL] {
        (try? fileSystem.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [], limit: Self.folderListLimit
        )) ?? []
    }

    private func nameCandidates(_ target: UninstallTarget, isCertain: Bool) -> [Candidate] {
        Self.nameRules.flatMap { rule -> [Candidate] in
            let folder = folderURL(rule.folder)
            return entries(of: folder).compactMap { entry in
                let name = entry.lastPathComponent
                guard name.caseInsensitiveCompare(target.displayName) == .orderedSame else { return nil }
                return accepted(folder: folder, name: name).map {
                    Candidate(url: $0, kind: rule.kind, match: .name, isUncertain: !isCertain, isProtected: rule.isProtected)
                }
            }
        }
    }

    /// The receipt only says where the cask's own data may be, so a row can be ticked only when its name
    /// also ties it to this app; anything else is shown locked. Rows sit exactly one level inside a
    /// known folder, the Library's minimum depth.
    private func homebrewCandidates(
        _ receipt: HomebrewReceipt?, target: UninstallTarget, nameIsCertain: Bool
    ) -> [Candidate] {
        guard let receipt else { return [] }
        return receipt.cleanupPaths.compactMap { url in
            guard let parts = library.components(of: url), parts.count == UserLibrary.minimumDepth,
                  let first = parts.first
            else { return nil }
            if Self.guardedFolders.contains(first) {
                // Never read: the row exists only to tell the person the item is there.
                return Candidate(url: url, kind: .container, match: .homebrew, isUncertain: false, isProtected: true)
            }
            guard let kind = Self.kindsByFolder[first],
                  let checked = accepted(folder: url.deletingLastPathComponent(), name: url.lastPathComponent)
            else { return nil }
            let tied = Self.tiesToApp(url.lastPathComponent, target: target, nameIsCertain: nameIsCertain)
            return Candidate(url: checked, kind: kind, match: .homebrew, isUncertain: !tied, isProtected: false)
        }
    }

    /// The name must be exactly the bundle ID or the app's certain display name. The ID plus a dotted
    /// part is not enough: another app can own that ID (`com.google.Chrome.canary` beside
    /// `com.google.Chrome`), so such a row stays listed but locked, like a shared vendor folder.
    private static func tiesToApp(_ name: String, target: UninstallTarget, nameIsCertain: Bool) -> Bool {
        var base = name
        if let suffix = knownSuffixes.first(where: { name.hasSuffix($0) && name.count > $0.count }) {
            base = String(name.dropLast(suffix.count))
        }
        if base == target.bundleID {
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

import Foundation

/// What Homebrew recorded when it installed an app, used to find leftovers that no bundle ID or
/// name rule would catch.
///
/// Homebrew's own cleanup list is the most precise source for a cask app, but the receipt is
/// untrusted input, so every path is cut down to plain folders inside the user's Library before the
/// scanner sees it.
nonisolated struct HomebrewReceipt: Equatable, Sendable {
    let token: String
    /// Already limited to the user's Library, free of wildcards and parent references.
    let cleanupPaths: [URL]

    private static let caskroomRoots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    private static let metadataFolder = ".metadata"
    private static let receiptFile = "INSTALL_RECEIPT.json"
    /// Real receipts are a few KB; the bound stops a crafted file from exhausting memory.
    private static let receiptMaxBytes = 1_048_576
    /// A Caskroom holds one folder per installed cask; the bound stops a crafted folder from stalling the scan.
    private static let caskroomListLimit = 5000
    private static let tokenStart = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let tokenBody = tokenStart.union(CharacterSet(charactersIn: "@+._-"))
    private static let artifactKeys = ["uninstall_artifacts", "artifacts"]
    private static let appKey = "app"
    private static let zapKey = "zap"
    private static let cleanupKeys = ["trash", "delete", "rmdir"]
    private static let homePrefix = "~/" + UserLibrary.folderName + "/"
    private static let pathSeparator: Character = "/"
    private static let forbiddenComponents: Set<String> = ["..", "."]
    private static let globCharacters = CharacterSet(charactersIn: "*?[]{}")

    /// Only `find` builds a receipt, so no caller can pass one whose link to the installed copy was
    /// never checked.
    private init(token: String, cleanupPaths: [URL]) {
        self.token = token
        self.cleanupPaths = cleanupPaths
    }

    /// Nil unless exactly one cask receipt names this app and the Caskroom holds a link that resolves
    /// to this very copy, so a same-named app elsewhere never inherits another install's cleanup list.
    /// `library` is the scan's own value, so cleanup paths and scan paths share one spelling.
    static func find(for target: UninstallTarget, library: UserLibrary, fileSystem: FileSystemProtocol) -> HomebrewReceipt? {
        let appFileName = target.bundleURL.lastPathComponent
        var matches: [HomebrewReceipt] = []
        for root in caskroomRoots {
            let rootURL = URL(fileURLWithPath: root)
            for entry in list(rootURL, fileSystem) {
                let token = entry.lastPathComponent
                guard isValid(token: token), !fileSystem.isSymbolicLink(at: entry),
                      linksToTarget(tokenFolder: entry, target: target, fileSystem: fileSystem)
                else { continue }
                let metadataURL = entry.appendingPathComponent(metadataFolder)
                let receiptURL = metadataURL.appendingPathComponent(receiptFile)
                guard !fileSystem.isSymbolicLink(at: metadataURL), !fileSystem.isSymbolicLink(at: receiptURL),
                      let data = fileSystem.readData(at: receiptURL, maxBytes: receiptMaxBytes),
                      let receipt = parse(data, token: token, appFileName: appFileName, library: library)
                else { continue }
                matches.append(receipt)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func list(_ folder: URL, _ fileSystem: FileSystemProtocol) -> [URL] {
        (try? fileSystem.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [], limit: caskroomListLimit
        )) ?? []
    }

    /// Homebrew leaves `<token>/<version>/<App>.app` as a link to the installed app, sometimes one
    /// folder deeper. That link is the only proof that this receipt belongs to this copy.
    private static func linksToTarget(tokenFolder: URL, target: UninstallTarget, fileSystem: FileSystemProtocol) -> Bool {
        let appFileName = target.bundleURL.lastPathComponent
        let targetPath = fileSystem.resolvingSymlinks(target.bundleURL).standardizedFileURL.path
        func isLink(_ url: URL) -> Bool {
            url.lastPathComponent == appFileName && fileSystem.isSymbolicLink(at: url)
                && fileSystem.resolvingSymlinks(url).standardizedFileURL.path == targetPath
        }
        for version in list(tokenFolder, fileSystem)
            where version.lastPathComponent != metadataFolder && !fileSystem.isSymbolicLink(at: version)
        {
            for child in list(version, fileSystem) {
                if isLink(child) {
                    return true
                }
                guard !fileSystem.isSymbolicLink(at: child) else { continue }
                if list(child, fileSystem).contains(where: isLink) {
                    return true
                }
            }
        }
        return false
    }

    /// Anything outside the set is refused, including a trailing newline that a `$` pattern lets pass.
    private static func isValid(token: String) -> Bool {
        guard let first = token.unicodeScalars.first, tokenStart.contains(first) else { return false }
        return token.unicodeScalars.allSatisfy(tokenBody.contains)
    }

    /// Wrong types are skipped rather than trusted, so a hostile receipt can only yield fewer paths.
    private static func parse(_ data: Data, token: String, appFileName: String, library: UserLibrary) -> HomebrewReceipt? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let artifacts = artifactKeys.flatMap { (root[$0] as? [Any]) ?? [] }.compactMap { $0 as? [String: Any] }
        let namesTarget = artifacts.contains { artifact in
            strings(in: artifact[appKey]).contains { ($0 as NSString).lastPathComponent == appFileName }
        }
        guard namesTarget else { return nil }
        let zapEntries = artifacts.flatMap { artifact -> [[String: Any]] in
            guard let zap = artifact[zapKey] else { return [] }
            if let list = zap as? [Any] {
                return list.compactMap { $0 as? [String: Any] }
            }
            return (zap as? [String: Any]).map { [$0] } ?? []
        }
        var seen = Set<String>()
        let paths = zapEntries
            .flatMap { entry in cleanupKeys.flatMap { strings(in: entry[$0]) } }
            .compactMap { libraryURL(from: $0, library: library) }
            .filter { seen.insert($0.path).inserted }
        return HomebrewReceipt(token: token, cleanupPaths: paths)
    }

    /// Homebrew accepts a single string or a list for most keys.
    private static func strings(in value: Any?) -> [String] {
        if let text = value as? String {
            return [text]
        }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// A path with fewer parts than the Library's minimum depth would name a whole shared folder such
    /// as Caches, so it is dropped here as well as at the move.
    private static func libraryURL(from path: String, library: UserLibrary) -> URL? {
        guard path.hasPrefix(homePrefix), path.rangeOfCharacter(from: globCharacters) == nil else { return nil }
        let parts = path.dropFirst(homePrefix.count).split(separator: pathSeparator, omittingEmptySubsequences: false)
        guard parts.count >= UserLibrary.minimumDepth,
              parts.allSatisfy({ !$0.isEmpty && !forbiddenComponents.contains(String($0)) })
        else { return nil }
        // The hint keeps URL building from reading the disk, so a guarded path stays unread.
        return parts.reduce(library.root) { $0.appendingPathComponent(String($1), isDirectory: false) }
    }
}

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
    private static let tokenPattern = "^[a-z0-9][a-z0-9@+._-]*$"
    private static let artifactKeys = ["uninstall_artifacts", "artifacts"]
    private static let appKey = "app"
    private static let zapKey = "zap"
    private static let cleanupKeys = ["trash", "delete", "rmdir"]
    private static let homePrefix = "~/Library/"
    private static let libraryFolder = "Library"
    private static let pathSeparator: Character = "/"
    private static let forbiddenComponents: Set<String> = ["..", "."]
    private static let globCharacters = CharacterSet(charactersIn: "*?[]{}")
    /// A path with fewer parts than this would name a whole Library folder such as Caches.
    private static let minimumLibraryDepth = 2

    /// Nil unless exactly one cask receipt names this app, so two casks that claim the same app
    /// never lead to guessing whose cleanup list applies.
    static func find(for target: UninstallTarget, fileSystem: FileSystemProtocol) -> HomebrewReceipt? {
        let appFileName = target.bundleURL.lastPathComponent
        let home = fileSystem.homeDirectoryForCurrentUser
        var matches: [HomebrewReceipt] = []
        for root in caskroomRoots {
            let rootURL = URL(fileURLWithPath: root)
            let entries = (try? fileSystem.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil, options: [], limit: caskroomListLimit
            )) ?? []
            for entry in entries {
                let token = entry.lastPathComponent
                guard isValid(token: token), !fileSystem.isSymbolicLink(at: entry) else { continue }
                let receiptURL = rootURL.appendingPathComponent(token)
                    .appendingPathComponent(metadataFolder)
                    .appendingPathComponent(receiptFile)
                guard let data = fileSystem.readData(at: receiptURL, maxBytes: receiptMaxBytes),
                      let receipt = parse(data, token: token, appFileName: appFileName, home: home)
                else { continue }
                matches.append(receipt)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func isValid(token: String) -> Bool {
        token.range(of: tokenPattern, options: .regularExpression) != nil
    }

    /// Wrong types are skipped rather than trusted, so a hostile receipt can only yield fewer paths.
    private static func parse(_ data: Data, token: String, appFileName: String, home: URL) -> HomebrewReceipt? {
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
            .compactMap { libraryURL(from: $0, home: home) }
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

    private static func libraryURL(from path: String, home: URL) -> URL? {
        guard path.hasPrefix(homePrefix), path.rangeOfCharacter(from: globCharacters) == nil else { return nil }
        let parts = path.dropFirst(homePrefix.count).split(separator: pathSeparator, omittingEmptySubsequences: false)
        guard parts.count >= minimumLibraryDepth,
              parts.allSatisfy({ !$0.isEmpty && !forbiddenComponents.contains(String($0)) })
        else { return nil }
        return parts.reduce(URL(fileURLWithPath: home.path).appendingPathComponent(libraryFolder)) {
            $0.appendingPathComponent(String($1))
        }
    }
}

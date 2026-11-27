import Foundation

/// The person's `~/Library`, the only place uninstall takes related items from.
///
/// The scan, the Homebrew receipt, the final move check and the sheet's shown paths all ask this one
/// value, so they cannot disagree on where the Library is or how deep an item must sit. The home path
/// is standardized once here; a scan that built its paths from another spelling of the home folder
/// would make the move check refuse every item as changed.
nonisolated struct UserLibrary: Equatable, Sendable {
    /// The folder's name below the home folder; Homebrew writes it as `~/Library/...`.
    static let folderName = "Library"
    /// An item must sit at least this many components below the Library, so a folder that every app
    /// shares, such as `~/Library/Caches`, can never be offered or moved.
    static let minimumDepth = 2

    /// The home folder, standardized; the sheet shortens it to `~` in shown paths.
    let home: URL
    let root: URL

    /// Built once per sheet from the file system seam, so tests pass a scripted home folder.
    init(home: URL) {
        self.home = home.standardizedFileURL
        root = self.home.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private init(resolvedRoot: URL) {
        home = resolvedRoot.deletingLastPathComponent()
        root = resolvedRoot
    }

    /// The Library as it really is on disk, `~/Library` itself resolved too, for the final check that a
    /// fully resolved item still lies inside it.
    func resolvingSymlinks(using fileSystem: FileSystemProtocol) -> UserLibrary {
        UserLibrary(resolvedRoot: fileSystem.resolvingSymlinks(root))
    }

    /// The parts of `url` below the Library, or nil when it is the Library itself or lies outside.
    /// Compared by whole components, so `~/LibraryX` is never inside.
    func components(of url: URL) -> [String]? {
        let rootParts = root.pathComponents
        let parts = url.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        return Array(parts.dropFirst(rootParts.count))
    }

    /// True when `url` lies inside the Library at least `minimumDepth` deep.
    func contains(_ url: URL) -> Bool {
        (components(of: url)?.count ?? 0) >= Self.minimumDepth
    }
}

import AppKit
@testable import SweetMX
import WMCore

/// The real file system, confined to one temporary folder.
///
/// Benchmarks must touch a real disk (the app does), but never the person's own data or installed
/// apps: those differ per Mac and would make the numbers meaningless. Home and Application Support
/// point inside `root`, and every path outside it reads as missing, so the fixed system scan roots
/// (/System/Applications, /Applications) contribute nothing.
final nonisolated class SandboxFileSystem: FileSystemProtocol, @unchecked Sendable {
    let root: URL
    let home: URL
    let applicationSupport: URL
    private let system = SystemFileManager()

    init(root: URL) {
        // Resolved, so `/var` and `/private/var` spell the same root in the containment check.
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        home = self.root.appendingPathComponent("home", isDirectory: true)
        applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private func inside(_ path: String) -> Bool {
        // Links are resolved first, so a link inside the sandbox cannot lead the benchmark outside it.
        let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return standardized == root.path || standardized.hasPrefix(root.path + "/")
    }

    var homeDirectoryForCurrentUser: URL {
        home
    }

    /// The file name, never a FileManager lookup: `displayName` registers each unknown bundle with
    /// LaunchServices, so the fixture apps would show up system-wide (Open With, Spotlight) and each
    /// first lookup costs about 18 ms. On installed apps, which are registered already, the lookup
    /// costs about 0.1 ms, so leaving it out keeps the scan metric close to what users pay.
    func displayName(atPath path: String) -> String {
        (path as NSString).lastPathComponent
    }

    func urls(for directory: FileManager.SearchPathDirectory, in _: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [applicationSupport] : [home]
    }

    func fileExists(atPath path: String) -> Bool {
        inside(path) && system.fileExists(atPath: path)
    }

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        inside(path) && system.fileExists(atPath: path, isDirectory: isDirectory)
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, limit: Int) throws -> [URL] {
        guard inside(url.path) else { return [] }
        return try system.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask, limit: limit)
    }

    func isApplicationSearchFolder(at url: URL) -> Bool {
        inside(url.path) && system.isApplicationSearchFolder(at: url)
    }

    func isApplicationBundle(at url: URL) -> Bool {
        inside(url.path) && system.isApplicationBundle(at: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try requireInside(url)
        try system.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    func contents(atPath path: String) -> Data? {
        inside(path) ? system.contents(atPath: path) : nil
    }

    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool {
        inside(path) && system.createFile(atPath: path, contents: data, attributes: attr)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try requireInside(url)
        try system.write(data, to: url, options: options)
    }

    func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data? {
        try requireInside(url)
        return try system.readPrivateFile(at: url, maximumBytes: maximumBytes)
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        try requireInside(url)
        try system.writePrivateFile(data, to: url)
    }

    func removePrivateFile(at url: URL) throws {
        try requireInside(url)
        try system.removePrivateFile(at: url)
    }

    func itemKind(at url: URL) throws -> FileItemKind {
        guard inside(url.path) else { return .missing }
        return try system.itemKind(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try requireInside(source)
        try requireInside(destination)
        try system.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try requireInside(source)
        try requireInside(destination)
        try system.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try requireInside(url)
        try system.removeItem(at: url)
    }

    func trashItem(at url: URL) throws -> URL? {
        try requireInside(url)
        return try system.trashItem(at: url)
    }

    func isWritableDirectory(at url: URL) -> Bool {
        inside(url.path) && system.isWritableDirectory(at: url)
    }

    func isSymbolicLink(at url: URL) -> Bool {
        inside(url.path) && system.isSymbolicLink(at: url)
    }

    func resolvingSymlinks(_ url: URL) -> URL {
        system.resolvingSymlinks(url)
    }

    func readData(at url: URL, maxBytes: Int) -> Data? {
        inside(url.path) ? system.readData(at: url, maxBytes: maxBytes) : nil
    }

    func allocatedSize(at url: URL, limit: Int) -> Int64? {
        inside(url.path) ? system.allocatedSize(at: url, limit: limit) : nil
    }

    /// Fails closed: a write that escapes the sandbox is a benchmark bug, never something to allow.
    private func requireInside(_ url: URL) throws {
        guard inside(url.path) else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}

/// A pasteboard that never changes and counts reads of `changeCount`. Each read is one poll by the
/// clipboard monitor, so the count over an idle window is the app's idle wakeup rate.
final class CountingPasteboard: PasteboardProtocol {
    private(set) var changeCountReads = 0

    var changeCount: Int {
        changeCountReads += 1
        return 0
    }

    var readAccess: ClipboardReadAccess {
        .allowed
    }

    var types: [NSPasteboard.PasteboardType]? {
        nil
    }

    func string(forType _: NSPasteboard.PasteboardType) -> String? {
        nil
    }

    func data(forType _: NSPasteboard.PasteboardType) -> Data? {
        nil
    }

    func replayData(_: Data, forType _: NSPasteboard.PasteboardType, source _: String?) -> Int? {
        nil
    }
}

/// Deterministic inputs sized like a heavy real setup, so a regression shows up the way a user with
/// many apps and a full history would feel it.
enum BenchmarkFixtures {
    /// A large Mac has a few hundred apps; 600 sits above that, so the index is never smaller than real.
    static let applicationCount = 600
    /// The history holds at most this many clips, so the clip benchmarks always run on a full history.
    static let clipCount = ClipboardHistoryLimits.itemCount
    /// Most clips are short; a few large ones (logs, files) dominate folding cost and memory.
    static let largeClipEvery = 10
    static let largeClipBytes = 64 * 1024
    static let shortClipRepeats = 4

    private static let appWords = [
        "Visual", "Studio", "Code", "Photo", "Music", "Mail", "Notes", "Calendar", "Terminal", "Preview",
        "Safari", "Chrome", "Firefox", "Slack", "Zoom", "Docker", "Xcode", "Finder", "Pages", "Numbers",
        "Keynote", "Spotify", "Figma", "Sketch", "Notion", "Obsidian", "Arc", "Raycast", "Utility", "Monitor",
    ]

    private static let clipWords = [
        "deploy", "server", "config", "error", "status", "function", "return", "import", "release", "branch",
        "commit", "build", "token", "request", "response", "timeout", "cache", "index", "search", "result",
    ]

    /// Real names the typed queries aim at, so each search ends on a true hit as it does in use.
    private static let wellKnownApplications = ["Visual Studio Code", "Terminal", "Spotify", "Music", "Activity Monitor", "System Settings"]

    /// The well-known names, then two- or three-word names from a fixed word list, numbered so every
    /// bundle path is unique.
    static func applicationNames() -> [String] {
        wellKnownApplications + (wellKnownApplications.count ..< applicationCount).map { index in
            let first = appWords[index % appWords.count]
            let second = appWords[(index / appWords.count + index * 7) % appWords.count]
            return index.isMultiple(of: 3) ? "\(first) \(second) \(index)" : "\(first) \(second)\(index)"
        }
    }

    /// Writes minimal but valid app bundles: `isApplicationBundle` checks the package type and an
    /// executable inside the bundle, so each bundle has both, as a real app does.
    static func writeApplications(into folder: URL) throws {
        let fileManager = FileManager.default
        for name in applicationNames() {
            let contents = folder.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            let executable = macOS.appendingPathComponent("app")
            guard fileManager.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: executable.path])
            }
            let plist: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "app", "CFBundleName": name]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
    }

    /// A full history, newest first, mixing short snippets with a few large clips.
    static func clips(now: Date = Date()) -> [ClipboardItem] {
        (0 ..< clipCount).map { index in
            let words = (0 ..< 12).map { clipWords[(index * 5 + $0 * 3) % clipWords.count] }
            let line = words.joined(separator: " ") + " #\(index)\n"
            let content = index.isMultiple(of: largeClipEvery)
                ? String(repeating: line, count: largeClipBytes / line.utf8.count)
                : String(repeating: line, count: shortClipRepeats)
            return ClipboardItem(
                id: UUID(),
                content: content,
                timestamp: now.addingTimeInterval(-Double(index) * 60),
                contentType: .text,
                image: nil,
                sourceBundleID: "com.example.editor"
            )
        }
    }

    /// Each query is typed one character at a time, as the launcher sees it.
    static func keystrokes(of query: String) -> [String] {
        query.indices.map { String(query[...$0]) }
    }
}

/// Window manager inputs for the model benchmark. No real window is involved: the model is pure.
extension BenchmarkFixtures {
    /// More windows than one workspace holds in real use, so the budget has room to spare.
    static let windowManagerWindowCount = 100
    /// Every this many windows the next one opens in a new split across the last, so the tree is
    /// nested as a used desktop is, not one flat row.
    private static let windowsPerSplit = 7
    private static let screen = Rect(x: 0, y: 0, width: 3840, height: 2160)
    private static let gaps = Gaps(inner: 8, outer: 8)
    /// A window in the middle of the tree, closed by one of the measured inputs.
    private static let middleWindow = WindowID(50)
    private static let otherCell = Coord(x: 1, y: 0)
    private static let resizeShare = 0.05

    /// One workspace with every window visible, built only through `reduce`, as the app builds it.
    static func windowManagerState() -> WMState {
        var state = WMState(screen: screen, gaps: gaps)
        for number in 1 ... windowManagerWindowCount {
            if number.isMultiple(of: windowsPerSplit) {
                state = reduce(state, .command(.split(number.isMultiple(of: 2) ? .horizontal : .vertical))).state
            }
            state = reduce(state, .event(.created(WindowID(UInt32(number))))).state
        }
        return state
    }

    /// One input of each kind that changes many frames, or walks the whole tree to find its
    /// window. Each is measured against the same state.
    static let windowManagerInputs: [Input] = [
        .event(.created(WindowID(UInt32(windowManagerWindowCount + 1)))),
        .event(.destroyed(middleWindow)),
        .event(.focused(middleWindow)),
        .event(.displayChanged(Rect(x: 0, y: 0, width: 1920, height: 1080))),
        .command(.zoomIn),
        .command(.focus(.left)),
        .command(.move(.left)),
        .command(.resize(.left, amount: resizeShare)),
        .command(.gridMove(.right)),
        .command(.sendToWorkspace(otherCell)),
    ]
}

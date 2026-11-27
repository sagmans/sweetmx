import Foundation
@testable import SweetMX
import XCTest

/// Runs the executor's last safety gate on a real temporary folder. A mock cannot show how a real
/// file system resolves a link in the middle of a path, which is exactly what the gate must catch.
/// The Trash move is a recording stub, so nothing is ever moved.
@MainActor
final class UninstallExecutorRealFileSystemTests: XCTestCase {
    private enum Names {
        static let rootPrefix = "sweetmx-executor-"
        static let home = "home"
        static let library = "Library"
        static let caches = "Caches"
        static let elsewhere = "elsewhere"
        static let item = "com.example.sample"
        static let appFolder = "Applications"
        static let app = "Sample.app"
        static let bundleID = "com.example.sample"
        static let link = "lnk"
        static let other = "Sample"
    }

    private var root: URL!
    private var home: URL!
    private var recorder: RecordingFileManager!

    override func setUp() async throws {
        try await super.setUp()
        // The temporary folder itself sits behind a system link, so work from its resolved path.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Names.rootPrefix)\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = root.appendingPathComponent(Names.home, isDirectory: true)
        recorder = RecordingFileManager(home: home)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
        root = nil
        recorder = nil
        try await super.tearDown()
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeApp() throws -> UninstallTarget {
        let app = root.appendingPathComponent(Names.appFolder).appendingPathComponent(Names.app)
        try makeDirectory(app.appendingPathComponent("Contents"))
        let info: [String: Any] = ["CFBundleIdentifier": Names.bundleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return UninstallTarget(bundleURL: app, displayName: "Sample", bundleID: Names.bundleID, identityConfirmed: true, needsFinder: false)
    }

    private func run(items: [URL]) async throws -> [UninstallItemResult] {
        let fileSystem = SystemFileManager(fileManager: recorder)
        let identity = MockCodeIdentity()
        let target = try makeApp()
        identity.setIdentifier(Names.bundleID, forBundleAt: target.bundleURL)
        let executor = UninstallExecutor(
            fileSystem: fileSystem,
            workspace: MockWorkspace(),
            finder: MockFinderTrash(),
            resolver: UninstallTargetResolver(fileSystem: fileSystem, codeIdentity: identity, ownBundleID: nil)
        )
        let rows = items.map { RelatedItem(url: $0, kind: .cache, match: .bundleID, sizeBytes: nil, lock: nil) }
        return await executor.run(UninstallRequest(target: target, items: rows))
    }

    private var caches: URL {
        home.appendingPathComponent(Names.library).appendingPathComponent(Names.caches)
    }

    func testItemBehindAFolderThatBecameALinkIsNotMoved() async throws {
        let elsewhere = root.appendingPathComponent(Names.elsewhere)
        try makeDirectory(elsewhere.appendingPathComponent(Names.item))
        try makeDirectory(home.appendingPathComponent(Names.library))
        try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: elsewhere)

        let results = try await run(items: [caches.appendingPathComponent(Names.item)])

        XCTAssertEqual(results.last?.outcome, .notMoved(.becameSymlink))
        XCTAssertFalse(recorder.recorded.contains(caches.appendingPathComponent(Names.item).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent(Names.item).path))
    }

    func testDotDotAfterALinkDoesNotEscapeTheGate() async throws {
        let elsewhere = root.appendingPathComponent(Names.elsewhere)
        try makeDirectory(elsewhere)
        try makeDirectory(caches)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent(Names.link), withDestinationURL: elsewhere)
        let sneaky = URL(fileURLWithPath: caches.path + "/\(Names.link)/../../\(Names.other)")

        let results = try await run(items: [sneaky])

        XCTAssertEqual(results.last?.outcome, .notMoved(.targetChanged))
        XCTAssertEqual(recorder.recorded.count, 1)
    }

    func testPlainItemInsideLibraryReachesTheMove() async throws {
        let item = caches.appendingPathComponent(Names.item)
        try makeDirectory(item)

        let results = try await run(items: [item])

        XCTAssertEqual(results.map(\.isApp), [true, false])
        XCTAssertTrue(recorder.recorded.contains(item.path))
    }
}

/// A file manager with a fake home whose Trash move is only written down, so a test can see what
/// the executor would have moved without touching the real Trash.
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let fakeHome: URL
    private let lock = NSLock()
    private var paths: [String] = []

    init(home: URL) {
        fakeHome = home
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL {
        fakeHome
    }

    var recorded: [String] {
        lock.withLock { paths }
    }

    override func trashItem(at url: URL, resultingItemURL _: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        lock.withLock { paths.append(url.path) }
    }
}

@testable import SweetMX
import XCTest

/// Runs the uninstall seams against a real temporary folder, because the mocks cannot show how the
/// system treats links, permissions, sizes and signatures. It never calls the real Trash move.
@MainActor
final class SystemUninstallSeamsTests: XCTestCase {
    private enum Names {
        static let rootPrefix = "sweetmx-seams-"
        static let target = "target"
        static let link = "link"
        static let file = "file"
        static let tree = "tree"
        static let leaf = "leaf"
        static let bundle = "Throwaway.app"
        static let contentsFolder = "Contents"
        static let macOSFolder = "MacOS"
        static let infoPlist = "Info.plist"
    }

    private enum Fixture {
        static let readOnlyMode: Int16 = 0o555
        static let writableMode: Int16 = 0o755
        static let leafCount = 5
        static let leafBytes = 8192
        static let underLimit = 100
        static let belowEntryCount = 3
        static let unmappedCode = -50
    }

    private var root: URL!
    private let fileSystem = SystemFileManager()

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(Names.rootPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // A read-only folder from a test cannot be removed until it is writable again.
        try? FileManager.default.setAttributes([.posixPermissions: Fixture.writableMode], ofItemAtPath: root.appendingPathComponent(Names.target).path)
        try FileManager.default.removeItem(at: root)
        root = nil
        try await super.tearDown()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTree(leaves: Int) throws -> URL {
        let tree = try makeDirectory(Names.tree)
        for index in 0 ..< leaves {
            try Data(count: Fixture.leafBytes).write(to: tree.appendingPathComponent("\(Names.leaf)\(index)"))
        }
        return tree
    }

    func testIsSymbolicLinkTrueOnlyForTheLink() throws {
        let target = try makeDirectory(Names.target)
        let link = root.appendingPathComponent(Names.link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(fileSystem.isSymbolicLink(at: link))
        XCTAssertFalse(fileSystem.isSymbolicLink(at: target))
    }

    func testResolvingSymlinksFollowsTheLink() throws {
        let target = try makeDirectory(Names.target)
        let link = root.appendingPathComponent(Names.link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(fileSystem.resolvingSymlinks(link).path, fileSystem.resolvingSymlinks(target).path)
    }

    func testIsWritableDirectoryDistinguishesWritableReadOnlyAndFile() throws {
        let writable = try makeDirectory(Names.tree)
        let readOnly = try makeDirectory(Names.target)
        try FileManager.default.setAttributes([.posixPermissions: Fixture.readOnlyMode], ofItemAtPath: readOnly.path)
        let file = root.appendingPathComponent(Names.file)
        try Data().write(to: file)

        XCTAssertTrue(fileSystem.isWritableDirectory(at: writable))
        XCTAssertFalse(fileSystem.isWritableDirectory(at: readOnly))
        XCTAssertFalse(fileSystem.isWritableDirectory(at: file))
    }

    func testAllocatedSizeCountsEntriesUnderTheLimit() throws {
        let tree = try makeTree(leaves: Fixture.leafCount)

        let size = try XCTUnwrap(fileSystem.allocatedSize(at: tree, limit: Fixture.underLimit))

        XCTAssertGreaterThanOrEqual(size, Int64(Fixture.leafCount * Fixture.leafBytes))
    }

    func testAllocatedSizeIsNilOverTheLimit() throws {
        let tree = try makeTree(leaves: Fixture.leafCount)

        XCTAssertNil(fileSystem.allocatedSize(at: tree, limit: Fixture.belowEntryCount))
    }

    func testAllocatedSizeAtExactlyTheLimitIsCounted() throws {
        let tree = try makeTree(leaves: Fixture.leafCount)

        XCTAssertNotNil(fileSystem.allocatedSize(at: tree, limit: Fixture.leafCount))
        XCTAssertNil(fileSystem.allocatedSize(at: tree, limit: Fixture.leafCount - 1))
    }

    func testAllocatedSizeDoesNotFollowASymlinkInsideTheTree() throws {
        let tree = try makeTree(leaves: 1)
        let outside = try makeDirectory(Names.target)
        for index in 0 ..< Fixture.leafCount {
            try Data(count: Fixture.leafBytes).write(to: outside.appendingPathComponent("\(Names.leaf)\(index)"))
        }
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent(Names.link), withDestinationURL: outside)

        // One leaf plus the link itself: the five files behind the link are not visited.
        XCTAssertNotNil(fileSystem.allocatedSize(at: tree, limit: 2))
    }

    func testFinderOutcomeMapping() {
        XCTAssertEqual(SystemFinderTrash.outcome(forCode: 0), .moved)
        XCTAssertEqual(SystemFinderTrash.outcome(forCode: -1743), .consentRefused)
        XCTAssertEqual(SystemFinderTrash.outcome(forCode: -128), .cancelled)
        XCTAssertEqual(SystemFinderTrash.outcome(forCode: -1712), .timedOut)
        XCTAssertEqual(SystemFinderTrash.outcome(forCode: Fixture.unmappedCode), .failed(code: Fixture.unmappedCode))
    }

    func testAllocatedSizeIsNilWhenMissing() {
        XCTAssertNil(fileSystem.allocatedSize(at: root.appendingPathComponent(Names.file), limit: Fixture.underLimit))
    }

    func testCodeIdentityIsNilForUnsignedBundle() throws {
        let bundle = try makeDirectory(Names.bundle)
        let contents = bundle.appendingPathComponent(Names.contentsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent(Names.macOSFolder), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent(Names.infoPlist))

        XCTAssertNil(SystemCodeIdentity().signedIdentifier(at: bundle))
    }
}

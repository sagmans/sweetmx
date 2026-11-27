import Foundation
@testable import SweetMX
import XCTest

/// Proves which Library items the scan lists and locks, with scripted seams only, so no test reads
/// the real home folder or a real app.
final class RelatedItemScannerTests: XCTestCase {
    private enum Fixture {
        static let home = "/Users/testuser"
        static let library = "/Users/testuser/Library"
        static let bundlePath = "/Applications/Sample Pro.app"
        static let bundleID = "com.x.app"
        static let displayName = "Sample Pro"
        static let infoSuffix = "/Contents/Info.plist"
        static let caskroom = "/opt/homebrew/Caskroom"
        static let token = "sample-pro"
        static let cleanupLimit = 20000
    }

    private var fileSystem: MockFileSystem!

    override func setUp() {
        super.setUp()
        fileSystem = MockFileSystem()
    }

    private func target(
        name: String = Fixture.displayName,
        bundleID: String = Fixture.bundleID,
        path: String = Fixture.bundlePath,
        confirmed: Bool = true
    ) -> UninstallTarget {
        UninstallTarget(
            bundleURL: URL(fileURLWithPath: path),
            displayName: name,
            bundleID: bundleID,
            identityConfirmed: confirmed,
            needsFinder: false
        )
    }

    private func lib(_ parts: String...) -> String {
        ([Fixture.library] + parts).joined(separator: "/")
    }

    private func put(_ path: String) {
        fileSystem.addFile(at: path, isDirectory: true)
    }

    private func list(_ folder: String, _ names: [String]) {
        fileSystem.directoryContents[URL(fileURLWithPath: folder)] = names.map {
            URL(fileURLWithPath: folder).appendingPathComponent($0)
        }
    }

    private func scan(
        _ target: UninstallTarget,
        others: [ApplicationInfo] = [],
        homebrew: HomebrewReceipt? = nil
    ) -> [RelatedItem] {
        RelatedItemScanner(fileSystem: fileSystem).scan(target, otherApps: others, homebrew: homebrew)
    }

    private func installOther(path: String, bundleID: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
        )
        fileSystem.addFile(at: path + Fixture.infoSuffix, contents: data)
    }

    private func item(_ items: [RelatedItem], _ path: String) -> RelatedItem? {
        items.first { $0.url.path == path }
    }

    // MARK: - Bundle ID

    func testFindsExactBundleIDItems() {
        let id = Fixture.bundleID
        let paths = [
            lib("Preferences", id + ".plist"), lib("Caches", id), lib("HTTPStorages", id),
            lib("HTTPStorages", id + ".binarycookies"), lib("WebKit", id), lib("Logs", id),
            lib("Application Support", id),
        ]
        paths.forEach(put)
        fileSystem.allocatedSizes[lib("Caches", id)] = 42

        let items = scan(target())

        XCTAssertEqual(Set(items.map(\.url.path)), Set(paths))
        XCTAssertTrue(items.allSatisfy { $0.match == .bundleID && $0.lock == nil })
        XCTAssertEqual(item(items, lib("Preferences", id + ".plist"))?.kind, .settings)
        XCTAssertEqual(item(items, lib("Caches", id))?.kind, .cache)
        XCTAssertEqual(item(items, lib("Caches", id))?.sizeBytes, 42)
        XCTAssertNil(item(items, lib("Logs", id))?.sizeBytes)
        XCTAssertEqual(fileSystem.allocatedSizeCalls.first?.limit, Fixture.cleanupLimit)
    }

    func testIgnoresSimilarBundleID() {
        put(lib("Caches", "com.x.app2"))
        put(lib("Caches", "com.x.app.helper"))
        put(lib("Caches", "COM.X.APP"))
        put(lib("Preferences", "com.x.app2.plist"))

        XCTAssertTrue(scan(target()).isEmpty)
    }

    func testContainerIsLocked() {
        let containers = lib("Containers", Fixture.bundleID)
        let scripts = lib("Application Scripts", Fixture.bundleID)
        put(containers)
        put(scripts)
        fileSystem.allocatedSizes[containers] = 99

        let items = scan(target())

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.lock == .protectedByMacOS && $0.kind == .container && $0.sizeBytes == nil })
        XCTAssertFalse(fileSystem.allocatedSizeCalls.contains { $0.url.path == containers || $0.url.path == scripts })
        XCTAssertTrue(fileSystem.contentsOfDirectoryCalls.allSatisfy { !$0.path.contains("Containers") })
    }

    // MARK: - Name matches

    func testNameMatchSelectableWhenUnique() {
        let folder = lib("Application Support", "sample pro")
        put(folder)
        list(lib("Application Support"), ["sample pro", "Other"])
        list(lib("Caches"), [])
        list(lib("Logs"), [])

        let items = scan(target())

        XCTAssertEqual(items.map(\.url.path), [folder])
        XCTAssertEqual(items.first?.match, .name)
        XCTAssertNil(items.first?.lock)
    }

    func testNameMatchIsNotListedTwiceWithBundleIDMatch() {
        let both = lib("Application Support", Fixture.bundleID)
        put(both)
        list(lib("Application Support"), [Fixture.bundleID])

        let items = scan(target(name: Fixture.bundleID))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.match, .bundleID)
    }

    func testLocksNameMatchWhenAnotherAppSharesName() {
        put(lib("Caches", Fixture.displayName))
        list(lib("Caches"), [Fixture.displayName])
        let other = ApplicationInfo(name: "SAMPLE PRO", bundlePath: "/Applications/Elsewhere/Sample.app")

        let items = scan(target(), others: [other])

        XCTAssertEqual(items.first?.lock, .nameNotCertain)
    }

    func testLocksShortNameMatch() {
        put(lib("Logs", "Go"))
        list(lib("Logs"), ["Go"])

        let items = scan(target(name: "Go", path: "/Applications/Go.app"))

        XCTAssertEqual(items.map(\.url.path), [lib("Logs", "Go")])
        XCTAssertEqual(items.first?.lock, .nameNotCertain)
    }

    // MARK: - Locks

    func testLocksAllWhenIdentityNotConfirmed() {
        put(lib("Caches", Fixture.bundleID))
        put(lib("Containers", Fixture.bundleID))

        let items = scan(target(confirmed: false))

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.lock == .identityNotConfirmed })
    }

    func testLocksAllWhenSecondCopySharesBundleID() throws {
        put(lib("Caches", Fixture.bundleID))
        put(lib("Containers", Fixture.bundleID))
        let copyPath = "/Users/testuser/Applications/Sample Pro.app"
        try installOther(path: copyPath, bundleID: Fixture.bundleID)
        let copy = ApplicationInfo(name: "Renamed", bundlePath: copyPath)
        let itself = ApplicationInfo(name: Fixture.displayName, bundlePath: Fixture.bundlePath)

        let items = scan(target(), others: [itself, copy])

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.lock == .secondCopyInstalled })
    }

    func testSameNameWithDifferentBundleIDIsNotASecondCopy() throws {
        put(lib("Caches", Fixture.bundleID))
        let otherPath = "/Applications/Other/Sample Pro.app"
        try installOther(path: otherPath, bundleID: "com.y.other")

        let items = scan(target(), others: [ApplicationInfo(name: Fixture.displayName, bundlePath: otherPath)])

        XCTAssertNil(items.first?.lock)
    }

    func testUnrelatedAppIsNotRead() {
        put(lib("Caches", Fixture.bundleID))
        let unrelated = ApplicationInfo(name: "Different", bundlePath: "/Applications/Different.app")

        _ = scan(target(), others: [unrelated])

        XCTAssertTrue(fileSystem.fileExistsAtPathCalls.allSatisfy { !$0.hasPrefix("/Applications/Different.app") })
    }

    // MARK: - Links and containment

    func testDropsSymlinkCandidate() {
        let linked = lib("Caches", Fixture.bundleID)
        put(linked)
        fileSystem.symbolicLinks.insert(linked)
        put(lib("Logs", Fixture.bundleID))
        fileSystem.resolvedPaths[lib("Logs", Fixture.bundleID)] = URL(fileURLWithPath: "/Volumes/Other/elsewhere")

        XCTAssertTrue(scan(target()).isEmpty)
    }

    func testDropsCandidateWhenAllowlistedFolderIsALink() {
        put(lib("Caches", Fixture.bundleID))
        fileSystem.symbolicLinks.insert(lib("Caches"))

        XCTAssertTrue(scan(target()).isEmpty)
    }

    // MARK: - Homebrew

    private func receiptJSON(app: String = "Sample Pro.app", zap: Any) throws -> Data {
        let root: [String: Any] = [
            "uninstall_artifacts": [["app": [app]], ["zap": [zap]]],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func installReceipt(token: String = Fixture.token, json: Data) {
        let root = URL(fileURLWithPath: Fixture.caskroom)
        fileSystem.directoryContents[root, default: []].append(root.appendingPathComponent(token))
        fileSystem.fileContents["\(Fixture.caskroom)/\(token)/.metadata/INSTALL_RECEIPT.json"] = json
    }

    private func find() -> HomebrewReceipt? {
        HomebrewReceipt.find(for: target(), fileSystem: fileSystem)
    }

    func testHomebrewReadsZapPaths() throws {
        try installReceipt(json: receiptJSON(zap: [
            "trash": ["~/Library/Saved Application State/com.x.app.savedState", "~/Library/Preferences/com.x.group.plist"],
            "delete": "~/Library/Application Support/SampleData",
            "rmdir": ["~/Library/Caches/Sample"],
        ]))
        let state = lib("Saved Application State", "com.x.app.savedState")
        let data = lib("Application Support", "SampleData")
        let other = lib("Application Support", "Gone")
        put(state)
        put(data)

        let receipt = try XCTUnwrap(find())
        XCTAssertEqual(receipt.token, Fixture.token)
        XCTAssertEqual(receipt.cleanupPaths.count, 4)

        let items = scan(target(), homebrew: receipt)

        XCTAssertEqual(Set(items.map(\.url.path)), [state, data])
        XCTAssertTrue(items.allSatisfy { $0.match == .homebrew && $0.lock == nil })
        XCTAssertNil(item(items, other))
    }

    func testHomebrewDuplicatesOfBundleIDRowsAreDropped() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Caches/com.x.app"]]))
        put(lib("Caches", Fixture.bundleID))

        let items = scan(target(), homebrew: find())

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.match, .bundleID)
    }

    func testHomebrewContainerStaysLocked() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Containers/org.other.id"]]))
        put(lib("Containers", "org.other.id"))

        let items = scan(target(), homebrew: find())

        XCTAssertEqual(items.first?.lock, .protectedByMacOS)
        XCTAssertNil(items.first?.sizeBytes)
    }

    func testHomebrewPathsOutsideLibraryAreDropped() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": [
            "/Applications/Other.app", "~/Documents/Notes", "~/Library", "~/Library/Caches",
            "~/Library/../Documents/x", "/Users/someone/Library/Caches/x",
        ]]))

        XCTAssertEqual(find()?.cleanupPaths, [])
    }

    func testHomebrewPathThatResolvesOutsideLibraryIsDropped() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Caches/Sample"]]))
        let path = lib("Caches", "Sample")
        put(path)
        fileSystem.resolvedPaths[path] = URL(fileURLWithPath: "/Users/testuser/Documents/Sample")

        XCTAssertTrue(scan(target(), homebrew: find()).isEmpty)
    }

    func testHomebrewPathsWithGlobsOrParentRefsAreDropped() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": [
            "~/Library/Caches/*", "~/Library/Caches/Sample?", "~/Library/Caches/../Preferences/x",
            "~/Library/Caches/./x", "~/Library/Caches//x", "~/Library/Caches/ok",
        ]]))

        XCTAssertEqual(find()?.cleanupPaths.map(\.path), [lib("Caches", "ok")])
    }

    func testHomebrewLinkedAncestorIsDropped() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Application Support/Sample/Deep"]]))
        put(lib("Application Support", "Sample", "Deep"))
        fileSystem.symbolicLinks.insert(lib("Application Support", "Sample"))

        XCTAssertTrue(scan(target(), homebrew: find()).isEmpty)
    }

    func testHomebrewReceiptMustNameTheTargetApp() throws {
        try installReceipt(json: receiptJSON(app: "Different.app", zap: ["trash": ["~/Library/Caches/ok"]]))

        XCTAssertNil(find())
    }

    func testHomebrewAmbiguousReceiptsGiveNoResult() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Caches/ok"]]))
        try installReceipt(token: "sample-pro-beta", json: receiptJSON(zap: ["trash": ["~/Library/Caches/ok"]]))

        XCTAssertNil(find())
    }

    func testRejectsBadHomebrewToken() throws {
        for token in ["Sample-Pro", "-sample", "sample pro", "sample\u{0}x", ".hidden"] {
            fileSystem = MockFileSystem()
            try installReceipt(token: token, json: receiptJSON(zap: ["trash": ["~/Library/Caches/ok"]]))
            XCTAssertNil(find(), token)
        }
    }

    func testHomebrewHostileReceiptsNeverCrash() {
        let bodies = [
            "[]", "{}", "null", "\"text\"", "{\"uninstall_artifacts\": 5}", "{\"uninstall_artifacts\": [1, null, \"x\"]}",
            "{\"uninstall_artifacts\": [{\"app\": 7}]}",
            "{\"uninstall_artifacts\": [{\"app\": [\"Sample Pro.app\"]}, {\"zap\": 3}]}",
            "{\"uninstall_artifacts\": [{\"app\": [\"Sample Pro.app\"]}, {\"zap\": [{\"trash\": [1, {}, null]}]}]}",
            "not json",
        ]
        for body in bodies {
            fileSystem = MockFileSystem()
            installReceipt(json: Data(body.utf8))
            let receipt = find()
            XCTAssertTrue(receipt?.cleanupPaths.isEmpty ?? true, body)
        }
    }

    func testHomebrewOversizeReceiptIsIgnored() {
        installReceipt(json: Data(count: 1_048_577))

        XCTAssertNil(find())
    }
}

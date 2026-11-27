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
        static let version = "1.0"
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

    /// Adds the item and lists it in its folder, as a real folder would.
    private func put(_ path: String) {
        fileSystem.addFile(at: path, isDirectory: true)
        fileSystem.itemKinds[path] = .directory
        let url = URL(fileURLWithPath: path)
        let parent = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        fileSystem.directoryContents[parent, default: []].append(url)
    }

    private func list(_ folder: String, _ names: [String]) {
        fileSystem.directoryContents[URL(fileURLWithPath: folder)] = names.map {
            URL(fileURLWithPath: folder).appendingPathComponent($0)
        }
    }

    private func scan(
        _ target: UninstallTarget,
        others: [ApplicationInfo] = [],
        copies: [URL] = [],
        homebrew: HomebrewReceipt? = nil
    ) -> [RelatedItem] {
        // A loaded index always lists the target itself, so the scan treats the list as ready.
        let itself = ApplicationInfo(name: target.displayName, bundlePath: target.bundleURL.path)
        return scanner.scan(target, installedApps: [itself] + others, registeredCopies: copies, homebrew: homebrew)
    }

    private var scanner: RelatedItemScanner {
        RelatedItemScanner(fileSystem: fileSystem, library: library)
    }

    private var library: UserLibrary {
        UserLibrary(home: fileSystem.homeDirectoryForCurrentUser)
    }

    private func installOther(path: String, bundleID: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
        )
        fileSystem.addFile(at: path + Fixture.infoSuffix, contents: data)
    }

    /// An indexed app with the target's display name but another bundle ID.
    private func installDifferentApp(name: String) throws -> ApplicationInfo {
        let path = "/Applications/Elsewhere/\(name).app"
        try installOther(path: path, bundleID: "com.y.other")
        return ApplicationInfo(name: name, bundlePath: path)
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
        XCTAssertEqual(fileSystem.allocatedSizeCalls.first?.limit, RelatedItemScanner.sizeEntryLimit)
    }

    func testIgnoresSimilarBundleID() {
        put(lib("Caches", "com.x.app2"))
        put(lib("Caches", "com.x.app.helper"))
        put(lib("Caches", "COM.X.APP"))
        put(lib("Preferences", "com.x.app2.plist"))

        XCTAssertTrue(scan(target()).isEmpty)
    }

    /// A guarded item gets one look that does not follow links, and nothing else touches the guarded
    /// folders: no stat, no link resolution, no listing, no size.
    func testContainerIsLocked() {
        let containers = lib("Containers", Fixture.bundleID)
        let scripts = lib("Application Scripts", Fixture.bundleID)
        put(containers)
        put(scripts)
        fileSystem.allocatedSizes[containers] = 99

        let items = scan(target())

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.lock == .protectedByMacOS && $0.kind == .container && $0.sizeBytes == nil })
        XCTAssertEqual(fileSystem.itemKindCalls.map(\.path).sorted(), [scripts, containers].sorted())
        let guarded = [lib("Containers"), lib("Application Scripts")]
        let inGuarded: (String) -> Bool = { path in guarded.contains { path == $0 || path.hasPrefix($0 + "/") } }
        XCTAssertFalse(fileSystem.fileExistsAtPathCalls.contains(where: inGuarded))
        XCTAssertFalse(fileSystem.isSymbolicLinkCalls.map(\.path).contains(where: inGuarded))
        XCTAssertFalse(fileSystem.resolvingSymlinksCalls.map(\.path).contains(where: inGuarded))
        XCTAssertFalse(fileSystem.contentsOfDirectoryCalls.map(\.path).contains(where: inGuarded))
        XCTAssertFalse(fileSystem.allocatedSizeCalls.map(\.url.path).contains(where: inGuarded))
    }

    /// A link in a guarded folder could stand for anything, so it gives no row.
    func testLinkedContainerIsDropped() {
        fileSystem.itemKinds[lib("Containers", Fixture.bundleID)] = .symbolicLink

        XCTAssertTrue(scan(target()).isEmpty)
    }

    /// Group container names are group IDs, almost never the bundle ID, and looking may raise a privacy
    /// prompt, so the bundle ID rule never reads there.
    func testGroupContainerIsNeverLookedUpByBundleID() {
        let group = lib("Group Containers", Fixture.bundleID)
        put(group)

        XCTAssertTrue(scan(target()).isEmpty)
        XCTAssertFalse(fileSystem.itemKindCalls.contains { $0.path.hasPrefix(lib("Group Containers")) })
        XCTAssertFalse(fileSystem.fileExistsAtPathCalls.contains { $0.hasPrefix(lib("Group Containers")) })
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

    func testLocksNameMatchWhenAnotherAppSharesName() throws {
        put(lib("Caches", Fixture.displayName))
        let other = try installDifferentApp(name: "SAMPLE PRO")

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

    /// A copy can carry any file name and Finder name (`Xcode-beta.app` beside `Xcode.app`), so the scan
    /// reads the bundle ID of every other app, not only the look-alikes.
    func testLocksAllWhenRenamedCopySharesBundleID() throws {
        put(lib("Caches", Fixture.bundleID))
        put(lib("Preferences", Fixture.bundleID + ".plist"))
        let copyPath = "/Applications/Sample Pro Beta.app"
        try installOther(path: copyPath, bundleID: Fixture.bundleID)
        let copy = ApplicationInfo(name: "Sample Pro Beta", bundlePath: copyPath)

        let items = scan(target(), others: [copy])

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.lock == .secondCopyInstalled })
    }

    /// An unrelated app is read too, and its own bundle ID leaves the rows free.
    func testUnrelatedAppIsReadAndLeavesRowsFree() throws {
        put(lib("Caches", Fixture.bundleID))
        let path = "/Applications/Different.app"
        try installOther(path: path, bundleID: "com.y.different")

        let items = scan(target(), others: [ApplicationInfo(name: "Different", bundlePath: path)])

        XCTAssertTrue(fileSystem.readDataCalls.contains { $0.path == path + Fixture.infoSuffix })
        XCTAssertNil(items.first?.lock)
    }

    /// An app the index does not list at all (Downloads, an external disk) still shares the files when
    /// the system knows it under the same bundle ID.
    func testLocksAllWhenOnlyTheSystemKnowsASecondCopy() {
        put(lib("Caches", Fixture.bundleID))
        put(lib("Containers", Fixture.bundleID))
        let copies = [URL(fileURLWithPath: Fixture.bundlePath), URL(fileURLWithPath: "/Users/testuser/Downloads/Sample Pro.app")]

        let items = scan(target(), copies: copies)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.lock == .secondCopyInstalled })
    }

    /// The system's answer always names the target itself, under any spelling of its path.
    func testSystemListingOnlyTheTargetIsNotASecondCopy() {
        put(lib("Caches", Fixture.bundleID))
        let itself = URL(fileURLWithPath: "/Applications/./Sample Pro.app/", isDirectory: true)

        XCTAssertNil(scan(target(), copies: [itself]).first?.lock)
    }

    /// A copy the system knows is a confirmed second copy, so it outranks the unknown app list.
    func testSystemCopyLocksEvenWhenTheIndexIsUnknown() {
        put(lib("Caches", Fixture.bundleID))
        let copies = [URL(fileURLWithPath: "/Volumes/Disk/Sample Pro.app")]

        let items = scanner.scan(
            target(), installedApps: nil, registeredCopies: copies, homebrew: nil
        )

        XCTAssertEqual(items.first?.lock, .secondCopyInstalled)
    }

    /// The index lists Finder's name, which follows the file name, while the target's name comes from its
    /// Info.plist; another app whose file is named like the target makes a name row uncertain.
    func testLocksNameMatchWhenAnotherAppsFileNameMatches() throws {
        put(lib("Caches", Fixture.displayName))
        let path = "/Applications/Other/Sample Pro.app"
        try installOther(path: path, bundleID: "com.y.other")

        let items = scan(target(), others: [ApplicationInfo(name: "Localized Name", bundlePath: path)])

        XCTAssertEqual(items.first?.lock, .nameNotCertain)
    }

    func testUnreadableBundleIDOfSameNamedAppLocksEverything() {
        put(lib("Caches", Fixture.bundleID))
        let twin = ApplicationInfo(name: Fixture.displayName, bundlePath: "/Applications/Twin/Sample Pro.app")

        XCTAssertEqual(scan(target(), others: [twin]).first?.lock, .secondCopyInstalled)
    }

    /// An index that is not loaded cannot rule out a twin or a same-named app, so nothing is selectable.
    func testUnknownIndexLocksEveryRow() {
        let cache = lib("Caches", Fixture.bundleID)
        let named = lib("Application Support", "sample pro")
        put(cache)
        put(named)

        let items = scanner.scan(target(), installedApps: nil, registeredCopies: [], homebrew: nil)

        XCTAssertEqual(Set(items.map(\.url.path)), [cache, named])
        XCTAssertTrue(items.allSatisfy { $0.lock == .appListNotReady })
    }

    /// An unknown app list never outranks a confirmed problem: identity first, then macOS protection.
    func testUnknownIndexRanksBelowIdentityAndProtection() {
        let cache = lib("Caches", Fixture.bundleID)
        let container = lib("Containers", Fixture.bundleID)
        put(cache)
        put(container)

        var items = scanner.scan(target(), installedApps: nil, registeredCopies: [], homebrew: nil)
        XCTAssertEqual(item(items, container)?.lock, .protectedByMacOS)
        XCTAssertEqual(item(items, cache)?.lock, .appListNotReady)

        items = scanner.scan(target(confirmed: false), installedApps: nil, registeredCopies: [], homebrew: nil)
        XCTAssertTrue(items.allSatisfy { $0.lock == .identityNotConfirmed })
    }

    /// A listed copy of the target under an unnormalized path is still the target, not a second copy.
    func testListedTargetWithUnnormalizedPathIsNotASecondCopy() {
        let cache = lib("Caches", Fixture.bundleID)
        put(cache)
        let unnormalized = (Fixture.bundlePath as NSString).deletingLastPathComponent + "/./"
            + (Fixture.bundlePath as NSString).lastPathComponent
        let listed = ApplicationInfo(name: Fixture.displayName, bundlePath: unnormalized)

        let items = scanner.scan(target(), installedApps: [listed], registeredCopies: [], homebrew: nil)

        XCTAssertNil(item(items, cache)?.lock)
    }

    /// An index that does not list the target is stale, whoever passes it, so it cannot rule out a twin.
    func testIndexWithoutTheTargetLocksEveryRow() throws {
        let cache = lib("Caches", Fixture.bundleID)
        put(cache)
        let other = try installDifferentApp(name: "Different")

        let items = scanner.scan(target(), installedApps: [other], registeredCopies: [], homebrew: nil)

        XCTAssertEqual(item(items, cache)?.lock, .appListNotReady)
    }

    func testLockPrecedence() throws {
        let cache = lib("Caches", Fixture.bundleID)
        let container = lib("Containers", Fixture.bundleID)
        let named = lib("Logs", "Go")
        [cache, container, named].forEach(put)
        let copyPath = "/Applications/Copy/Go.app"
        try installOther(path: copyPath, bundleID: "com.x.go")
        let copy = ApplicationInfo(name: "Go", bundlePath: copyPath)

        // identity beats second copy
        var items = scan(target(name: "Go", bundleID: "com.x.go", confirmed: false), others: [copy])
        XCTAssertTrue(items.allSatisfy { $0.lock == .identityNotConfirmed })

        // second copy beats nameNotCertain
        items = scan(target(name: "Go", bundleID: "com.x.go"), others: [copy])
        XCTAssertEqual(item(items, named)?.lock, .secondCopyInstalled)

        // protected beats nameNotCertain: the short name also matches the container folder name
        let shortProtected = lib("Containers", "com.x.go")
        put(shortProtected)
        items = scan(target(name: "Go", bundleID: "com.x.go"))
        XCTAssertEqual(item(items, shortProtected)?.lock, .protectedByMacOS)
        XCTAssertEqual(item(items, named)?.lock, .nameNotCertain)
    }

    func testIgnoresDifferentlyCasedOnDiskName() {
        let onDisk = lib("Caches", "Com.X.App")
        put(onDisk)
        fileSystem.existingFiles[lib("Caches", Fixture.bundleID)] = true

        XCTAssertTrue(scan(target()).isEmpty)
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

    /// Scripts the Caskroom layout Homebrew leaves: a receipt and, when `linkTarget` is set, a link
    /// `<token>/<version>/<App>.app` to the installed copy.
    private func installReceipt(
        token: String = Fixture.token,
        json: Data,
        linkTarget: String? = Fixture.bundlePath,
        app: String = "Sample Pro.app"
    ) {
        let root = URL(fileURLWithPath: Fixture.caskroom)
        let tokenURL = root.appendingPathComponent(token)
        fileSystem.directoryContents[root, default: []].append(tokenURL)
        fileSystem.fileContents["\(tokenURL.path)/.metadata/INSTALL_RECEIPT.json"] = json
        guard let linkTarget else { return }
        let versionURL = tokenURL.appendingPathComponent(Fixture.version)
        let linkURL = versionURL.appendingPathComponent(app)
        fileSystem.directoryContents[tokenURL] = [tokenURL.appendingPathComponent(".metadata"), versionURL]
        fileSystem.directoryContents[versionURL] = [linkURL]
        fileSystem.symbolicLinks.insert(linkURL.path)
        fileSystem.resolvedPaths[linkURL.path] = URL(fileURLWithPath: linkTarget)
    }

    private func find() -> HomebrewReceipt? {
        HomebrewReceipt.find(for: target(), library: library, fileSystem: fileSystem)
    }

    func testHomebrewReadsZapPaths() throws {
        try installReceipt(json: receiptJSON(zap: [
            "trash": ["~/Library/Preferences/com.x.app.helper.plist", "~/Library/Preferences/com.x.group.plist"],
            "delete": "~/Library/Application Support/Sample Pro",
            "rmdir": ["~/Library/Caches/Sample"],
        ]))
        let helper = lib("Preferences", "com.x.app.helper.plist")
        let data = lib("Application Support", "Sample Pro")
        let foreign = lib("Preferences", "com.x.group.plist")
        [helper, data, foreign].forEach(put)

        let receipt = try XCTUnwrap(find())
        XCTAssertEqual(receipt.token, Fixture.token)
        XCTAssertEqual(receipt.cleanupPaths.count, 4)

        let items = scan(target(), homebrew: receipt)

        XCTAssertEqual(Set(items.map(\.url.path)), [helper, data, foreign])
        XCTAssertEqual(item(items, helper)?.match, .homebrew)
        XCTAssertEqual(item(items, data)?.match, .name, "the name rule lists it first")
        XCTAssertEqual(item(items, helper)?.lock, .nameNotCertain, "the ID plus a dotted part is not certain")
        XCTAssertNil(item(items, data)?.lock)
        XCTAssertEqual(item(items, foreign)?.lock, .nameNotCertain)
    }

    func testHomebrewKeychainPathIsDropped() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": [
            "~/Library/Keychains/login.keychain-db", "~/Library/Saved Application State/com.x.app.savedState",
            "~/Library/Application Support/Sample Pro/Deep",
        ]]))
        put(lib("Keychains", "login.keychain-db"))
        put(lib("Application Support", "Sample Pro", "Deep"))

        XCTAssertTrue(scan(target(), homebrew: find()).isEmpty)
    }

    func testHomebrewGroupContainerIsLockedAndNotStatted() throws {
        let group = lib("Group Containers", "group.com.x.app")
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Group Containers/group.com.x.app"]]))

        let items = scan(target(), homebrew: find())

        XCTAssertEqual(items.map(\.url.path), [group])
        XCTAssertEqual(items.first?.lock, .protectedByMacOS)
        XCTAssertNil(items.first?.sizeBytes)
        XCTAssertFalse(fileSystem.fileExistsAtPathCalls.contains(group))
        XCTAssertFalse(fileSystem.isSymbolicLinkCalls.contains { $0.path == group })
        XCTAssertFalse(fileSystem.allocatedSizeCalls.contains { $0.url.path == group })
    }

    func testHomebrewAnotherAppsCacheIsLocked() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Caches/com.other.app"]]))
        put(lib("Caches", "com.other.app"))

        XCTAssertEqual(scan(target(), homebrew: find()).first?.lock, .nameNotCertain)
    }

    func testHomebrewSharedVendorFolderIsLocked() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Application Support/Google"]]))
        put(lib("Application Support", "Google"))

        XCTAssertEqual(scan(target(), homebrew: find()).first?.lock, .nameNotCertain)
    }

    func testHomebrewDisplayNameRowIsLockedWhenNameIsNotCertain() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Caches/Sample Pro"]]))
        put(lib("Caches", "Sample Pro"))
        let twin = try installDifferentApp(name: "sample pro")

        XCTAssertEqual(scan(target(), others: [twin], homebrew: find()).first?.lock, .nameNotCertain)
    }

    func testHomebrewBundleIDFollowedByDotIsListedButLocked() throws {
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Preferences/com.x.app.helper.plist"]]))
        put(lib("Preferences", "com.x.app.helper.plist"))

        let items = scan(target(), homebrew: find())

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.lock, .nameNotCertain)
    }

    /// Removing Chrome must not offer Chrome Canary's files, whose ID only extends Chrome's.
    func testHomebrewSiblingAppSharingTheIDPrefixIsLocked() throws {
        let chrome = target(name: "Google Chrome", bundleID: "com.google.Chrome")
        let canary = lib("Caches", "com.google.Chrome.canary")
        put(canary)
        try installReceipt(json: receiptJSON(zap: ["trash": ["~/Library/Caches/com.google.Chrome.canary"]]))

        let items = scan(chrome, homebrew: HomebrewReceipt.find(for: chrome, library: library, fileSystem: fileSystem))

        XCTAssertEqual(items.map(\.url.path), [canary])
        XCTAssertEqual(items.first?.lock, .nameNotCertain)
    }

    /// The two names that do tie a Homebrew row to the app: the exact bundle ID and the certain name.
    func testHomebrewExactIDAndCertainNameAreSelectable() throws {
        let exact = lib("Caches", "com.x.app.plist")
        let named = lib("Preferences", "Sample Pro.plist")
        [exact, named].forEach(put)
        try installReceipt(json: receiptJSON(zap: ["trash": [
            "~/Library/Caches/com.x.app.plist", "~/Library/Preferences/Sample Pro.plist",
        ]]))

        let items = scan(target(), homebrew: find())

        XCTAssertEqual(Set(items.map(\.url.path)), [exact, named])
        XCTAssertNil(item(items, exact)?.lock)
        XCTAssertNil(item(items, named)?.lock)
    }

    func testHomebrewReceiptWithoutLinkToTargetIsIgnored() throws {
        let json = try receiptJSON(zap: ["trash": ["~/Library/Caches/ok"]])
        installReceipt(json: json, linkTarget: nil)
        XCTAssertNil(find(), "no link at all")

        fileSystem = MockFileSystem()
        installReceipt(json: json, linkTarget: "/Applications/Other/Sample Pro.app")
        XCTAssertNil(find(), "link to a different copy")

        fileSystem = MockFileSystem()
        installReceipt(json: json)
        XCTAssertEqual(find()?.token, Fixture.token)
    }

    func testHomebrewRefusesLinkedMetadataOrReceipt() throws {
        let json = try receiptJSON(zap: ["trash": ["~/Library/Caches/ok"]])
        installReceipt(json: json)
        fileSystem.symbolicLinks.insert("\(Fixture.caskroom)/\(Fixture.token)/.metadata")
        XCTAssertNil(find())

        fileSystem = MockFileSystem()
        installReceipt(json: json)
        fileSystem.symbolicLinks.insert("\(Fixture.caskroom)/\(Fixture.token)/.metadata/INSTALL_RECEIPT.json")
        XCTAssertNil(find())
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
        for token in ["Sample-Pro", "-sample", "sample pro", "sample\u{0}x", ".hidden", "abc\n"] {
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

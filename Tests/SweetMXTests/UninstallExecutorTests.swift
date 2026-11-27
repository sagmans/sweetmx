import Foundation
@testable import SweetMX
import XCTest

/// Proves what the executor moves, in what order and what it refuses, with scripted seams only:
/// no real app, Trash, Finder or home folder is touched.
@MainActor
final class UninstallExecutorTests: XCTestCase {
    private enum Fixture {
        static let appPath = "/Applications/Sample.app"
        static let appFolder = "/Applications"
        static let bundleID = "com.example.sample"
        static let otherBundleID = "com.example.other"
        static let plistKey = "CFBundleIdentifier"
        static let infoSuffix = "/Contents/Info.plist"
        static let home = "/Users/testuser"
        static let cachePath = "/Users/testuser/Library/Caches/com.example.sample"
        static let prefsPath = "/Users/testuser/Library/Preferences/com.example.sample.plist"
        static let supportPath = "/Users/testuser/Library/Application Support/Sample"
        static let outsidePath = "/Users/testuser/Documents/Sample"
        static let trashedURL = URL(fileURLWithPath: "/Users/testuser/.Trash/trashed")
        static let quitTimeout = Duration.milliseconds(60)
        static let pollInterval = Duration.milliseconds(5)
        static let patientTimeout = Duration.seconds(5)
        static let quitAfterReads = 3
        static let finderTimeoutValue: TimeInterval = 120
        static let permissionCode = 513
        static let failureCode = 99
        static let finderFailureCode = -1728
    }

    private var fileSystem: MockFileSystem!
    private var workspace: MockWorkspace!
    private var finder: MockFinderTrash!
    private var identity: MockCodeIdentity!

    override func setUp() async throws {
        try await super.setUp()
        fileSystem = MockFileSystem()
        workspace = MockWorkspace()
        finder = MockFinderTrash()
        identity = MockCodeIdentity()
        fileSystem.writableDirectories.insert(Fixture.appFolder)
        fileSystem.addFile(at: Fixture.appPath, isDirectory: true)
        installPlist(bundleID: Fixture.bundleID)
        identity.setIdentifier(Fixture.bundleID, forBundleAt: appURL)
        for path in [Fixture.cachePath, Fixture.prefsPath, Fixture.supportPath, Fixture.outsidePath] {
            fileSystem.addFile(at: path)
        }
    }

    private var appURL: URL {
        URL(fileURLWithPath: Fixture.appPath)
    }

    private func installPlist(bundleID: String) {
        let info: [String: Any] = [Fixture.plistKey: bundleID]
        let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        fileSystem.addFile(at: Fixture.appPath + Fixture.infoSuffix, contents: data)
    }

    private func target(identityConfirmed: Bool = true, needsFinder: Bool = false) -> UninstallTarget {
        UninstallTarget(
            bundleURL: appURL,
            displayName: "Sample",
            bundleID: Fixture.bundleID,
            identityConfirmed: identityConfirmed,
            needsFinder: needsFinder
        )
    }

    private func item(_ path: String, lock: RelatedItem.Lock? = nil) -> RelatedItem {
        RelatedItem(url: URL(fileURLWithPath: path), kind: .cache, match: .bundleID, sizeBytes: nil, lock: lock)
    }

    private func executor(
        finder: FinderTrashProtocol? = nil,
        finderHandOffEnabled: Bool = false,
        quitTimeout: Duration = Fixture.quitTimeout
    ) -> UninstallExecutor {
        UninstallExecutor(
            fileSystem: fileSystem,
            workspace: workspace,
            finder: finder ?? self.finder,
            resolver: UninstallTargetResolver(fileSystem: fileSystem, codeIdentity: identity, ownBundleID: nil),
            library: UserLibrary(home: fileSystem.homeDirectoryForCurrentUser),
            finderHandOffEnabled: finderHandOffEnabled,
            quitTimeout: quitTimeout,
            quitPollInterval: Fixture.pollInterval
        )
    }

    private func run(
        _ executor: UninstallExecutor,
        target: UninstallTarget? = nil,
        items: [RelatedItem]
    ) async -> [UninstallItemResult] {
        await executor.run(UninstallRequest(target: target ?? self.target(), items: items))
    }

    private func permissionError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: Fixture.permissionCode)
    }

    private func reasons(_ results: [UninstallItemResult]) -> [UninstallItemResult.Reason?] {
        results.map { result in
            if case let .notMoved(reason) = result.outcome {
                return reason
            }
            return nil
        }
    }

    // MARK: - Happy path and order

    func testMovesAppThenTickedItems() async {
        let running = MockRunningApplication(isTerminated: false)
        running.terminatesAfterReads = Fixture.quitAfterReads
        workspace.runningApplicationsByBundlePath[Fixture.appPath] = [running]
        let items = [item(Fixture.prefsPath), item(Fixture.cachePath)]

        let results = await run(executor(quitTimeout: Fixture.patientTimeout), items: items)

        XCTAssertEqual(results.map(\.url.path), [Fixture.appPath, Fixture.prefsPath, Fixture.cachePath])
        XCTAssertEqual(results.map(\.isApp), [true, false, false])
        XCTAssertEqual(results.map(\.outcome), Array(repeating: .moved(to: Fixture.trashedURL), count: 3))
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath, Fixture.prefsPath, Fixture.cachePath])
        XCTAssertEqual(running.terminateCallCount, 1)
        XCTAssertTrue(finder.moveToTrashCalls.isEmpty)
    }

    func testWaitsForAppThatQuitsLaterEvenWhenTerminateReturnsFalse() async {
        let running = MockRunningApplication(isTerminated: false, terminateResult: false)
        workspace.runningApplicationsByBundlePath[Fixture.appPath] = [running]
        running.terminatesAfterReads = Fixture.quitAfterReads

        let results = await run(executor(quitTimeout: Fixture.patientTimeout), items: [])

        XCTAssertEqual(results.map(\.outcome), [.moved(to: Fixture.trashedURL)])
    }

    // MARK: - Quit

    func testStopsWhenAppDoesNotQuit() async {
        let running = MockRunningApplication(isTerminated: false)
        workspace.runningApplicationsByBundlePath[Fixture.appPath] = [running]

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.appStillRunning, .appStillRunning])
        XCTAssertTrue(fileSystem.trashItemCalls.isEmpty)
        XCTAssertTrue(finder.moveToTrashCalls.isEmpty)
    }

    func testSendsOneQuitRequestAndMovesNothingWhileAppRuns() async {
        let running = MockRunningApplication(isTerminated: false)
        workspace.runningApplicationsByBundlePath[Fixture.appPath] = [running]

        _ = await run(executor(), items: [])

        // The handle type has no force-quit member, so only the request count can be proven here.
        XCTAssertEqual(running.terminateCallCount, 1)
        XCTAssertTrue(fileSystem.trashItemCalls.isEmpty)
    }

    func testCancellationDuringQuitWaitMovesNothing() async {
        let running = MockRunningApplication(isTerminated: false)
        workspace.runningApplicationsByBundlePath[Fixture.appPath] = [running]
        let subject = executor(quitTimeout: Fixture.patientTimeout)
        let request = UninstallRequest(target: target(), items: [item(Fixture.cachePath)])

        let task = Task { await subject.run(request) }
        task.cancel()
        let results = await task.value

        // A wait that ends early is an app that did not quit; there is no separate cancel outcome.
        XCTAssertEqual(reasons(results), [.appStillRunning, .appStillRunning])
        XCTAssertTrue(fileSystem.trashItemCalls.isEmpty)
    }

    // MARK: - Re-resolve

    func testAbortsWhenBundleIDChangedSinceSheetOpened() async {
        installPlist(bundleID: Fixture.otherBundleID)
        identity.setIdentifier(Fixture.otherBundleID, forBundleAt: appURL)
        let running = MockRunningApplication(isTerminated: false)
        workspace.runningApplicationsByBundlePath[Fixture.appPath] = [running]

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        // A changed target is not the app the person confirmed, so it gets no quit request.
        XCTAssertEqual(running.terminateCallCount, 0)

        XCTAssertEqual(reasons(results), [.targetChanged, .targetChanged])
        XCTAssertTrue(fileSystem.trashItemCalls.isEmpty)
    }

    func testAbortsWhenAppIsNowRefused() async {
        fileSystem.symbolicLinks.insert(Fixture.appPath)

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.targetChanged, .targetChanged])
        XCTAssertTrue(fileSystem.trashItemCalls.isEmpty)
    }

    func testAbortsWhenIdentityNoLongerConfirmed() async {
        identity.setIdentifier("com.example.forged", forBundleAt: appURL)

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.targetChanged, .targetChanged])
        XCTAssertTrue(fileSystem.trashItemCalls.isEmpty)
    }

    func testUnconfirmedIdentityStaysUnconfirmedAndStillMovesApp() async {
        identity.setIdentifier("com.example.forged", forBundleAt: appURL)

        let results = await run(executor(), target: target(identityConfirmed: false), items: [])

        XCTAssertEqual(results.map(\.outcome), [.moved(to: Fixture.trashedURL)])
    }

    // MARK: - Related item re-check

    func testSkipsItemThatBecameSymlink() async {
        fileSystem.symbolicLinks.insert(Fixture.cachePath)

        let results = await run(executor(), items: [item(Fixture.cachePath), item(Fixture.prefsPath)])

        XCTAssertEqual(reasons(results), [nil, .becameSymlink, nil])
        XCTAssertFalse(fileSystem.trashItemCalls.map(\.path).contains(Fixture.cachePath))
    }

    func testSkipsItemWhoseParentFolderBecameALink() async {
        // The folder that held the item now leads somewhere else.
        fileSystem.resolvedPaths["/Users/testuser/Library/Caches"] = URL(fileURLWithPath: "/Volumes/Elsewhere/Caches")

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [nil, .becameSymlink])
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testSkipsItemWhenAnyFolderAboveItIsALink() async {
        fileSystem.symbolicLinks.insert("/Users/testuser/Library/Caches")

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [nil, .becameSymlink])
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testSkipsItemWhenLibraryItselfIsALink() async {
        fileSystem.symbolicLinks.insert("/Users/testuser/Library")

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [nil, .becameSymlink])
    }

    func testParentLinkToAnotherPlaceIsCaughtEvenWhenNoFolderReportsALink() async {
        // Only the resolved path shows that the item now lives outside the Library.
        fileSystem.resolvedPaths["/Users/testuser/Library/Application Support"] = URL(fileURLWithPath: "/Volumes/Elsewhere/Support")

        let results = await run(executor(), items: [item(Fixture.supportPath)])

        XCTAssertEqual(reasons(results), [nil, .becameSymlink])
    }

    func testSkipsItemThatIsGone() async {
        fileSystem.existingFiles[Fixture.cachePath] = nil

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [nil, .missing])
    }

    func testLockedItemInRequestIsNeverMoved() async {
        let items = [
            item(Fixture.cachePath, lock: .protectedByMacOS),
            item(Fixture.prefsPath, lock: .nameNotCertain),
        ]

        let results = await run(executor(), items: items)

        XCTAssertEqual(reasons(results), [nil, .protectedByMacOS, .targetChanged])
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testItemOutsideLibraryIsNeverMoved() async {
        let escape = Fixture.home + "/Library/../Documents/Sample"
        let throughLink = Fixture.home + "/Library/Caches/lnk/../../Sample"
        let items = [Fixture.outsidePath, Fixture.home + "/Library", escape, throughLink].map { item($0) }

        let results = await run(executor(), items: items)

        XCTAssertEqual(reasons(results), [nil] + Array(repeating: .targetChanged, count: 4))
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testTopLevelLibraryFoldersAreNeverMoved() async {
        let folders = ["Caches", "Preferences", "Application Support"].map { item(Fixture.home + "/Library/" + $0) }

        let results = await run(executor(), items: folders)

        XCTAssertEqual(reasons(results), [nil] + Array(repeating: .targetChanged, count: 3))
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testOneItemFailureDoesNotStopOthers() async {
        fileSystem.trashItemResults[Fixture.cachePath] = .failure(NSError(domain: NSCocoaErrorDomain, code: Fixture.failureCode))

        let results = await run(executor(), items: [item(Fixture.cachePath), item(Fixture.prefsPath), item(Fixture.supportPath)])

        XCTAssertEqual(reasons(results), [nil, .other(domain: NSCocoaErrorDomain, code: Fixture.failureCode), nil, nil])
        XCTAssertEqual(fileSystem.trashItemCalls.count, 4)
    }

    func testPermissionFailureOnAnItemIsReportedAndNeverGoesToFinder() async {
        fileSystem.trashItemResults[Fixture.cachePath] = .failure(permissionError())

        let results = await run(executor(finderHandOffEnabled: true), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [nil, .permissionDenied])
        XCTAssertTrue(finder.moveToTrashCalls.isEmpty)
    }

    // MARK: - Finder hand-off

    func testUsesFinderOnPermissionFailure() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(permissionError())
        let clearing = FileClearingFinder(fileSystem: fileSystem, base: finder)

        let results = await run(executor(finder: clearing, finderHandOffEnabled: true), items: [item(Fixture.cachePath)])

        XCTAssertEqual(results.map(\.outcome), [.moved(to: nil), .moved(to: Fixture.trashedURL)])
        XCTAssertEqual(finder.moveToTrashCalls.map(\.url.path), [Fixture.appPath])
        XCTAssertEqual(finder.moveToTrashCalls.first?.timeout, Fixture.finderTimeoutValue)
        XCTAssertEqual(fileSystem.trashItemCalls.first?.path, Fixture.appPath)
    }

    func testUsesFinderWhenWrappedErrorIsAPermissionFailure() async {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: Fixture.failureCode, userInfo: [NSUnderlyingErrorKey: permissionError()])
        fileSystem.trashItemResults[Fixture.appPath] = .failure(wrapped)
        let clearing = FileClearingFinder(fileSystem: fileSystem, base: finder)

        let results = await run(executor(finder: clearing, finderHandOffEnabled: true), items: [])

        XCTAssertEqual(results.map(\.outcome), [.moved(to: nil)])
    }

    func testFlagOffReportsPermissionDeniedAndNeverCallsFinder() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(permissionError())

        let results = await run(executor(finderHandOffEnabled: false), target: target(needsFinder: true), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.permissionDenied, .appDidNotMove])
        XCTAssertTrue(finder.moveToTrashCalls.isEmpty)
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testFinderRefusalLeavesEverythingInPlace() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(permissionError())
        finder.defaultOutcome = .consentRefused

        let results = await run(executor(finderHandOffEnabled: true), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.finderConsentRefused, .appDidNotMove])
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testFinderCancelLeavesEverythingInPlace() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(permissionError())
        finder.defaultOutcome = .cancelled

        let results = await run(executor(finderHandOffEnabled: true), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.finderCancelled, .appDidNotMove])
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testFinderTimeoutAndFailureAreReported() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(permissionError())
        finder.defaultOutcome = .timedOut
        let timedOut = await run(executor(finderHandOffEnabled: true), items: [])
        finder.defaultOutcome = .failed(code: Fixture.finderFailureCode)
        let failed = await run(executor(finderHandOffEnabled: true), items: [])

        XCTAssertEqual(reasons(timedOut), [.finderTimedOut])
        guard case let .notMoved(.other(domain, code)) = failed.first?.outcome else {
            return XCTFail("Expected an other failure")
        }
        XCTAssertFalse(domain.isEmpty)
        XCTAssertEqual(code, Fixture.finderFailureCode)
    }

    func testFinderMovedButAppStillThereIsReportedAsFailure() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(permissionError())
        // The plain mock Finder says "moved" and leaves the app in place.

        let results = await run(executor(finderHandOffEnabled: true), items: [item(Fixture.cachePath)])

        guard case let .notMoved(.other(domain, code)) = results.first?.outcome else {
            return XCTFail("Expected an other failure")
        }
        XCTAssertFalse(domain.isEmpty)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(reasons(results).last, .appDidNotMove)
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    // MARK: - App failures

    func testAppThatVanishesBeforeTheMoveIsReportedMissing() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(CocoaError(.fileNoSuchFile))

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.missing, .appDidNotMove])
        XCTAssertEqual(fileSystem.trashItemCalls.map(\.path), [Fixture.appPath])
    }

    func testOtherAppErrorIsReported() async {
        fileSystem.trashItemResults[Fixture.appPath] = .failure(NSError(domain: NSPOSIXErrorDomain, code: Fixture.failureCode))

        let results = await run(executor(), items: [item(Fixture.cachePath)])

        XCTAssertEqual(reasons(results), [.other(domain: NSPOSIXErrorDomain, code: Fixture.failureCode), .appDidNotMove])
    }

    // MARK: - Removal calls

    func testNeverCallsRemoveItem() async {
        fileSystem.trashItemResults[Fixture.cachePath] = .failure(permissionError())

        _ = await run(executor(), items: [item(Fixture.cachePath), item(Fixture.prefsPath)])

        XCTAssertTrue(fileSystem.removeItemCalls.isEmpty)
        XCTAssertTrue(fileSystem.moveItemCalls.isEmpty)
        XCTAssertTrue(fileSystem.copyItemCalls.isEmpty)
    }
}

/// A Finder that really takes the item away in the mock file system, so the executor's check that
/// the app left its place can pass.
private final class FileClearingFinder: FinderTrashProtocol {
    private let fileSystem: MockFileSystem
    private let base: MockFinderTrash

    init(fileSystem: MockFileSystem, base: MockFinderTrash) {
        self.fileSystem = fileSystem
        self.base = base
    }

    func moveToTrash(_ url: URL, timeout: TimeInterval) async -> FinderTrashOutcome {
        let outcome = await base.moveToTrash(url, timeout: timeout)
        if outcome == .moved {
            fileSystem.existingFiles[url.path] = nil
        }
        return outcome
    }
}

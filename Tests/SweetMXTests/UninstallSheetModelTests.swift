import AppKit
@testable import SweetMX
import XCTest

/// Proves the decisions of the uninstall sheet without rendering it: what can be ticked, what the
/// button promises, and that only ticked, unlocked rows reach the executor. Scripted seams only.
@MainActor
final class UninstallSheetModelTests: XCTestCase {
    private typealias Path = UninstallSheetFixture.Path
    private typealias Size = UninstallSheetFixture.Size

    private enum Fixture {
        static let permissionCode = 513
        static let vendorPage = "https://example.com/uninstall"
        static let unsafeLink = "file:///etc/hosts"
        static let otherAppPath = "/Applications/Other.app"
        static let otherAppName = "Other"
        /// A file name with a right-to-left override and a newline, which must never reach the screen raw.
        static let hostileAppPath = "/Applications/Sam\u{202E}ple\nPro.app"
        static let cleanedHostileName = "Sample Pro"
        /// Key code of "a"; the handler matches the character, the code only builds the event.
        static let aKeyCode: UInt16 = 0
        static let choiceKey = "a"
    }

    private var world: UninstallSheetFixture!

    override func setUp() async throws {
        try await super.setUp()
        world = UninstallSheetFixture()
    }

    override func tearDown() async throws {
        world.launcher.hide()
        world = nil
        try await super.tearDown()
    }

    /// Settings, cache and a name match (selectable) plus the container (locked).
    private func fullModel() async -> UninstallSheetModel {
        world.addBundleIDItems()
        world.addNameMatch()
        world.addContainer()
        return await world.loadedModel()
    }

    private func index(of path: String, in model: UninstallSheetModel) throws -> Int {
        try XCTUnwrap(model.rows.firstIndex { $0.item.url.path == path })
    }

    private func size(_ bytes: Int64) -> String {
        DesignTokens.uninstallSize(bytes, locale: UninstallSheetFixture.locale)
    }

    // MARK: - Choice and ticks

    func testStartsOnAppOnlyWithNothingTicked() async {
        let model = await fullModel()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.choice, .appOnly)
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertFalse(model.rows.contains(where: \.isTicked))
        XCTAssertTrue(model.canConfirm)
    }

    func testListsSelectableRowsBeforeLockedOnes() async {
        let model = await fullModel()

        XCTAssertEqual(model.rows.map(\.isLocked), [false, false, false, true])
        XCTAssertEqual(model.rows.last?.item.lock, .protectedByMacOS)
    }

    func testChoosingEverythingTicksOnlyUnlockedRows() async throws {
        let model = await fullModel()

        model.setChoice(.everything)

        XCTAssertEqual(model.choice, .everything)
        XCTAssertTrue(model.rows.filter { !$0.isLocked }.allSatisfy(\.isTicked))
        XCTAssertFalse(try model.rows[index(of: Path.container, in: model)].isTicked)
    }

    func testChoosingAppOnlyUnticksEverything() async {
        let model = await fullModel()
        model.setChoice(.everything)

        model.setChoice(.appOnly)

        XCTAssertFalse(model.rows.contains(where: \.isTicked))
    }

    func testUntickingOneRowAfterEverythingSelectsNoSegment() async throws {
        let model = await fullModel()
        model.setChoice(.everything)

        try model.toggle(index(of: Path.cache, in: model))

        XCTAssertNil(model.choice)
        XCTAssertEqual(model.rows.filter(\.isTicked).count, 2)
    }

    func testTickingEveryUnlockedRowByHandSelectsEverything() async throws {
        let model = await fullModel()

        XCTAssertEqual(model.choice, .appOnly)
        for path in [Path.settings, Path.cache] {
            try model.toggle(index(of: path, in: model))
            XCTAssertNil(model.choice)
        }
        try model.toggle(index(of: Path.nameMatch, in: model))

        XCTAssertEqual(model.choice, .everything)
    }

    func testUntickingTheLastRowSelectsAppOnly() async throws {
        let model = await fullModel()
        try model.toggle(index(of: Path.cache, in: model))
        XCTAssertNil(model.choice)

        try model.toggle(index(of: Path.cache, in: model))

        XCTAssertEqual(model.choice, .appOnly)
    }

    func testChoosingAppOnlyFromAMixClearsEveryTick() async throws {
        let model = await fullModel()
        try model.toggle(index(of: Path.cache, in: model))

        model.setChoice(.appOnly)

        XCTAssertEqual(model.choice, .appOnly)
        XCTAssertFalse(model.rows.contains(where: \.isTicked))
        XCTAssertEqual(model.confirmTitle, "Move 1 item to Trash (\(size(Size.app)))")
    }

    func testChoosingEverythingFromAMixTicksEveryUnlockedRow() async throws {
        let model = await fullModel()
        try model.toggle(index(of: Path.cache, in: model))

        model.setChoice(.everything)

        XCTAssertEqual(model.choice, .everything)
        XCTAssertEqual(model.rows.filter(\.isTicked).count, 3)
    }

    // MARK: - Command-A

    func testCommandAFlipsTheChoice() async {
        let model = await fullModel()

        model.toggleChoice()
        XCTAssertEqual(model.choice, .everything)
        model.toggleChoice()
        XCTAssertEqual(model.choice, .appOnly)
    }

    func testCommandAFromAMixChoosesEverything() async throws {
        let model = await fullModel()
        try model.toggle(index(of: Path.cache, in: model))

        model.toggleChoice()

        XCTAssertEqual(model.choice, .everything)
    }

    func testCommandADoesNothingWhenBlockedRefusedOrMoving() async {
        world.addBundleIDItems()
        world.addSystemExtension()
        let blocked = await world.loadedModel()
        blocked.toggleChoice()
        XCTAssertFalse(blocked.rows.contains(where: \.isTicked))

        let refusedWorld = UninstallSheetFixture()
        refusedWorld.fileSystem.symbolicLinks.insert(Path.app)
        let refused = await refusedWorld.loadedModel()
        refused.toggleChoice()
        XCTAssertFalse(refused.canChoose)
        refusedWorld.launcher.hide()

        let movingWorld = UninstallSheetFixture()
        movingWorld.addBundleIDItems()
        let moving = await movingWorld.loadedModel()
        moving.confirm()
        moving.toggleChoice()
        XCTAssertFalse(moving.rows.contains(where: \.isTicked))
        await moving.moveTask?.value
        movingWorld.launcher.hide()
    }

    func testCommandAKeyFlipsOnceAndIgnoresRepeats() async throws {
        let model = await fullModel()

        XCTAssertTrue(try UninstallPrompt.handle(commandA(repeat: false), model: model))
        XCTAssertEqual(model.choice, .everything)
        XCTAssertTrue(try UninstallPrompt.handle(commandA(repeat: true), model: model))
        XCTAssertEqual(model.choice, .everything)
    }

    private func commandA(repeat isRepeat: Bool) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: Fixture.choiceKey, charactersIgnoringModifiers: Fixture.choiceKey, isARepeat: isRepeat,
            keyCode: Fixture.aKeyCode
        ))
    }

    func testArrowKeysAskForListFocusEvenAtTheEnd() async {
        let model = await fullModel()

        model.moveFocus(by: -1)
        model.moveFocus(by: 1)

        XCTAssertEqual(model.listFocusRequests, 2)
    }

    func testLockedRowsNeverToggle() async throws {
        let model = await fullModel()
        let locked = try index(of: Path.container, in: model)

        model.toggle(locked)
        model.moveFocus(by: model.rows.count)
        model.toggleFocusedRow()

        XCTAssertEqual(model.focusedRow, locked)
        XCTAssertFalse(model.rows[locked].isTicked)
    }

    func testArrowFocusStopsAtTheEnds() async {
        let model = await fullModel()

        model.moveFocus(by: -1)
        XCTAssertEqual(model.focusedRow, model.rows.count - 1)
        model.moveFocus(by: 1)
        XCTAssertEqual(model.focusedRow, model.rows.count - 1)
        model.moveFocus(by: -model.rows.count)
        XCTAssertEqual(model.focusedRow, 0)
        model.toggleFocusedRow()
        XCTAssertTrue(model.rows[0].isTicked)
    }

    // MARK: - Button title

    func testButtonTitleCountsAppAlone() async {
        let model = await fullModel()

        XCTAssertEqual(model.confirmTitle, "Move 1 item to Trash (\(size(Size.app)))")
    }

    func testButtonTitleAddsTickedSizes() async throws {
        let model = await fullModel()

        try model.toggle(index(of: Path.settings, in: model))
        try model.toggle(index(of: Path.cache, in: model))

        XCTAssertEqual(model.confirmTitle, "Move 3 items to Trash (\(size(Size.app + Size.settings + Size.cache)))")
    }

    func testButtonTitleSaysAtLeastWhenASizeIsUnknown() async throws {
        let model = await fullModel()

        try model.toggle(index(of: Path.nameMatch, in: model))

        XCTAssertEqual(model.confirmTitle, "Move 2 items to Trash (at least \(size(Size.app)))")
    }

    func testButtonTitleHasNoSizeWhenNothingIsKnown() async {
        world.fileSystem.allocatedSizes[Path.app] = nil

        let model = await world.loadedModel()

        XCTAssertEqual(model.confirmTitle, "Move 1 item to Trash")
    }

    // MARK: - When confirming is off

    func testCannotConfirmWhileScanning() {
        world.launcher.show(mode: .applications)
        let model = UninstallSheetModel(bundlePath: Path.app, launcher: world.launcher, dependencies: world.dependencies)

        XCTAssertEqual(model.phase, .scanning)
        XCTAssertFalse(model.canConfirm)
    }

    func testRefusalShowsNoDestructiveAction() async {
        world.fileSystem.symbolicLinks.insert(Path.app)

        let model = await world.loadedModel()

        XCTAssertEqual(model.refusal, .symlinkedApp)
        XCTAssertNil(model.target)
        XCTAssertTrue(model.isBlocked)
        XCTAssertFalse(model.canConfirm)
        model.confirm()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(world.fileSystem.trashItemCalls.isEmpty)
    }

    func testRefusedAndBlockedSheetsDoNotAsk() async {
        world.addSystemExtension()
        let blocked = await world.loadedModel()
        XCTAssertEqual(blocked.title, DesignTokens.Copy.uninstallRefusedTitle(Path.displayName))

        let ready = UninstallSheetFixture()
        let model = await ready.loadedModel()
        XCTAssertEqual(model.title, DesignTokens.Copy.uninstallTitle(Path.displayName))
        ready.launcher.hide()
    }

    /// The window title and its spoken label follow the loaded title, so a blocked sheet stops asking.
    func testLoadReportsTheRefusedTitleToTheWindow() async {
        world.addSystemExtension()
        world.launcher.show(mode: .applications)
        let model = UninstallSheetModel(bundlePath: Path.app, launcher: world.launcher, dependencies: world.dependencies)
        var reported: [String] = []
        model.onTitleChange = { reported.append($0) }

        model.start()
        await model.loadTask?.value

        XCTAssertEqual(reported, [DesignTokens.Copy.uninstallRefusedTitle(Path.displayName)])
    }

    /// A related file's name can carry a right-to-left override that would make the shown path lie.
    func testShownPathsCleanTheFileName() async {
        let override = "\u{202E}"
        let spoofed = Path.home + "/Library/Application Support/" + Path.displayName + override + "fdp.exe"
        world.put(spoofed, size: nil)

        let model = await world.loadedModel()
        let url = URL(fileURLWithPath: spoofed)

        XCTAssertFalse(model.fullPath(url).contains(override))
        XCTAssertFalse(model.displayPath(url).contains(override))
        XCTAssertTrue(model.fullPath(url).hasPrefix(Path.home + "/Library/Application Support/"))
    }

    func testBlockingNoticeTurnsConfirmOff() async {
        world.addBundleIDItems()
        world.addSystemExtension()

        let model = await world.loadedModel()

        XCTAssertTrue(model.notices.contains(where: \.blocksRemoval))
        XCTAssertTrue(model.isBlocked)
        XCTAssertFalse(model.canConfirm)
        model.setChoice(.everything)
        XCTAssertFalse(model.rows.contains(where: \.isTicked))
    }

    func testCannotConfirmWhileMoving() async {
        let model = await fullModel()

        model.confirm()

        XCTAssertEqual(model.phase, .moving)
        XCTAssertFalse(model.canConfirm)
        XCTAssertFalse(model.canCancel)
        await model.moveTask?.value
    }

    // MARK: - App index

    func testIndexNotLoadedLocksNameRows() async {
        world.installedApps = nil
        world.addBundleIDItems()
        world.addNameMatch()

        let model = await world.loadedModel()

        XCTAssertEqual(model.rows.count, 3)
        XCTAssertTrue(model.rows.allSatisfy(\.isLocked))
        XCTAssertTrue(model.rows.allSatisfy { $0.item.lock == .appListNotReady })
        XCTAssertFalse(model.canChoose)
    }

    func testIndexWithoutTheTargetLocks() async {
        world.installedApps = [ApplicationInfo(name: Fixture.otherAppName, bundlePath: Fixture.otherAppPath)]
        world.addNameMatch()

        let model = await world.loadedModel()

        XCTAssertEqual(model.rows.first?.item.lock, .appListNotReady)
    }

    func testIndexListingTheTargetUnderAnUnnormalizedPathCountsAsListed() async {
        let unnormalized = Path.appFolder + "/./" + Path.appFileName
        world.installedApps = [ApplicationInfo(name: Path.displayName, bundlePath: unnormalized)]
        world.addNameMatch()

        let model = await world.loadedModel()

        XCTAssertEqual(model.rows.map(\.isLocked), [false])
    }

    func testIndexListingTheTargetLeavesUniqueRowsSelectable() async {
        world.addNameMatch()

        let model = await world.loadedModel()

        XCTAssertEqual(model.rows.map(\.isLocked), [false])
    }

    // MARK: - Words

    func testSizesFollowTheInjectedLocale() async {
        let model = await world.loadedModel()

        XCTAssertEqual(model.sizeText(Size.app), "52.4 MB")
    }

    func testPermissionSentenceNamesFinderPasswordOnlyForTheApp() async {
        let model = await world.loadedModel()
        let denied = UninstallItemResult.Outcome.notMoved(.permissionDenied)

        XCTAssertEqual(
            model.sentence(for: UninstallItemResult(url: world.appURL, isApp: true, outcome: denied)),
            DesignTokens.Copy.uninstallReason(.permissionDenied, isApp: true)
        )
        XCTAssertEqual(
            model.sentence(for: UninstallItemResult(url: URL(fileURLWithPath: Path.cache), isApp: false, outcome: denied)),
            DesignTokens.Copy.uninstallItemPermissionDenied
        )
        XCTAssertNotEqual(
            DesignTokens.Copy.uninstallReason(.permissionDenied, isApp: true),
            DesignTokens.Copy.uninstallItemPermissionDenied
        )
    }

    func testNamesAreCleanedBeforeTheTargetResolves() {
        world.launcher.show(mode: .applications)
        let model = UninstallSheetModel(bundlePath: Fixture.hostileAppPath, launcher: world.launcher, dependencies: world.dependencies)

        XCTAssertEqual(model.displayName, Fixture.cleanedHostileName)
        XCTAssertEqual(model.itemName(URL(fileURLWithPath: Fixture.hostileAppPath)), Fixture.cleanedHostileName + ".app")
    }

    // MARK: - Administrator line

    func testAdministratorLineFollowsTheFinderPolicy() async {
        world.makeAppFolderReadOnly()

        let manual = await world.loadedModel()
        XCTAssertEqual(manual.administratorNote, DesignTokens.Copy.uninstallMayNeedAdministrator)
        XCTAssertTrue(manual.canConfirm)

        world.finderHandOffEnabled = true
        let handOff = await world.loadedModel()
        XCTAssertEqual(handOff.administratorNote, DesignTokens.Copy.uninstallFinderWillAsk)
    }

    func testNoAdministratorLineForAWritableFolder() async {
        let model = await world.loadedModel()

        XCTAssertNil(model.administratorNote)
    }

    // MARK: - Moving

    func testConfirmSendsOnlyTickedUnlockedRows() async throws {
        let model = await fullModel()
        try model.toggle(index(of: Path.cache, in: model))

        model.confirm()
        await model.moveTask?.value

        XCTAssertEqual(world.fileSystem.trashItemCalls.map(\.path), [Path.app, Path.cache])
    }

    func testAllMovedSetsTheInfoStatusAndClosesTheSheet() async {
        let model = await fullModel()
        var closed = false
        model.onClose = { closed = true }
        model.setChoice(.everything)

        model.confirm()
        await model.moveTask?.value

        XCTAssertTrue(closed)
        XCTAssertFalse(model.showsResults)
        XCTAssertEqual(world.launcher.status, .info(DesignTokens.Copy.uninstallMovedStatus(4)))
        XCTAssertNil(world.launcher.pendingUninstallResults)
    }

    func testFailureProducesResultRows() async throws {
        let model = await fullModel()
        var closed = false
        model.onClose = { closed = true }
        try model.toggle(index(of: Path.cache, in: model))
        world.fileSystem.trashItemResults[Path.cache] = .failure(
            NSError(domain: NSCocoaErrorDomain, code: Fixture.permissionCode)
        )

        model.confirm()
        await model.moveTask?.value

        XCTAssertFalse(closed)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertTrue(model.showsResults)
        XCTAssertEqual(model.results?.map(\.url.path), [Path.app, Path.cache])
        XCTAssertEqual(model.results?.last?.outcome, .notMoved(.permissionDenied))
        XCTAssertNil(world.launcher.status)
    }

    /// Closing during a move is not a cancel: the move ends normally and its results wait.
    func testResultsWaitWhenTheLauncherClosedDuringTheMove() async {
        let model = await fullModel()
        var reported = false
        model.onFinishedWithoutSheet = { reported = true }

        model.confirm()
        world.launcher.hide()
        model.sheetDidClose()
        await model.moveTask?.value

        XCTAssertTrue(reported)
        XCTAssertEqual(world.launcher.pendingUninstallResults?.map(\.url.path), [Path.app])
        XCTAssertTrue(UninstallSheetModel.allMoved(world.launcher.pendingUninstallResults ?? []))
        XCTAssertEqual(world.fileSystem.trashItemCalls.map(\.path), [Path.app])
    }

    func testLaterResultsAreAppendedToPendingOnes() async {
        let earlier = UninstallItemResult(url: URL(fileURLWithPath: Fixture.otherAppPath), isApp: true, outcome: .moved(to: nil))
        world.launcher.pendingUninstallResults = [earlier]
        let model = await fullModel()

        model.confirm()
        world.launcher.hide()
        model.sheetDidClose()
        await model.moveTask?.value

        XCTAssertEqual(world.launcher.pendingUninstallResults?.map(\.url.path), [Fixture.otherAppPath, Path.app])
    }

    func testOnlyOneMoveRunsAtATime() async {
        let model = await fullModel()
        let second = UninstallSheetModel(bundlePath: Path.app, launcher: world.launcher, dependencies: world.dependencies)
        second.start()
        await second.loadTask?.value

        model.confirm()
        XCTAssertTrue(world.launcher.uninstallInFlight)
        second.confirm()
        XCTAssertEqual(second.phase, .ready)
        UninstallPrompt.present(bundlePath: Path.app, for: world.launcher, over: NSWindow())
        XCTAssertEqual(world.launcher.status, .info(DesignTokens.Copy.uninstallStillRunning))

        await model.moveTask?.value
        XCTAssertFalse(world.launcher.uninstallInFlight)
        XCTAssertEqual(world.fileSystem.trashItemCalls.map(\.path), [Path.app])
    }

    func testPendingAllMovedResultsBecomeTheStatusOnNextOpening() {
        world.launcher.pendingUninstallResults = [
            UninstallItemResult(url: world.appURL, isApp: true, outcome: .moved(to: nil)),
        ]
        world.launcher.show(mode: .applications)

        UninstallPrompt.presentPendingResults(for: world.launcher, over: NSWindow())

        XCTAssertNil(world.launcher.pendingUninstallResults)
        XCTAssertEqual(world.launcher.status, .info(DesignTokens.Copy.uninstallMovedStatus(1)))
    }

    // MARK: - Leaving

    func testClosingWhileScanningStopsTheLoad() async {
        world.addBundleIDItems()
        world.launcher.show(mode: .applications)
        let model = UninstallSheetModel(bundlePath: Path.app, launcher: world.launcher, dependencies: world.dependencies)

        model.start()
        model.sheetDidClose()
        await model.loadTask?.value

        XCTAssertEqual(model.loadTask?.isCancelled, true)
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertTrue(world.fileSystem.contentsOfDirectoryCalls.isEmpty)
        XCTAssertTrue(world.fileSystem.allocatedSizeCalls.isEmpty)
    }

    func testShowInFinderClosesSheetAndLauncherThenReveals() async {
        let model = await fullModel()
        var closed = false
        model.onClose = { closed = true }

        model.showInFinder(URL(fileURLWithPath: Path.container))

        XCTAssertTrue(closed)
        XCTAssertEqual(world.workspace.revealInFinderCalls.map(\.path), [Path.container])
        XCTAssertTrue(world.fileSystem.trashItemCalls.isEmpty)
    }

    func testOnlyWebPagesOpenFromANotice() async throws {
        let model = await fullModel()

        try model.openInstructions(XCTUnwrap(URL(string: Fixture.unsafeLink)))
        XCTAssertTrue(world.workspace.openCalls.isEmpty)

        try model.openInstructions(XCTUnwrap(URL(string: Fixture.vendorPage)))
        XCTAssertEqual(world.workspace.openCalls.map(\.absoluteString), [Fixture.vendorPage])
    }
}

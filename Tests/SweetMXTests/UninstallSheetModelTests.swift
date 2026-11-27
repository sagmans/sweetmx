import Foundation
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
        DesignTokens.uninstallSize(bytes)
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

    func testUntickingOneRowMovesChoiceBackToAppOnly() async throws {
        let model = await fullModel()
        model.setChoice(.everything)

        try model.toggle(index(of: Path.cache, in: model))

        XCTAssertEqual(model.choice, .appOnly)
        XCTAssertEqual(model.rows.filter(\.isTicked).count, 2)
    }

    func testTickingEveryUnlockedRowByHandSelectsEverything() async throws {
        let model = await fullModel()

        for path in [Path.settings, Path.cache] {
            try model.toggle(index(of: path, in: model))
            XCTAssertEqual(model.choice, .appOnly)
        }
        try model.toggle(index(of: Path.nameMatch, in: model))

        XCTAssertEqual(model.choice, .everything)
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

    func testClosingWhileScanningStopsTheLoad() {
        world.launcher.show(mode: .applications)
        let model = UninstallSheetModel(bundlePath: Path.app, launcher: world.launcher, dependencies: world.dependencies)

        model.start()
        model.sheetDidClose()

        XCTAssertEqual(model.loadTask?.isCancelled, true)
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

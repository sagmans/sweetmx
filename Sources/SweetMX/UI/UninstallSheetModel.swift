import Foundation
import Observation

/// Every decision of the uninstall sheets, kept apart from the views so tests can prove what the
/// person can tick and what reaches the executor without rendering anything.
///
/// `UninstallPrompt` creates one per sheet and the views only draw what it publishes. The resolver, the
/// scan and the size reads touch the disk, so they run off the main actor while the sheet already
/// shows a progress line.
@MainActor @Observable
final class UninstallSheetModel {
    /// Where the sheet is in its short life. A refusal ends scanning in `ready` with no target.
    enum Phase: Equatable {
        /// Resolving the app and scanning its related files.
        case scanning
        case ready
        case moving
        case finished
    }

    /// The two-way choice at the top. It starts on `appOnly` so the destructive choice is a deliberate act.
    enum Choice: Hashable {
        case appOnly
        case everything
    }

    /// One related item with the person's tick on it.
    struct Row: Identifiable, Equatable {
        let item: RelatedItem
        var isTicked: Bool

        var id: String {
            item.id
        }

        var isLocked: Bool {
            item.lock != nil
        }
    }

    /// What the background load found; plain values so it can cross back to the main actor.
    private enum LoadOutcome: Sendable {
        case refused(UninstallRefusal)
        case ready(target: UninstallTarget, appSize: Int64?, items: [RelatedItem], notices: [UninstallNotice])
    }

    private(set) var phase: Phase = .scanning
    private(set) var target: UninstallTarget?
    private(set) var refusal: UninstallRefusal?
    private(set) var appSizeBytes: Int64?
    private(set) var notices: [UninstallNotice] = []
    /// Selectable rows first, then locked ones, so the list reads "what can move" before "what stays".
    private(set) var rows: [Row] = []
    private(set) var choice: Choice = .appOnly
    /// The row the arrow keys point at; nil until the person presses one.
    private(set) var focusedRow: Int?
    /// Whether the app runs right now, so the sheet can say it will be asked to quit.
    private(set) var appIsRunning = false
    /// One result per item once the move ended, in executor order (app first).
    private(set) var results: [UninstallItemResult]?

    /// The path the person chose, captured when the sheet opened so a later list change cannot swap it.
    let bundlePath: String
    /// Name for the header before (or instead of) a resolved target.
    var displayName: String {
        target?.displayName ?? (bundlePath as NSString).lastPathComponent.replacingOccurrences(
            of: Self.appSuffix, with: "", options: [.anchored, .backwards, .caseInsensitive]
        )
    }

    /// Asks the sheet host to close the sheet; set by `UninstallPrompt`.
    @ObservationIgnored var onClose: () -> Void = {}
    /// Told the content size whenever it changes (rows arrived, results replaced the list), so the
    /// host can fit the sheet window to it.
    @ObservationIgnored var onSizeChange: (CGSize) -> Void = { _ in }
    /// Told when a move ended after the sheet was gone, so the host can show the stored results if the
    /// launcher is open again.
    @ObservationIgnored var onFinishedWithoutSheet: () -> Void = {}

    /// The background load, kept so closing the sheet can stop it and tests can await it.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// The move in flight; tests await it. It is never cancelled: closing cannot undo a move.
    @ObservationIgnored private(set) var moveTask: Task<Void, Never>?
    /// False once the host closed the sheet, so a late result goes to the launcher instead.
    @ObservationIgnored private var isSheetOpen = true

    private static let appSuffix = ".app"
    /// Only web pages may open from a notice; the vendor table holds nothing else, and this keeps it so.
    private static let allowedLinkScheme = "https"

    @ObservationIgnored private let launcher: LauncherModel
    @ObservationIgnored private let dependencies: UninstallDependencies

    /// Opens on a path; call `start()` to resolve and scan.
    init(bundlePath: String, launcher: LauncherModel, dependencies: UninstallDependencies) {
        self.bundlePath = bundlePath
        self.launcher = launcher
        self.dependencies = dependencies
    }

    /// A sheet for results that are already known, used when the launcher reopens after a move that
    /// finished while it was closed.
    init(results: [UninstallItemResult], launcher: LauncherModel, dependencies: UninstallDependencies) {
        bundlePath = results.first { $0.isApp }?.url.path ?? ""
        self.launcher = launcher
        self.dependencies = dependencies
        self.results = results
        phase = .finished
    }

    // MARK: - Derived state

    /// A refusal or a blocking notice turns the sheet into an explanation with no destructive action.
    var isBlocked: Bool {
        refusal != nil || notices.contains(where: \.blocksRemoval)
    }

    /// The vendor page of a blocking notice, the way out the blocked sheet offers instead of Finder.
    var blockingPage: URL? {
        for case let .blocked(_, page?) in notices {
            return page
        }
        return nil
    }

    var canConfirm: Bool {
        phase == .ready && target != nil && !isBlocked
    }

    var hasLockedRows: Bool {
        rows.contains(where: \.isLocked)
    }

    /// The Finder line under the button, or nil when the app's folder is writable.
    var administratorNote: String? {
        guard let target, target.needsFinder, !isBlocked else { return nil }
        return dependencies.finderHandOffEnabled
            ? DesignTokens.Copy.uninstallFinderWillAsk
            : DesignTokens.Copy.uninstallMayNeedAdministrator
    }

    /// Counts the app plus the ticked rows; sizes that are unknown are left out and the title then
    /// says "at least", so the number never promises more precision than the scan had.
    var confirmTitle: String {
        let ticked = rows.filter { $0.isTicked && !$0.isLocked }
        let sizes = [appSizeBytes] + ticked.map(\.item.sizeBytes)
        let known = sizes.compactMap(\.self)
        let size = known.isEmpty ? nil : DesignTokens.uninstallSize(known.reduce(0, +))
        return DesignTokens.Copy.uninstallMoveButton(
            count: 1 + ticked.count, size: size, sizeIsLowerBound: known.count < sizes.count
        )
    }

    /// The bundle path with the home folder shortened to `~`, like the spec's sheet.
    func displayPath(_ url: URL) -> String {
        let home = dependencies.fileSystem.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    var appLocation: String {
        let size = appSizeBytes.map(DesignTokens.uninstallSize) ?? DesignTokens.Copy.uninstallSizeUnknown
        return DesignTokens.Copy.uninstallLocation(displayPath(URL(fileURLWithPath: bundlePath)), size: size)
    }

    // MARK: - Loading

    /// Resolves the app and scans its files off the main actor. The sheet shows a progress row meanwhile.
    func start() {
        guard phase == .scanning, loadTask == nil else { return }
        let path = bundlePath
        let fileSystem = dependencies.fileSystem
        let resolver = UninstallTargetResolver(
            fileSystem: fileSystem, codeIdentity: dependencies.codeIdentity, ownBundleID: dependencies.ownBundleID
        )
        let otherApps = dependencies.otherApps()
        loadTask = Task { [weak self] in
            let outcome = await Self.load(path: path, resolver: resolver, fileSystem: fileSystem, otherApps: otherApps)
            guard !Task.isCancelled, let self else { return }
            apply(outcome)
        }
    }

    /// Every disk read of the sheet in one place, on the global executor.
    @concurrent
    private static func load(
        path: String, resolver: UninstallTargetResolver, fileSystem: FileSystemProtocol, otherApps: [ApplicationInfo]
    ) async -> LoadOutcome {
        switch resolver.resolve(bundlePath: path) {
        case let .failure(refusal):
            return .refused(refusal)
        case let .success(target):
            let homebrew = HomebrewReceipt.find(for: target, fileSystem: fileSystem)
            let items = RelatedItemScanner(fileSystem: fileSystem).scan(target, otherApps: otherApps, homebrew: homebrew)
            let notices = UninstallNotice.notices(for: target, homebrew: homebrew, fileSystem: fileSystem)
            let size = fileSystem.allocatedSize(at: target.bundleURL, limit: RelatedItemScanner.sizeEntryLimit)
            return .ready(target: target, appSize: size, items: items, notices: notices)
        }
    }

    private func apply(_ outcome: LoadOutcome) {
        switch outcome {
        case let .refused(refusal):
            self.refusal = refusal
        case let .ready(target, appSize, items, notices):
            self.target = target
            appSizeBytes = appSize
            self.notices = notices
            rows = (items.filter { $0.lock == nil } + items.filter { $0.lock != nil }).map { Row(item: $0, isTicked: false) }
            appIsRunning = dependencies.workspace.runningApplications(atBundleURL: target.bundleURL)
                .contains { !$0.isTerminated }
        }
        phase = .ready
    }

    // MARK: - Choosing

    /// "Everything" ticks every row without a lock; "app only" unticks all.
    func setChoice(_ newChoice: Choice) {
        guard phase == .ready, !isBlocked else { return }
        choice = newChoice
        for index in rows.indices where !rows[index].isLocked {
            rows[index].isTicked = newChoice == .everything
        }
    }

    /// A locked row never changes. The choice stays on "everything" only while every selectable row is
    /// ticked, so the control never claims more than the list shows.
    func toggle(_ index: Int) {
        guard phase == .ready, !isBlocked, rows.indices.contains(index), !rows[index].isLocked else { return }
        rows[index].isTicked.toggle()
        let selectable = rows.filter { !$0.isLocked }
        choice = !selectable.isEmpty && selectable.allSatisfy(\.isTicked) ? .everything : .appOnly
    }

    func toggleFocusedRow() {
        guard let focusedRow else { return }
        toggle(focusedRow)
    }

    /// Up and Down move one row and stop at the ends, so a held key never wraps.
    func moveFocus(by delta: Int) {
        guard phase == .ready, !isBlocked, !rows.isEmpty else { return }
        let next = (focusedRow ?? (delta > 0 ? -1 : rows.count)) + delta
        focusedRow = min(max(next, 0), rows.count - 1)
    }

    // MARK: - Moving

    /// Sends the app and only the ticked rows without a lock to the executor, so nothing the person did
    /// not choose, and nothing the scan locked, can move.
    func confirm() {
        guard canConfirm, let target else { return }
        phase = .moving
        let request = UninstallRequest(
            target: target,
            items: rows.filter { $0.isTicked && !$0.isLocked }.map(\.item)
        )
        let executor = UninstallExecutor(
            fileSystem: dependencies.fileSystem,
            workspace: dependencies.workspace,
            finder: dependencies.finder,
            resolver: UninstallTargetResolver(
                fileSystem: dependencies.fileSystem,
                codeIdentity: dependencies.codeIdentity,
                ownBundleID: dependencies.ownBundleID
            ),
            finderHandOffEnabled: dependencies.finderHandOffEnabled
        )
        // Holds the model strongly on purpose: the move must finish and report even if the sheet closed.
        moveTask = Task {
            let results = await executor.run(request)
            finish(results)
        }
    }

    /// All moved: the footer says so and the sheet closes. Anything left: the result list replaces the
    /// rows. A launcher that closed meanwhile keeps the results for its next opening.
    private func finish(_ results: [UninstallItemResult]) {
        self.results = results
        phase = .finished
        guard isSheetOpen, launcher.isPresented else {
            launcher.pendingUninstallResults = results
            onFinishedWithoutSheet()
            return
        }
        if Self.allMoved(results) {
            launcher.showUninstallStatus(.info(DesignTokens.Copy.uninstallMovedStatus(results.count)))
            onClose()
        }
    }

    /// The result view shows only when something stayed; an all-moved finish closes the sheet instead.
    var showsResults: Bool {
        guard phase == .finished, let results else { return false }
        return !Self.allMoved(results)
    }

    static func allMoved(_ results: [UninstallItemResult]) -> Bool {
        results.allSatisfy { result in
            if case .moved = result.outcome {
                return true
            }
            return false
        }
    }

    // MARK: - Leaving

    /// Esc does nothing while a move runs, because closing the sheet cannot stop it.
    var canCancel: Bool {
        phase != .moving
    }

    /// Cancel, Done and Esc all end here, so none of them can close the sheet during a move.
    func close() {
        guard canCancel else { return }
        onClose()
    }

    /// The host calls this whenever the sheet closes, by any path. A scan still running is stopped and
    /// its result dropped; a move goes on and reports to the launcher.
    func sheetDidClose() {
        isSheetOpen = false
        loadTask?.cancel()
    }

    /// Closes the sheet and the launcher, then shows the item, so Finder is in front when it appears.
    func showInFinder(_ url: URL) {
        guard leave() else { return }
        dependencies.workspace.revealInFinder(url)
    }

    /// Same as `showInFinder` for a vendor page. Anything but an https page is refused.
    func openInstructions(_ url: URL) {
        guard url.scheme?.lowercased() == Self.allowedLinkScheme, leave() else { return }
        dependencies.workspace.open(url)
    }

    /// Leaving is refused only while a move runs: before it nothing has moved, and after it the
    /// results were already shown.
    private func leave() -> Bool {
        guard phase != .moving else { return false }
        onClose()
        launcher.escape()
        return true
    }
}

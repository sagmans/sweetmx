import Foundation
import Observation

/// The uninstall state that outlives one sheet: the seams, the on switch, the one move slot, the results
/// that wait for the next opening, and the footer line.
///
/// A sub-model of `LauncherModel`, like `apps` and `clips`, so the state changes only through the few
/// calls below. A loose writable flag or list on the launcher could be set on one path and never
/// cleared on another, which would block every later uninstall or lose a result. The sheet model and
/// `UninstallPrompt` are its only writers.
@Observable
final class UninstallSession {
    /// System seams of the uninstall flow, built from the same workspace and file system as app search.
    @ObservationIgnored let dependencies: UninstallDependencies
    /// Whether uninstall is on; the key handler, row menu, footer, prompt and confirm all ask here, so
    /// one switch decides every way in.
    @ObservationIgnored let settings: UninstallSettings

    /// True from `begin()` until `finish(_:)`. One move at a time: a second sheet could offer files the
    /// first move is already taking, and its results would race the first one's.
    @ObservationIgnored private(set) var isInFlight = false
    /// Results of a move that finished after the sheet or the launcher closed, kept so the person still
    /// learns what moved. They wait until the launcher next opens in app mode; a clipboard opening
    /// leaves them here. Later results are appended, never written over, so no outcome is lost.
    @ObservationIgnored private(set) var pendingResults: [UninstallItemResult] = []
    /// Footer line after an uninstall; one launcher session long, like a launch failure.
    private(set) var status: LauncherStatus?

    init(dependencies: UninstallDependencies, settings: UninstallSettings) {
        self.dependencies = dependencies
        self.settings = settings
    }

    /// Read at use time so a changed preference applies at once.
    var isEnabled: Bool {
        settings.isEnabled
    }

    /// Takes the one move slot; false when another move holds it, and then nothing may start.
    func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    /// Frees the move slot. `unshown` holds the results no sheet showed; they wait for the next opening
    /// after any that already wait there.
    func finish(_ unshown: [UninstallItemResult]) {
        isInFlight = false
        pendingResults += unshown
    }

    /// Hands out the waiting results once, so two openings never show the same results.
    func takePending() -> [UninstallItemResult] {
        defer { pendingResults = [] }
        return pendingResults
    }

    /// Returns results a sheet could not show, ahead of any that arrived meanwhile, so the order stays
    /// the order the moves ended in.
    func putBack(_ results: [UninstallItemResult]) {
        pendingResults = results + pendingResults
    }

    /// Only `LauncherModel` calls this, after it checked that app search is on screen.
    func show(_ newStatus: LauncherStatus) {
        status = newStatus
    }

    /// Part of the launcher's single status reset, so a new opening or a typed query never keeps it.
    func clearStatus() {
        status = nil
    }
}

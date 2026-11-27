import Foundation

/// Switches that decide how far uninstall may go on a system it has not been proven on.
nonisolated enum UninstallPolicy {
    /// Off because the Finder hand-off (Finder shows the administrator prompt) is unproven on this
    /// macOS release. While it is off, a permission failure is reported as such, so the person can
    /// finish the removal in Finder themselves. `UninstallExecutor` takes the value through its
    /// initializer so tests cover both settings. Before this flag is turned on, the links on the target
    /// must be checked again right before the Finder request, because Finder follows a link the move
    /// check never saw; that check does not exist yet.
    static let finderHandOffEnabled = false

    /// How long an app gets to quit after a polite request; a document with unsaved changes may
    /// keep it open, and the flow must stop waiting instead of forcing it closed. Policy, not a
    /// design token: it decides when uninstall gives up, not how anything looks.
    static let quitTimeout: Duration = .seconds(10)
    /// How often the flow looks again, short enough that a quick quit does not feel slow.
    static let quitPollInterval: Duration = .milliseconds(100)
    /// How long Finder gets to move one item, including time for a person to type a password.
    static let finderTrashTimeout: Duration = .seconds(120)
}

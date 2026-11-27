import Foundation

/// How a Finder Trash request ended, so the flow can tell a person what happened and what to do next.
public nonisolated enum FinderTrashOutcome: Equatable, Sendable {
    case moved
    /// The person dismissed Finder's password prompt.
    case cancelled
    /// macOS refused SweetMX permission to control Finder.
    case consentRefused
    case timedOut
    /// Any other error; the code is kept so the log can name it.
    case failed(code: Int)
}

/// Moves an item to the Trash through Finder, for items SweetMX cannot trash itself because the
/// account needs an administrator. Finder shows the password prompt, so SweetMX never sees a password.
///
/// Nonisolated and Sendable because the wait for Finder must not block the main actor.
public nonisolated protocol FinderTrashProtocol: Sendable {
    /// Asks Finder to move one item to Trash. Finder owns any password prompt.
    func moveToTrash(_ url: URL, timeout: TimeInterval) async -> FinderTrashOutcome
}

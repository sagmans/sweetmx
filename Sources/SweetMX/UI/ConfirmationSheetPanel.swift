import AppKit

/// Sheet host that can take keyboard focus without pulling SweetMX ahead of the app behind the launcher.
///
/// Its own file so every sheet on the launcher panel can share the same focus rules.
final class ConfirmationSheetPanel: NSPanel {
    /// Required so Return and Escape reach the sheet even while SweetMX stays non-activating.
    override var canBecomeKey: Bool {
        true
    }

    /// A confirmation sheet is transient and must never take over the main-window role.
    override var canBecomeMain: Bool {
        false
    }

    /// Ensures Escape routed via accessibility or responder commands cancels the sheet just like the key monitor.
    override func cancelOperation(_ sender: Any?) {
        if let parent = sheetParent {
            parent.endSheet(self, returnCode: .cancel)
        } else {
            super.cancelOperation(sender)
        }
    }
}

import AppKit
import SwiftUI

/// Sheet host that can take keyboard focus without pulling SweetMX ahead of the app behind the launcher.
///
/// Its own file so every sheet on the launcher panel can share the same focus rules.
final class ConfirmationSheetPanel: NSPanel {
    /// Asked before a responder-driven cancel closes the sheet. The uninstall sheet answers false while
    /// a move runs, because closing cannot undo a move in flight; the clipboard sheet keeps the default.
    var canCancel: () -> Bool = { true }

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
        guard canCancel() else { return }
        if let parent = sheetParent {
            parent.endSheet(self, returnCode: .cancel)
        } else {
            super.cancelOperation(sender)
        }
    }

    /// Opens `rootView` as a glass sheet on `window`: no title bar, never movable, sized to its content.
    /// The clipboard and uninstall prompts both call it, so the two sheets cannot drift apart in look or
    /// in how their keys are caught.
    ///
    /// `prepare` runs before the sheet opens, so callbacks that follow the sheet are in place when it
    /// first lays out. `keyHandler` sees only the sheet's own key-downs and returns true for a key it
    /// used. `onEnd` runs once the sheet closed, after the key monitor is gone. Returns nil without
    /// opening anything when the key monitor cannot be installed, because a sheet that cannot hear Escape
    /// could not be closed by keyboard; the caller logs it under its own category.
    @discardableResult
    static func present(
        rootView: some View,
        over window: NSWindow,
        prepare: (ConfirmationSheetPanel) -> Void = { _ in },
        keyHandler: @escaping (NSEvent, ConfirmationSheetPanel) -> Bool,
        onEnd: @escaping () -> Void = {}
    ) -> ConfirmationSheetPanel? {
        let sheet = ConfirmationSheetPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isOpaque = false
        sheet.backgroundColor = .clear
        sheet.isMovable = false
        sheet.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: rootView)
        let glass = NSGlassEffectView()
        glass.contentView = host
        sheet.contentView = glass
        sheet.setContentSize(host.fittingSize)
        prepare(sheet)

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak sheet] event in
            guard let sheet, event.window === sheet else { return event }
            return keyHandler(event, sheet) ? nil : event
        }) else { return nil }

        window.beginSheet(sheet) { _ in
            NSEvent.removeMonitor(monitor)
            onEnd()
        }
        return sheet
    }
}

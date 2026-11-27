import AppKit
import OSLog
import SwiftUI

/// Opens the uninstall sheet on the launcher panel and translates its keys, so the sheet model stays
/// free of windows and events.
///
/// A sheet, like the clipboard prompt, because the controller keeps the launcher open while a sheet is
/// attached and the question stays tied to the list the person chose from. Unlike the clipboard
/// prompt, Return alone does nothing here: removing an app must be a deliberate act, so only ⌘Return,
/// a click, or Tab and Space confirm.
enum UninstallPrompt {
    /// Makes a failed key-monitor setup diagnosable; it never logs a path.
    private static let logger = Logger(subsystem: LogSubsystem.name, category: "uninstall")
    /// The key that flips the two-way choice, matched by character so it follows the keyboard layout.
    private static let choiceKey = "a"

    /// Opens the sheet for the app path captured now. Does nothing when a sheet is already attached,
    /// and says so in the footer while an earlier move still runs.
    static func present(bundlePath: String, for model: LauncherModel, over window: NSWindow?) {
        guard model.isPresented, model.mode == .applications, let window, window.attachedSheet == nil else { return }
        guard !model.uninstallInFlight else {
            model.showUninstallStatus(.info(DesignTokens.Copy.uninstallStillRunning))
            return
        }
        let sheetModel = UninstallSheetModel(bundlePath: bundlePath, launcher: model, dependencies: model.uninstall)
        sheetModel.onFinishedWithoutSheet = { [weak model, weak window] in
            guard let model else { return }
            presentPendingResults(for: model, over: window)
        }
        guard show(sheetModel, title: DesignTokens.Copy.uninstallTitle(sheetModel.displayName), over: window) else { return }
        sheetModel.start()
    }

    /// Shows the results of a move that ended while the launcher was closed. The shell calls it each
    /// time the launcher opens; with nothing pending it does nothing.
    static func presentPendingResults(for model: LauncherModel, over window: NSWindow?) {
        guard model.isPresented, model.mode == .applications, let window, window.attachedSheet == nil,
              let results = model.pendingUninstallResults
        else { return }
        model.pendingUninstallResults = nil
        if UninstallSheetModel.allMoved(results) {
            model.showUninstallStatus(.info(DesignTokens.Copy.uninstallMovedStatus(results.count)))
            return
        }
        let sheetModel = UninstallSheetModel(results: results, launcher: model, dependencies: model.uninstall)
        guard show(sheetModel, title: DesignTokens.Copy.uninstallResultTitle, over: window) else {
            // Kept for the next opening rather than lost, ahead of anything that arrived meanwhile.
            model.pendingUninstallResults = results + (model.pendingUninstallResults ?? [])
            return
        }
    }

    /// Hosts the sheet the same way as the clipboard prompt: glass, no title bar, never main.
    private static func show(_ sheetModel: UninstallSheetModel, title: String, over window: NSWindow) -> Bool {
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
        // Hidden on screen, but VoiceOver announces it when the sheet takes focus.
        sheet.title = title
        sheet.setAccessibilityLabel(title)
        sheet.canCancel = { [weak sheetModel] in sheetModel?.canCancel ?? true }

        let host = NSHostingView(rootView: UninstallSheetView(model: sheetModel))
        let glass = NSGlassEffectView()
        glass.contentView = host
        sheet.contentView = glass
        sheet.setContentSize(host.fittingSize)

        sheetModel.onSizeChange = { [weak sheet] size in fit(sheet, to: size) }
        sheetModel.onClose = { [weak sheet] in
            guard let sheet, let parent = sheet.sheetParent else { return }
            parent.endSheet(sheet, returnCode: .cancel)
        }

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak sheet, weak sheetModel] event in
            guard let sheet, let sheetModel, event.window === sheet else { return event }
            return handle(event, model: sheetModel) ? nil : event
        }) else {
            logger.error("Could not install the keyboard monitor for the uninstall sheet")
            return false
        }

        window.beginSheet(sheet) { _ in
            NSEvent.removeMonitor(monitor)
            sheetModel.sheetDidClose()
        }
        return true
    }

    /// Returns true when the key was used. Plain Return is swallowed in the confirmation, so it can never
    /// press the destructive button; in the result view it reaches Done, the default button. Internal so
    /// tests can prove the key rules with synthetic events.
    static func handle(_ event: NSEvent, model: UninstallSheetModel) -> Bool {
        let modifiers = event.modifierFlags.intersection(CopyClipShortcut.relevantModifiers)
        switch event.keyCode {
        case LauncherKeyCode.escape:
            model.close()
            return true
        case LauncherKeyCode.returnKey, LauncherKeyCode.keypadEnter:
            guard !model.showsResults else { return false }
            // A Return held before the sheet opened must not confirm it.
            if !event.isARepeat, modifiers == .command {
                model.confirm()
            }
            return true
        case LauncherKeyCode.upArrow, LauncherKeyCode.downArrow:
            guard !model.showsResults else { return false }
            model.moveFocus(by: event.keyCode == LauncherKeyCode.upArrow ? -1 : 1)
            return true
        default:
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == choiceKey,
                  !model.showsResults
            else { return false }
            // Swallowed even when it does nothing, so ⌘A never selects text behind the sheet.
            if !event.isARepeat {
                model.toggleChoice()
            }
            return true
        }
    }

    /// Keeps the top edge where AppKit attached the sheet, so a taller list grows downward instead of
    /// climbing over the launcher's search field.
    private static func fit(_ sheet: NSWindow?, to size: CGSize) {
        guard let sheet, size.width > 0, size.height > 0 else { return }
        let current = sheet.frame
        var frame = sheet.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard frame.size != current.size else { return }
        frame.origin = NSPoint(x: current.minX, y: current.maxY - frame.height)
        sheet.setFrame(frame, display: true)
    }
}

import AppKit
import OSLog
import SwiftUI

/// Single-action destructive prompt styled to match system Liquid Glass sheets while keeping a solid red
/// primary button with white text. AppKit's `_NSAlertButton` ignores `bezelColor` and strips Return
/// confirmation when `hasDestructiveAction` is set, so single-clip confirmation renders its own glass sheet.
private struct SingleClipConfirmationView: View {
    let onConfirm: () -> Void
    @FocusState private var isDeleteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.confirmationTextSpacing) {
            Text(DesignTokens.Copy.deleteClipTitle)
                .font(DesignTokens.Typography.confirmationTitle)
            Text(DesignTokens.Copy.deleteClipExplanation)
                .font(DesignTokens.Typography.confirmationBody)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onConfirm) {
                Text(DesignTokens.Copy.deleteClip)
                    .frame(maxWidth: .infinity)
            }
            .launcherButtonStyle(prominent: true)
            .tint(DesignTokens.Palette.destructiveAction)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .focused($isDeleteFocused)
            .padding(.top, DesignTokens.Metrics.confirmationButtonTopSpacing)
        }
        .padding(.top, DesignTokens.Metrics.confirmationTopPadding)
        .padding(.horizontal, DesignTokens.Metrics.confirmationHorizontalPadding)
        .padding(.bottom, DesignTokens.Metrics.confirmationBottomPadding)
        .frame(width: DesignTokens.Metrics.confirmationWidth)
        .onAppear {
            isDeleteFocused = true
        }
    }
}

/// Confirms removing saved clipboard entries, because the removal cannot be undone.
///
/// A sheet on the launcher panel, not a free-standing alert: a sheet keeps the panel open (the controller
/// ignores resign-key while one is attached) and ties the question to the window the user is looking at.
enum ClipboardRemovalPrompt {
    /// Makes a failed shortcut setup diagnosable without including any clipboard data.
    private static let logger = Logger(subsystem: LogSubsystem.name, category: "clipboard-confirmation")

    /// Binds the removal to the clip ID named when the sheet opens, since live capture can reorder results.
    static func present(_ removal: ClipboardManager.HistoryRemoval, for model: LauncherModel, over window: NSWindow?) {
        guard model.isPresented, model.mode == .clipboard, let window, window.attachedSheet == nil else { return }
        switch removal {
        case let .item(id):
            // A second prompt cannot change a removal the user has already confirmed.
            guard !model.clips.departingIDs.contains(id) else { return }
            presentSingleClip(id, for: model, over: window)
        case .all:
            presentClearHistory(for: model, over: window)
        }
    }

    /// One focused red destructive action keeps keyboard deletion quick while clearly signalling irreversibility.
    private static func presentSingleClip(_ id: UUID, for model: LauncherModel, over window: NSWindow) {
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

        var didConfirm = false
        let confirm: () -> Void = { [weak sheet, weak model] in
            // Guard against a second click or key event while the sheet dismissal animation runs.
            guard !didConfirm, let sheet, let parent = sheet.sheetParent else { return }
            didConfirm = true
            // Drop the clip immediately upon confirmation instead of waiting for the sheet close animation.
            model?.removeClips(.item(id))
            parent.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }

        let host = NSHostingView(rootView: SingleClipConfirmationView(onConfirm: confirm))
        let glass = NSGlassEffectView()
        glass.contentView = host
        sheet.contentView = glass
        sheet.setContentSize(host.fittingSize)

        // A buttonless Cancel needs its own Escape handling, and both Return keys must ignore repeats.
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak sheet] event in
            guard let sheet, event.window === sheet, let parent = sheet.sheetParent else { return event }
            switch event.keyCode {
            case LauncherKeyCode.escape:
                parent.endSheet(sheet, returnCode: .cancel)
                return nil
            case LauncherKeyCode.returnKey, LauncherKeyCode.keypadEnter:
                // A Return held before opening the sheet must not confirm it.
                guard !event.isARepeat else { return nil }
                guard event.modifierFlags.isDisjoint(with: CopyClipShortcut.relevantModifiers) else { return event }
                confirm()
                return nil
            default:
                return event
            }
        }) else {
            logger.error("Could not install the keyboard monitor for single-clip confirmation")
            return
        }

        window.beginSheet(sheet) { _ in
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Clearing the whole archive keeps Cancel as the safe default for a destructive bulk action.
    private static func presentClearHistory(for model: LauncherModel, over window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = DesignTokens.Copy.clearHistoryTitle
        alert.informativeText = DesignTokens.Copy.clearHistoryExplanation
        let cancel = alert.addButton(withTitle: DesignTokens.Copy.cancel)
        alert.addButton(withTitle: DesignTokens.Copy.clearHistoryButton).hasDestructiveAction = true
        // Escape cancels explicitly. Return also targets Cancel so it cannot confirm by default.
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        cancel.keyEquivalent = DesignTokens.Keys.cancelKeyEquivalent
        alert.beginSheetModal(for: window) { [weak model] response in
            guard response == .alertSecondButtonReturn else { return }
            model?.removeClips(.all)
        }
    }

    /// The launcher panel, found by type because SwiftUI menu actions have no handle to their window.
    @MainActor
    static var launcherWindow: NSWindow? {
        NSApp.windows.first { $0 is LauncherPanel }
    }
}

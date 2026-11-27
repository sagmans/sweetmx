import AppKit

/// The launcher keys the shell reserves. A closed set lets the controller map each one to a model
/// intent without knowing anything about raw key codes.
enum LauncherKey: Equatable {
    case up
    case down
    case activate
    case copy
    case deleteClip(isRepeat: Bool)
    case uninstall(isRepeat: Bool)
    case escape
}

/// Hardware key codes the panel reserves, so a focused text field cannot consume these keys first.
/// Internal, not private, so tests post the same codes the panel matches instead of keeping copies.
enum LauncherKeyCode {
    static let escape: UInt16 = 53
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
}

/// A standard editing chord and the responder action it stands for.
///
/// The agent app has no main menu, so nothing else turns these chords into actions; the panel does it
/// itself. Held as a table so the chords this panel claims are one reviewable closed set.
struct EditingShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let action: Selector

    /// Undo and redo are not declared on `NSResponder`, so they are named by string; the field editor's
    /// text view answers to these standard names.
    private static let undoAction = Selector(("undo:"))
    private static let redoAction = Selector(("redo:"))

    /// Exactly the chords the search field needs. Anything else, including other Command chords, must
    /// fall through so global hotkeys and the clipboard context menu keep working.
    static let all: [EditingShortcut] = [
        EditingShortcut(key: "a", modifiers: .command, action: #selector(NSText.selectAll(_:))),
        EditingShortcut(key: "c", modifiers: .command, action: #selector(NSText.copy(_:))),
        EditingShortcut(key: "v", modifiers: .command, action: #selector(NSText.paste(_:))),
        EditingShortcut(key: "x", modifiers: .command, action: #selector(NSText.cut(_:))),
        EditingShortcut(key: "z", modifiers: .command, action: undoAction),
        EditingShortcut(key: "z", modifiers: [.command, .shift], action: redoAction),
    ]

    /// The shortcut an event stands for, or nil. Modifiers must match exactly, so Option or Control
    /// variants of a chord are never mistaken for the plain one.
    static func match(_ event: NSEvent) -> EditingShortcut? {
        guard event.type == .keyDown,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let held = event.modifierFlags.intersection(CopyClipShortcut.relevantModifiers)
        return all.first { $0.key == key && $0.modifiers == held }
    }
}

/// A borderless, non-activating panel for the launcher.
///
/// Non-activating, so opening it does not pull SweetMX to the front of the other apps, which keeps
/// the app that will receive a paste focused. It can still become key, so the search field takes typing.
final class LauncherPanel: NSPanel {
    /// Match the Command-modified letter for layouts that remap keys while Command is held.
    private static let deleteClipKey = "d"
    /// Same reason as `deleteClipKey`: the character, not the key code, so remapped layouts still work.
    private static let uninstallKey = "u"

    /// Set by the controller. Returning false lets the event continue to the responder chain, so a key
    /// the shell declines still behaves as it would in any window.
    var keyHandler: ((LauncherKey) -> Bool)?

    /// Set by the controller during the close fade. Only reserved keys reach the key handler, so ordinary
    /// typing must be dropped here, or it would start a search in a field the user can no longer see.
    var dropsKeyEvents = false

    /// Required so the search field can take focus even though the panel never activates the app.
    override var canBecomeKey: Bool {
        true
    }

    /// The launcher is not a document window, so it must never take over the main-window role.
    override var canBecomeMain: Bool {
        false
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        // Floating, on every Space and over full-screen apps, so the launcher appears wherever the user is.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The SwiftUI glass draws its own background and shadow shape; an opaque window would show a box.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The panel never activates the app, so a deactivate-hide would hide it while the model still
        // thinks it is presented; dismissal is owned by the controller.
        hidesOnDeactivate = false
        // The controller owns the lifetime; a released-on-close panel would dangle behind it.
        isReleasedWhenClosed = false
    }

    /// Matches the exact modifiers so editing chords stay with the focused field and a stray modifier
    /// cannot turn a copy into a paste. Arrow events also carry non-modifier flags that we ignore here.
    static func launcherKey(for event: NSEvent) -> LauncherKey? {
        guard event.type == .keyDown else { return nil }
        let held = event.modifierFlags.intersection(CopyClipShortcut.relevantModifiers)
        switch event.keyCode {
        case LauncherKeyCode.escape: return .escape
        case LauncherKeyCode.upArrow: return held.isEmpty ? .up : nil
        case LauncherKeyCode.downArrow: return held.isEmpty ? .down : nil
        case LauncherKeyCode.returnKey:
            if held.isEmpty {
                return .activate
            }
            let isCopyChord = event.charactersIgnoringModifiers == CopyClipShortcut.key
                && held == CopyClipShortcut.modifiers
            return isCopyChord ? .copy : nil
        default:
            guard held == .command, let character = event.characters?.lowercased() else { return nil }
            switch character {
            case deleteClipKey: return .deleteClip(isRepeat: event.isARepeat)
            case uninstallKey: return .uninstall(isRepeat: event.isARepeat)
            default: return nil
            }
        }
    }

    /// Whether a reserved key belongs to the launcher given where the keyboard focus is. A text view that
    /// is not the search field's editor, such as the selectable preview, needs arrows and Return for
    /// its own text navigation, so they pass through to it. A read-only preview can still ask to delete
    /// the selected clip, and Esc closes the launcher from anywhere.
    static func routes(_ key: LauncherKey, firstResponder: NSResponder?) -> Bool {
        if key == .escape {
            return true
        }
        guard let textView = firstResponder as? NSTextView else { return true }
        // A read-only preview can still ask for these two, which act on the highlighted row.
        switch key {
        case .deleteClip, .uninstall: if !textView.isEditable {
                return true
            }
        default: break
        }
        return textView.isFieldEditor
    }

    /// Intercepts reserved keys before the field editor sees them. Skipped during IME composition,
    /// because those keys then confirm or cancel the composed text and must reach the input method.
    override func sendEvent(_ event: NSEvent) {
        if dropsKeyEvents, event.type == .keyDown || event.type == .keyUp {
            return
        }
        // A held Return can outlive a confirmation sheet and reach the next selected clip.
        if (firstResponder as? NSTextView)?.hasMarkedText() != true,
           let key = Self.launcherKey(for: event),
           Self.routes(key, firstResponder: firstResponder),
           (key == .activate && event.isARepeat) || keyHandler?(key) == true
        {
            return
        }
        super.sendEvent(event)
    }

    /// Runs the standard editing chords against the first responder. Without a main menu the system
    /// finds no menu item for them, so the chord would otherwise do nothing. A chord the responder
    /// cannot perform is declined, so it still reaches `super` and other handlers.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !dropsKeyEvents,
           let shortcut = EditingShortcut.match(event),
           NSApp.sendAction(shortcut.action, to: nil, from: self)
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc can arrive as a command from a control that swallowed the key event, so it is routed too.
    override func cancelOperation(_ sender: Any?) {
        if keyHandler?(.escape) != true {
            super.cancelOperation(sender)
        }
    }
}

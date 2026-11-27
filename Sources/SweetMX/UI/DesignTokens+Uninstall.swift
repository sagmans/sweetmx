import Foundation
import SwiftUI

/// Tokens of the uninstall flow. They live beside `DesignTokens` so the flow's waits, copy and sizes
/// are named in one place, and the sheet, its model and their tests read the same values.
extension DesignTokens.Timing {
    /// How long an app gets to quit after a polite request; a document with unsaved changes may
    /// keep it open, and the flow must stop waiting instead of forcing it closed.
    static let uninstallQuitTimeout: Duration = .seconds(10)
    /// How often the flow looks again, short enough that a quick quit does not feel slow.
    static let uninstallQuitPollInterval: Duration = .milliseconds(100)
    /// How long Finder gets to move one item, including time for a person to type a password.
    static let finderTrashTimeout: TimeInterval = 120
}

/// Product names the notices show; they are proper names, kept here so the sheet and its tests read
/// one source.
extension DesignTokens.Copy {
    nonisolated static let vendorDockerDesktop = "Docker Desktop"
    nonisolated static let vendorKarabinerElements = "Karabiner-Elements"
    nonisolated static let vendorLittleSnitch = "Little Snitch"
}

/// Words of the uninstall sheets. A destructive prompt must say exactly what moves and what stays, so
/// every sentence is short and plain, and each enum case maps to one sentence through an exhaustive
/// switch: a new case fails to compile here instead of showing nothing.
extension DesignTokens.Copy {
    // MARK: Entry points

    /// Context-menu title; the ellipsis says a confirmation follows.
    static let uninstallMenu = "Uninstall…"
    /// Footer hint for the uninstall key, with the key cap text and what VoiceOver says for it.
    static let actionUninstall = "Uninstall"
    static let uninstallKeyCap = "⌘U"
    static let uninstallKeySpoken = "Command U"

    // MARK: Header and phases

    static func uninstallTitle(_ name: String) -> String {
        "Uninstall “\(name)”?"
    }

    /// Title when the app may not be removed, so the sheet never reads as a question it cannot answer.
    static func uninstallRefusedTitle(_ name: String) -> String {
        "Can’t uninstall “\(name)”"
    }

    /// Path and size under the title, joined like Finder joins file facts.
    static func uninstallLocation(_ path: String, size: String) -> String {
        path + uninstallDetailSeparator + size
    }

    /// Joins the facts of one line (path and size, size and effect).
    static let uninstallDetailSeparator = " · "

    static let uninstallSizeUnknown = "size unknown"
    static let uninstallScanning = "Looking for related files…"
    static let uninstallMoving = "Moving to Trash…"
    static func uninstallAppRunning(_ name: String) -> String {
        "“\(name)” is open. SweetMX asks it to quit first and never forces it."
    }

    // MARK: Choice and list

    static let uninstallChoiceLabel = "What to move"
    static let uninstallChoiceAppOnly = "App only"
    static let uninstallChoiceEverything = "App and all related files"
    static let uninstallSelectableSection = "Also move to Trash"
    static let uninstallLockedSection = "Not removed by SweetMX"
    static let uninstallNoRelatedItems = "No related files found."
    /// Help and VoiceOver hint of the choice, so the one key that flips it can be found.
    static let uninstallChoiceHelp = "Press Command-A to switch between App only and App and all related files."
    static let uninstallMatchedByName = "Matched by name"
    static let uninstallListedByHomebrew = "Listed by Homebrew"

    // MARK: Footer and buttons

    static let uninstallTrashFooter = "Items go to Trash. You can restore them until you empty it."
    static let uninstallSomeItemsStay = "Some items can stay on this Mac."
    /// Under the button when Finder will take over the move and show the password prompt.
    static let uninstallFinderWillAsk = "Finder will ask for an administrator name and password."
    /// Under the button while the Finder hand-off is off: the move may still succeed, and Finder is the
    /// way out when it does not.
    static let uninstallMayNeedAdministrator = "Your account may need an administrator for this app. If the move fails, finish in Finder."
    static let uninstallShowInFinder = "Show in Finder"
    static let uninstallOpenInstructions = "Open uninstall instructions"
    static let uninstallDone = "Done"

    /// The destructive button counts what moves, so the person sees the scope before pressing it.
    static func uninstallMoveButton(count: Int, size: String?, sizeIsLowerBound: Bool) -> String {
        let items = count == 1 ? "1 item" : "\(count) items"
        guard let size else { return "Move \(items) to Trash" }
        return sizeIsLowerBound ? "Move \(items) to Trash (at least \(size))" : "Move \(items) to Trash (\(size))"
    }

    /// Footer status when ⌘U is pressed while a move still runs; one move at a time.
    static let uninstallStillRunning = "An uninstall is still running."

    /// Footer status after everything moved.
    static func uninstallMovedStatus(_ count: Int) -> String {
        count == 1 ? "Moved 1 item to Trash" : "Moved \(count) items to Trash"
    }

    // MARK: Result sheet

    static let uninstallResultTitle = "Some items were not moved"
    static let uninstallResultExplanation = "Items that moved are in Trash. The others stay where they are."
    static let uninstallResultMoved = "Moved to Trash."

    // MARK: Accessibility

    static let uninstallRelatedListLabel = "Related files"
    static let uninstallRelatedListHelp = "Use the Up and Down Arrow keys to move between files and Space to select one."
    static let uninstallResultListLabel = "Uninstall results"
    static let uninstallRowSelected = "Selected"
    static let uninstallRowNotSelected = "Not selected"
    static let uninstallToggleAction = "Select or deselect"
    static func uninstallRowLocked(_ reason: String) -> String {
        "Locked. \(reason)"
    }

    static let uninstallConfirmHelp = "Press Command-Return to move the selected items to Trash."

    // MARK: Per-case sentences

    static func uninstallKind(_ kind: RelatedItem.Kind) -> String {
        switch kind {
        case .settings: "Settings"
        case .cache: "Cache"
        case .webData: "Web data"
        case .logs: "Logs"
        case .appData: "App data"
        case .container: "Sandbox data"
        }
    }

    static func uninstallEffect(_ kind: RelatedItem.Kind) -> String {
        switch kind {
        case .settings: "The app starts with default settings."
        case .cache: "The app makes it again when needed."
        case .webData: "Sessions and site data of the app. A sign-in can be lost."
        case .logs: "Diagnostic history."
        case .appData: "Can hold accounts, history and documents. The app cannot make it again."
        case .container: "Data that macOS keeps for the app in a protected folder."
        }
    }

    static func uninstallLockReason(_ lock: RelatedItem.Lock) -> String {
        switch lock {
        case .nameNotCertain: "Matches the app name only. Another app can use the same name."
        case .protectedByMacOS: "Protected by macOS."
        case .identityNotConfirmed: "The app’s signature does not confirm which files are its own."
        case .secondCopyInstalled: "Another copy of this app uses these files."
        }
    }

    /// Only the app can be handed to Finder with an administrator prompt; a Library item the account
    /// cannot move gets the plain way out.
    static func uninstallReason(_ reason: UninstallItemResult.Reason, isApp: Bool) -> String {
        if reason == .permissionDenied, !isApp {
            return uninstallItemPermissionDenied
        }
        return uninstallReason(reason)
    }

    static let uninstallItemPermissionDenied = "SweetMX could not move this item. Move it to Trash in Finder."

    private static func uninstallReason(_ reason: UninstallItemResult.Reason) -> String {
        switch reason {
        case .appStillRunning: "The app did not quit. Quit it and try again."
        case .targetChanged: "The item changed after you confirmed, so it was left in place."
        case .becameSymlink: "The item is now a link, so it was left in place."
        case .missing: "The item is no longer there."
        case .permissionDenied: "SweetMX does not have permission to move this item. Move it to Trash in Finder; Finder asks for an administrator password."
        case .finderCancelled: "The administrator prompt was cancelled, so nothing moved."
        case .finderConsentRefused: "SweetMX may not control Finder. Move the app to Trash in Finder."
        case .finderTimedOut: "Finder did not answer in time."
        case .protectedByMacOS: "macOS protects this item."
        case .appDidNotMove: "Kept because the app did not move."
        case .other: "macOS could not move this item."
        case .cancelled: "The move stopped before anything moved."
        }
    }

    static func uninstallRefusal(_ refusal: UninstallRefusal) -> String {
        switch refusal {
        case .systemApp: "This app is part of macOS."
        case .requiredAppleApp: "macOS needs this Apple app, so SweetMX keeps it."
        case .sweetMXItself: "SweetMX cannot remove itself. Move it to Trash in Finder."
        case .symlinkedApp: "This is a link to an app. Moving it would remove only the link."
        case .unreadableBundleID: "SweetMX cannot read which app this is, so it keeps it."
        case .notAnApplication: "This item is not an app."
        }
    }

    static func uninstallNoticeTitle(_ notice: UninstallNotice) -> String {
        switch notice {
        case .homebrew: "Installed with Homebrew"
        case .vendorUninstaller: "This app has its own uninstaller"
        case .blocked: "Use Finder or the app’s own uninstaller"
        }
    }

    static func uninstallNoticeBody(_ notice: UninstallNotice) -> String {
        switch notice {
        case .homebrew:
            "This command also updates Homebrew’s records:"
        case let .vendorUninstaller(vendor, _):
            "It removes background parts that Trash leaves. \(vendor) explains the steps."
        case .blocked(reason: .systemExtension, _):
            "This app installs a system extension. Only its own uninstaller or Finder removes it, so SweetMX does not move this app."
        case .blocked(reason: .securitySoftware, _):
            "This app installs a security component. Only its own uninstaller removes it, so SweetMX does not move this app."
        }
    }
}

extension DesignTokens {
    /// One size style for every byte count in the sheets, the same one Finder uses for files, in the
    /// locale the caller passes so tests and snapshots can pin one.
    static func uninstallSize(_ bytes: Int64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}

extension DesignTokens.Metrics {
    /// Fixed sheet width, so long paths truncate instead of widening the sheet past the launcher.
    static let uninstallSheetWidth: CGFloat = 520
    /// Tallest the related list grows before it scrolls, so the sheet stays near the launcher's height.
    static let uninstallListMaxHeight: CGFloat = 220
    /// Shortest the list gets when notices take the room, so at least two rows stay visible.
    static let uninstallListMinHeight: CGFloat = 96
    /// Tallest the whole sheet may be: the launcher panel's height, so the sheet never hangs below it.
    static let uninstallSheetMaxHeight: CGFloat = DesignTokens.Layout.appPanelSize.height
    /// Width of the kind column of a row; fits the longest kind and the "Listed by Homebrew" mark.
    static let uninstallKindColumnWidth: CGFloat = 104
    /// Tallest the result list grows before it scrolls.
    static let uninstallResultListMaxHeight: CGFloat = 240
    /// Inner padding of the sheet, matching the clipboard confirmation's side margin.
    static let uninstallSheetPadding: CGFloat = 20
    /// Gap between the sheet's blocks (header, notices, choice, list, footer).
    static let uninstallBlockSpacing: CGFloat = 12
    /// Gap between lines inside one block.
    static let uninstallLineSpacing: CGFloat = 2
    /// Gap between list rows.
    static let uninstallRowSpacing: CGFloat = 2
    /// Padding inside a row, so the focus fill does not touch the text.
    static let uninstallRowPadding: CGFloat = 6
    /// Corner radius of the row focus fill and of notice boxes.
    static let uninstallCornerRadius: CGFloat = 8
    /// Width of the checkbox or lock column, so row text lines up whatever the mark.
    static let uninstallMarkWidth: CGFloat = 18
    /// Padding inside a notice box.
    static let uninstallNoticePadding: CGFloat = 10
}

extension DesignTokens.Typography {
    /// Path and size under the sheet title; quieter than the title.
    static let uninstallDetail = Font.callout
    /// Kind name of a row: the word the person scans for.
    static let uninstallRowTitle = Font.callout.weight(.semibold)
    /// Path of a row, the same size as the kind so the two read as one line.
    static let uninstallPath = Font.callout
    /// Size, effect, lock reason and match mark of a row.
    static let uninstallRowDetail = Font.caption
    /// The Homebrew command, monospaced so it reads as something to type.
    static let uninstallCommand = Font.caption.monospaced()
    /// Section captions of the list.
    static let uninstallSection = Font.caption.weight(.semibold)
}

extension DesignTokens.Palette {
    /// Fill behind the row that has keyboard focus, from the app accent so it matches the launcher.
    static let uninstallFocusOpacity: Double = 0.25
    /// Color of a notice that only informs (Homebrew), apart from warnings and blocks.
    static let uninstallInformation: Color = .blue
    /// Fill behind a notice, a quiet tint of the notice color.
    static let uninstallNoticeOpacity: Double = 0.12
    /// Mark of an item that reached Trash.
    static let uninstallMoved: Color = .green
}

extension DesignTokens.Symbol {
    static let uninstallChecked = "checkmark.square.fill"
    static let uninstallUnchecked = "square"
    static let uninstallLocked = "lock.fill"
    static let uninstallMoved = "checkmark.circle.fill"
    static let uninstallNotMoved = "xmark.circle.fill"
    static let uninstallBlocked = "hand.raised.fill"
}

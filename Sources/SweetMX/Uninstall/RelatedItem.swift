import Foundation

/// One file or folder an app left in the user's Library, with the verdict on whether the person
/// may tick it for removal.
///
/// The scanner produces these and the confirmation step shows them; carrying the lock on the value
/// means the UI cannot offer a row the scan decided was unsafe.
nonisolated struct RelatedItem: Equatable, Identifiable, Sendable {
    /// Groups rows so the list can explain what each one is.
    enum Kind: Sendable { case settings, cache, webData, logs, appData, container }

    /// How the scan tied the item to the app; it tells the person how sure the scan is.
    enum Match: Sendable { case bundleID, name, homebrew }

    /// Why a row cannot be ticked. One reason per row; the scanner picks it in a fixed order.
    enum Lock: Equatable, Sendable {
        case nameNotCertain, protectedByMacOS, identityNotConfirmed, secondCopyInstalled
    }

    let url: URL
    let kind: Kind
    let match: Match
    /// Nil when the size is not known: too large to scan cheaply, unreadable, or deliberately not read.
    let sizeBytes: Int64?
    /// Nil means the person may tick it.
    let lock: Lock?

    var id: String {
        url.path
    }
}

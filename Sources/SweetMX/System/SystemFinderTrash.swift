import Foundation

/// Finder-backed Trash move for items that need an administrator.
///
/// It sends the Apple Event as a structured descriptor, never as script text and never through a
/// shell, so the path cannot be read as code. It is not covered by an automated test because it
/// would drive the real Finder; keep it small so a read proves it.
public nonisolated struct SystemFinderTrash: FinderTrashProtocol {
    private enum Finder {
        static let bundleIdentifier = "com.apple.finder"
        /// Finder's "delete" moves to Trash: event class `core`, event ID `delo`.
        static let eventClass: AEEventClass = 0x636F_7265
        static let eventID: AEEventID = 0x6465_6C6F
        /// Reply parameter `errn` that Finder sets when the command ran and failed.
        static let errorNumberKeyword: AEKeyword = 0x6572_726E
    }

    private enum ErrorCode {
        static let consentRefused = -1743
        static let cancelled = -128
        static let timedOut = -1712
        static let none = 0
    }

    /// A zero or negative timeout would mean "wait forever" to the Apple Event API.
    private static let minimumTimeout: Duration = .seconds(1)
    /// The Apple Event API counts its timeout in seconds.
    private static let apiTimeoutUnit: Duration = .seconds(1)

    /// The send blocks for as long as a password prompt stays open. A dedicated queue keeps that
    /// wait off the cooperative pool, which would otherwise lose a thread for the whole timeout.
    private static let sendQueue = DispatchQueue(label: "com.sagmans.sweetmx.finder-trash", qos: .userInitiated)

    public init() {}

    public func moveToTrash(_ url: URL, timeout: Duration) async -> FinderTrashOutcome {
        let bounded = max(timeout, Self.minimumTimeout) / Self.apiTimeoutUnit
        return await withCheckedContinuation { continuation in
            Self.sendQueue.async {
                continuation.resume(returning: Self.send(url, timeout: bounded))
            }
        }
    }

    private static func send(_ url: URL, timeout: TimeInterval) -> FinderTrashOutcome {
        let event = NSAppleEventDescriptor(
            eventClass: Finder.eventClass,
            eventID: Finder.eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: Finder.bundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(keyDirectObject))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
            let code = Int(reply.paramDescriptor(forKeyword: Finder.errorNumberKeyword)?.int32Value ?? 0)
            return outcome(forCode: code)
        } catch {
            return outcome(forCode: (error as NSError).code)
        }
    }

    /// Internal so a test can prove the mapping without driving Finder.
    static func outcome(forCode code: Int) -> FinderTrashOutcome {
        switch code {
        case ErrorCode.none: .moved
        case ErrorCode.consentRefused: .consentRefused
        case ErrorCode.cancelled: .cancelled
        case ErrorCode.timedOut: .timedOut
        default: .failed(code: code)
        }
    }
}

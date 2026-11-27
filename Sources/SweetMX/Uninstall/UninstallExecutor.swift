import Foundation
import os

/// What the person confirmed: the app and only the related items they ticked.
///
/// The sheet builds it and the executor consumes it, so nothing outside the ticked rows can move.
nonisolated struct UninstallRequest: Sendable {
    let target: UninstallTarget
    let items: [RelatedItem]
}

/// What happened to one item, so the result screen can tell the person exactly what moved and what did not.
nonisolated struct UninstallItemResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// `nil` when the Trash location is unknown (Finder does not report it).
        case moved(to: URL?)
        case notMoved(Reason)
    }

    /// One case per message the person can act on; `other` keeps the system's error for the log.
    enum Reason: Equatable, Sendable {
        case appStillRunning, targetChanged, becameSymlink, missing,
             permissionDenied, finderCancelled, finderConsentRefused,
             finderTimedOut, protectedByMacOS, appDidNotMove, other(domain: String, code: Int)
    }

    let url: URL
    let isApp: Bool
    let outcome: Outcome
}

/// The only code of the uninstall flow that moves anything. It quits the app, checks the app and
/// every ticked item again right before the move (the sheet may have been open for minutes), and
/// then moves each to the Trash, so every removal can be undone.
///
/// One failure never stops the next item, and the app goes first: when it stays, its files stay
/// too, because a half-removed app is worse than an untouched one.
final class UninstallExecutor {
    private static let logger = Logger(subsystem: LogSubsystem.name, category: "uninstall")

    /// Cocoa codes for the failures that need their own message.
    private nonisolated static let permissionCode = NSFileWriteNoPermissionError
    private nonisolated static let noSuchFileCodes: Set<Int> = [NSFileNoSuchFileError, NSFileReadNoSuchFileError]
    /// Domains for failures the system did not label itself, so a log line still says where they came from.
    private static let finderErrorDomain = "SweetMX.FinderAppleEvent"
    private static let stillPresentDomain = "SweetMX.AppStillPresent"
    private static let stillPresentCode = 0
    private nonisolated static let libraryFolder = "Library"
    private nonisolated static let pathSeparator = "/"

    private let fileSystem: FileSystemProtocol
    private let workspace: WorkspaceProtocol
    private let finder: FinderTrashProtocol
    private let resolver: UninstallTargetResolver
    private let finderHandOffEnabled: Bool
    private let quitTimeout: Duration
    private let quitPollInterval: Duration

    /// `finderHandOffEnabled`, `quitTimeout` and `quitPollInterval` are injectable so tests cover
    /// both policies and run in milliseconds; production uses the defaults.
    init(
        fileSystem: FileSystemProtocol,
        workspace: WorkspaceProtocol,
        finder: FinderTrashProtocol,
        resolver: UninstallTargetResolver,
        finderHandOffEnabled: Bool = UninstallPolicy.finderHandOffEnabled,
        quitTimeout: Duration = DesignTokens.Timing.uninstallQuitTimeout,
        quitPollInterval: Duration = DesignTokens.Timing.uninstallQuitPollInterval
    ) {
        self.fileSystem = fileSystem
        self.workspace = workspace
        self.finder = finder
        self.resolver = resolver
        self.finderHandOffEnabled = finderHandOffEnabled
        self.quitTimeout = quitTimeout
        self.quitPollInterval = quitPollInterval
    }

    /// Returns one result per item: the app first, then the ticked items in request order.
    func run(_ request: UninstallRequest) async -> [UninstallItemResult] {
        guard await quitApp(at: request.target.bundleURL) else {
            return refuseAll(request, reason: .appStillRunning)
        }
        guard targetStillMatches(request.target) else {
            return refuseAll(request, reason: .targetChanged)
        }

        let appOutcome = await moveApp(request.target)
        var results = [UninstallItemResult(url: request.target.bundleURL, isApp: true, outcome: appOutcome)]
        guard case .moved = appOutcome else {
            results += request.items.map { UninstallItemResult(url: $0.url, isApp: false, outcome: .notMoved(.appDidNotMove)) }
            logFailures(results)
            return results
        }
        for item in request.items {
            await results.append(UninstallItemResult(url: item.url, isApp: false, outcome: moveRelated(item)))
        }
        logFailures(results)
        return results
    }

    // MARK: - Steps

    /// Asks the app to quit and waits a bounded time. Only the timeout decides, because an app that
    /// answers "no" may still be closing a document. It never forces a quit: unsaved work is not ours to discard.
    private func quitApp(at bundleURL: URL) async -> Bool {
        let running = workspace.runningApplications(atBundleURL: bundleURL).filter { !$0.isTerminated }
        guard !running.isEmpty else { return true }
        for application in running {
            _ = application.terminate()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: quitTimeout)
        while running.contains(where: { !$0.isTerminated }) {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: quitPollInterval)
        }
        return true
    }

    /// The sheet may have been open for a long time, so the app is judged again: a swapped bundle or
    /// a signature that no longer matches means the person confirmed something else.
    private func targetStillMatches(_ target: UninstallTarget) -> Bool {
        guard case let .success(current) = resolver.resolve(bundlePath: target.bundleURL.path), current.bundleID == target.bundleID else { return false }
        return !(target.identityConfirmed && !current.identityConfirmed)
    }

    private func moveApp(_ target: UninstallTarget) async -> UninstallItemResult.Outcome {
        let fileSystem = fileSystem
        let url = target.bundleURL
        let outcome = await Task.detached { Self.trash(url, using: fileSystem) }.value
        guard finderHandOffEnabled, outcome == .notMoved(.permissionDenied) else { return outcome }
        return await moveThroughFinder(url)
    }

    /// Finder shows the administrator prompt, so SweetMX never handles a password. The app must really
    /// be gone afterwards: a "moved" answer alone is not trusted with the person's data.
    private func moveThroughFinder(_ url: URL) async -> UninstallItemResult.Outcome {
        switch await finder.moveToTrash(url, timeout: DesignTokens.Timing.finderTrashTimeout) {
        case .moved:
            let fileSystem = fileSystem
            let stillThere = await Task.detached { fileSystem.fileExists(atPath: url.path) }.value
            if stillThere {
                return .notMoved(.other(domain: Self.stillPresentDomain, code: Self.stillPresentCode))
            }
            return .moved(to: nil)
        case .cancelled:
            return .notMoved(.finderCancelled)
        case .consentRefused:
            return .notMoved(.finderConsentRefused)
        case .timedOut:
            return .notMoved(.finderTimedOut)
        case let .failed(code):
            return .notMoved(.other(domain: Self.finderErrorDomain, code: code))
        }
    }

    private func moveRelated(_ item: RelatedItem) async -> UninstallItemResult.Outcome {
        if let lock = item.lock {
            // A locked row must never reach the executor; reaching it is a bug in the caller.
            Self.logger.error("Locked item in uninstall request: path=\(item.url.path, privacy: .private) lock=\(String(describing: lock), privacy: .public)")
            return .notMoved(lock == .protectedByMacOS ? .protectedByMacOS : .targetChanged)
        }
        let fileSystem = fileSystem
        let url = item.url
        return await Task.detached { Self.recheckAndTrash(url, using: fileSystem) }.value
    }

    // MARK: - File work (runs off the main actor)

    /// Re-checks one item right before the move, because the folders around it may have changed since the scan.
    private nonisolated static func recheckAndTrash(_ url: URL, using fileSystem: FileSystemProtocol) -> UninstallItemResult.Outcome {
        guard isInsideLibrary(url, home: fileSystem.homeDirectoryForCurrentUser) else { return .notMoved(.targetChanged) }
        guard fileSystem.fileExists(atPath: url.path) else { return .notMoved(.missing) }
        guard !fileSystem.isSymbolicLink(at: url) else { return .notMoved(.becameSymlink) }
        let itemParent = fileSystem.resolvingSymlinks(url).deletingLastPathComponent().path
        let folder = fileSystem.resolvingSymlinks(url.deletingLastPathComponent()).path
        guard itemParent == folder else { return .notMoved(.becameSymlink) }
        return trash(url, using: fileSystem)
    }

    /// Strictly inside `<home>/Library/`: the folder itself and anything reached through `..` do not count.
    private nonisolated static func isInsideLibrary(_ url: URL, home: URL) -> Bool {
        let library = home.appendingPathComponent(libraryFolder, isDirectory: true).standardizedFileURL.path
        let prefix = library.hasSuffix(pathSeparator) ? library : library + pathSeparator
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) && path.count > prefix.count
    }

    /// The single removal call of the flow. It is a Trash move, so nothing is deleted for good.
    private nonisolated static func trash(_ url: URL, using fileSystem: FileSystemProtocol) -> UninstallItemResult.Outcome {
        guard fileSystem.fileExists(atPath: url.path) else { return .notMoved(.missing) }
        do {
            return try .moved(to: fileSystem.trashItem(at: url))
        } catch {
            return .notMoved(reason(for: error))
        }
    }

    /// Only a Cocoa "no permission" error (also when wrapped) means an administrator could help.
    private nonisolated static func reason(for error: Error) -> UninstallItemResult.Reason {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        for candidate in [nsError, underlying].compactMap(\.self) where candidate.domain == NSCocoaErrorDomain {
            if candidate.code == permissionCode {
                return .permissionDenied
            }
        }
        if nsError.domain == NSCocoaErrorDomain, noSuchFileCodes.contains(nsError.code) {
            return .missing
        }
        return .other(domain: nsError.domain, code: nsError.code)
    }

    // MARK: - Reporting

    private func refuseAll(_ request: UninstallRequest, reason: UninstallItemResult.Reason) -> [UninstallItemResult] {
        let app = UninstallItemResult(url: request.target.bundleURL, isApp: true, outcome: .notMoved(reason))
        let items = request.items.map { UninstallItemResult(url: $0.url, isApp: false, outcome: .notMoved(reason)) }
        let results = [app] + items
        logFailures(results)
        return results
    }

    /// One error line per failure, with the operation and the system's code but never file contents.
    private func logFailures(_ results: [UninstallItemResult]) {
        for result in results {
            guard case let .notMoved(reason) = result.outcome else { continue }
            let operation = result.isApp ? "move app to Trash" : "move item to Trash"
            Self.logger.error("Uninstall not moved: operation=\(operation, privacy: .public) path=\(result.url.path, privacy: .private) reason=\(String(describing: reason), privacy: .public)")
        }
    }
}

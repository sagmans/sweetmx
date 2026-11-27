import AppKit
@testable import SweetMX

/// A running app a test can script, because `NSRunningApplication` cannot be created in a test.
final class MockRunningApplication: RunningApplicationHandle {
    private var storedIsTerminated: Bool
    private var readCount = 0
    /// When set, the app reads as quit from the read after this many reads, so a test makes an app
    /// "quit later" without a wall-clock delay.
    var terminatesAfterReads: Int?

    var isTerminated: Bool {
        get {
            readCount += 1
            if let limit = terminatesAfterReads, readCount > limit {
                return true
            }
            return storedIsTerminated
        }
        set { storedIsTerminated = newValue }
    }

    /// What `terminate()` answers.
    var terminateResult: Bool
    private(set) var terminateCallCount = 0

    init(isTerminated: Bool = false, terminateResult: Bool = true) {
        storedIsTerminated = isTerminated
        self.terminateResult = terminateResult
    }

    func terminate() -> Bool {
        terminateCallCount += 1
        return terminateResult
    }
}

/// Mock implementation of WorkspaceProtocol for testing
final class MockWorkspace: WorkspaceProtocol {
    var frontmostApplication: NSRunningApplication?

    // MARK: - Configurable Properties

    /// If set, the completion handler will be called with this running application
    var mockRunningApplication: NSRunningApplication?

    /// If set, the completion handler will be called with this error
    var mockOpenError: Error?

    /// Whether openApplication should call completion handler immediately (sync) or asynchronously
    var callCompletionSynchronously: Bool = true

    /// Running apps per bundle path; a bundle that is absent here has none.
    var runningApplicationsByBundlePath: [String: [MockRunningApplication]] = [:]

    // MARK: - Invocation Tracking

    /// Bundle URLs asked about by `runningApplications(atBundleURL:)`.
    var runningApplicationsCalls: [URL] = []

    /// URLs passed to `revealInFinder`.
    var revealInFinderCalls: [URL] = []

    /// Recorded openApplication calls
    struct OpenApplicationCall {
        let applicationURL: URL
        let configuration: NSWorkspace.OpenConfiguration
        let hasCompletionHandler: Bool
    }

    /// Tracks all openApplication calls
    var openApplicationCalls: [OpenApplicationCall] = []

    // MARK: - WorkspaceProtocol Implementation

    func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration, completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?) {
        let call = OpenApplicationCall(
            applicationURL: applicationURL,
            configuration: configuration,
            hasCompletionHandler: completionHandler != nil
        )
        openApplicationCalls.append(call)

        // Call completion handler if provided
        if let completionHandler {
            if callCompletionSynchronously {
                completionHandler(mockRunningApplication, mockOpenError)
            } else {
                DispatchQueue.main.async { [weak self] in
                    completionHandler(self?.mockRunningApplication, self?.mockOpenError)
                }
            }
        }
    }

    func runningApplications(atBundleURL url: URL) -> [any RunningApplicationHandle] {
        runningApplicationsCalls.append(url)
        return runningApplicationsByBundlePath[url.path] ?? []
    }

    func revealInFinder(_ url: URL) {
        revealInFinderCalls.append(url)
    }

    // MARK: - Helper Methods

    /// Clears all recorded invocations
    func resetInvocations() {
        openApplicationCalls = []
        runningApplicationsCalls = []
        revealInFinderCalls = []
    }

    /// Returns the last application URL that was opened
    var lastOpenedApplicationURL: URL? {
        openApplicationCalls.last?.applicationURL
    }

    /// Returns the number of times openApplication was called
    var openApplicationCallCount: Int {
        openApplicationCalls.count
    }
}

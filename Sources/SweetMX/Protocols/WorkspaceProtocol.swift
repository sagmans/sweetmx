import AppKit

/// The part of a running app that uninstall needs: whether it is gone and a polite quit request.
///
/// `NSRunningApplication` cannot be created in a test, so the protocol gives mocks something they can build.
/// It has no force-terminate member on purpose: uninstall must never discard an app's unsaved work, so a force quit is impossible through this type.
public protocol RunningApplicationHandle {
    /// True once the app has quit, so the flow can stop waiting.
    var isTerminated: Bool { get }

    /// Ask the app to quit; false when the request was not delivered.
    func terminate() -> Bool
}

extension NSRunningApplication: RunningApplicationHandle {}

/// Protocol abstracting NSWorkspace operations for testability
public protocol WorkspaceProtocol {
    /// Identify the app that owns focus before SweetMX activates.
    var frontmostApplication: NSRunningApplication? { get }

    /// Opens the application at the specified URL asynchronously
    /// - Parameters:
    ///   - applicationURL: The URL of the application to open
    ///   - configuration: The configuration options for opening the application
    ///   - completionHandler: A closure called when the operation completes
    func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration, completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?)

    /// Find the processes that run from one bundle, so uninstall can quit them before it removes the app.
    func runningApplications(atBundleURL url: URL) -> [any RunningApplicationHandle]

    /// Leave the item visible in Finder when SweetMX cannot remove it itself.
    func revealInFinder(_ url: URL)
}

import AppKit

/// Production implementation of WorkspaceProtocol wrapping NSWorkspace.shared
public final class SystemWorkspace: WorkspaceProtocol {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public var frontmostApplication: NSRunningApplication? {
        workspace.frontmostApplication
    }

    public func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration, completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?) {
        workspace.openApplication(at: applicationURL, configuration: configuration, completionHandler: completionHandler)
    }

    public func runningApplications(atBundleURL url: URL) -> [any RunningApplicationHandle] {
        // Resolve links on both sides so an app opened through a symlinked path still matches.
        let wanted = url.resolvingSymlinksInPath().standardizedFileURL
        return workspace.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == wanted }
    }

    public func urlsForApplications(withBundleIdentifier bundleID: String) -> [URL] {
        workspace.urlsForApplications(withBundleIdentifier: bundleID)
    }

    public func revealInFinder(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }

    public func open(_ url: URL) {
        workspace.open(url)
    }
}

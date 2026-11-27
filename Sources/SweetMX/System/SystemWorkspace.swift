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
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }

    public func revealInFinder(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }
}

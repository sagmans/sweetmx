import Foundation

/// The system seams one uninstall needs, gathered so the launcher model holds them once and the sheet
/// model can be built with mocks in tests.
///
/// The launcher model owns one value built from the same workspace and file system it already uses
/// for app search, so the uninstall flow never creates a second set of system objects.
struct UninstallDependencies {
    let fileSystem: FileSystemProtocol
    let workspace: WorkspaceProtocol
    let codeIdentity: CodeIdentityProtocol
    let finder: FinderTrashProtocol
    /// SweetMX's own bundle ID, so the resolver refuses to remove SweetMX itself.
    let ownBundleID: String?
    /// Read by the sheet to pick the administrator line and passed to the executor, so both always
    /// follow the same policy.
    let finderHandOffEnabled: Bool
    /// The live app index, read when a sheet opens. The scan needs it to lock files that a second copy
    /// or a same-named app may share. Nil while there is no index, so the sheet can lock every row
    /// instead of mistaking a missing index for "no other apps".
    let installedApps: () -> [ApplicationInfo]?
    /// Formats byte counts in the sheets; injected so tests pin one locale and the app follows the Mac's.
    let locale: Locale

    /// Production seams around the workspace and file system the launcher already owns; `apps` gives
    /// the live index once the app delegate supplies it.
    static func live(workspace: WorkspaceProtocol, fileSystem: FileSystemProtocol, apps: AppSearchModel) -> UninstallDependencies {
        UninstallDependencies(
            fileSystem: fileSystem,
            workspace: workspace,
            codeIdentity: SystemCodeIdentity(),
            finder: SystemFinderTrash(),
            ownBundleID: Bundle.main.bundleIdentifier,
            finderHandOffEnabled: UninstallPolicy.finderHandOffEnabled,
            installedApps: { [weak apps] in apps?.searchService?.applicationSnapshot().applications },
            locale: .autoupdatingCurrent
        )
    }
}

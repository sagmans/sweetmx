import Foundation

/// Switches that decide how far uninstall may go on a system it has not been proven on.
nonisolated enum UninstallPolicy {
    /// Off because the Finder hand-off (Finder shows the administrator prompt) is unproven on this
    /// macOS release. While it is off, a permission failure is reported as such, so the person can
    /// finish the removal in Finder themselves. `UninstallExecutor` takes the value through its
    /// initializer so tests cover both settings.
    static let finderHandOffEnabled = false
}

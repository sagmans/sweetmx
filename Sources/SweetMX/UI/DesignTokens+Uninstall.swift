import Foundation

/// Tokens of the uninstall flow. They live beside `DesignTokens` so the flow's waits are named in
/// one place; the confirmation sheet adds its copy and metrics here later.
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

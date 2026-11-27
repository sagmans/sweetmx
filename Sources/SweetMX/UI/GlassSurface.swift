import SwiftUI

extension EnvironmentValues {
    /// Replaces every glass surface with a fixed, opaque background.
    ///
    /// Exists for ASG-1279: glass samples what is behind it and follows the display profile, so the color
    /// profile of a snapshot changed from machine to machine and the references never matched. Only tests
    /// set it; it defaults to false, so production always draws glass.
    @Entry var launcherSnapshotMode = false
}

/// Draws a glass surface, or the fixed snapshot background when `launcherSnapshotMode` is on.
///
/// One modifier for all surfaces so the snapshot swap cannot be forgotten on a new one.
private struct GlassSurface<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    /// Fixed fill used instead of the glass in snapshot mode; selection capsules pass a stronger one so
    /// the highlight stays visible in the references.
    let snapshotFill: Color

    @Environment(\.launcherSnapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content.background(snapshotFill, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

/// The glass button style of the launcher's own controls (the pause control, the clipboard prompt and
/// the uninstall sheets), or a plain bordered one in snapshot mode where glass would sample whatever is
/// behind the test window.
/// One style, so every button on the launcher panel reads alike.
private struct LauncherButtonStyle: ViewModifier {
    /// The filled style, for the one action a prompt is about.
    let prominent: Bool
    @Environment(\.launcherSnapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        switch (prominent, snapshotMode) {
        case (true, false): content.buttonStyle(.glassProminent)
        case (false, false): content.buttonStyle(.glass)
        case (true, true): content.buttonStyle(.borderedProminent)
        case (false, true): content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Glass in `shape`, swapped for `snapshotFill` when the environment asks for stable snapshots.
    func launcherGlass(
        _ glass: Glass = .regular,
        in shape: some Shape,
        snapshotFill: Color = DesignTokens.Palette.snapshotSurface
    ) -> some View {
        modifier(GlassSurface(glass: glass, shape: shape, snapshotFill: snapshotFill))
    }

    /// The launcher's button style; see `LauncherButtonStyle`.
    func launcherButtonStyle(prominent: Bool = false) -> some View {
        modifier(LauncherButtonStyle(prominent: prominent))
    }
}

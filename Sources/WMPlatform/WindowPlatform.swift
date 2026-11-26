import WMCore

/// Entry point of the layer that will read real windows, keys and touches and apply the effects
/// that `WMCore` returns.
///
/// It is a separate target so the model never links AppKit or Accessibility, and so the window
/// manager can move to its own process later without a rewrite. Unlike the `SweetMX` target it has
/// no default main-actor isolation: Accessibility calls must run off the main actor, so a hung app
/// cannot freeze app search or the clipboard history.
public enum WindowPlatform {
    /// The model this layer is built against, so a diagnostic can name both sides of the boundary.
    public static let modelVersion = WMVersion.current
}

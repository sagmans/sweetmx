/// Version of the window manager model, apart from the app version in `Info.plist`.
///
/// Scenario files and their expected output are written against one model, so the tools that read
/// them (`wm-sim` today) report this value. The model changes on its own schedule while the window
/// manager stays off by default, which is why it does not follow the app release number.
public enum WMVersion {
    /// Below 1.0 until the window manager is safe for daily use.
    public static let current = "0.1.0"
}

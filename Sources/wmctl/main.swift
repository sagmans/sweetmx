import Foundation

// Development tool: will send commands to a development build of SweetMX and read its window
// manager state over the control socket. It imports Foundation only, so it can never reach a
// window by itself, and it is never copied into `SweetMX.app`.

/// Until the control socket exists there is nothing to talk to, and saying so is safer than a
/// tool that exits 0 and lets a live check pass without running.
private enum Unavailable {
    static let message = "wmctl: no commands yet; the control socket arrives with window tiling"
}

FileHandle.standardError.write(Data("\(Unavailable.message)\n".utf8))
exit(EX_UNAVAILABLE)

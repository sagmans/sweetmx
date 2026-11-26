import Foundation
import WMCore

// Development tool: runs the window manager model with no real window and no permission, so
// scenario checks can prove layout rules in milliseconds. It is built beside the app and never
// copied into `SweetMX.app` (`make bundle` refuses a bundle that holds it).

/// The whole command line in one place, so the usage text and the parser cannot drift apart.
private enum Invocation {
    static let toolName = "wm-sim"
    static let versionFlag = "--version"
    static let usage = "usage: \(toolName) \(versionFlag)"
}

let arguments = Array(CommandLine.arguments.dropFirst())
// Anything but the one known form fails with the usage text: a scenario check must never pass
// because the tool ignored an argument it did not understand.
guard arguments == [Invocation.versionFlag] else {
    FileHandle.standardError.write(Data("\(Invocation.usage)\n".utf8))
    exit(EX_USAGE)
}

print("\(Invocation.toolName) \(WMVersion.current)")

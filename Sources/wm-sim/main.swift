import Foundation
import WMCore

// Development tool: runs the window manager model with no real window and no permission, so
// scenario checks can prove layout rules in milliseconds. It is built beside the app and never
// copied into `SweetMX.app` (`make bundle` refuses a bundle that holds it).

/// A reason to stop with a message and an exit status. Every failure of the tool is one of these,
/// so a scenario check can tell a bad command line from a bad file from a broken model.
struct SimulatorFailure: Error {
    let message: String
    let status: Int32
}

/// The whole command line in one place, so the usage text and the parser cannot drift apart.
private enum Invocation {
    static let toolName = "wm-sim"
    static let versionFlag = "--version"
    static let fuzzFlag = "--fuzz"
    static let seedFlag = "--seed"
    /// A scenario file may not start with this, so a mistyped flag is never read as a file name.
    static let flagPrefix = "-"
    static let usage = "usage: \(toolName) \(versionFlag) | <scenario-file> | \(fuzzFlag) <steps> [\(seedFlag) <number>]"

    case version
    case scenario(path: String)
    case fuzz(steps: Int, seed: UInt64)

    /// Anything but a known form is nil and fails with the usage text: a scenario check must never
    /// pass because the tool ignored an argument it did not understand.
    static func parse(_ arguments: [String]) -> Invocation? {
        switch arguments.count {
        case 1 where arguments[0] == versionFlag:
            return .version
        case 1 where !arguments[0].hasPrefix(flagPrefix) && !arguments[0].isEmpty:
            return .scenario(path: arguments[0])
        case 2 where arguments[0] == fuzzFlag:
            return Fuzzer.stepCount(arguments[1]).map { .fuzz(steps: $0, seed: Fuzzer.defaultSeed) }
        case 4 where arguments[0] == fuzzFlag && arguments[2] == seedFlag:
            guard let steps = Fuzzer.stepCount(arguments[1]), let seed = UInt64(arguments[3]) else { return nil }
            return .fuzz(steps: steps, seed: seed)
        default:
            return nil
        }
    }

    func run() throws(SimulatorFailure) -> String {
        switch self {
        case .version: "\(Invocation.toolName) \(WMVersion.current)\n"
        case let .scenario(path): try ScenarioFile.run(path: path)
        case let .fuzz(steps, seed): try Fuzzer.run(steps: steps, seed: seed)
        }
    }
}

private func stop(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

guard let invocation = Invocation.parse(Array(CommandLine.arguments.dropFirst())) else {
    stop(Invocation.usage, status: EX_USAGE)
}

do {
    // The output is written once, at the end: a run that fails prints no partial result that a
    // reader could take for a pass.
    try FileHandle.standardOutput.write(contentsOf: Data(invocation.run().utf8))
} catch let failure as SimulatorFailure {
    stop("\(Invocation.toolName): \(failure.message)", status: failure.status)
} catch {
    stop("\(Invocation.toolName): cannot write the result: \(error.localizedDescription)", status: EX_IOERR)
}

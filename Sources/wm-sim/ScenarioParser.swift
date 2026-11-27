import Foundation
import WMCore

// The scenario file format. One line is one step: an input for the model, written the way a
// person would say it ("zoom in", "move left"). The file is input from outside the tool, so every
// word is checked, and the limits below keep a wrong or hostile file from running for hours.

/// One thing a scenario line does to the model.
enum ScenarioStep: Equatable {
    /// A new window. The simulator numbers windows 1, 2, 3 in the order they open, so a scenario
    /// never has to invent window numbers and cannot open the same one twice by mistake.
    case create
    case input(Input)
}

/// One line of a scenario file that does something.
struct ScenarioLine: Equatable {
    enum Action: Equatable {
        case steps([ScenarioStep])
        /// The same steps many times with one result block, for scenarios about long runs.
        case repeated([ScenarioStep], times: Int)
        case gaps(Gaps)
    }

    let text: String
    let action: Action
}

/// A bad line. The caller adds the file name and the line number.
struct ScenarioSyntaxError: Error {
    let message: String
}

enum ScenarioParser {
    enum Limit {
        /// Scenario files are a few hundred bytes; this only stops a wrong path (a disk image, a
        /// log) from being read into memory.
        static let fileBytes = 1 << 20
        static let repeats = 100_000
        /// All steps of one file. The property run is the place for millions of inputs.
        static let totalSteps = 1_000_000
        /// The tree is walked by recursion and can be as deep as it has windows, so the window
        /// count is what bounds the stack.
        static let windows = 2000
    }

    private static let commentPrefix = "#"
    private static let repeatKeyword = "repeat"
    private static let gapsKeyword = "gaps"
    private static let stepSeparator = ";"

    private static let directions: [String: Direction] = ["left": .left, "right": .right, "up": .up, "down": .down]
    private static let axes: [String: Axis] = ["horizontal": .horizontal, "vertical": .vertical]
    private static let zooms: [String: Command] = ["in": .zoomIn, "out": .zoomOut]

    /// Every input word and how its arguments are read. A table, so the format is in one place and
    /// a new input is one row.
    private static let steps: [String: @Sendable (inout Words) throws -> ScenarioStep] = [
        "create": { _ in .create },
        "destroy": { try .input(.event(.destroyed($0.window()))) },
        "focused": { try .input(.event(.focused($0.window()))) },
        "screen": { try .input(.event(.displayChanged(Rect(x: $0.number(), y: $0.number(), width: $0.number(), height: $0.number())))) },
        "focus": { try .input(.command(.focus($0.oneOf(directions, "a direction")))) },
        "move": { try .input(.command(.move($0.oneOf(directions, "a direction")))) },
        "split": { try .input(.command(.split($0.oneOf(axes, "an axis")))) },
        "resize": { try .input(.command(.resize($0.oneOf(directions, "a direction"), amount: $0.number()))) },
        "zoom": { try .input(.command($0.oneOf(zooms, "in or out"))) },
        "grid": { try .input(.command(.gridMove($0.oneOf(directions, "a direction")))) },
        "goto": { try .input(.command(.gotoWorkspace(Coord(x: $0.integer(), y: $0.integer())))) },
        "send": { try .input(.command(.sendToWorkspace(Coord(x: $0.integer(), y: $0.integer())))) },
    ]

    /// The lines that do something, in order. Throws at the first bad line with its number, and
    /// checks the limits for the whole file before anything runs.
    static func parse(_ text: String) throws -> [ScenarioLine] {
        var lines: [ScenarioLine] = []
        var totals = (steps: 0, windows: 0)
        // Any line end and any blank between words: a file saved with Windows line ends or tabs
        // must mean the same as one saved on a Mac. `\r\n` is one character in Swift, so a split
        // on `\n` alone would read such a file as a single line.
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(commentPrefix) else { continue }
            do {
                let action = try action(trimmed)
                try count(action, isFirst: lines.isEmpty, into: &totals)
                lines.append(ScenarioLine(text: trimmed, action: action))
            } catch let error as ScenarioSyntaxError {
                throw ScenarioSyntaxError(message: "\(index + 1): \(error.message)")
            }
        }
        return lines
    }

    private static func action(_ line: String) throws -> ScenarioLine.Action {
        var words = Words(line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)[...])
        switch words.peek {
        case gapsKeyword:
            _ = try words.next("a keyword")
            let gaps = try Gaps(inner: words.number(), outer: words.number())
            try words.end()
            return .gaps(gaps)
        case repeatKeyword:
            _ = try words.next("a keyword")
            let times = try words.integer()
            guard (1 ... Limit.repeats).contains(times) else {
                throw ScenarioSyntaxError(message: "a repeat count is from 1 to \(Limit.repeats)")
            }
            return try .repeated(stepList(words.rest), times: times)
        default:
            return try .steps([step(&words)])
        }
    }

    private static func stepList(_ words: ArraySlice<Substring>) throws -> [ScenarioStep] {
        try words.split(separator: Substring(stepSeparator), omittingEmptySubsequences: false).map { part in
            var words = Words(part)
            return try step(&words)
        }
    }

    private static func step(_ words: inout Words) throws -> ScenarioStep {
        let keyword = try String(words.next("an input"))
        guard let read = steps[keyword] else {
            throw ScenarioSyntaxError(message: "unknown input '\(keyword)'")
        }
        let step = try read(&words)
        try words.end()
        return step
    }

    private static func count(_ action: ScenarioLine.Action, isFirst: Bool, into totals: inout (steps: Int, windows: Int)) throws {
        let (steps, times): ([ScenarioStep], Int)
        switch action {
        case .gaps:
            // Gaps are part of the starting state, as they are when the app reads its config at
            // launch. Changing them later would move windows with no input to explain it.
            guard isFirst else { throw ScenarioSyntaxError(message: "gaps must be the first line that does something") }
            return
        case let .steps(list): (steps, times) = (list, 1)
        case let .repeated(list, count): (steps, times) = (list, count)
        }
        totals.steps += steps.count * times
        totals.windows += steps.count(where: { $0 == .create }) * times
        guard totals.steps <= Limit.totalSteps else {
            throw ScenarioSyntaxError(message: "a scenario runs at most \(Limit.totalSteps) steps")
        }
        guard totals.windows <= Limit.windows else {
            throw ScenarioSyntaxError(message: "a scenario opens at most \(Limit.windows) windows")
        }
    }
}

/// The words of one step, read from left to right. Each reader says what it wanted when the word
/// is missing or wrong, so the error names the fix.
struct Words {
    private var remaining: ArraySlice<Substring>

    init(_ words: ArraySlice<Substring>) {
        remaining = words
    }

    var peek: String? {
        remaining.first.map(String.init)
    }

    var rest: ArraySlice<Substring> {
        remaining
    }

    mutating func next(_ wanted: String) throws -> Substring {
        guard let word = remaining.popFirst() else {
            throw ScenarioSyntaxError(message: "expected \(wanted)")
        }
        return word
    }

    func end() throws {
        if let extra = remaining.first {
            throw ScenarioSyntaxError(message: "unexpected '\(extra)'")
        }
    }

    mutating func oneOf<Value>(_ choices: [String: Value], _ wanted: String) throws -> Value {
        let word = try next(wanted)
        guard let value = choices[String(word)] else {
            throw ScenarioSyntaxError(message: "expected \(wanted), not '\(word)'")
        }
        return value
    }

    mutating func integer() throws -> Int {
        let word = try next("a whole number")
        guard let value = Int(word) else {
            throw ScenarioSyntaxError(message: "expected a whole number, not '\(word)'")
        }
        return value
    }

    /// Finite only: "nan" and "inf" parse as numbers, and a scenario that uses one by accident
    /// would give frames that mean nothing. The property run covers those values on purpose.
    mutating func number() throws -> Double {
        let word = try next("a number")
        guard let value = Double(word), value.isFinite else {
            throw ScenarioSyntaxError(message: "expected a number, not '\(word)'")
        }
        return value
    }

    mutating func window() throws -> WindowID {
        let word = try next("a window number")
        guard let value = UInt32(word) else {
            throw ScenarioSyntaxError(message: "expected a window number, not '\(word)'")
        }
        return WindowID(value)
    }
}

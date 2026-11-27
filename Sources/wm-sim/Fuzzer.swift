import Foundation
import WMCore

// The property run: many random inputs, with the rules of a sound state checked after each one.
// Scenario files prove the cases someone thought of; this proves the rules hold in the states
// nobody thought of. It is seeded, so a failure gives a seed and a step that replay it exactly.

/// SplitMix64: a small generator with a fixed, public algorithm, so one seed gives the same inputs
/// on every machine and toolchain. The system generator cannot be seeded, and the standard
/// library may change how it turns random bits into a choice, so the choice is made here too.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// A number from 0 up to, not including, `count`. The small bias of the remainder does not
    /// matter for picking test inputs.
    mutating func index(below count: Int) -> Int {
        Int(next() % UInt64(max(count, 1)))
    }
}

/// What the platform layer would hold after applying every effect so far. If the effects of each
/// step are complete, this always equals what the state says the screen must show.
private struct ScreenReplay {
    private var frames: [WindowID: Rect] = [:]
    private var hidden: Set<WindowID> = []
    private var focus: WindowID?

    mutating func apply(_ input: Input, _ effects: [Effect]) {
        // What the system does by itself: a closed window is gone, and a window it focused has
        // the focus without any effect from the model.
        if case let .event(.destroyed(window)) = input {
            frames[window] = nil
            hidden.remove(window)
            focus = focus == window ? nil : focus
        }
        if case let .event(.focused(window)) = input, frames[window] != nil || hidden.contains(window) {
            focus = window
        }
        for effect in effects {
            switch effect {
            case let .setFrame(window, frame):
                frames[window] = frame
                hidden.remove(window)
            case let .hide(window):
                frames[window] = nil
                hidden.insert(window)
            case let .raiseAndFocus(window):
                focus = window
            }
        }
    }

    /// Nil when the replay matches, else what differs. An empty workspace has no focus to give,
    /// so the focus is compared only when the state names one.
    func difference(from wanted: Presentation) -> String? {
        if frames != Dictionary(wanted.frames.map { ($0.window, $0.frame) }, uniquingKeysWith: { first, _ in first }) {
            return "the effects left other frames than the state shows"
        }
        if hidden != Set(wanted.hidden) {
            return "the effects left other windows hidden than the state shows"
        }
        if let wantedFocus = wanted.focus, wantedFocus != focus {
            return "the effects left the focus on another window than the state shows"
        }
        return nil
    }
}

struct Fuzzer {
    static let defaultSeed: UInt64 = 1
    /// Upper limit for one run; the scenario check uses 100 000.
    private static let maximumSteps = 10_000_000
    /// Above this many windows a "created" turns into a "destroyed", so the run stays in the
    /// range of a real desktop and keeps removing as much as it adds.
    private static let windowCeiling = 24
    /// One input in this many uses a window the model does not hold, or opens one it holds.
    private static let strangerOdds = 10
    /// One coordinate in this many is at the end of `Int`, where a grid move must not overflow.
    private static let farCellOdds = 50
    private static let nearCells = [-1, 0, 1]
    private static let farCells = [Int.max, Int.min]
    /// Offset that makes a window number the run never opens.
    private static let strangerOffset: UInt32 = 1_000_000

    private static let screens = [
        Rect(x: 0, y: 0, width: 1920, height: 1080),
        Rect(x: 0, y: 25, width: 1440, height: 875),
        Rect(x: -3840, y: 0, width: 3840, height: 1600),
        Rect(x: 0.5, y: 0.5, width: 800.5, height: 600.25),
        Rect(x: 0, y: 0, width: 1, height: 1),
        // Not usable; the model must keep the screen it has.
        Rect(x: 0, y: 0, width: 0, height: 0),
        Rect(x: 0, y: 0, width: -100, height: 100),
        Rect(x: .nan, y: 0, width: 100, height: 100),
        Rect(x: 0, y: 0, width: .infinity, height: 100),
        Rect(x: -1e308, y: 0, width: 1.5e308, height: 1080),
    ]
    /// A run is cut into one part for each of these, in order, and each part starts from an empty
    /// state. No gaps comes first: only there do the frames have to cover the whole screen. The
    /// rest are a usual config, an inner gap with no outer gap (the first box is then larger than
    /// the screen), a gap larger than the screen, and a number near the end of the range, which
    /// the model takes as its largest gap.
    private static let gapSettings = [
        Gaps.none,
        Gaps(inner: 10, outer: 10),
        Gaps(inner: 40, outer: 0),
        Gaps(inner: 5000, outer: 0),
        Gaps(inner: 1.7e308, outer: 5),
    ]
    private static let resizeAmounts: [Double] = [0.05, -0.05, 0.3, -0.3, 5, -5, 0, 1e308, .nan, .infinity, -.infinity]

    /// Each kind of input and how often it comes up. Windows open more often than they close, so
    /// trees grow deep enough for zoom and move to matter.
    private enum Kind: CaseIterable {
        case created, destroyed, focused, displayChanged, focus, move, split, resize, zoomIn, zoomOut, gridMove, gotoWorkspace, sendToWorkspace

        var weight: Int {
            switch self {
            case .created: 14
            case .move: 12
            case .focus: 10
            case .destroyed, .zoomIn: 8
            case .zoomOut: 7
            case .focused, .split, .resize, .gridMove: 6
            case .sendToWorkspace: 4
            case .gotoWorkspace: 3
            case .displayChanged: 2
            }
        }

        static let deck = allCases.flatMap { Array(repeating: $0, count: $0.weight) }
    }

    private var random: SeededGenerator
    private var state = WMState(screen: Fuzzer.screens[0])
    private var replay = ScreenReplay()
    private var live: [WindowID] = []
    private var opened: UInt32 = 0
    private var peak = (windows: 0, workspaces: 0)
    private var effectCount = 0

    static func stepCount(_ text: String) -> Int? {
        Int(text).flatMap { (1 ... maximumSteps).contains($0) ? $0 : nil }
    }

    static func run(steps: Int, seed: UInt64) throws(SimulatorFailure) -> String {
        // A checker that cannot see a broken state would pass every run, so it is tested first.
        let blind = StateRule.undetected()
        guard blind.isEmpty else {
            throw SimulatorFailure(message: "the state check does not see: \(blind.map(\.rawValue).joined(separator: ", "))", status: EX_SOFTWARE)
        }
        var fuzzer = Fuzzer(random: SeededGenerator(seed: seed))
        var part = -1
        for step in 1 ... steps {
            let wanted = (step - 1) * gapSettings.count / steps
            if wanted != part {
                part = wanted
                fuzzer.restart(gaps: gapSettings[part])
            }
            let input = fuzzer.nextInput()
            if let problem = fuzzer.apply(input) {
                // The step count is part of the replay: it decides where each gap setting starts.
                let place = "step \(step) of \(steps), seed \(seed), gaps \(fuzzer.state.gaps.inner) \(fuzzer.state.gaps.outer)"
                throw SimulatorFailure(message: "fuzz failed at \(place): \(problem); input \(input)", status: EX_SOFTWARE)
            }
        }
        return "fuzz ok: steps=\(steps) seed=\(seed) rules=\(StateRule.allCases.count) gap-settings=\(min(steps, gapSettings.count)) "
            + "peak-windows=\(fuzzer.peak.windows) peak-workspaces=\(fuzzer.peak.workspaces) effects=\(fuzzer.effectCount)\n"
    }

    /// Starts again from an empty state, as the app does at launch with a new config. The window
    /// numbers go on, so a window of an earlier part is a stranger in the next.
    private mutating func restart(gaps: Gaps) {
        state = WMState(screen: Fuzzer.screens[0], gaps: gaps)
        replay = ScreenReplay()
        live = []
    }

    /// Applies one input and returns what went wrong, or nil.
    private mutating func apply(_ input: Input) -> String? {
        let (next, effects) = reduce(state, input)
        replay.apply(input, effects)
        state = next
        effectCount += effects.count
        peak = (max(peak.windows, live.count), max(peak.workspaces, state.grid.cells.count))
        let presentation = Presentation(of: state)
        if let violation = state.violations(presentation: presentation).first {
            return "\(violation.rule.rawValue): \(violation.detail)"
        }
        return replay.difference(from: presentation)
    }

    private mutating func nextInput() -> Input {
        let kind = pick(Kind.deck, or: .created)
        switch kind {
        case .created where live.count < Fuzzer.windowCeiling: return .event(.created(openWindow()))
        case .created, .destroyed: return .event(.destroyed(closeWindow()))
        case .focused: return .event(.focused(someWindow()))
        case .displayChanged: return .event(.displayChanged(pick(Fuzzer.screens, or: Fuzzer.screens[0])))
        case .focus: return .command(.focus(direction()))
        case .move: return .command(.move(direction()))
        case .split: return .command(.split(pick(Axis.allCases, or: .horizontal)))
        case .resize: return .command(.resize(direction(), amount: pick(Fuzzer.resizeAmounts, or: 0)))
        case .zoomIn: return .command(.zoomIn)
        case .zoomOut: return .command(.zoomOut)
        case .gridMove: return .command(.gridMove(direction()))
        case .gotoWorkspace: return .command(.gotoWorkspace(cell()))
        case .sendToWorkspace: return .command(.sendToWorkspace(cell()))
        }
    }

    private mutating func pick<Value>(_ values: [Value], or fallback: Value) -> Value {
        values.isEmpty ? fallback : values[random.index(below: values.count)]
    }

    private mutating func direction() -> Direction {
        pick(Direction.allCases, or: .left)
    }

    private mutating func oneIn(_ odds: Int) -> Bool {
        random.index(below: odds) == 0
    }

    private mutating func cell() -> Coord {
        func coordinate() -> Int {
            oneIn(Fuzzer.farCellOdds) ? pick(Fuzzer.farCells, or: 0) : pick(Fuzzer.nearCells, or: 0)
        }
        return Coord(x: coordinate(), y: coordinate())
    }

    private var stranger: WindowID {
        WindowID(opened + Fuzzer.strangerOffset)
    }

    private mutating func someWindow() -> WindowID {
        oneIn(Fuzzer.strangerOdds) ? stranger : pick(live, or: stranger)
    }

    /// A new window, or now and then one that is already open: the platform layer can report a
    /// window twice, and the model must hold it once.
    private mutating func openWindow() -> WindowID {
        if oneIn(Fuzzer.strangerOdds), !live.isEmpty {
            return pick(live, or: stranger)
        }
        opened += 1
        live.append(WindowID(opened))
        return WindowID(opened)
    }

    private mutating func closeWindow() -> WindowID {
        let window = someWindow()
        live.removeAll { $0 == window }
        return window
    }
}

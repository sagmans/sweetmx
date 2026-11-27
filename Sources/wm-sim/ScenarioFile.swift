import Foundation
import WMCore

// Runs one scenario file through the model and prints, after each line, what a user would see:
// where they are, the tree, the frame of each visible window, the hidden windows, and the effects
// the line caused. The output is compared with a committed expected file, byte for byte, so it
// uses whole numbers and one fixed order.

enum ScenarioFile {
    /// The display a scenario starts on, unless its first lines say otherwise. A common size, so
    /// the expected frames are easy to check by hand.
    private static let defaultScreen = Rect(x: 0, y: 0, width: 1920, height: 1080)

    static func run(path: String) throws(SimulatorFailure) -> String {
        let lines: [ScenarioLine]
        do {
            lines = try ScenarioParser.parse(read(path))
        } catch let error as ScenarioSyntaxError {
            throw SimulatorFailure(message: "\(path):\(error.message)", status: EX_DATAERR)
        } catch let failure as SimulatorFailure {
            throw failure
        } catch {
            // A fixed text: the system's own message changes with the language of the Mac, and a
            // scenario check compares this line.
            throw SimulatorFailure(message: "\(path): cannot read the file", status: EX_NOINPUT)
        }
        var simulation = Simulation(state: WMState(screen: defaultScreen))
        // One empty line between blocks and none after the last: the result is committed as an
        // expected file, and the commit check refuses a file that ends in an empty line.
        return lines.map { simulation.run($0) }.joined(separator: "\n")
    }

    /// Reads at most the size limit plus one byte, so a huge file is refused without being loaded.
    private static func read(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ScenarioParser.Limit.fileBytes + 1) ?? Data()
        guard data.count <= ScenarioParser.Limit.fileBytes else {
            throw SimulatorFailure(message: "\(path): larger than \(ScenarioParser.Limit.fileBytes) bytes", status: EX_DATAERR)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SimulatorFailure(message: "\(path): not UTF-8 text", status: EX_DATAERR)
        }
        return text
    }
}

/// The model plus the one thing a scenario needs that the model does not hold: the number of the
/// next window to open.
struct Simulation {
    private(set) var state: WMState
    private var windowsOpened: UInt32 = 0

    init(state: WMState) {
        self.state = state
    }

    /// Runs one line and returns its result block.
    mutating func run(_ line: ScenarioLine) -> String {
        var report = ["> \(line.text)"]
        switch line.action {
        case let .gaps(gaps):
            state = WMState(grid: state.grid, screen: state.screen, gaps: gaps, nodeIDs: state.nodeIDs)
            report += StateText.lines(state) + ["effects 0"]
        case let .steps(steps):
            let effects = apply(steps)
            report += StateText.lines(state) + ["effects \(effects.count)"] + effects.map { "  \(StateText.effect($0))" }
        case let .repeated(steps, times):
            // The count only: a long run would print thousands of effect lines that no reader
            // checks. The state after the run is what the scenario is about.
            let count = (0 ..< times).reduce(0) { total, _ in total + apply(steps).count }
            report += StateText.lines(state) + ["effects \(count)"]
        }
        return report.joined(separator: "\n") + "\n"
    }

    private mutating func apply(_ steps: [ScenarioStep]) -> [Effect] {
        steps.flatMap { step -> [Effect] in
            let input: Input
            switch step {
            case .create:
                windowsOpened += 1
                input = .event(.created(WindowID(windowsOpened)))
            case let .input(given):
                input = given
            }
            let result = reduce(state, input)
            state = result.state
            return result.effects
        }
    }
}

/// The text form of a state. Short words and whole numbers, so an expected file reads like a
/// description of the screen and a diff shows which window moved.
enum StateText {
    /// Marks the node that fills the screen, in front of it.
    private static let viewMark = "@"
    /// Marks the focused window, after it.
    private static let focusMark = "*"
    /// Stands for "none" where a list or a tree is empty, so no line ends in a bare keyword.
    private static let nothing = "-"

    static func lines(_ state: WMState) -> [String] {
        let workspace = state.grid.currentWorkspace
        let presentation = Presentation(of: state)
        let hidden = presentation.hidden.map { String($0.rawValue) }
        return [
            "grid \(state.grid.current.x),\(state.grid.current.y) workspaces \(state.grid.cells.count) zoom \(zoomDepth(workspace))",
            "tree \(workspace.root.map { tree($0, in: workspace) } ?? nothing)",
        ] + presentation.frames.map { "frame \($0.window.rawValue) \(rect($0.frame))" }
            + ["hidden \(hidden.isEmpty ? nothing : hidden.joined(separator: " "))"]
    }

    static func effect(_ effect: Effect) -> String {
        switch effect {
        case let .setFrame(window, frame): "frame \(window.rawValue) \(rect(frame))"
        case let .hide(window): "hide \(window.rawValue)"
        case let .raiseAndFocus(window): "focus \(window.rawValue)"
        }
    }

    /// The tree on one line: `h(...)` and `v(...)` for the two kinds of split, window numbers for
    /// windows.
    private static func tree(_ node: Node, in workspace: Workspace) -> String {
        let view = node.id == workspace.viewRoot ? viewMark : ""
        switch node.content {
        case let .window(window):
            return "\(view)\(window.rawValue)\(node.id == workspace.focus ? focusMark : "")"
        case let .split(split):
            let children = split.children.map { tree($0, in: workspace) }.joined(separator: " ")
            return "\(view)\(split.axis == .horizontal ? "h" : "v")(\(children))"
        }
    }

    /// How many times the user has zoomed in: the number of levels between the root and the view.
    private static func zoomDepth(_ workspace: Workspace) -> Int {
        func depth(of node: Node, at level: Int) -> Int? {
            if node.id == workspace.viewRoot {
                return level
            }
            guard case let .split(split) = node.content else { return nil }
            // A plain loop on purpose: `lazy.compactMap { }.first` runs its closure twice for the
            // match, which doubles the work at every level of a deep tree.
            for child in split.children {
                if let found = depth(of: child, at: level + 1) {
                    return found
                }
            }
            return nil
        }
        return workspace.root.flatMap { depth(of: $0, at: 0) } ?? 0
    }

    private static func rect(_ rect: Rect) -> String {
        [rect.x, rect.y, rect.width, rect.height].map(number).joined(separator: " ")
    }

    /// Frames are whole points, so they print as whole numbers. A value too large for that prints
    /// as it is; it can only come from a screen of that size.
    private static func number(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(value)
    }
}

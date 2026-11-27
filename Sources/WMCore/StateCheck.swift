// The rules that every state must keep, written once and apart from the code that is meant to
// keep them. `wm-sim --fuzz` applies them after each random input, and the platform layer can
// apply them to a live state when a window ends up in the wrong place.

/// One rule that a state must keep. The raw value is the name a failure report prints.
public enum StateRule: String, CaseIterable, Sendable {
    /// Every window is in exactly one tree, once, and every node name is used once.
    case windowOnce = "window-once"
    /// `viewRoot` and `focus` name existing nodes, and the focus is a window inside the view.
    case references
    /// Every split has a child, and the weights keep one scale: their mean is one and none is
    /// below the smallest share.
    case splitShape = "split-shape"
    /// The current cell exists, and no other workspace is empty.
    case gridCells = "grid-cells"
    /// Visible frames never overlap.
    case overlap
    /// Visible frames stay on the screen and, with no gaps, cover all of it.
    case coverage
}

/// One broken rule, with enough detail to find the node or window.
public struct Violation: Equatable, Sendable {
    public let rule: StateRule
    public let detail: String
}

public extension WMState {
    /// Every rule this state breaks; empty for a sound state. A caller that already made the
    /// state's presentation passes it in, so a check after every input does the layout once.
    func violations(presentation: Presentation? = nil) -> [Violation] {
        var found = duplicateNames()
        if grid.cells[grid.current] == nil {
            found.append(Violation(rule: .gridCells, detail: "current cell \(grid.current) has no workspace"))
        }
        for (coord, workspace) in grid.cells {
            if workspace.root == nil, coord != grid.current {
                found.append(Violation(rule: .gridCells, detail: "empty workspace kept at \(coord)"))
            }
            found += workspace.brokenReferences().map { Violation(rule: .references, detail: "\(coord): \($0)") }
            found += (workspace.root?.brokenSplits() ?? []).map { Violation(rule: .splitShape, detail: "\(coord): \($0)") }
        }
        return found + WMState.frameViolations((presentation ?? Presentation(of: self)).frames, screen: screen, gaps: gaps)
    }

    private func duplicateNames() -> [Violation] {
        var windows: Set<WindowID> = []
        var nodes: Set<NodeID> = []
        var found: [Violation] = []
        for workspace in grid.cells.values {
            workspace.root?.visit { node in
                if !nodes.insert(node.id).inserted {
                    found.append(Violation(rule: .windowOnce, detail: "node \(node.id.rawValue) appears twice"))
                }
                if let window = node.window, !windows.insert(window).inserted {
                    found.append(Violation(rule: .windowOnce, detail: "window \(window.rawValue) appears twice"))
                }
            }
        }
        return found
    }
}

extension WMState {
    /// How far the weights of a split may be from their scale, as a part of it. Each edit leaves a
    /// rounding error of a few bits; this is far above that and far below any real drift.
    static let weightTolerance = 1e-9

    /// The rules about frames, on their own so they can be checked against any list of frames:
    /// the layout can only break them through a fault, and a checker that was never shown a broken
    /// list could not be trusted to notice one.
    static func frameViolations(_ frames: [WindowFrame], screen: Rect, gaps: Gaps) -> [Violation] {
        var found: [Violation] = []
        for (index, first) in frames.enumerated() {
            for second in frames[(index + 1)...] where first.frame.overlaps(second.frame) {
                found.append(Violation(rule: .overlap, detail: "windows \(first.window.rawValue) and \(second.window.rawValue) overlap"))
            }
            let frame = first.frame
            // Every comparison with a value that is not a number is false, so such a frame would
            // pass the checks below.
            if ![frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) {
                found.append(Violation(rule: .coverage, detail: "window \(first.window.rawValue) has a frame that is not a number"))
            } else if frame.x < screen.x.rounded() || frame.y < screen.y.rounded() || frame.maxX > screen.maxX.rounded() || frame.maxY > screen.maxY.rounded() {
                found.append(Violation(rule: .coverage, detail: "window \(first.window.rawValue) leaves the screen"))
            }
        }
        // With no overlap and nothing off screen, equal areas mean the frames tile the screen
        // exactly. Frames and screen are in whole points, so the sum is exact.
        let covered = frames.reduce(0) { $0 + $1.frame.area }
        let whole = (screen.maxX.rounded() - screen.x.rounded()) * (screen.maxY.rounded() - screen.y.rounded())
        if gaps == .none, !frames.isEmpty, covered != whole {
            found.append(Violation(rule: .coverage, detail: "frames cover \(covered) of \(whole) square points"))
        }
        return found
    }
}

private extension Workspace {
    func brokenReferences() -> [String] {
        guard let root else {
            return viewRoot == nil && focus == nil ? [] : ["an empty workspace has a view or a focus"]
        }
        guard let viewRoot, let viewPath = root.path(to: viewRoot) else { return ["viewRoot names no node"] }
        guard let focus, let focusPath = root.path(to: focus) else { return ["focus names no node"] }
        var broken: [String] = []
        if root.node(at: focusPath)?.window == nil {
            broken.append("focus is not a window")
        }
        if !focusPath.starts(with: viewPath) {
            broken.append("focus is outside the view")
        }
        return broken
    }
}

private extension Node {
    func visit(_ body: (Node) -> Void) {
        body(self)
        split?.children.forEach { $0.node.visit(body) }
    }

    func brokenSplits() -> [String] {
        var broken: [String] = []
        visit { node in
            guard let split = node.split else { return }
            if split.children.isEmpty {
                broken.append("split \(node.id.rawValue) has no child")
            }
            let count = Double(split.children.count)
            let floor = Split.settledFloor * (1 - WMState.weightTolerance)
            if !split.children.allSatisfy({ $0.weight.isFinite && $0.weight >= floor }) {
                broken.append("split \(node.id.rawValue) has bad weights")
            } else if abs(split.totalWeight - count) > count * WMState.weightTolerance {
                broken.append("split \(node.id.rawValue) has weights that left their scale")
            }
        }
        return broken
    }
}

public extension StateRule {
    /// The rules that the check fails to report on a state made to break them, plus any rule with
    /// no broken example. A caller runs this before it trusts a clean check: a checker that cannot
    /// see a broken state would pass every run. It lives here, beside the rules, because only this
    /// module can build a state that breaks one.
    static func undetected() -> [StateRule] {
        let missed = BrokenExample.all.filter { example in !example.violations.contains { $0.rule == example.rule } }.map(\.rule)
        let untested = allCases.filter { rule in !BrokenExample.all.contains { $0.rule == rule } }
        return missed + untested
    }
}

/// States and frames that break one rule each, made by hand.
private enum BrokenExample {
    private static let screen = Rect(x: 0, y: 0, width: 100, height: 100)
    private static let half = Rect(x: 0, y: 0, width: 50, height: 100)
    /// Half of it lies past the right edge of the screen.
    private static let aside = Rect(x: 75, y: 0, width: 50, height: 100)
    private static let notANumber = Rect(x: .nan, y: 0, width: 50, height: 100)
    /// With gaps the frames need not cover the screen, so an example checked with them proves
    /// the other frame checks only.
    private static let someGaps = Gaps(inner: 1, outer: 1)

    private static func leaf(_ window: UInt32, node: UInt64) -> Node {
        Node(id: NodeID(node), content: .window(WindowID(window)))
    }

    private static func state(_ workspace: Workspace, extra: [Coord: Workspace] = [:]) -> WMState {
        var state = WMState(screen: screen)
        state.grid = Grid(cells: extra.merging([.origin: workspace]) { _, current in current })
        return state
    }

    private static func row(_ nodes: [Node], weights: [Double]? = nil) -> Workspace {
        var split = Split(axis: .horizontal, nodes: nodes)
        for (index, weight) in (weights ?? []).enumerated() {
            split.children[index].weight = weight
        }
        return Workspace(root: Node(id: NodeID(0), content: .split(split)), viewRoot: NodeID(0), focus: nodes.first?.id)
    }

    static let all: [(rule: StateRule, violations: [Violation])] = [
        (.windowOnce, state(row([leaf(1, node: 1), leaf(1, node: 2)])).violations()),
        (.references, state(Workspace(root: leaf(1, node: 1), viewRoot: NodeID(1), focus: NodeID(9))).violations()),
        (.references, state(Workspace(root: leaf(1, node: 1), viewRoot: NodeID(9), focus: NodeID(1))).violations()),
        (.splitShape, state(row([leaf(1, node: 1), leaf(2, node: 2)], weights: [0, 2])).violations()),
        (.splitShape, state(row([leaf(1, node: 1), leaf(2, node: 2)], weights: [0.5, 0.5])).violations()),
        (.splitShape, state(Workspace(root: Node(id: NodeID(0), content: .split(Split(axis: .horizontal, nodes: []))), viewRoot: NodeID(0), focus: nil)).violations()),
        (.gridCells, state(Workspace(), extra: [Coord(x: 1, y: 0): Workspace()]).violations()),
        (.overlap, WMState.frameViolations([WindowFrame(window: WindowID(1), frame: screen), WindowFrame(window: WindowID(2), frame: half)], screen: screen, gaps: .none)),
        (.coverage, WMState.frameViolations([WindowFrame(window: WindowID(1), frame: half)], screen: screen, gaps: .none)),
        (.coverage, WMState.frameViolations([WindowFrame(window: WindowID(1), frame: aside)], screen: screen, gaps: someGaps)),
        (.coverage, WMState.frameViolations([WindowFrame(window: WindowID(1), frame: notANumber)], screen: screen, gaps: someGaps)),
    ]
}

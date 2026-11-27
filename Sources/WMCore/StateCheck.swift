// The rules that every state must keep, written once and apart from the code that is meant to
// keep them. `wm-sim --fuzz` applies them after each random input, and the platform layer can
// apply them to a live state when a window ends up in the wrong place.

/// One rule that a state must keep. The raw value is the name a failure report prints.
public enum StateRule: String, CaseIterable, Sendable {
    /// Every window is in exactly one tree, once, and every node name is used once.
    case windowOnce = "window-once"
    /// `viewRoot` and `focus` name existing nodes, and the focus is a window inside the view.
    case references
    /// Every split has a child, and one positive, finite weight for each child.
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
            if frame.x < screen.x.rounded() || frame.y < screen.y.rounded() || frame.maxX > screen.maxX.rounded() || frame.maxY > screen.maxY.rounded() {
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
        split?.children.forEach { $0.visit(body) }
    }

    func brokenSplits() -> [String] {
        var broken: [String] = []
        visit { node in
            guard let split = node.split else { return }
            if split.children.isEmpty {
                broken.append("split \(node.id.rawValue) has no child")
            }
            if split.weights.count != split.children.count || !split.weights.allSatisfy({ $0.isFinite && $0 > 0 }) {
                broken.append("split \(node.id.rawValue) has bad weights")
            }
        }
        return broken
    }
}

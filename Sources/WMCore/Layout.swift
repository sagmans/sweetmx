// Layout math: from a workspace tree to one frame per visible window. Pure, so the same tree and
// screen always give the same frames, and `wm-sim` can compare them with an expected file.

/// The frame the layout gives to one window.
public struct WindowFrame: Equatable, Sendable {
    public let window: WindowID
    public let frame: Rect

    public init(window: WindowID, frame: Rect) {
        self.window = window
        self.frame = frame
    }
}

/// One frame for each window inside the workspace's `viewRoot`, in tree order. Windows outside the
/// view get no frame; they are hidden.
///
/// Frames are in whole points. With no gaps they tile `screenRect` exactly: no overlap and no
/// hole, however deep the tree is. The model sets no smallest size, so a window deep in a tree
/// can get a frame with no area; the platform layer reads back the frame a real window accepts.
public func layout(_ workspace: Workspace, screenRect: Rect, gaps: Gaps) -> [WindowFrame] {
    guard screenRect.isUsable, let root = workspace.root, let viewRoot = workspace.viewRoot,
          let view = root.path(to: viewRoot).flatMap({ root.node(at: $0) })
    else { return [] }
    // Each window is inset by half the inner gap, so two neighbors are one inner gap apart. The
    // screen is inset by the rest, so a window at the edge is one outer gap from it.
    let halfInner = gaps.inner / 2
    var frames: [WindowFrame] = []
    place(view, in: Box(screenRect).inset(by: gaps.outer - halfInner), halfInner: halfInner, into: &frames)
    return frames
}

private func place(_ node: Node, in box: Box, halfInner: Double, into frames: inout [WindowFrame]) {
    switch node.content {
    case let .window(window):
        frames.append(WindowFrame(window: window, frame: box.inset(by: halfInner).snapped))
    case let .split(split):
        for (child, part) in zip(split.children, box.divided(along: split.axis, weights: split.weights)) {
            place(child, in: part, halfInner: halfInner, into: &frames)
        }
    }
}

/// A rectangle held as its four edges. Two neighbors share one edge value, bit for bit, which a
/// rectangle held as an origin and a size cannot promise: `x + width` may round differently from
/// the next `x`. Shared edges are what make the frames tile with no overlap and no hole.
private struct Box {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    init(_ rect: Rect) {
        minX = rect.x
        minY = rect.y
        maxX = rect.maxX
        maxY = rect.maxY
    }

    /// Shrinks every side by `amount` (grows it when negative). A box too small for the inset
    /// closes at its middle, so a gap larger than the window gives an empty frame, never one
    /// turned inside out.
    func inset(by amount: Double) -> Box {
        var box = self
        (box.minX, box.maxX) = Box.inset(minX, maxX, by: amount)
        (box.minY, box.maxY) = Box.inset(minY, maxY, by: amount)
        return box
    }

    private static func inset(_ lower: Double, _ upper: Double, by amount: Double) -> (Double, Double) {
        let (low, high) = (lower + amount, upper - amount)
        guard low <= high else {
            let middle = lower + (upper - lower) / 2
            return (middle, middle)
        }
        return (low, high)
    }

    /// One box per weight along `axis`. The first starts at this box's first edge and the last
    /// ends at its last edge exactly, so rounding can never leave a strip uncovered.
    func divided(along axis: Axis, weights: [Double]) -> [Box] {
        let (lower, upper) = axis == .horizontal ? (minX, maxX) : (minY, maxY)
        let total = weights.reduce(0, +)
        var parts: [Box] = []
        parts.reserveCapacity(weights.count)
        var start = lower
        var running = 0.0
        for (index, weight) in weights.enumerated() {
            running += weight
            // Weights that are not positive numbers are a fault; the children then share one
            // point, which the state check reports, instead of frames made from NaN.
            let share = total > 0 && total.isFinite ? running / total : 0
            let end = index == weights.count - 1 ? upper : min(max(lower + (upper - lower) * share, start), upper)
            var part = self
            if axis == .horizontal {
                (part.minX, part.maxX) = (start, end)
            } else {
                (part.minY, part.maxY) = (start, end)
            }
            parts.append(part)
            start = end
        }
        return parts
    }

    /// Whole points. Each edge is rounded by itself, so an edge that two boxes share rounds to
    /// the same point for both.
    var snapped: Rect {
        let (left, top) = (minX.rounded(), minY.rounded())
        return Rect(x: left, y: top, width: max(maxX.rounded() - left, 0), height: max(maxY.rounded() - top, 0))
    }
}

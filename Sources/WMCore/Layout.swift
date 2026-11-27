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
    guard screenRect.isUsable, let viewRoot = workspace.viewRoot, let view = workspace.root?.find(viewRoot) else { return [] }
    // Each window is inset by half the inner gap, so two neighbors are one inner gap apart. The
    // screen is inset by the rest, so a window at the edge is one outer gap from it.
    let halfInner = gaps.inner / 2
    let screen = Box(screenRect)
    var frames: [WindowFrame] = []
    place(view, in: screen.inset(by: gaps.outer - halfInner), halfInner: halfInner, limit: screen, into: &frames)
    return frames
}

/// `limit` is the screen, and no frame leaves it. An inner gap larger than twice the outer gap makes
/// the first box larger than the screen, and a part smaller than the gap closes at its middle,
/// which can then lie outside the screen. Such a window gets an empty frame at the screen edge.
private func place(_ node: Node, in box: Box, halfInner: Double, limit: Box, into frames: inout [WindowFrame]) {
    switch node.content {
    case let .window(window):
        frames.append(WindowFrame(window: window, frame: box.inset(by: halfInner).clamped(to: limit).snapped))
    case let .split(split):
        for (child, part) in zip(split.children, box.divided(along: split.axis, weights: split.children.map(\.weight))) {
            place(child.node, in: part, halfInner: halfInner, limit: limit, into: &frames)
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

    /// The part of this box inside `limit`. Each edge moves by itself and keeps its order, so two
    /// boxes that did not overlap before do not overlap after.
    func clamped(to limit: Box) -> Box {
        var box = self
        box.minX = min(max(minX, limit.minX), limit.maxX)
        box.maxX = min(max(maxX, limit.minX), limit.maxX)
        box.minY = min(max(minY, limit.minY), limit.maxY)
        box.maxY = min(max(maxY, limit.minY), limit.maxY)
        return box
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

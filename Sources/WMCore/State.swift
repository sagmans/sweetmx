// The whole window manager state as one value. The platform layer only produces inputs and applies
// effects, so every layout rule can be checked by `wm-sim` with no real window and no permission.
//
// The types are values with no behavior of their own; `reduce` in Reducer.swift is the only code
// that moves a state forward, and `layout` in Layout.swift is the only code that makes frames.

/// A real window, named by the number the window server gives it. The model never looks inside the
/// number; it only tells windows apart.
public struct WindowID: Hashable, Comparable, Sendable {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Ordered so that every list of windows the model returns has one stable order.
    public static func < (lhs: WindowID, rhs: WindowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Names one node of a workspace tree. `viewRoot` and `focus` refer to nodes by this value, so they
/// stay valid while the tree around the node changes.
public struct NodeID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Hands out node names. It lives in the state, so the same inputs always give the same names and
/// a scenario gives the same output on every run. One source for all workspaces, because a window
/// keeps its node when it moves to another workspace.
public struct NodeIDSource: Equatable, Sendable {
    public private(set) var next: UInt64

    public init(next: UInt64 = 0) {
        self.next = next
    }

    /// Wraps instead of trapping: a model fault must never stop app search or the clipboard
    /// history, and 2^64 names cannot run out in practice.
    mutating func make() -> NodeID {
        defer { next &+= 1 }
        return NodeID(next)
    }
}

/// One side of a window, and so one way to go on the screen or across the grid.
public enum Direction: Sendable, CaseIterable {
    case left
    case right
    case up
    case down

    /// The split axis that this direction runs along.
    var axis: Axis {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// +1 toward the later child of a split and the larger grid coordinate, -1 the other way.
    var step: Int {
        switch self {
        case .right, .down: 1
        case .left, .up: -1
        }
    }
}

/// How a split lines up its children: `horizontal` puts them side by side from left to right,
/// `vertical` stacks them from top to bottom.
public enum Axis: Sendable, CaseIterable {
    case horizontal
    case vertical

    /// The other axis. A split made inside another one uses it, so nested splits keep dividing
    /// the screen both ways instead of making thinner and thinner strips.
    var crossed: Axis {
        switch self {
        case .horizontal: .vertical
        case .vertical: .horizontal
        }
    }
}

/// A cell of the workspace grid. The grid is a sparse map, so it has no edge.
public struct Coord: Hashable, Sendable {
    public let x: Int
    public let y: Int

    public static let origin = Coord(x: 0, y: 0)

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// The next cell in a direction; `y` grows downward, as screen coordinates do. Nil at the end
    /// of `Int`, so a grid move there changes nothing instead of trapping.
    func neighbor(_ direction: Direction) -> Coord? {
        let (value, overflow) = switch direction.axis {
        case .horizontal: x.addingReportingOverflow(direction.step)
        case .vertical: y.addingReportingOverflow(direction.step)
        }
        guard !overflow else { return nil }
        return switch direction.axis {
        case .horizontal: Coord(x: value, y: y)
        case .vertical: Coord(x: x, y: value)
        }
    }
}

/// A rectangle in screen points with the origin at the top left and `y` growing downward, as the
/// Accessibility API reports window frames. Its own type so `WMCore` needs no graphics framework.
public struct Rect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double {
        x + width
    }

    public var maxY: Double {
        y + height
    }

    public var area: Double {
        width * height
    }

    /// A display rectangle comes from outside the model, so it is checked before use: every number
    /// finite and a real area. Anything else would turn into frames that no window can take.
    public var isUsable: Bool {
        [x, y, width, height, maxX, maxY].allSatisfy(\.isFinite) && width > 0 && height > 0
    }

    /// True when the two rectangles share an area. Touching edges do not count, and neither does a
    /// rectangle with no area, so tiled frames never overlap.
    public func overlaps(_ other: Rect) -> Bool {
        min(maxX, other.maxX) - max(x, other.x) > 0 && min(maxY, other.maxY) - max(y, other.y) > 0
    }
}

/// Space left free around and between tiled windows, in points.
public struct Gaps: Equatable, Sendable {
    /// Between two windows that share an edge.
    public let inner: Double
    /// Between a window and the edge of the screen.
    public let outer: Double

    public static let none = Gaps(inner: 0, outer: 0)

    /// Gaps will come from the config file, which is untrusted input. A value that is negative or
    /// not finite becomes no gap, so a bad number can never push a window off the screen.
    public init(inner: Double, outer: Double) {
        self.inner = Gaps.usable(inner)
        self.outer = Gaps.usable(outer)
    }

    private static func usable(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}

/// A container that divides its rectangle among its children along one axis.
public struct Split: Equatable, Sendable {
    /// The weight of a child in a fresh split. Only the ratio between weights matters.
    static let unitWeight = 1.0
    /// The smallest part of two neighbors' shared size that a resize leaves to either of them, so
    /// no resize can make a window vanish.
    static let minimumPairShare = 0.1

    public internal(set) var axis: Axis
    public internal(set) var children: [Node]
    /// One weight per child: the child's part of the split is its weight over the sum.
    public internal(set) var weights: [Double]

    public init(axis: Axis, children: [Node], weights: [Double]) {
        self.axis = axis
        self.children = children
        self.weights = weights
    }
}

/// One node of a workspace tree: a window, or a split that holds more nodes.
public struct Node: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case window(WindowID)
        case split(Split)
    }

    public let id: NodeID
    public internal(set) var content: Content

    public init(id: NodeID, content: Content) {
        self.id = id
        self.content = content
    }
}

/// One cell of the grid: a tree of splits and windows, and where the user is in it.
public struct Workspace: Equatable, Sendable {
    /// Nil while the workspace holds no window.
    public internal(set) var root: Node?
    /// The node that fills the screen. Zoom is this one field: it equals the root when the user has
    /// not zoomed in, and nodes outside it are hidden.
    public internal(set) var viewRoot: NodeID?
    /// The window node that has the focus. It is always inside `viewRoot`, so the focus is never
    /// on a hidden window.
    public internal(set) var focus: NodeID?

    public init(root: Node? = nil, viewRoot: NodeID? = nil, focus: NodeID? = nil) {
        self.root = root
        self.viewRoot = viewRoot
        self.focus = focus
    }
}

/// The workspaces on an endless 2D grid. A workspace exists only while it holds a window or is the
/// current cell, so walking across empty cells leaves nothing behind.
public struct Grid: Equatable, Sendable {
    public internal(set) var cells: [Coord: Workspace]
    public internal(set) var current: Coord

    public init(cells: [Coord: Workspace] = [.origin: Workspace()], current: Coord = .origin) {
        self.cells = cells
        self.current = current
    }

    /// The workspace on the screen. An empty one stands in if the map lost the current cell, so a
    /// reader never has to handle a missing workspace.
    public var currentWorkspace: Workspace {
        cells[current] ?? Workspace()
    }
}

/// Everything the window manager knows. `reduce` is the only way to get a next one.
public struct WMState: Equatable, Sendable {
    public internal(set) var grid: Grid
    /// The part of the display that windows may cover.
    public internal(set) var screen: Rect
    public internal(set) var gaps: Gaps
    public internal(set) var nodeIDs: NodeIDSource

    public init(grid: Grid = Grid(), screen: Rect, gaps: Gaps = .none, nodeIDs: NodeIDSource = NodeIDSource()) {
        self.grid = grid
        self.screen = screen
        self.gaps = gaps
        self.nodeIDs = nodeIDs
    }
}

/// What the user asks for with a key or a gesture.
///
/// `toggleFloat` and `reloadConfig` are not here yet on purpose: a floating window and a config
/// have no meaning in the model until real windows and the config loader exist, and a command that
/// does nothing would let a scenario pass without proving anything.
public enum Command: Equatable, Sendable {
    /// Give the focus to the nearest window in a direction, inside the zoomed view.
    case focus(Direction)
    /// Move the focused window one step in a direction through the tree.
    case move(Direction)
    /// Put the focused window in its own split, so the next window opens beside it on that axis.
    case split(Axis)
    /// Grow the focused window toward a direction by a part of its split (negative shrinks it).
    case resize(Direction, amount: Double)
    case zoomIn
    case zoomOut
    case gridMove(Direction)
    case gotoWorkspace(Coord)
    case sendToWorkspace(Coord)
}

/// What the platform layer saw happen to real windows and displays.
public enum WindowEvent: Equatable, Sendable {
    case created(WindowID)
    case destroyed(WindowID)
    /// The system gave the focus to a window without being asked, for example after a click.
    case focused(WindowID)
    case displayChanged(Rect)
}

public enum Input: Equatable, Sendable {
    case command(Command)
    case event(WindowEvent)
}

/// One thing the platform layer must do to a real window to match the new state.
public enum Effect: Equatable, Sendable {
    case setFrame(WindowID, Rect)
    case hide(WindowID)
    case raiseAndFocus(WindowID)
}

// The one function that moves the window manager forward. It is pure: no clock, no window, no
// global. The same state and input always give the same result, which is what lets scenario files
// and the property run in `wm-sim` stand as proof for the real window manager.

/// Returns the state after `input` and what the platform layer must do to real windows to match
/// it. An input that makes no sense for the state (an unknown window, a move at the edge, a zoom
/// out at the root) returns the same state and no effect; inputs come from outside the model, so
/// none of them may trap.
public func reduce(_ state: WMState, _ input: Input) -> (state: WMState, effects: [Effect]) {
    var next = state
    var reportedFocus: WindowID?
    switch input {
    case let .command(command):
        next.apply(command)
    case let .event(event):
        next.apply(event)
        if case let .focused(window) = event {
            reportedFocus = window
        }
    }
    // The same state shows the same screen, so there is nothing to compare, and "nothing changes"
    // always means "no effect".
    guard next != state else { return (state, []) }
    return (next, Presentation(of: state).effects(to: Presentation(of: next), reportedFocus: reportedFocus))
}

extension WMState {
    fileprivate mutating func apply(_ command: Command) {
        switch command {
        case let .focus(direction): editCurrent { workspace, _ in workspace.focusNeighbor(direction) }
        case let .move(direction): editCurrent { workspace, ids in workspace.moveFocused(direction, ids: &ids) }
        case let .split(axis): editCurrent { workspace, ids in workspace.splitFocused(axis, ids: &ids) }
        case let .resize(direction, amount): editCurrent { workspace, _ in workspace.resizeFocused(direction, by: amount) }
        case .zoomIn: editCurrent { workspace, _ in workspace.zoomIn() }
        case .zoomOut: editCurrent { workspace, _ in workspace.zoomOut() }
        case let .gridMove(direction): grid.current.neighbor(direction).map { show($0) }
        case let .gotoWorkspace(coord): show(coord)
        case let .sendToWorkspace(coord): sendFocused(to: coord)
        }
    }

    fileprivate mutating func apply(_ event: WindowEvent) {
        switch event {
        case let .created(window):
            // A window the model already holds is reported twice by a fault of the platform
            // layer; a second node for it would break every rule after.
            guard coord(of: window) == nil else { return }
            let leaf = Node.window(window, id: nodeIDs.make())
            editCurrent { workspace, ids in workspace.insert(leaf, ids: &ids) }
        case let .destroyed(window):
            guard let coord = coord(of: window) else { return }
            edit(coord) { workspace, _ in _ = workspace.remove(window) }
        case let .focused(window):
            // The view follows the focus: a window that an app brings forward must be on screen.
            guard let coord = coord(of: window) else { return }
            show(coord)
            edit(coord) { workspace, _ in workspace.followFocus(to: window) }
        case let .displayChanged(rect):
            guard rect.isUsable else { return }
            screen = rect
        }
    }

    private func coord(of window: WindowID) -> Coord? {
        grid.cells.first { $0.value.root?.path(toWindow: window) != nil }?.key
    }

    private mutating func editCurrent(_ body: (inout Workspace, inout NodeIDSource) -> Void) {
        edit(grid.current, body)
    }

    /// Every change to a workspace goes through here, so one place keeps the grid rule: a
    /// workspace exists only while it holds a window or is the current cell.
    private mutating func edit(_ coord: Coord, _ body: (inout Workspace, inout NodeIDSource) -> Void) {
        var workspace = grid.cells[coord] ?? Workspace()
        body(&workspace, &nodeIDs)
        grid.cells[coord] = workspace.root == nil && coord != grid.current ? nil : workspace
    }

    /// Makes `coord` the current cell. An empty cell becomes an empty workspace on arrival, and an
    /// empty workspace is dropped when the user leaves it, so the map never grows from walking.
    private mutating func show(_ coord: Coord) {
        let left = grid.current
        guard coord != left else { return }
        grid.current = coord
        if grid.cells[coord] == nil {
            grid.cells[coord] = Workspace()
        }
        if grid.cells[left]?.root == nil {
            grid.cells[left] = nil
        }
    }

    /// The focused window goes to another workspace and the user stays here. The window keeps its
    /// node, takes the focus there, and is hidden until the user goes to that workspace.
    private mutating func sendFocused(to coord: Coord) {
        guard coord != grid.current, let window = grid.currentWorkspace.focusedWindow else { return }
        var sent: Node?
        editCurrent { workspace, _ in sent = workspace.remove(window) }
        guard let sent else { return }
        edit(coord) { workspace, ids in workspace.insert(sent, ids: &ids) }
    }
}

// What a state looks like on the screen, and the effects that take the screen from one state to
// the next. The reducer changes the state only; effects are always the difference between two
// presentations, so no rule can forget to move, hide or focus a window.

/// What the screen must show for one state: a frame for each visible window, the windows that are
/// hidden, and the window with the focus.
public struct Presentation: Equatable, Sendable {
    /// Windows inside the current workspace's view, in tree order.
    public let frames: [WindowFrame]
    /// Every other window the model knows, in ascending order: windows outside the zoomed view and
    /// windows on other workspaces.
    public let hidden: [WindowID]
    public let focus: WindowID?

    public init(of state: WMState) {
        let current = state.grid.currentWorkspace
        frames = layout(current, screenRect: state.screen, gaps: state.gaps)
        let visible = Set(frames.map(\.window))
        hidden = state.grid.cells.values.flatMap(\.windows).filter { !visible.contains($0) }.sorted()
        focus = current.focusedWindow
    }

    /// The effects that turn `self` on the screen into `newer`: hides first, so a window never
    /// shows over the ones about to move, then frames, then the focus.
    ///
    /// `reportedFocus` is a window that the system itself just focused. Raising it again would
    /// only send the same event back, so it gets no focus effect.
    public func effects(to newer: Presentation, reportedFocus: WindowID? = nil) -> [Effect] {
        let wasHidden = Set(hidden)
        let oldFrames = Dictionary(frames.map { ($0.window, $0.frame) }) { first, _ in first }
        var effects: [Effect] = newer.hidden.filter { !wasHidden.contains($0) }.map(Effect.hide)
        effects += newer.frames.filter { oldFrames[$0.window] != $0.frame }.map { .setFrame($0.window, $0.frame) }
        if let focus = newer.focus, focus != self.focus, focus != reportedFocus {
            effects.append(.raiseAndFocus(focus))
        }
        return effects
    }
}

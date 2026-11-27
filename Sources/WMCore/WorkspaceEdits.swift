// The rules of one workspace: where a new window goes, what a removal leaves behind, and what
// focus, move, resize and zoom mean in a tree. Each edit keeps the three promises that the
// reducer and the layout rely on: every window is in the tree once, `viewRoot` and `focus` name
// real nodes, and the focus is inside the view.

extension Workspace {
    /// The paths that most edits start from. Nil when the workspace is empty or, by a fault, its
    /// two names do not resolve; an edit then changes nothing.
    private var anchors: (tree: Node, focus: NodePath, view: NodePath)? {
        guard let root, let focus, let viewRoot,
              let focusPath = root.path(to: focus), let viewPath = root.path(to: viewRoot)
        else { return nil }
        return (root, focusPath, viewPath)
    }

    /// Adds a window node next to the focused window and gives it the focus.
    ///
    /// When the focused window fills the view by itself (a zoomed window, or the only window), it
    /// becomes a split that holds both, and the view follows that split. This is what lets the
    /// user zoom in on one window and keep opening windows inside its slot.
    mutating func insert(_ leaf: Node, ids: inout NodeIDSource) {
        guard root != nil else {
            root = leaf
            viewRoot = leaf.id
            focus = leaf.id
            return
        }
        guard var (tree, focusPath, _) = anchors else {
            assertionFailure("WMCore: a workspace with windows has no focus")
            return
        }
        if focus == viewRoot {
            let parentAxis = tree.node(at: focusPath.dropLast())?.split?.axis
            let axis = focusPath.isEmpty ? Axis.horizontal : parentAxis?.crossed ?? .horizontal
            wrap(&tree, at: focusPath, axis: axis, ids: &ids) { [$0, leaf] }
        } else if let index = focusPath.popLast() {
            tree.updateSplit(at: focusPath) { $0.insert(leaf, at: index + 1) }
        }
        root = tree
        focus = leaf.id
    }

    /// Puts the node at `path` in a new split, with the nodes that `arrange` gives for it. This is
    /// the one place where the tree gains a level, so it holds the zoom rule for all of them: when
    /// the wrapped node was the view, the view is the new split, which shows that node and what
    /// came to stand beside it.
    private mutating func wrap(_ tree: inout Node, at path: NodePath, axis: Axis, ids: inout NodeIDSource, _ arrange: (Node) -> [Node]) {
        let wrapper = ids.make()
        var wrapped: NodeID?
        tree.update(at: path) { node in
            wrapped = node.id
            node = Node(id: wrapper, content: .split(Split(axis: axis, nodes: arrange(node))))
        }
        if wrapped == viewRoot {
            viewRoot = wrapper
        }
    }

    /// Takes a window out of the tree and returns its node, so it can go to another workspace
    /// with its name. The focus moves to the window beside the hole.
    mutating func remove(_ window: WindowID) -> Node? {
        guard let tree = root, let path = tree.path(toWindow: window), let leaf = tree.node(at: path) else { return nil }
        switch detach(at: path) {
        case .faulted:
            // Nothing left the tree, so there is no node to hand on: a caller that put it in
            // another workspace would hold the window twice.
            return nil
        case .emptied:
            break
        case let .detached(detachment):
            if focus == leaf.id {
                focus = self.leaf(beside: detachment)
            }
        }
        return leaf
    }

    /// Follows a focus change that the system made. A window outside the zoomed view cannot have
    /// the focus while hidden, so the view widens to the nearest node that holds both.
    mutating func followFocus(to window: WindowID) {
        guard let (tree, _, viewPath) = anchors, let leafPath = tree.path(toWindow: window), let leaf = tree.node(at: leafPath) else { return }
        focus = leaf.id
        let shared = zip(viewPath, leafPath).prefix { $0 == $1 }.count
        if shared < viewPath.count, let common = tree.node(at: viewPath.prefix(shared)) {
            viewRoot = common.id
        }
    }

    /// The nearest split above the focus, inside the view, that lies along `direction` and has a
    /// child on that side of the branch that holds the focus.
    private func splitWithNeighbor(_ direction: Direction) -> (path: NodePath, branch: Int, neighbor: Int)? {
        guard let (tree, focusPath, viewPath) = anchors else { return nil }
        var path = focusPath
        while path.count > viewPath.count, let branch = path.popLast() {
            let neighbor = branch + direction.step
            if let split = tree.node(at: path)?.split, split.axis == direction.axis, split.children.indices.contains(neighbor) {
                return (path, branch, neighbor)
            }
        }
        return nil
    }

    /// The focus stops at the edge of the view; it does not wrap and does not leave the workspace,
    /// so a key held down cannot throw the user to another place.
    mutating func focusNeighbor(_ direction: Direction) {
        guard let root, let found = splitWithNeighbor(direction),
              let target = root.node(at: found.path + [found.neighbor])
        else { return }
        focus = target.leafEntered(from: direction).id
    }

    mutating func resizeFocused(_ direction: Direction, by amount: Double) {
        // The amount will come from the config file; a value that is not a number changes nothing.
        guard amount.isFinite, var tree = root, let found = splitWithNeighbor(direction) else { return }
        tree.updateSplit(at: found.path) { $0.grow(found.branch, by: amount, takingFrom: found.neighbor) }
        root = tree
    }

    /// Puts the focused window in a split of its own, so the next window opens beside it on
    /// `axis`. A window that is already alone in its split only changes that split's axis, so
    /// repeated use cannot build a chain of empty levels.
    ///
    /// For a zoomed window that split is outside the view, and the next window opens inside the
    /// view. The view moves out to the split, which shows the same one window, so the axis the
    /// user chose is the one used.
    mutating func splitFocused(_ axis: Axis, ids: inout NodeIDSource) {
        guard let (root, focusPath, _) = anchors else { return }
        var tree = root
        let parentPath = focusPath.dropLast()
        if let parent = tree.node(at: parentPath), parent.split?.children.count == 1 {
            tree.updateSplit(at: parentPath) { $0.axis = axis }
            if viewRoot == focus {
                viewRoot = parent.id
            }
        } else {
            // A zoomed window stays zoomed: the view follows the new split that holds only it.
            wrap(&tree, at: focusPath, axis: axis, ids: &ids) { [$0] }
        }
        self.root = tree
    }

    mutating func zoomIn() {
        guard let (tree, focusPath, viewPath) = anchors, focusPath.count > viewPath.count,
              let child = tree.node(at: focusPath.prefix(viewPath.count + 1))
        else { return }
        viewRoot = child.id
    }

    mutating func zoomOut() {
        guard let (tree, _, viewPath) = anchors, !viewPath.isEmpty, let parent = tree.node(at: viewPath.dropLast()) else { return }
        viewRoot = parent.id
    }

    /// Moves the focused window one step. It swaps with a window beside it, enters a split beside
    /// it, or leaves its own split to stand beside it. It never leaves the zoomed view, because a
    /// window outside the view is hidden and the user would lose it. In a swap each window keeps
    /// its size: a window the user made larger stays larger at its new place.
    mutating func moveFocused(_ direction: Direction, ids: inout NodeIDSource) {
        guard let (root, focusPath, viewPath) = anchors, focusPath.count > viewPath.count,
              let leaf = root.node(at: focusPath), let index = focusPath.last,
              let parent = root.node(at: focusPath.dropLast())?.split
        else { return }
        let before = self
        var tree = root
        let parentPath = Array(focusPath.dropLast())
        let neighbor = index + direction.step
        let move = Move(leaf: leaf, from: focusPath, view: viewPath, direction: direction)

        // Every kind of move but the swap puts the window at its new place first and takes the
        // old node out after, so `detach` repairs the tree around the hole in one way for all.
        // Each returns where the old node is once the new one is in.
        let stalePath: NodePath
        if parent.axis == direction.axis, parent.children.indices.contains(neighbor) {
            guard parent.children[neighbor].node.split != nil else {
                tree.updateSplit(at: parentPath) { $0.children.swapAt(index, neighbor) }
                self.root = tree
                return
            }
            tree.updateSplit(at: parentPath + [neighbor]) { $0.adopt(leaf, movingIn: direction) }
            stalePath = focusPath
        } else if let level = Workspace.splitToLeaveInto(tree, focusPath: focusPath, viewDepth: viewPath.count, direction) {
            stalePath = move.leave(&tree, intoSplitAt: level)
        } else if parentPath == viewPath, parent.axis == direction.axis {
            // Already at the edge of the view, along its axis: there is nowhere further to go.
            return
        } else {
            wrap(&tree, at: viewPath, axis: direction.axis, ids: &ids) { move.towardEnd ? [$0, leaf] : [leaf, $0] }
            stalePath = move.pathAfterWrappingView
        }
        self.root = tree
        // The tree holds the window twice until the old node is out. A move leaves at least that
        // window, so anything but a detachment is a fault, and the whole move is undone.
        guard case .detached = detach(at: stalePath) else {
            self = before
            return
        }
    }

    /// The depth of the nearest split above the focused window's parent, inside the view, that
    /// lies along `direction`. The window leaves its own split to stand in that one.
    private static func splitToLeaveInto(_ tree: Node, focusPath: NodePath, viewDepth: Int, _ direction: Direction) -> Int? {
        let parentDepth = focusPath.count - 1
        guard viewDepth < parentDepth else { return nil }
        return (viewDepth ..< parentDepth).reversed().first { depth in
            tree.node(at: focusPath.prefix(depth))?.split?.axis == direction.axis
        }
    }
}

/// One move of a window that leaves its place: what moves, from where, and which way. It holds the
/// path arithmetic of a move, so `moveFocused` reads as the choice between the kinds of move.
private struct Move {
    let leaf: Node
    let from: NodePath
    let view: NodePath
    let direction: Direction

    var towardEnd: Bool {
        direction.step > 0
    }

    /// The window leaves its own split and stands in the split at depth `level`, on the side of
    /// the branch it came from that the move points to. Returns where the old node is after:
    /// one place later in that split when the new node went in before it.
    func leave(_ tree: inout Node, intoSplitAt level: Int) -> NodePath {
        tree.updateSplit(at: from.prefix(level)) { $0.insert(leaf, at: from[level] + (towardEnd ? 1 : 0)) }
        var stale = from
        stale[level] += towardEnd ? 0 : 1
        return stale
    }

    /// Where the old node is after the view was wrapped in a split with the window beside it: one
    /// level deeper, under the old view's place in the new split.
    var pathAfterWrappingView: NodePath {
        var stale = from
        stale.insert(towardEnd ? 0 : 1, at: view.count)
        return stale
    }
}

private extension Split {
    /// Takes a window that moves into this split from a sibling place. It enters at the near edge
    /// when the split lies along the move, and at the end when it does not.
    mutating func adopt(_ leaf: Node, movingIn direction: Direction) {
        let atNearEdge = axis == direction.axis && direction.step > 0
        insert(leaf, at: atNearEdge ? 0 : children.count)
    }
}

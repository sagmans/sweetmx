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
            let wrapper = ids.make()
            tree.update(at: focusPath) { node in
                node = Node(id: wrapper, content: .split(Split(axis: axis, children: [node, leaf], weights: [Split.unitWeight, Split.unitWeight])))
            }
            viewRoot = wrapper
        } else if let index = focusPath.popLast() {
            tree.update(at: focusPath) { parent in
                guard var split = parent.split else { return }
                split.insert(leaf, at: index + 1)
                parent.content = .split(split)
            }
        }
        root = tree
        focus = leaf.id
    }

    /// Takes a window out of the tree and returns its node, so it can go to another workspace
    /// with its name. The focus moves to the window beside the hole.
    mutating func remove(_ window: WindowID) -> Node? {
        guard let tree = root, let path = tree.path(toWindow: window), let leaf = tree.node(at: path) else { return nil }
        let detachment = detach(at: path)
        settleView(after: detachment)
        if focus == leaf.id, let detachment {
            focus = self.leaf(beside: detachment)
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
        tree.update(at: found.path) { node in
            guard var split = node.split else { return }
            split.grow(found.branch, by: amount, takingFrom: found.neighbor)
            node.content = .split(split)
        }
        root = tree
    }

    /// Puts the focused window in a split of its own, so the next window opens beside it on
    /// `axis`. A window that is already alone in its split only changes that split's axis, so
    /// repeated use cannot build a chain of empty levels.
    mutating func splitFocused(_ axis: Axis, ids: inout NodeIDSource) {
        guard let (root, focusPath, _) = anchors else { return }
        var tree = root
        let parentPath = focusPath.dropLast()
        if !focusPath.isEmpty, let parent = tree.node(at: parentPath)?.split, parent.children.count == 1 {
            tree.update(at: parentPath) { node in
                node.content = .split(Split(axis: axis, children: parent.children, weights: parent.weights))
            }
        } else {
            let wrapper = ids.make()
            tree.update(at: focusPath) { node in
                node = Node(id: wrapper, content: .split(Split(axis: axis, children: [node], weights: [Split.unitWeight])))
            }
            // A zoomed window stays zoomed: the view follows the new split that holds only it.
            if viewRoot == focus {
                viewRoot = wrapper
            }
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
    /// window outside the view is hidden and the user would lose it.
    mutating func moveFocused(_ direction: Direction, ids: inout NodeIDSource) {
        guard let (root, focusPath, viewPath) = anchors, focusPath.count > viewPath.count,
              let leaf = root.node(at: focusPath), let index = focusPath.last
        else { return }
        var tree = root
        let parentPath = Array(focusPath.dropLast())
        guard let parent = tree.node(at: parentPath)?.split else { return }
        let neighbor = index + direction.step
        let besideNeighbor = parent.axis == direction.axis && parent.children.indices.contains(neighbor)

        if besideNeighbor, parent.children[neighbor].split == nil {
            tree.update(at: parentPath) { node in
                guard var split = node.split else { return }
                split.children.swapAt(index, neighbor)
                node.content = .split(split)
            }
            self.root = tree
            return
        }
        // The window goes to its new place first and the old node is removed after, so `detach`
        // repairs the tree around the hole in one way for every kind of move.
        var stalePath = focusPath
        if besideNeighbor {
            tree.update(at: parentPath + [neighbor]) { $0.adopt(leaf, movingIn: direction) }
        } else if let level = Workspace.splitToLeaveInto(tree, focusPath: focusPath, viewDepth: viewPath.count, direction) {
            let towardEnd = direction.step > 0
            tree.update(at: focusPath.prefix(level)) { node in
                guard var split = node.split else { return }
                split.insert(leaf, at: focusPath[level] + (towardEnd ? 1 : 0))
                node.content = .split(split)
            }
            stalePath[level] += towardEnd ? 0 : 1
        } else if parentPath == viewPath, parent.axis == direction.axis {
            // Already at the edge of the view, along its axis: there is nowhere further to go.
            return
        } else {
            let towardEnd = direction.step > 0
            let wrapper = ids.make()
            tree.update(at: viewPath) { node in
                let children = towardEnd ? [node, leaf] : [leaf, node]
                node = Node(id: wrapper, content: .split(Split(axis: direction.axis, children: children, weights: [Split.unitWeight, Split.unitWeight])))
            }
            viewRoot = wrapper
            stalePath.insert(towardEnd ? 0 : 1, at: viewPath.count)
        }
        self.root = tree
        settleView(after: detach(at: stalePath))
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

private extension Node {
    /// Takes a window that moves into this split from a sibling place. It enters at the near edge
    /// when the split lies along the move, and at the end when it does not.
    mutating func adopt(_ leaf: Node, movingIn direction: Direction) {
        guard var split else { return }
        let atNearEdge = split.axis == direction.axis && direction.step > 0
        split.insert(leaf, at: atNearEdge ? 0 : split.children.count)
        content = .split(split)
    }
}

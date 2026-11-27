// Reading and editing one workspace tree. Kept apart from the reducer so the reducer reads as the
// rules of the window manager, and this file as the tree surgery those rules need.

/// The child indexes that lead from a tree's root to one node. Paths are made and used inside one
/// edit, because any change to the tree can make an older path point somewhere else.
typealias NodePath = [Int]

extension Split {
    /// A new child takes the mean weight, so it gets the same share as an average sibling whatever
    /// the earlier resizes were.
    mutating func insert(_ child: Node, at index: Int) {
        let share = children.isEmpty ? Split.unitWeight : totalWeight / Double(children.count)
        children.insert(Child(node: child, weight: share), at: index)
    }

    var totalWeight: Double {
        children.reduce(0) { $0 + $1.weight }
    }

    /// Moves the border between two children. Their combined weight stays the same, so no other
    /// child moves, and each keeps at least `minimumPairShare` of it.
    mutating func grow(_ index: Int, by amount: Double, takingFrom neighbor: Int) {
        let pair = children[index].weight + children[neighbor].weight
        let floor = pair * Split.minimumPairShare
        let wanted = children[index].weight + amount * totalWeight
        let grown = min(max(wanted, floor), pair - floor)
        children[index].weight = grown
        children[neighbor].weight = pair - grown
    }
}

extension Node {
    static func window(_ window: WindowID, id: NodeID) -> Node {
        Node(id: id, content: .window(window))
    }

    var split: Split? {
        if case let .split(split) = content {
            split
        } else {
            nil
        }
    }

    var window: WindowID? {
        if case let .window(window) = content {
            window
        } else {
            nil
        }
    }

    /// Every window below this node, in the order the layout places them.
    var windows: [WindowID] {
        var found: [WindowID] = []
        collectWindows(into: &found)
        return found
    }

    private func collectWindows(into found: inout [WindowID]) {
        switch content {
        case let .window(window): found.append(window)
        case let .split(split): split.children.forEach { $0.node.collectWindows(into: &found) }
        }
    }

    func path(to id: NodeID) -> NodePath? {
        path { $0.id == id }
    }

    func path(toWindow window: WindowID) -> NodePath? {
        path { $0.window == window }
    }

    private func path(where matches: (Node) -> Bool) -> NodePath? {
        var path: NodePath = []
        return search(matches, path: &path) ? path : nil
    }

    private func search(_ matches: (Node) -> Bool, path: inout NodePath) -> Bool {
        if matches(self) {
            return true
        }
        guard let split else { return false }
        for (index, child) in split.children.enumerated() {
            path.append(index)
            if child.node.search(matches, path: &path) {
                return true
            }
            path.removeLast()
        }
        return false
    }

    /// The node at a path, or nil when the path leaves the tree.
    func node(at path: some Collection<Int>) -> Node? {
        var node = self
        for index in path {
            guard let split = node.split, split.children.indices.contains(index) else { return nil }
            node = split.children[index].node
        }
        return node
    }

    /// Edits the node at a path in place. A path that leaves the tree is a fault in this module,
    /// not bad input: it stops a debug build (so `wm-sim --fuzz` finds it) and changes nothing in
    /// a release build, because a model fault must never crash the app.
    mutating func update(at path: some Collection<Int>, _ body: (inout Node) -> Void) {
        guard let index = path.first else {
            body(&self)
            return
        }
        guard case var .split(split) = content, split.children.indices.contains(index) else {
            assertionFailure("WMCore: path leaves the tree")
            return
        }
        split.children[index].node.update(at: path.dropFirst(), body)
        content = .split(split)
    }

    /// Edits the split at a path in place. Every edit of a split goes through here, so a path that
    /// names a window by a fault is reported once, in the same way as a path that leaves the tree.
    mutating func updateSplit(at path: some Collection<Int>, _ body: (inout Split) -> Void) {
        update(at: path) { node in
            guard var split = node.split else {
                assertionFailure("WMCore: the path names a window where an edit needs a split")
                return
            }
            body(&split)
            node.content = .split(split)
        }
    }

    /// Follows one child at each split until a window is reached.
    func descend(_ choose: (Split) -> Node?) -> Node {
        var node = self
        while let split = node.split, let next = choose(split) {
            node = next
        }
        return node
    }

    /// The window node that a move in `direction` reaches first when it enters this subtree: the
    /// near edge of splits that lie along the move, the first child of the others.
    func leafEntered(from direction: Direction) -> Node {
        descend { split in
            (split.axis == direction.axis && direction.step < 0 ? split.children.last : split.children.first)?.node
        }
    }
}

/// Where a tree changed after a window node left it.
struct Detachment {
    /// The node that now stands where the removed node's parent stood.
    let heirPath: NodePath
    /// The index the removed node had under that parent.
    let gap: Int
    /// True when the parent kept one child only and that child took the parent's place.
    let hoisted: Bool
}

extension Workspace {
    var focusedWindow: WindowID? {
        guard let root, let focus else { return nil }
        return root.path(to: focus).flatMap { root.node(at: $0) }?.window
    }

    var windows: [WindowID] {
        root?.windows ?? []
    }

    /// How many times the user has zoomed in: the number of levels between the root and the view.
    public var zoomDepth: Int {
        guard let root, let viewRoot else { return 0 }
        return root.path(to: viewRoot)?.count ?? 0
    }

    /// Takes the node at `path` out of the tree and repairs the tree around the hole: a split left
    /// with no child goes too, and a split left with one child gives its place to that child, so
    /// a removal never leaves an empty box on the screen. Returns nil when the tree is now empty.
    ///
    /// It works by path, not by name, because a move puts a copy of the window node at its new
    /// place first and then removes the old one, and both carry the same name for that moment.
    mutating func detach(at nodePath: NodePath) -> Detachment? {
        guard var tree = root else { return nil }
        var path = nodePath
        while let index = path.popLast() {
            var remaining = 0
            tree.update(at: path) { parent in
                guard var split = parent.split else { return }
                split.children.remove(at: index)
                remaining = split.children.count
                parent = remaining == 1 ? split.children[0].node : Node(id: parent.id, content: .split(split))
            }
            if remaining > 0 {
                root = tree
                return Detachment(heirPath: path, gap: index, hoisted: remaining == 1)
            }
        }
        root = nil
        return nil
    }

    /// Keeps `viewRoot` on a real node after a removal. When the zoomed node itself is gone, the
    /// view moves to the node that took its parent's place: one level out, never to a hidden node.
    mutating func settleView(after detachment: Detachment?) {
        guard let root, let detachment, let heir = root.node(at: detachment.heirPath) else {
            if root == nil {
                viewRoot = nil
                focus = nil
            }
            return
        }
        if let viewRoot, root.path(to: viewRoot) == nil {
            self.viewRoot = heir.id
        }
    }

    /// The window node next to a hole: the sibling before it, or the one after it when the hole
    /// was first, so the focus stays where the user was looking.
    func leaf(beside detachment: Detachment) -> NodeID? {
        guard let heir = root?.node(at: detachment.heirPath) else { return nil }
        let before = detachment.gap > 0
        var neighbor = heir
        if !detachment.hoisted, let split = heir.split {
            neighbor = split.children[before ? detachment.gap - 1 : 0].node
        }
        return neighbor.descend { (before ? $0.children.last : $0.children.first)?.node }.id
    }
}

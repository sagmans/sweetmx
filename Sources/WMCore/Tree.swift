// Reading and editing one workspace tree. Kept apart from the reducer so the reducer reads as the
// rules of the window manager, and this file as the tree surgery those rules need.

/// The child indexes that lead from a tree's root to one node. Paths are made and used inside one
/// edit, because any change to the tree can make an older path point somewhere else.
typealias NodePath = [Int]

extension Split {
    /// A new child takes the mean weight, which is always one, so it gets the same share as an
    /// average sibling whatever the earlier resizes were.
    mutating func insert(_ child: Node, at index: Int) {
        children.insert(Child(node: child, weight: Split.unitWeight), at: index)
        settleWeights()
    }

    mutating func remove(at index: Int) {
        children.remove(at: index)
        settleWeights()
    }

    var totalWeight: Double {
        children.reduce(0) { $0 + $1.weight }
    }

    /// Brings the weights back to one scale: a mean of one, and none below `minimumShare`.
    ///
    /// Only the ratios matter to the layout, but the numbers must not drift. Without this, each
    /// large child that leaves makes the sum smaller, each new child joins at the smaller scale,
    /// and after some hundred windows every weight is zero and the windows have no area.
    ///
    /// A child below the smallest share is set to it and stays there; the others share what is
    /// left. That can push one more child below, so it repeats, at most once for each child.
    mutating func settleWeights() {
        var pinned = Array(repeating: false, count: children.count)
        while true {
            let free = children.indices.filter { !pinned[$0] }
            let freeTotal = free.reduce(0) { $0 + children[$1].weight }
            // Weights that are not positive numbers are a fault that the state check reports; a
            // scale made from them would spread the fault to every child.
            guard freeTotal.isFinite, freeTotal > 0 else { return }
            let share = Double(children.count) - Double(children.count - free.count) * Split.minimumShare
            for index in free {
                children[index].weight *= share / freeTotal
            }
            let low = free.filter { children[$0].weight < Split.minimumShare }
            guard !low.isEmpty else { return }
            for index in low {
                children[index].weight = Split.minimumShare
                pinned[index] = true
            }
        }
    }

    /// Moves the border between two children. Their combined weight stays the same, so no other
    /// child moves, and each keeps at least `minimumShare` (the mean weight is one). The limit only
    /// stops a border: it never moves one against the direction the user asked for, whatever
    /// rounding left in the weights.
    mutating func grow(_ index: Int, by amount: Double, takingFrom neighbor: Int) {
        let pair = children[index].weight + children[neighbor].weight
        let floor = Split.minimumShare
        let wanted = children[index].weight + amount * totalWeight
        let smallest = min(floor, children[index].weight)
        let largest = pair - min(floor, children[neighbor].weight)
        let grown = min(max(wanted, smallest), largest)
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

    /// Calls `body` for this node and every node below it, parents first, in the order the layout
    /// places them. The one walk of a whole tree; readers that need every node build on it.
    func visit(_ body: (Node) -> Void) {
        body(self)
        split?.children.forEach { $0.node.visit(body) }
    }

    /// Every window below this node, in the order the layout places them.
    var windows: [WindowID] {
        var found: [WindowID] = []
        visit { node in
            if let window = node.window {
                found.append(window)
            }
        }
        return found
    }

    /// The node with that name below this one, or nil.
    func find(_ id: NodeID) -> Node? {
        path(to: id).flatMap { node(at: $0) }
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

/// What `detach` did. Three cases with three names, so no caller has to work out from the state
/// of the tree which one it got.
enum Removal {
    /// The node is out and the tree still holds a window.
    case detached(Detachment)
    /// The node was the last window. The workspace is empty now.
    case emptied
    /// The path was wrong, by a fault in this module. Nothing changed.
    case faulted
}

extension Workspace {
    var focusedWindow: WindowID? {
        guard let root, let focus else { return nil }
        return root.find(focus)?.window
    }

    var windows: [WindowID] {
        root?.windows ?? []
    }

    /// How many times the user has zoomed in: the number of levels between the root and the view.
    public var zoomDepth: Int {
        guard let root, let viewRoot else { return 0 }
        return root.path(to: viewRoot)?.count ?? 0
    }

    /// Takes the node at `path` out of the tree and repairs the workspace around the hole. A split
    /// left with no child goes too, and a split left with one child gives its place to that
    /// child, so a removal never leaves an empty box on the screen. The view is repaired in the
    /// same step, because a caller that forgot it would leave `viewRoot` on a node that is gone.
    ///
    /// It works by path, not by name, because a move puts a copy of the window node at its new
    /// place first and then removes the old one, and both carry the same name for that moment.
    mutating func detach(at nodePath: NodePath) -> Removal {
        guard var tree = root else { return .faulted }
        var path = nodePath
        while let index = path.popLast() {
            var remaining: Int?
            // Not `updateSplit`: a split left with one child is replaced by that child.
            tree.update(at: path) { parent in
                guard var split = parent.split else {
                    assertionFailure("WMCore: the path of a removal names a window as a parent")
                    return
                }
                split.remove(at: index)
                remaining = split.children.count
                parent = remaining == 1 ? split.children[0].node : Node(id: parent.id, content: .split(split))
            }
            // One level up, the same index would remove a window that the caller did not name.
            guard let remaining else { return .faulted }
            if remaining > 0 {
                root = tree
                let detachment = Detachment(heirPath: path, gap: index, hoisted: remaining == 1)
                settleView(after: detachment)
                return .detached(detachment)
            }
        }
        // Every split above the node held nothing else, so the tree is empty now. An empty path
        // names the root itself, and that is a removal only when the root is the last window.
        guard !nodePath.isEmpty || tree.window != nil else {
            assertionFailure("WMCore: a removal names the root of a tree that holds a split")
            return .faulted
        }
        root = nil
        viewRoot = nil
        focus = nil
        return .emptied
    }

    /// Keeps `viewRoot` on a real node after a removal. When the zoomed node itself is gone, the
    /// view moves to the node that took its parent's place: one level out, never to a hidden node.
    private mutating func settleView(after detachment: Detachment) {
        guard let root, let viewRoot, root.path(to: viewRoot) == nil, let heir = root.node(at: detachment.heirPath) else { return }
        self.viewRoot = heir.id
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

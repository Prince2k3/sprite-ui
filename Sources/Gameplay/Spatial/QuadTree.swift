/// Points in a fixed region, split into quarters where they crowd together.
///
/// It's a value: copy it to snapshot it, and it's `Codable` when its elements are.
///
/// ```swift
/// var tree = QuadTree<Entity.ID>(bounds: BoundingBox(center: .zero, size: [800, 800]))
/// tree.insert(enemy.id, at: enemy.position)
/// let threats = tree.elements(within: 120, of: player.position)
/// let closest = tree.nearest(to: player.position)
/// ```
///
/// A region splits once it holds more than `nodeCapacity` elements, and merges back
/// when removals leave its quarters that sparse. Use ``SpatialHash`` instead when
/// elements can be anywhere.
public struct QuadTree<Element: Hashable>: SpatialIndex {
    /// The region elements can be stored in.
    public let bounds: BoundingBox
    /// How many elements a region holds before it splits.
    public let nodeCapacity: Int
    /// How many times a region can split; caps the work for many elements at one spot.
    public let maxDepth: Int

    struct Item {
        var element: Element
        var position: SIMD2<Float>
    }

    struct Node {
        var bounds: BoundingBox
        var depth: Int
        /// Index of the first of four consecutive children, or -1 for a leaf.
        var firstChild = -1
        /// Elements in this subtree.
        var count = 0
        /// Stored only in leaves.
        var items: [Item] = []

        var isLeaf: Bool { firstChild < 0 }
    }

    private var nodes: [Node]
    /// Blocks of four node slots freed by merges, reused by later splits.
    private var freeBlocks: [Int] = []
    private var positions: [Element: SIMD2<Float>] = [:]

    public init(bounds: BoundingBox, nodeCapacity: Int = 8, maxDepth: Int = 10) {
        precondition(bounds.size.x > 0 && bounds.size.y > 0, "A quadtree needs a non-empty region.")
        precondition(nodeCapacity > 0, "Nodes need room for at least one element.")
        self.bounds = bounds
        self.nodeCapacity = nodeCapacity
        self.maxDepth = maxDepth
        nodes = [Node(bounds: bounds, depth: 0)]
    }

    public var count: Int { positions.count }

    public func position(of element: Element) -> SIMD2<Float>? { positions[element] }

    /// Every element and where it is, in no particular order.
    public var elements: Dictionary<Element, SIMD2<Float>> { positions }

    /// The regions that hold elements directly; useful for drawing the tree.
    public var leafBounds: [BoundingBox] {
        var result: [BoundingBox] = []
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            if node.isLeaf { result.append(node.bounds) }
            else { stack.append(contentsOf: node.firstChild..<node.firstChild + 4) }
        }
        return result
    }

    // MARK: Editing

    @discardableResult
    public mutating func insert(_ element: Element, at position: SIMD2<Float>) -> Bool {
        guard bounds.contains(position) else { return false }
        if positions[element] != nil { remove(element) }
        positions[element] = position

        var index = 0
        while true {
            nodes[index].count += 1
            if nodes[index].isLeaf { break }
            index = child(of: index, containing: position)
        }
        nodes[index].items.append(Item(element: element, position: position))
        splitIfNeeded(index)
        return true
    }

    @discardableResult
    public mutating func remove(_ element: Element) -> Bool {
        guard let position = positions.removeValue(forKey: element) else { return false }
        var path: [Int] = []
        var index = 0
        while true {
            path.append(index)
            nodes[index].count -= 1
            if nodes[index].isLeaf { break }
            index = child(of: index, containing: position)
        }
        nodes[index].items.removeAll { $0.element == element }

        // Merge the highest region that's now sparse enough to be one leaf.
        if let sparse = path.dropLast().first(where: { nodes[$0].count <= nodeCapacity }) {
            merge(sparse)
        }
        return true
    }

    /// Moves `element` to `position`. Same as inserting it again.
    @discardableResult
    public mutating func move(_ element: Element, to position: SIMD2<Float>) -> Bool {
        insert(element, at: position)
    }

    public mutating func removeAll() {
        nodes = [Node(bounds: bounds, depth: 0)]
        freeBlocks = []
        positions = [:]
    }

    private func child(of index: Int, containing position: SIMD2<Float>) -> Int {
        let mid = nodes[index].bounds.center
        let quadrant = (position.x >= mid.x ? 1 : 0) + (position.y >= mid.y ? 2 : 0)
        return nodes[index].firstChild + quadrant
    }

    private mutating func splitIfNeeded(_ index: Int) {
        guard nodes[index].items.count > nodeCapacity, nodes[index].depth < maxDepth else { return }
        let quarters = nodes[index].bounds.quadrants
        let depth = nodes[index].depth + 1
        let first: Int
        if let reused = freeBlocks.popLast() {
            first = reused
            for i in 0..<4 { nodes[first + i] = Node(bounds: quarters[i], depth: depth) }
        } else {
            first = nodes.count
            nodes.append(contentsOf: quarters.map { Node(bounds: $0, depth: depth) })
        }
        nodes[index].firstChild = first

        let items = nodes[index].items
        nodes[index].items = []
        for item in items {
            let target = child(of: index, containing: item.position)
            nodes[target].items.append(item)
            nodes[target].count += 1
        }
        for i in first..<first + 4 { splitIfNeeded(i) }
    }

    private mutating func merge(_ index: Int) {
        var items: [Item] = []
        collect(nodes[index].firstChild, into: &items)
        nodes[index].firstChild = -1
        nodes[index].items = items
    }

    /// Moves every item under the block of four at `first` into `items`, freeing the nodes.
    private mutating func collect(_ first: Int, into items: inout [Item]) {
        for i in first..<first + 4 {
            if nodes[i].isLeaf {
                items.append(contentsOf: nodes[i].items)
                nodes[i].items = []
            } else {
                collect(nodes[i].firstChild, into: &items)
            }
        }
        freeBlocks.append(first)
    }

    // MARK: Queries

    public func elements(in box: BoundingBox) -> [Element] {
        var result: [Element] = []
        visit(where: { $0.intersects(box) }) { item in
            if box.contains(item.position) { result.append(item.element) }
        }
        return result
    }

    public func elements(within radius: Float, of center: SIMD2<Float>) -> [Element] {
        let limit = radius * radius
        var result: [Element] = []
        visit(where: { $0.intersects(circleAt: center, radius: radius) }) { item in
            if distanceSquared(item.position, center) <= limit { result.append(item.element) }
        }
        return result
    }

    public func nearest(to point: SIMD2<Float>, count: Int, maxDistance: Float) -> [Element] {
        var best = NearestList<Element>(capacity: count, maxDistance: maxDistance)
        nearest(in: 0, to: point, best: &best)
        return best.elements
    }

    private func nearest(in index: Int, to point: SIMD2<Float>, best: inout NearestList<Element>) {
        let node = nodes[index]
        guard node.count > 0, node.bounds.distanceSquared(to: point) <= best.cutoff else { return }
        if node.isLeaf {
            for item in node.items {
                best.offer(item.element, distanceSquared: distanceSquared(item.position, point))
            }
            return
        }
        // Closest quarters first, so the cutoff tightens before the far ones are checked.
        let children = (node.firstChild..<node.firstChild + 4)
            .map { ($0, nodes[$0].bounds.distanceSquared(to: point)) }
            .sorted { $0.1 < $1.1 }
        for (child, _) in children { nearest(in: child, to: point, best: &best) }
    }

    private func visit(where overlaps: (BoundingBox) -> Bool, _ body: (Item) -> Void) {
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            guard node.count > 0, overlaps(node.bounds) else { continue }
            if node.isLeaf { node.items.forEach(body) }
            else { stack.append(contentsOf: node.firstChild..<node.firstChild + 4) }
        }
    }
}

extension QuadTree: Sendable where Element: Sendable {}
extension QuadTree.Item: Sendable where Element: Sendable {}
extension QuadTree.Node: Sendable where Element: Sendable {}

extension QuadTree: Equatable {
    /// Trees are equal when they cover the same region with the same settings and
    /// hold the same elements at the same positions.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bounds == rhs.bounds && lhs.nodeCapacity == rhs.nodeCapacity
            && lhs.maxDepth == rhs.maxDepth && lhs.positions == rhs.positions
    }
}

extension QuadTree: Codable where Element: Codable {
    private enum CodingKeys: String, CodingKey { case bounds, nodeCapacity, maxDepth, elements }

    private struct Entry: Codable {
        var element: Element
        var position: SIMD2<Float>
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bounds: try container.decode(BoundingBox.self, forKey: .bounds),
            nodeCapacity: try container.decode(Int.self, forKey: .nodeCapacity),
            maxDepth: try container.decode(Int.self, forKey: .maxDepth)
        )
        for entry in try container.decode([Entry].self, forKey: .elements) {
            insert(entry.element, at: entry.position)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bounds, forKey: .bounds)
        try container.encode(nodeCapacity, forKey: .nodeCapacity)
        try container.encode(maxDepth, forKey: .maxDepth)
        try container.encode(positions.map { Entry(element: $0.key, position: $0.value) }, forKey: .elements)
    }
}

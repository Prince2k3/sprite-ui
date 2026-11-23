/// Anything you can search for paths through.
///
/// Conform a type by listing each node's neighbors. Add an estimate of the remaining
/// cost to make ``findPath(from:to:)`` an A* search; without one it's Dijkstra's.
///
/// ```swift
/// struct Rooms: Graph {
///     var doors: [String: [String]]
///     func neighbors(of room: String) -> [GraphEdge<String>] {
///         doors[room, default: []].map { GraphEdge(to: $0, cost: 1) }
///     }
/// }
///
/// Rooms(doors: ...).findPath(from: "hall", to: "vault")  // ["hall", "armory", "vault"]
/// ```
public protocol Graph {
    associatedtype Node: Hashable

    /// The nodes one step away from `node`, with the cost of each step.
    /// Costs must not be negative.
    func neighbors(of node: Node) -> [GraphEdge<Node>]

    /// A guess at the cheapest cost from `node` to `goal`.
    ///
    /// It must never be more than the real cost, or A* can return a path that isn't
    /// the shortest. The default, 0, is always safe but searches more nodes.
    func estimatedCost(from node: Node, to goal: Node) -> Float
}

extension Graph {
    public func estimatedCost(from node: Node, to goal: Node) -> Float { 0 }
}

/// One step through a ``Graph``: the node it leads to and what it costs.
public struct GraphEdge<Node: Hashable>: Hashable {
    public var to: Node
    public var cost: Float

    public init(to: Node, cost: Float = 1) {
        self.to = to
        self.cost = cost
    }
}

extension GraphEdge: Sendable where Node: Sendable {}
extension GraphEdge: Codable where Node: Codable {}

// MARK: - Search

extension Graph {
    /// The cheapest path from `start` to `goal`, both included, or `nil` if there is none.
    ///
    /// Uses A* guided by ``estimatedCost(from:to:)``. Ties are broken the same way every
    /// time, so the same graph always gives the same path.
    public func findPath(from start: Node, to goal: Node) -> [Node]? {
        if start == goal { return [start] }
        var open = PriorityQueue<Node>()
        var cameFrom: [Node: Node] = [:]
        var costSoFar: [Node: Float] = [start: 0]
        var closed: Set<Node> = []
        open.push(start, priority: estimatedCost(from: start, to: goal))

        while let current = open.pop() {
            if current == goal {
                return Self.reconstruct(to: goal, cameFrom: cameFrom)
            }
            guard closed.insert(current).inserted, let base = costSoFar[current] else { continue }
            for edge in neighbors(of: current) where !closed.contains(edge.to) {
                let cost = base + edge.cost
                if cost < costSoFar[edge.to, default: .infinity] {
                    costSoFar[edge.to] = cost
                    cameFrom[edge.to] = current
                    open.push(edge.to, priority: cost + estimatedCost(from: edge.to, to: goal))
                }
            }
        }
        return nil
    }

    /// The cheapest cost from the nearest of `sources` to every node reachable from them,
    /// using Dijkstra's algorithm.
    ///
    /// One search answers "how far is everything from here", which suits range
    /// highlighting and many agents heading to one place:
    ///
    /// ```swift
    /// let map = grid.costMap(from: [player])
    /// let step = map.nextStep(from: enemy)  // one cell closer to the player
    /// ```
    ///
    /// - Parameter maxCost: Stop exploring past this cost.
    public func costMap(from sources: some Sequence<Node>, maxCost: Float = .infinity) -> CostMap<Node> {
        var open = PriorityQueue<Node>()
        var costs: [Node: Float] = [:]
        var parents: [Node: Node] = [:]
        var closed: Set<Node> = []
        for source in sources where costs[source] == nil {
            costs[source] = 0
            open.push(source, priority: 0)
        }
        while let current = open.pop() {
            guard closed.insert(current).inserted, let base = costs[current] else { continue }
            for edge in neighbors(of: current) where !closed.contains(edge.to) {
                let cost = base + edge.cost
                if cost <= maxCost, cost < costs[edge.to, default: .infinity] {
                    costs[edge.to] = cost
                    parents[edge.to] = current
                    open.push(edge.to, priority: cost)
                }
            }
        }
        return CostMap(costs: costs, parents: parents)
    }

    /// The cheapest cost from `source` to every node reachable from it.
    public func costMap(from source: Node, maxCost: Float = .infinity) -> CostMap<Node> {
        costMap(from: [source], maxCost: maxCost)
    }

    fileprivate static func reconstruct(to goal: Node, cameFrom: [Node: Node]) -> [Node] {
        var path = [goal]
        var node = goal
        while let previous = cameFrom[node] {
            path.append(previous)
            node = previous
        }
        return path.reversed()
    }
}

/// The result of ``Graph/costMap(from:maxCost:)-(Sequence,_)``: how cheaply each
/// reachable node can be reached from the nearest source.
public struct CostMap<Node: Hashable>: Hashable {
    private let costs: [Node: Float]
    private let parents: [Node: Node]

    init(costs: [Node: Float], parents: [Node: Node]) {
        self.costs = costs
        self.parents = parents
    }

    /// Every node that was reached.
    public var nodes: Dictionary<Node, Float>.Keys { costs.keys }

    /// The cheapest cost to reach `node`, or `nil` if it wasn't reached.
    public func cost(to node: Node) -> Float? { costs[node] }

    /// One step from `node` toward the nearest source, or `nil` at a source or
    /// for an unreached node. Following it repeatedly walks the cheapest path home.
    public func nextStep(from node: Node) -> Node? { parents[node] }

    /// The cheapest path from the nearest source to `node`, both included.
    public func path(to node: Node) -> [Node]? {
        guard costs[node] != nil else { return nil }
        var path = [node]
        var current = node
        while let parent = parents[current] {
            path.append(parent)
            current = parent
        }
        return path.reversed()
    }
}

extension CostMap: Sendable where Node: Sendable {}

/// A binary min-heap. Equal priorities come out in the order they went in,
/// which keeps searches deterministic.
struct PriorityQueue<Element> {
    private var heap: [(priority: Float, order: Int, element: Element)] = []
    private var counter = 0

    var isEmpty: Bool { heap.isEmpty }
    var count: Int { heap.count }

    mutating func push(_ element: Element, priority: Float) {
        heap.append((priority, counter, element))
        counter += 1
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.less(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            var smallest = parent
            if left < heap.count, Self.less(heap[left], heap[smallest]) { smallest = left }
            if right < heap.count, Self.less(heap[right], heap[smallest]) { smallest = right }
            guard smallest != parent else { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
        return top.element
    }

    private static func less(
        _ a: (priority: Float, order: Int, element: Element),
        _ b: (priority: Float, order: Int, element: Element)
    ) -> Bool {
        a.priority != b.priority ? a.priority < b.priority : a.order < b.order
    }
}

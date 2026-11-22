/// A graph of nodes and the edges you add between them, in place of `GKGraph`
/// with `GKGraphNode`s. Good for waypoints, rooms, or a level's road network.
///
/// ```swift
/// var roads = AdjacencyGraph<String>()
/// roads.connect("camp", "bridge", cost: 4)
/// roads.connect("bridge", "castle", cost: 6)
/// roads.findPath(from: "camp", to: "castle")  // ["camp", "bridge", "castle"]
/// ```
///
/// It has no cost estimate, so searches run as Dijkstra's. For A* over positioned
/// waypoints, conform your own type to ``Graph`` and implement `estimatedCost`.
public struct AdjacencyGraph<Node: Hashable>: Graph, Hashable {
    private var edges: [Node: [GraphEdge<Node>]] = [:]

    public init() {}

    /// Every node in the graph.
    public var nodes: Dictionary<Node, [GraphEdge<Node>]>.Keys { edges.keys }

    public func neighbors(of node: Node) -> [GraphEdge<Node>] { edges[node, default: []] }

    /// Adds `node` with no edges, if it isn't already in the graph.
    public mutating func add(_ node: Node) {
        if edges[node] == nil { edges[node] = [] }
    }

    /// Adds an edge from `a` to `b`, and from `b` to `a` unless `bidirectional` is false.
    /// Connecting the same pair again replaces the cost.
    public mutating func connect(_ a: Node, _ b: Node, cost: Float = 1, bidirectional: Bool = true) {
        addEdge(from: a, to: b, cost: cost)
        if bidirectional { addEdge(from: b, to: a, cost: cost) }
        else { add(b) }
    }

    /// Removes the edges between `a` and `b` in both directions.
    public mutating func disconnect(_ a: Node, _ b: Node) {
        edges[a]?.removeAll { $0.to == b }
        edges[b]?.removeAll { $0.to == a }
    }

    /// Removes `node` and every edge leading to it.
    public mutating func remove(_ node: Node) {
        edges[node] = nil
        for key in edges.keys { edges[key]?.removeAll { $0.to == node } }
    }

    private mutating func addEdge(from a: Node, to b: Node, cost: Float) {
        if let index = edges[a]?.firstIndex(where: { $0.to == b }) {
            edges[a]![index].cost = cost
        } else {
            edges[a, default: []].append(GraphEdge(to: b, cost: cost))
        }
    }
}

extension AdjacencyGraph: Sendable where Node: Sendable {}
extension AdjacencyGraph: Codable where Node: Codable {}

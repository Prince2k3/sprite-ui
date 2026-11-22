import Gameplay
import SpriteBackend

extension TileMapComponent {
    /// A pathfinding grid with a node for every cell, in place of building a
    /// `GKGridGraph` from a tile map by hand.
    ///
    /// `cost` says how much stepping onto a cell costs, given its tile (`nil` when the
    /// cell is empty). Return `nil` to block it. Costs below 1 count as 1.
    public func gridGraph(
        allowsDiagonals: Bool = false,
        cost: (Tile?) -> Float?
    ) -> GridGraph {
        var graph = GridGraph(width: columns, height: rows, allowsDiagonals: allowsDiagonals)
        for row in 0..<rows {
            for column in 0..<columns {
                let point = GridPoint(column, row)
                if let cost = cost(self[column, row]) {
                    graph.setCost(Swift.max(cost, 1), at: point)
                } else {
                    graph.setWalkable(false, at: point)
                }
            }
        }
        return graph
    }

    /// A pathfinding grid that reads each tile's User Data from the editor: tiles whose
    /// `walkable` is false are blocked, and `cost` makes a tile slower to cross.
    /// Empty cells are walkable unless `emptyIsWalkable` is false.
    public func gridGraph(allowsDiagonals: Bool = false, emptyIsWalkable: Bool = true) -> GridGraph {
        gridGraph(allowsDiagonals: allowsDiagonals) { tile in
            guard let tile else { return emptyIsWalkable ? 1 : nil }
            if tile["walkable"]?.bool == false { return nil }
            return tile["cost"]?.float ?? 1
        }
    }

    /// Converts between cells and scene positions for a map whose entity is at
    /// `position` in the scene, such as its `scenePosition`. The map's rotation and
    /// scale aren't taken into account. Tiles are taken to be square, `tileSize.x` wide.
    public func gridSpace(at position: SIMD2<Float> = .zero) -> GridSpace {
        GridSpace(cellSize: tileSize.x, origin: position + centerOfTile(column: 0, row: 0))
    }
}

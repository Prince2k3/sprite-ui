import SpriteUI
import Testing

private let floor = TileMapComponent.Tile(name: "floor")
private let wall = TileMapComponent.Tile(name: "wall", userData: ["walkable": .bool(false)])
private let mud = TileMapComponent.Tile(name: "mud", userData: ["cost": .int(5)])

@Suite struct TileMapGridTests {
    let map = TileMapComponent(tileSize: [20, 20], tiles: [floor, wall, mud],
                               legend: [".": 0, "#": 1, "~": 2], rows: [
        ".....",
        ".###.",
        "..~..",
    ])

    @Test func userDataBlocksAndSlowsCells() throws {
        let graph = map.gridGraph()
        #expect(graph.width == 5 && graph.height == 3)
        #expect(!graph.isWalkable(GridPoint(1, 1)))
        #expect(graph.isWalkable(GridPoint(0, 0)))
        #expect(graph.cost(at: GridPoint(2, 0)) == 5)
        // Around the wall: through the mud costs more than over the top.
        let path = try #require(graph.findPath(from: GridPoint(0, 1), to: GridPoint(4, 1)))
        #expect(path.contains(GridPoint(2, 2)))
        #expect(!path.contains(GridPoint(2, 0)))
    }

    @Test func emptyCellsAndCustomCosts() {
        var holes = map
        holes.setTile(named: nil, column: 0, row: 0)
        #expect(holes.gridGraph().isWalkable(GridPoint(0, 0)))
        #expect(!holes.gridGraph(emptyIsWalkable: false).isWalkable(GridPoint(0, 0)))
        let onlyMud = map.gridGraph { $0?.name == "mud" ? 1 : nil }
        #expect(onlyMud.isWalkable(GridPoint(2, 0)))
        #expect(!onlyMud.isWalkable(GridPoint(0, 0)))
    }

    @Test func gridSpaceMatchesTileCenters() {
        let space = map.gridSpace(at: [100, 50])
        for (column, row) in [(0, 0), (4, 2), (2, 1)] {
            let center = map.centerOfTile(column: column, row: row) + [100, 50]
            #expect(space.position(of: GridPoint(column, row)) == center)
            #expect(space.point(at: center + [9, -9]) == GridPoint(column, row))
        }
    }
}

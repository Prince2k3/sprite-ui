import ECSCore
import Foundation
@testable import SpriteBackend
import SpriteKit
import Testing

private let floor = TileMapComponent.Tile(name: "floor", color: .gray)
private let wall = TileMapComponent.Tile(name: "wall", color: .brown, userData: ["walkable": .bool(false)])

@Suite struct TileMapComponentTests {
    @Test func charactersLayOutTheMapTopRowFirst() {
        let map = TileMapComponent(tileSize: [32, 32], tiles: [floor, wall], legend: [".": 0, "#": 1], rows: [
            "###",
            "#. ",
        ])
        #expect(map.columns == 3 && map.rows == 2)
        #expect(map[0, 1]?.name == "wall")
        #expect(map[1, 0]?.name == "floor")
        #expect(map[2, 0] == nil)        // a space isn't in the legend
        #expect(map[5, 5] == nil)        // off the map
    }

    @Test func settingCells() {
        var map = TileMapComponent(columns: 4, rows: 3, tileSize: [10, 10], tiles: [floor, wall])
        map.setTile(named: "wall", column: 3, row: 2)
        #expect(map[3, 2] == wall)
        #expect(map.cells[2 * 4 + 3] == 1)
        map.setTile(named: nil, column: 3, row: 2)
        #expect(map[3, 2] == nil)
        map[tileIndexAt: 9, 9] = 0       // off the map: ignored
        #expect(map.cells.allSatisfy { $0 == nil })
    }

    @Test func tileCentersAndLookupsFollowTheAnchor() {
        var map = TileMapComponent(columns: 5, rows: 3, tileSize: [32, 32])
        #expect(map.size == [160, 96])
        // Matches SKTileMapNode.centerOfTile(atColumn:row:) for a centered map.
        #expect(map.centerOfTile(column: 0, row: 0) == [-64, -32])
        #expect(map.tileCoordinates(at: [-64, -32])! == (0, 0))
        #expect(map.tileCoordinates(at: [79, 47])! == (4, 2))
        #expect(map.tileCoordinates(at: [81, 0]) == nil)
        map.anchorPoint = [0, 0]
        #expect(map.centerOfTile(column: 1, row: 2) == [48, 80])
        #expect(map.tileCoordinates(at: [-1, 5]) == nil)
    }
}

/// A tile map like one painted in the editor: grass everywhere, a wall with User
/// Data, mud that's slow to cross, and a group with two variants.
@MainActor
private func makeTileScene() -> SKScene {
    func definition(_ color: SKColor, _ name: String, _ userData: NSMutableDictionary? = nil) -> SKTileDefinition {
        let image = SpriteImage(width: 1, height: 1, pixels: color == .red ? [255, 0, 0, 255] : [0, 255, 0, 255])
        let definition = SKTileDefinition(texture: SpriteRenderer.makeTexture(image)!, size: CGSize(width: 16, height: 16))
        definition.name = name
        definition.userData = userData
        return definition
    }
    let grassA = definition(.green, "grass-a")
    let grassB = definition(.green, "grass-b")
    let grass = SKTileGroup(rules: [SKTileGroupRule(adjacency: .adjacencyAll, tileDefinitions: [grassA, grassB])])
    grass.name = "grass"
    let wall = SKTileGroup(tileDefinition: definition(.red, "wall", ["walkable": false]))
    wall.name = "wall"
    let mudDefinition = SKTileDefinition(texture: SKTexture(imageNamed: "mud"), size: CGSize(width: 16, height: 16))
    mudDefinition.userData = ["cost": 4]
    let mud = SKTileGroup(tileDefinition: mudDefinition)
    mud.name = "mud"

    let map = SKTileMapNode(tileSet: SKTileSet(tileGroups: [grass, wall, mud], tileSetType: .grid),
                            columns: 4, rows: 3, tileSize: CGSize(width: 16, height: 16))
    map.name = "ground"
    map.position = CGPoint(x: 50, y: 20)
    map.anchorPoint = .zero
    map.fill(with: grass)
    map.setTileGroup(wall, forColumn: 1, row: 1)
    map.setTileGroup(mud, forColumn: 2, row: 0)
    map.setTileGroup(grass, andTileDefinition: grassB, forColumn: 3, row: 2)
    map.setTileGroup(nil, forColumn: 0, row: 2)

    let scene = SKScene(size: CGSize(width: 200, height: 100))
    scene.addChild(map)
    return scene
}

@MainActor @Suite struct TileMapLoadingTests {
    private func load() throws -> TileMapComponent {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TileMapTests-\(UUID().uuidString).sks")
        try NSKeyedArchiver.archivedData(withRootObject: makeTileScene(), requiringSecureCoding: false).write(to: url)
        let root = try Entity.load(contentsOf: url)
        let ground = try #require(root.findEntity(named: "ground"))
        #expect(ground.position == [50, 20])
        return try #require(ground.components[TileMapComponent.self])
    }

    @Test func tileMapsLoadTheirShapeAndCells() throws {
        let map = try load()
        #expect(map.columns == 4 && map.rows == 3)
        #expect(map.tileSize == [16, 16])
        #expect(map.anchorPoint == [0, 0])
        #expect(map[1, 1]?.name == "wall")
        #expect(map[2, 0]?.name == "mud")
        #expect(map[0, 0]?.name == "grass")
        #expect(map[0, 2] == nil)
    }

    @Test func everyDefinitionIsATileWithItsUserDataAndImage() throws {
        let map = try load()
        // Two grass variants, the wall and the mud, in tile set order.
        #expect(map.tiles.map(\.name) == ["grass", "grass", "wall", "mud"])
        #expect(map[3, 2] == map.tiles[1])
        #expect(map[1, 1]?["walkable"]?.bool == false)
        #expect(map[2, 0]?["cost"]?.int == 4)
        #expect(map[2, 0]?.imageName == "mud")
        #expect(map[1, 1]?.image?.pixels == [255, 0, 0, 255])
    }
}

@MainActor @Suite struct TileMapRenderingTests {
    @Test func cellsDrawAsATileMapNodeAndUpdateInPlace() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        var map = TileMapComponent(tileSize: [8, 8], tiles: [floor, wall], legend: [".": 0, "#": 1], rows: [
            "#.",
            "..",
        ])
        let entity = Entity(components: map)
        world.addEntity(entity)
        renderer.flush()
        let node = try #require(renderer.node(for: entity)?.childNode(withName: SpriteRenderer.tileMapNodeName) as? SKTileMapNode)
        #expect(node.numberOfColumns == 2 && node.numberOfRows == 2)
        #expect(node.tileGroup(atColumn: 0, row: 1)?.name == "wall")
        #expect(node.tileGroup(atColumn: 1, row: 0)?.name == "floor")

        map.setTile(named: nil, column: 0, row: 1)
        map.setTile(named: "wall", column: 1, row: 0)
        entity.components.set(map)
        renderer.flush()
        let same = renderer.node(for: entity)?.childNode(withName: SpriteRenderer.tileMapNodeName)
        #expect(same === node)
        #expect(node.tileGroup(atColumn: 0, row: 1) == nil)
        #expect(node.tileGroup(atColumn: 1, row: 0)?.name == "wall")

        entity.components[TileMapComponent.self] = nil
        renderer.flush()
        #expect(renderer.node(for: entity)?.childNode(withName: SpriteRenderer.tileMapNodeName) == nil)
    }
}

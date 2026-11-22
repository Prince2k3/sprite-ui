@_spi(Backend) import ECSCore
import Foundation
import SpriteKit
import SwiftUI

/// A grid of tiles drawn at the entity's transform, in place of `SKTileMapNode`.
///
/// Tiles come from a palette, ``tiles``, and each cell holds the index of its tile or
/// `nil` when it's empty. Column 0 is on the left and row 0 at the bottom, the way
/// `SKTileMapNode` counts them, so a cell's `(column, row)` is also its `GridPoint`.
///
/// Tile maps in a scene file load as this component, keeping each tile's User Data,
/// so a level painted in Xcode's tile editor can drive pathfinding directly:
///
/// ```swift
/// let level = try Entity.load(named: "Maze")
/// let floor = level.findEntity(named: "floor")!
/// let map = floor.components[TileMapComponent.self]!
/// let graph = map.gridGraph()                   // "walkable" and "cost" User Data
/// let space = map.gridSpace(at: floor.scenePosition)
/// let path = graph.findPath(from: space.point(at: start), to: space.point(at: goal))
/// ```
public struct TileMapComponent: Component, Equatable, Sendable {
    /// One kind of tile: what it looks like and what the editor said about it.
    public struct Tile: Equatable, Sendable {
        /// The tile group's name in the editor, such as "Grass".
        public var name: String
        /// Name of an image in the asset catalog.
        public var imageName: String?
        /// Pixels made in code. Wins over `imageName`.
        public var image: SpriteImage?
        /// Fill color for a tile with no image.
        public var color: Color
        /// The tile definition's User Data from the editor.
        public var userData: [String: SceneValue]

        public init(
            name: String,
            imageName: String? = nil,
            image: SpriteImage? = nil,
            color: Color = .white,
            userData: [String: SceneValue] = [:]
        ) {
            self.name = name
            self.imageName = imageName
            self.image = image
            self.color = color
            self.userData = userData
        }

        public subscript(key: String) -> SceneValue? {
            get { userData[key] }
            set { userData[key] = newValue }
        }
    }

    public var columns: Int
    public var rows: Int
    /// The size of one tile, in points.
    public var tileSize: SIMD2<Float>
    /// The point in the map placed at the entity's position. (0.5, 0.5) is the middle.
    public var anchorPoint: SIMD2<Float>
    /// Every kind of tile the map uses.
    public var tiles: [Tile]
    /// Each cell's index into ``tiles``, `nil` for empty, a row at a time from the
    /// bottom row. Use the subscripts rather than indexing it yourself.
    public var cells: [Int?]

    /// An empty map.
    public init(
        columns: Int,
        rows: Int,
        tileSize: SIMD2<Float>,
        tiles: [Tile] = [],
        anchorPoint: SIMD2<Float> = [0.5, 0.5]
    ) {
        precondition(columns > 0 && rows > 0, "A tile map needs at least one column and row")
        self.columns = columns
        self.rows = rows
        self.tileSize = tileSize
        self.anchorPoint = anchorPoint
        self.tiles = tiles
        self.cells = Array(repeating: nil, count: columns * rows)
    }

    /// A map drawn with one character per cell, top row first, the way it looks.
    /// `legend` says which tile each character stands for; others leave the cell empty.
    ///
    /// ```swift
    /// TileMapComponent(tileSize: [32, 32], tiles: [floor, wall], legend: [".": 0, "#": 1], rows: [
    ///     "#####",
    ///     "#...#",
    ///     "#####",
    /// ])
    /// ```
    public init(
        tileSize: SIMD2<Float>,
        tiles: [Tile],
        legend: [Character: Int],
        rows lines: [String],
        anchorPoint: SIMD2<Float> = [0.5, 0.5]
    ) {
        let width = lines.map(\.count).max() ?? 0
        self.init(columns: max(width, 1), rows: max(lines.count, 1), tileSize: tileSize,
                  tiles: tiles, anchorPoint: anchorPoint)
        for (line, text) in lines.enumerated() {
            let row = lines.count - 1 - line
            for (column, character) in text.enumerated() {
                self[tileIndexAt: column, row] = legend[character]
            }
        }
    }

    /// Whether a cell is on the map.
    public func contains(column: Int, row: Int) -> Bool {
        column >= 0 && column < columns && row >= 0 && row < rows
    }

    /// The index into ``tiles`` of a cell's tile, `nil` when it's empty or off the map.
    /// Setting a cell off the map does nothing.
    public subscript(tileIndexAt column: Int, row: Int) -> Int? {
        get { contains(column: column, row: row) ? cells[row * columns + column] : nil }
        set {
            guard contains(column: column, row: row) else { return }
            precondition(newValue.map { tiles.indices.contains($0) } ?? true, "No tile \(newValue!) in the palette")
            cells[row * columns + column] = newValue
        }
    }

    /// A cell's tile, `nil` when it's empty or off the map.
    public subscript(column: Int, row: Int) -> Tile? {
        self[tileIndexAt: column, row].map { tiles[$0] }
    }

    /// Puts the first tile called `name` in a cell, or empties it for `nil`.
    public mutating func setTile(named name: String?, column: Int, row: Int) {
        self[tileIndexAt: column, row] = name.flatMap { name in tiles.firstIndex { $0.name == name } }
    }

    /// The map's size, in points.
    public var size: SIMD2<Float> {
        SIMD2(Float(columns), Float(rows)) * tileSize
    }

    /// The middle of a cell, relative to the entity's position.
    public func centerOfTile(column: Int, row: Int) -> SIMD2<Float> {
        -size * anchorPoint + (SIMD2(Float(column), Float(row)) + 0.5) * tileSize
    }

    /// The cell under a point relative to the entity's position, `nil` off the map.
    public func tileCoordinates(at point: SIMD2<Float>) -> (column: Int, row: Int)? {
        let cell = ((point + size * anchorPoint) / tileSize).rounded(.down)
        guard cell.x.isFinite, cell.y.isFinite else { return nil }
        let column = Int(cell.x), row = Int(cell.y)
        return contains(column: column, row: row) ? (column, row) : nil
    }
}

// MARK: - Renderer support

extension SpriteRenderer {
    static let tileMapNodeName = "__tilemap"

    static let tileMapBinding = Binding<TileMapComponent>(
        apply: { new, old, node, _ in
            let existing = node.childNode(withName: tileMapNodeName) as? SKTileMapNode
            guard let map = new else {
                existing?.removeFromParent()
                return
            }
            let tileSize = CGSize(width: CGFloat(map.tileSize.x), height: CGFloat(map.tileSize.y))
            // A new palette or shape needs a new tile set; otherwise only changed cells are redrawn.
            let rebuild = existing == nil || old == nil || old?.tiles != map.tiles
                || old?.columns != map.columns || old?.rows != map.rows
            let mapNode: SKTileMapNode
            if rebuild {
                existing?.removeFromParent()
                let groups = map.tiles.map { tile in
                    let definition = tileTexture(tile).map { SKTileDefinition(texture: $0, size: tileSize) }
                        ?? SKTileDefinition()
                    definition.name = tile.name
                    let group = SKTileGroup(tileDefinition: definition)
                    group.name = tile.name
                    return group
                }
                mapNode = SKTileMapNode(tileSet: SKTileSet(tileGroups: groups, tileSetType: .grid),
                                        columns: map.columns, rows: map.rows, tileSize: tileSize)
                mapNode.name = tileMapNodeName
                mapNode.zPosition = -0.001
                node.addChild(mapNode)
            } else {
                mapNode = existing!
            }
            if rebuild || old?.tileSize != map.tileSize {
                mapNode.tileSize = tileSize
            }
            if rebuild || old?.anchorPoint != map.anchorPoint {
                mapNode.anchorPoint = CGPoint(x: CGFloat(map.anchorPoint.x), y: CGFloat(map.anchorPoint.y))
            }
            let groups = mapNode.tileSet.tileGroups
            for index in map.cells.indices where rebuild || old?.cells[index] != map.cells[index] {
                let group = map.cells[index].flatMap { $0 < groups.count ? groups[$0] : nil }
                mapNode.setTileGroup(group, forColumn: index % map.columns, row: index / map.columns)
            }
        }
    )

    /// What a tile draws: its image, or a texture of its color.
    static func tileTexture(_ tile: TileMapComponent.Tile) -> SKTexture? {
        if let image = tile.image { return makeTexture(image) }
        if let name = tile.imageName { return SKTexture(imageNamed: name) }
        let rgba = SKColor(tile.color).rgbaBytes
        return makeTexture(SpriteImage(width: 1, height: 1, pixels: rgba, smoothsScaling: false))
    }
}

private extension SKColor {
    /// sRGB components as 8-bit RGBA.
    var rgbaBytes: [UInt8] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return [r, g, b, a].map { UInt8(max(0, min(1, $0)) * 255 + 0.5) }
    }
}

/// Points sorted into square buckets of one size, with no fixed region.
///
/// A good fit for many moving things of about the same size: moving within a bucket
/// is just a position update, and a query only looks in the buckets it overlaps.
/// Pick a `cellSize` near the radius you usually search.
///
/// ```swift
/// var hash = SpatialHash<Entity.ID>(cellSize: 64)
/// for bullet in bullets { hash.insert(bullet.id, at: bullet.position) }
/// let hits = hash.elements(within: 20, of: ship.position)
/// ```
public struct SpatialHash<Element: Hashable>: SpatialIndex {
    /// The width and height of each bucket.
    public let cellSize: Float

    private var buckets: [GridPoint: [Element]] = [:]
    private var positions: [Element: SIMD2<Float>] = [:]

    public init(cellSize: Float) {
        precondition(cellSize > 0, "Buckets need a positive size.")
        self.cellSize = cellSize
    }

    public var count: Int { positions.count }

    public func position(of element: Element) -> SIMD2<Float>? { positions[element] }

    /// Every element and where it is, in no particular order.
    public var elements: Dictionary<Element, SIMD2<Float>> { positions }

    /// The bucket that holds `position`.
    public func cell(containing position: SIMD2<Float>) -> GridPoint {
        GridPoint(Int((position.x / cellSize).rounded(.down)), Int((position.y / cellSize).rounded(.down)))
    }

    /// The region a bucket covers.
    public func bounds(of cell: GridPoint) -> BoundingBox {
        let min = SIMD2(Float(cell.x), Float(cell.y)) * cellSize
        return BoundingBox(min: min, max: min + cellSize)
    }

    /// The buckets that hold at least one element.
    public var occupiedCells: Dictionary<GridPoint, [Element]>.Keys { buckets.keys }

    // MARK: Editing

    @discardableResult
    public mutating func insert(_ element: Element, at position: SIMD2<Float>) -> Bool {
        guard position.x.isFinite, position.y.isFinite else { return false }
        let cell = cell(containing: position)
        if let old = positions.updateValue(position, forKey: element) {
            let oldCell = self.cell(containing: old)
            if oldCell == cell { return true }
            removeFromBucket(element, oldCell)
        }
        buckets[cell, default: []].append(element)
        return true
    }

    @discardableResult
    public mutating func remove(_ element: Element) -> Bool {
        guard let position = positions.removeValue(forKey: element) else { return false }
        removeFromBucket(element, cell(containing: position))
        return true
    }

    /// Moves `element` to `position`. Same as inserting it again.
    @discardableResult
    public mutating func move(_ element: Element, to position: SIMD2<Float>) -> Bool {
        insert(element, at: position)
    }

    public mutating func removeAll() {
        buckets = [:]
        positions = [:]
    }

    private mutating func removeFromBucket(_ element: Element, _ cell: GridPoint) {
        buckets[cell]?.removeAll { $0 == element }
        if buckets[cell]?.isEmpty == true { buckets[cell] = nil }
    }

    // MARK: Queries

    public func elements(in box: BoundingBox) -> [Element] {
        var result: [Element] = []
        forEachCandidate(in: box) { element, position in
            if box.contains(position) { result.append(element) }
        }
        return result
    }

    public func elements(within radius: Float, of center: SIMD2<Float>) -> [Element] {
        let limit = radius * radius
        var result: [Element] = []
        forEachCandidate(in: BoundingBox(center: center, radius: radius)) { element, position in
            if distanceSquared(position, center) <= limit { result.append(element) }
        }
        return result
    }

    public func nearest(to point: SIMD2<Float>, count: Int, maxDistance: Float) -> [Element] {
        var best = NearestList<Element>(capacity: count, maxDistance: maxDistance)
        guard count > 0, !buckets.isEmpty else { return [] }
        let center = cell(containing: point)
        var seen = 0
        var ring = 0
        // Search rings of buckets outward. Anything in ring r+1 or beyond is at least
        // r buckets away, so stop once the list's cutoff is closer than that.
        while seen < buckets.count {
            let reach = Float(ring - 1) * cellSize
            if ring > 0, reach * reach > best.cutoff { break }
            if 8 * ring > buckets.count {
                // Rings now have more cells than there are buckets: check the rest directly.
                for (cell, bucket) in buckets where max(abs(cell.x - center.x), abs(cell.y - center.y)) >= ring {
                    for element in bucket {
                        best.offer(element, distanceSquared: distanceSquared(positions[element]!, point))
                    }
                }
                break
            }
            for cell in Self.ring(ring, around: center) {
                guard let bucket = buckets[cell] else { continue }
                seen += 1
                for element in bucket {
                    best.offer(element, distanceSquared: distanceSquared(positions[element]!, point))
                }
            }
            ring += 1
        }
        return best.elements
    }

    private func forEachCandidate(in box: BoundingBox, _ body: (Element, SIMD2<Float>) -> Void) {
        let low = cell(containing: box.min), high = cell(containing: box.max)
        let spanned = (high.x - low.x + 1) * (high.y - low.y + 1)
        if spanned > buckets.count {
            // A huge query: walking the occupied buckets is cheaper than every cell it spans.
            for (cell, bucket) in buckets where (low.x...high.x).contains(cell.x) && (low.y...high.y).contains(cell.y) {
                for element in bucket { body(element, positions[element]!) }
            }
        } else {
            for y in low.y...high.y {
                for x in low.x...high.x {
                    for element in buckets[GridPoint(x, y)] ?? [] { body(element, positions[element]!) }
                }
            }
        }
    }

    /// The cells exactly `radius` steps from `center` (Chebyshev distance).
    private static func ring(_ radius: Int, around center: GridPoint) -> [GridPoint] {
        guard radius > 0 else { return [center] }
        var cells: [GridPoint] = []
        for x in -radius...radius {
            cells.append(GridPoint(center.x + x, center.y - radius))
            cells.append(GridPoint(center.x + x, center.y + radius))
        }
        for y in (-radius + 1)..<radius {
            cells.append(GridPoint(center.x - radius, center.y + y))
            cells.append(GridPoint(center.x + radius, center.y + y))
        }
        return cells
    }
}

extension SpatialHash: Sendable where Element: Sendable {}

extension SpatialHash: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cellSize == rhs.cellSize && lhs.positions == rhs.positions
    }
}

extension SpatialHash: Codable where Element: Codable {
    private enum CodingKeys: String, CodingKey { case cellSize, elements }

    private struct Entry: Codable {
        var element: Element
        var position: SIMD2<Float>
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cellSize: try container.decode(Float.self, forKey: .cellSize))
        for entry in try container.decode([Entry].self, forKey: .elements) {
            insert(entry.element, at: entry.position)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cellSize, forKey: .cellSize)
        try container.encode(positions.map { Entry(element: $0.key, position: $0.value) }, forKey: .elements)
    }
}

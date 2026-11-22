/// A structure that finds elements by position without checking every one.
///
/// ``QuadTree`` and ``SpatialHash`` both conform. Each element has one position;
/// inserting an element that's already there moves it.
public protocol SpatialIndex<Element> {
    associatedtype Element: Hashable

    /// How many elements are stored.
    var count: Int { get }

    /// Stores `element` at `position`, moving it if it's already stored.
    /// Returns `false` if the position can't be stored, such as outside a quadtree's bounds.
    @discardableResult
    mutating func insert(_ element: Element, at position: SIMD2<Float>) -> Bool

    /// Removes `element`. Returns `false` if it wasn't stored.
    @discardableResult
    mutating func remove(_ element: Element) -> Bool

    /// Where `element` is stored, or `nil` if it isn't.
    func position(of element: Element) -> SIMD2<Float>?

    /// The elements inside `box`, edges included, in no particular order.
    func elements(in box: BoundingBox) -> [Element]

    /// The elements within `radius` of `center`, in no particular order.
    func elements(within radius: Float, of center: SIMD2<Float>) -> [Element]

    /// Up to `count` elements nearest to `point`, nearest first, no farther than `maxDistance`.
    func nearest(to point: SIMD2<Float>, count: Int, maxDistance: Float) -> [Element]
}

extension SpatialIndex {
    public var isEmpty: Bool { count == 0 }

    /// Whether `element` is stored.
    public func contains(_ element: Element) -> Bool {
        position(of: element) != nil
    }

    /// The element nearest to `point`, if any is within `maxDistance`.
    public func nearest(to point: SIMD2<Float>, maxDistance: Float = .infinity) -> Element? {
        nearest(to: point, count: 1, maxDistance: maxDistance).first
    }

    /// Up to `count` elements nearest to `point`, nearest first.
    public func nearest(to point: SIMD2<Float>, count: Int) -> [Element] {
        nearest(to: point, count: count, maxDistance: .infinity)
    }
}

/// The best `capacity` candidates seen so far, nearest first.
struct NearestList<Element> {
    let capacity: Int
    let maxDistanceSquared: Float
    private(set) var items: [(distanceSquared: Float, element: Element)] = []

    init(capacity: Int, maxDistance: Float) {
        self.capacity = capacity
        maxDistanceSquared = maxDistance * maxDistance
    }

    /// Anything farther than this can't make the list.
    var cutoff: Float {
        items.count < capacity ? maxDistanceSquared : items[items.count - 1].distanceSquared
    }

    mutating func offer(_ element: Element, distanceSquared: Float) {
        guard capacity > 0, distanceSquared <= cutoff else { return }
        if items.count == capacity, distanceSquared >= items[items.count - 1].distanceSquared { return }
        let index = items.firstIndex { $0.distanceSquared > distanceSquared } ?? items.count
        items.insert((distanceSquared, element), at: index)
        if items.count > capacity { items.removeLast() }
    }

    var elements: [Element] { items.map(\.element) }
}

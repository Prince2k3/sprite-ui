import CoreGraphics
import Foundation

/// A rectangle selected from a game surface's local, top-left coordinate space.
public enum GameSurfaceRegion: Hashable, Codable, Sendable {
    /// The complete surface, before safe-area insets or reservations.
    case surface
    /// The surface after applying its safe-area insets.
    case safeArea
    /// The largest usable rectangle, with ties resolved by top-to-bottom, then left-to-right order.
    case largestUsable
    /// A zero-based index into the ordered usable rectangles; missing indices resolve to zero.
    case usable(Int)
}

/// Immutable surface geometry in points, with x increasing rightward and y downward.
/// This model has no rendering or platform-view dependencies. Display scale is metadata;
/// it never changes point coordinates or rounds them to pixels.
public struct GameSurfaceGeometry: Equatable, Sendable {
    /// Nonnegative, finite distances from the four edges of a surface, in points.
    public struct Insets: Hashable, Codable, Sendable {
        /// The distance from the top edge.
        public let top: CGFloat
        /// The distance from the left edge.
        public let left: CGFloat
        /// The distance from the bottom edge.
        public let bottom: CGFloat
        /// The distance from the right edge.
        public let right: CGFloat

        /// Creates insets, replacing negative or nonfinite values with zero.
        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = GameSurfaceGeometry.nonnegative(top)
            self.left = GameSurfaceGeometry.nonnegative(left)
            self.bottom = GameSurfaceGeometry.nonnegative(bottom)
            self.right = GameSurfaceGeometry.nonnegative(right)
        }

        /// Decodes insets using the same sanitization as the memberwise initializer.
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(top: try values.decode(CGFloat.self, forKey: .top),
                      left: try values.decode(CGFloat.self, forKey: .left),
                      bottom: try values.decode(CGFloat.self, forKey: .bottom),
                      right: try values.decode(CGFloat.self, forKey: .right))
        }

        private enum CodingKeys: String, CodingKey { case top, left, bottom, right }
    }

    /// A named rectangle unavailable for placement while active.
    /// IDs are preserved as supplied; duplicate IDs do not suppress reservations.
    public struct ReservedRegion: Equatable, Sendable, Identifiable {
        /// The reason a rectangle is reserved. Both kinds subtract their entire frame.
        public enum Kind: Hashable, Codable, Sendable {
            /// An overlay or hardware feature covering part of the surface.
            case occlusion
            /// A gap or fold dividing the surface into separate areas.
            case division
        }

        /// The caller-provided identity of this reservation.
        public let id: String
        /// The reason this rectangle is reserved.
        public let kind: Kind
        /// The reserved rectangle in local surface points; geometry initialization clips it.
        public let frame: CGRect
        /// Whether this reservation participates in the default usable geometry.
        public let isActive: Bool

        /// Creates a reservation. Null or infinite rectangles, nonfinite components,
        /// or nonpositive dimensions produce a zero frame; negative dimensions
        /// are never standardized.
        public init(id: String, kind: Kind, frame: CGRect, isActive: Bool = true) {
            self.id = id
            self.kind = kind
            self.frame = GameSurfaceGeometry.validRectangle(frame) ? frame : .zero
            self.isActive = isActive
        }
    }

    /// The surface size in points; each invalid dimension is replaced with zero.
    public let size: CGSize
    /// Pixels per point, or one when the supplied scale is nonfinite or nonpositive.
    public let displayScale: CGFloat
    /// Sanitized safe-area distances. Oversized distances are clamped when resolving safe bounds.
    public let safeAreaInsets: Insets
    /// Reservations clipped to the surface and sorted by ID, kind (occlusion first),
    /// frame (y, x, width, height), and activity (inactive first). Query order cannot
    /// change geometry equality. Invalid, empty, or outside frames remain zero rectangles.
    public let reservedRegions: [ReservedRegion]

    /// Creates finite surface geometry without requiring valid input geometry.
    /// Invalid size dimensions become zero, invalid scale becomes one, and invalid
    /// insets become zero. Reservation frames are clipped before any subtraction.
    /// - Complexity: O(n log n) time and O(n) space for n reservations.
    public init(size: CGSize, displayScale: CGFloat = 1, safeAreaInsets: Insets = .init(),
                reservedRegions: [ReservedRegion] = []) {
        let size = CGSize(width: Self.nonnegative(size.width), height: Self.nonnegative(size.height))
        self.size = size
        self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        self.safeAreaInsets = Insets(top: safeAreaInsets.top, left: safeAreaInsets.left,
                                     bottom: safeAreaInsets.bottom, right: safeAreaInsets.right)
        self.reservedRegions = reservedRegions.map {
            ReservedRegion(id: $0.id, kind: $0.kind, frame: Self.clip($0.frame, to: size), isActive: $0.isActive)
        }.sorted(by: Self.reservationOrdered)
    }

    /// The complete surface rectangle, whose origin is always zero.
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// The inset surface. Top and left distances are clamped first, then bottom
    /// and right consume only the remaining space, so dimensions never become negative.
    public var safeBounds: CGRect {
        let left = min(safeAreaInsets.left, size.width)
        let top = min(safeAreaInsets.top, size.height)
        let width = size.width - left
        let height = size.height - top
        return CGRect(x: left, y: top, width: width - min(safeAreaInsets.right, width),
                      height: height - min(safeAreaInsets.bottom, height))
    }

    /// Returns nonempty, nonoverlapping rectangles remaining inside the safe area.
    /// Reservations are processed in canonical y, x, width, height order, independent
    /// of declaration order. Each cut emits full-width top/bottom strips and left/right
    /// strips beside the intersection. Results are sorted by y, then x, width, height;
    /// adjacent fragments are not merged. Zero-area reservations do not divide space.
    /// - Parameter includingInactive: Whether inactive reservations should also subtract space.
    /// - Complexity: O(r log r + r f + f log f) time and O(r + f) space, where r is
    ///   the reservation count and f is the maximum intermediate fragment count.
    public func usableRegions(includingInactive: Bool = false) -> [CGRect] {
        guard !safeBounds.isEmpty else { return [] }
        let reservations = reservedRegions.filter { (includingInactive || $0.isActive) && !$0.frame.isEmpty }
            .map(\.frame).sorted(by: Self.ordered)
        var rectangles = [safeBounds]
        for reservation in reservations {
            rectangles = rectangles.flatMap { Self.subtract(reservation, from: $0) }
        }
        return rectangles.sorted(by: Self.ordered)
    }

    /// The usable rectangle with greatest area, or zero if none remains.
    /// Equal areas retain the first rectangle in the deterministic usable-region order.
    /// - Complexity: Recomputes ``usableRegions(includingInactive:)``, then scans its
    ///   result in O(f) time; it has the same overall time and space complexity.
    public var largestUsableRegion: CGRect {
        var largest = CGRect.zero
        for rectangle in usableRegions() where Self.hasGreaterArea(rectangle, than: largest) {
            largest = rectangle
        }
        return largest
    }

    /// Resolves a selector using active reservations. Missing usable indices return zero.
    /// - Complexity: O(1) for surface and safe-area selectors. Other selectors recompute
    ///   ``usableRegions(includingInactive:)`` and have its time and space complexity.
    public func rect(for region: GameSurfaceRegion) -> CGRect {
        switch region {
        case .surface: return bounds
        case .safeArea: return safeBounds
        case .largestUsable: return largestUsableRegion
        case .usable(let index):
            guard index >= 0 else { return .zero }
            let rectangles = usableRegions()
            return index < rectangles.count ? rectangles[index] : .zero
        }
    }

    /// Places a control wholly inside one usable rectangle, or returns nil if no rectangle fits.
    /// The normalized anchor specifies its desired center in the complete surface bounds.
    /// Each finite anchor component is clamped to 0...1; nonfinite components become 0.5.
    /// For each fitting rectangle, the control's center is clamped to keep its full size
    /// inside that rectangle. The placement with the smallest squared center distance
    /// to the requested anchor wins; ties use usable-region order. A common distance
    /// scale avoids overflow without changing the metric. Sizes must be finite and positive.
    /// - Complexity: Recomputes ``usableRegions(includingInactive:)``, then scans its
    ///   result in O(f) time; it has the same overall time and space complexity.
    public func placement(of size: CGSize, anchor: SIMD2<Double> = [0.5, 0.5],
                          includingInactive: Bool = false) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let target = CGPoint(x: Self.unitAnchor(anchor.x) * self.size.width,
                             y: Self.unitAnchor(anchor.y) * self.size.height)
        let distanceScale = max(self.size.width, self.size.height)
        var nearest: CGRect?
        var nearestDistance = CGFloat.infinity
        for rectangle in usableRegions(includingInactive: includingInactive)
            where size.width <= rectangle.width && size.height <= rectangle.height {
            let origin = CGPoint(
                x: min(max(target.x - size.width / 2, rectangle.minX), rectangle.maxX - size.width),
                y: min(max(target.y - size.height / 2, rectangle.minY), rectangle.maxY - size.height)
            )
            let dx = (origin.x + size.width / 2 - target.x) / distanceScale
            let dy = (origin.y + size.height / 2 - target.y) / distanceScale
            let distance = dx * dx + dy * dy
            if nearest == nil || distance < nearestDistance {
                nearest = CGRect(origin: origin, size: size)
                nearestDistance = distance
            }
        }
        return nearest
    }

    private static func nonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    private static func unitAnchor(_ value: Double) -> CGFloat {
        value.isFinite ? CGFloat(min(1, max(0, value))) : 0.5
    }

    private static func validRectangle(_ rectangle: CGRect) -> Bool {
        !rectangle.isNull && !rectangle.isInfinite
            && rectangle.origin.x.isFinite && rectangle.origin.y.isFinite
            && rectangle.size.width.isFinite && rectangle.size.height.isFinite
            && rectangle.size.width > 0 && rectangle.size.height > 0
    }

    private static func clip(_ rectangle: CGRect, to size: CGSize) -> CGRect {
        guard validRectangle(rectangle), size.width > 0, size.height > 0,
              let x = clippedAxis(rectangle.origin.x, length: rectangle.size.width, limit: size.width),
              let y = clippedAxis(rectangle.origin.y, length: rectangle.size.height, limit: size.height)
        else { return .zero }
        return CGRect(x: x.lowerBound, y: y.lowerBound,
                      width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }

    private static func clippedAxis(_ origin: CGFloat, length: CGFloat, limit: CGFloat) -> Range<CGFloat>? {
        guard origin < limit else { return nil }
        let start = max(0, origin)
        // Opposite-signed addition cannot overflow. For positive origins, cap the
        // length before addition instead of forming a potentially infinite endpoint.
        let end = origin < 0 ? min(limit, origin + length) : min(limit, origin + min(length, limit - origin))
        return end > start ? start..<end : nil
    }

    private static func ordered(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        return lhs.height < rhs.height
    }

    private static func reservationOrdered(_ lhs: ReservedRegion, _ rhs: ReservedRegion) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.kind != rhs.kind { return lhs.kind == .occlusion }
        if lhs.frame != rhs.frame { return ordered(lhs.frame, rhs.frame) }
        return !lhs.isActive && rhs.isActive
    }

    private static func subtract(_ reservation: CGRect, from rectangle: CGRect) -> [CGRect] {
        let left = max(rectangle.minX, reservation.minX)
        let top = max(rectangle.minY, reservation.minY)
        let right = min(rectangle.maxX, reservation.maxX)
        let bottom = min(rectangle.maxY, reservation.maxY)
        guard right > left, bottom > top else { return [rectangle] }
        return [
            CGRect(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: top - rectangle.minY),
            CGRect(x: rectangle.minX, y: bottom, width: rectangle.width, height: rectangle.maxY - bottom),
            CGRect(x: rectangle.minX, y: top, width: left - rectangle.minX, height: bottom - top),
            CGRect(x: right, y: top, width: rectangle.maxX - right, height: bottom - top)
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private static func hasGreaterArea(_ lhs: CGRect, than rhs: CGRect) -> Bool {
        guard !rhs.isEmpty else { return !lhs.isEmpty }
        // Compare products by exponent/significand so finite dimensions can have
        // distinguishable areas even when their direct products would overflow.
        func area(_ rectangle: CGRect) -> (exponent: Int, significand: CGFloat) {
            let product = rectangle.width.significand * rectangle.height.significand
            let adjustment = product >= 2 ? 1 : 0
            return (rectangle.width.exponent + rectangle.height.exponent + adjustment,
                    adjustment == 1 ? product / 2 : product)
        }
        let a = area(lhs), b = area(rhs)
        return a.exponent == b.exponent ? a.significand > b.significand : a.exponent > b.exponent
    }
}

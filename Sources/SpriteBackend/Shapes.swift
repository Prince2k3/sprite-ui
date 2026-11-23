import CoreGraphics
import ECSCore
import SwiftUI

/// A serializable path in local scene coordinates, with nonzero winding for fills.
/// Begin each contour with move(to:). Curves and multiple contours are preserved
/// when loading shape nodes from an .sks file. Open contours are implicitly closed
/// for filling, and remain open for stroking.
public struct VectorPath: Hashable, Codable, Sendable {
    public enum Element: Hashable, Codable, Sendable {
        case move(to: SIMD2<Float>)
        case line(to: SIMD2<Float>)
        case quadCurve(to: SIMD2<Float>, control: SIMD2<Float>)
        case curve(to: SIMD2<Float>, control1: SIMD2<Float>, control2: SIMD2<Float>)
        case close
    }
    public var elements: [Element]
    public init(elements: [Element] = []) { self.elements = elements }
    public mutating func move(to point: SIMD2<Float>) { elements.append(.move(to: point)) }
    public mutating func addLine(to point: SIMD2<Float>) { elements.append(.line(to: point)) }
    public mutating func addQuadCurve(to point: SIMD2<Float>, control: SIMD2<Float>) { elements.append(.quadCurve(to: point, control: control)) }
    public mutating func addCurve(to point: SIMD2<Float>, control1: SIMD2<Float>, control2: SIMD2<Float>) { elements.append(.curve(to: point, control1: control1, control2: control2)) }
    public mutating func closeSubpath() { elements.append(.close) }

    var native: CGPath? {
        let path = CGMutablePath()
        var started = false
        func point(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
        func finite(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
        for element in elements {
            switch element {
            case .move(let p):
                guard finite(p) else { return nil }; path.move(to: point(p)); started = true
            case .line(let p):
                guard finite(p) else { return nil }; if started { path.addLine(to: point(p)) }
            case .quadCurve(let p, let c):
                guard finite(p), finite(c) else { return nil }; if started { path.addQuadCurve(to: point(p), control: point(c)) }
            case .curve(let p, let c1, let c2):
                guard finite(p), finite(c1), finite(c2) else { return nil }
                if started { path.addCurve(to: point(p), control1: point(c1), control2: point(c2)) }
            case .close: if started { path.closeSubpath() }
            }
        }
        return path.copy()
    }

    init(_ path: CGPath) {
        elements = []
        path.applyWithBlock { element in
            let e = element.pointee
            func p(_ i: Int) -> SIMD2<Float> { [Float(e.points[i].x), Float(e.points[i].y)] }
            switch e.type {
            case .moveToPoint: elements.append(.move(to: p(0)))
            case .addLineToPoint: elements.append(.line(to: p(0)))
            case .addQuadCurveToPoint: elements.append(.quadCurve(to: p(1), control: p(0)))
            case .addCurveToPoint: elements.append(.curve(to: p(2), control1: p(0), control2: p(1)))
            case .closeSubpath: elements.append(.close)
            @unknown default: break
            }
        }
    }
}

/// A local outline. Primitives are centered at the entity's origin; custom paths
/// keep their authored coordinates. Invalid/nonfinite dimensions draw nothing.
public enum ShapeGeometry: Hashable, Codable, Sendable {
    case circle(radius: Float)
    case rectangle(size: SIMD2<Float>)
    case roundedRectangle(size: SIMD2<Float>, cornerRadius: Float)
    case ellipse(size: SIMD2<Float>)
    case path(VectorPath)

    var native: CGPath? {
        if case .path(let path) = self { return path.native }
        let size: SIMD2<Float>
        switch self {
        case .circle(let radius): size = [radius * 2, radius * 2]
        case .rectangle(let value), .roundedRectangle(let value, _), .ellipse(let value): size = value
        case .path: return nil
        }
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0 else { return nil }
        let rect = CGRect(x: -CGFloat(size.x) / 2, y: -CGFloat(size.y) / 2, width: CGFloat(size.x), height: CGFloat(size.y))
        switch self {
        case .circle, .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        case .roundedRectangle(_, let radius):
            let corner = radius.isFinite ? max(0, min(CGFloat(radius), min(rect.width, rect.height) / 2)) : 0
            return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        default: return CGPath(rect: rect, transform: nil)
        }
    }
}

/// A live vector shape with independent fill and stroke. Uses SpriteKit's shape
/// renderer; for large repeated decorations, prefer shared sprite textures.
/// Hit tests include the fill and stroke, excluding transparent interiors and glow.
/// Explicit collision components override visual hit testing. No physics body is
/// generated automatically. Geometry/style edits are immediate; transforms and
/// opacity animate with withAnimation.
public struct ShapeComponent: Component, Hashable, Codable, Sendable {
    public enum LineCap: String, Codable, Sendable { case butt, round, square }
    public enum LineJoin: String, Codable, Sendable { case miter, round, bevel }
    public var geometry: ShapeGeometry
    public var fill: Color
    public var stroke: Color
    /// Nonnegative scene points. Nonfinite values render as zero.
    public var lineWidth: Float
    public var glowWidth: Float
    public var lineCap: LineCap
    public var lineJoin: LineJoin
    public var miterLimit: Float
    public var isAntialiased: Bool
    public var opacity: Float
    public var blendMode: SpriteBlendMode

    public init(_ geometry: ShapeGeometry, fill: Color = .clear, stroke: Color = .white, lineWidth: Float = 1,
                glowWidth: Float = 0, lineCap: LineCap = .butt, lineJoin: LineJoin = .miter, miterLimit: Float = 10,
                isAntialiased: Bool = true, opacity: Float = 1, blendMode: SpriteBlendMode = .alpha) {
        self.geometry = geometry; self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth; self.glowWidth = glowWidth
        self.lineCap = lineCap; self.lineJoin = lineJoin; self.miterLimit = miterLimit
        self.isAntialiased = isAntialiased; self.opacity = opacity; self.blendMode = blendMode
    }

    private enum CodingKeys: String, CodingKey { case geometry, fill, stroke, lineWidth, glowWidth, lineCap, lineJoin, miterLimit, isAntialiased, opacity, blendMode }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(ShapeGeometry.self, forKey: .geometry), fill: try c.decodeColor(forKey: .fill), stroke: try c.decodeColor(forKey: .stroke),
                  lineWidth: try c.decode(Float.self, forKey: .lineWidth), glowWidth: try c.decode(Float.self, forKey: .glowWidth),
                  lineCap: try c.decode(LineCap.self, forKey: .lineCap), lineJoin: try c.decode(LineJoin.self, forKey: .lineJoin),
                  miterLimit: try c.decode(Float.self, forKey: .miterLimit), isAntialiased: try c.decode(Bool.self, forKey: .isAntialiased),
                  opacity: try c.decode(Float.self, forKey: .opacity), blendMode: try c.decode(SpriteBlendMode.self, forKey: .blendMode))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(geometry, forKey: .geometry); try c.encode(color: fill, forKey: .fill); try c.encode(color: stroke, forKey: .stroke)
        try c.encode(lineWidth, forKey: .lineWidth); try c.encode(glowWidth, forKey: .glowWidth); try c.encode(lineCap, forKey: .lineCap)
        try c.encode(lineJoin, forKey: .lineJoin); try c.encode(miterLimit, forKey: .miterLimit); try c.encode(isAntialiased, forKey: .isAntialiased)
        try c.encode(opacity, forKey: .opacity); try c.encode(blendMode, forKey: .blendMode)
    }
}

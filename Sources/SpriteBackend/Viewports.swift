import ECSCore
import Foundation
import SpriteKit

/// A normalized rectangle measured from the surface's top-left corner.
/// Rectangles are intersected with the surface. Nonfinite or nonpositive sizes
/// produce an empty rectangle rather than a drawable or interactive region.
public struct ViewportRect: Hashable, Codable, Sendable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float
    public init(x: Float, y: Float, width: Float, height: Float) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
            self.x = 0; self.y = 0; self.width = 0; self.height = 0
            return
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case x, y, width, height }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decode(Float.self, forKey: .x), y: try c.decode(Float.self, forKey: .y),
                  width: try c.decode(Float.self, forKey: .width), height: try c.decode(Float.self, forKey: .height))
    }
    public static let full = Self(x: 0, y: 0, width: 1, height: 1)
    public func rect(in size: CGSize) -> CGRect {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .zero }
        let left = max(0, min(1, Double(x)))
        let top = max(0, min(1, Double(y)))
        let right = max(0, min(1, Double(x) + Double(width)))
        let bottom = max(0, min(1, Double(y) + Double(height)))
        guard right > left, bottom > top else { return .zero }
        return CGRect(x: left * size.width, y: top * size.height,
                      width: (right - left) * size.width, height: (bottom - top) * size.height)
    }
}

/// One camera view into a shared world. IDs belong to the containing GameView;
/// they distinguish input captures and attachment instances, not world entities.
public struct GameViewport: Identifiable, Hashable, Sendable {
    public let id: String
    /// Nil uses the world's selected/automatic camera, or the origin without one.
    /// An explicit missing, disabled or inactive camera makes this view unavailable.
    public var camera: Entity.ID?
    public var frame: ViewportRect
    /// A noninteractive view still blocks input to any view underneath it.
    public var isInteractive: Bool
    /// Optionally narrows the selected camera's culling mask. Never broadens it.
    public var cullingMask: RenderLayer?
    public init(id: String, camera: Entity.ID? = nil, frame: ViewportRect = .full,
                isInteractive: Bool = true, cullingMask: RenderLayer? = nil) {
        self.id = id; self.camera = camera; self.frame = frame; self.isInteractive = isInteractive
        self.cullingMask = cullingMask
    }
}

extension SpriteRenderer {
    private var viewportCanvasSize: CGSize { viewportRenderSurfaceSize ?? size }
    /// Views with usable geometry and cameras, in drawing order. Empty IDs and
    /// duplicate IDs are ignored (the first declaration wins). An empty configured
    /// list supplies a full-surface view named `main` for legacy compatibility.
    public var resolvedViewports: [GameViewport] {
        let declared = viewports.isEmpty ? [GameViewport(id: "main")] : viewports
        var seen: Set<String> = []
        return declared.filter { viewport in
            guard !viewport.id.isEmpty, seen.insert(viewport.id).inserted,
                  !viewport.frame.rect(in: viewportCanvasSize).isEmpty else { return false }
            return viewport.camera == nil || viewportCamera(viewport) != nil
        }
    }

    /// Finds the front-most view under a global top-left surface point. Gaps and
    /// noninteractive overlays never pass a gameplay hit to an underlying view.
    public func viewport(at point: CGPoint, interactiveOnly: Bool = true) -> GameViewport? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard let viewport = resolvedViewports.reversed().first(where: { $0.frame.rect(in: viewportCanvasSize).contains(point) }) else { return nil }
        return !interactiveOnly || viewport.isInteractive ? viewport : nil
    }

    public func viewportRect(id: String) -> CGRect? {
        resolvedViewports.first { $0.id == id }?.frame.rect(in: viewportCanvasSize)
    }

    /// Converts global surface points through a specific presented camera. Points
    /// outside the rectangle are allowed so a captured drag can cross a split
    /// without switching cameras. A disappeared view/camera returns nil.
    public func scenePoint(fromView point: CGPoint, inViewport id: String) -> SIMD2<Float>? {
        guard point.x.isFinite, point.y.isFinite,
              let viewport = resolvedViewports.first(where: { $0.id == id }) else { return nil }
        let frame = viewport.frame.rect(in: viewportCanvasSize)
        var native = CGPoint(x: point.x - frame.midX, y: frame.midY - point.y)
        if let camera = viewportCamera(viewport) { native = camera.convert(native, to: self) }
        let result = SIMD2(Float(native.x), Float(native.y))
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    /// Projects into global top-left surface coordinates. The result can fall
    /// outside its view; overlays must clip against `viewportRect(id:)`.
    public func viewPoint(from point: SIMD2<Float>, relativeTo entity: Entity? = nil,
                          inViewport id: String) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              let viewport = resolvedViewports.first(where: { $0.id == id }) else { return nil }
        var native = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        if let entity {
            guard entity.world === world, let node = node(for: entity) else { return nil }
            native = node.convert(native, to: self)
        }
        if let camera = viewportCamera(viewport) { native = camera.convert(native, from: self) }
        let frame = viewport.frame.rect(in: viewportCanvasSize)
        let result = CGPoint(x: native.x + frame.midX, y: frame.midY - native.y)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    /// Native render scope. Rendering selects a camera and logical point size
    /// without advancing the world, changing the audio listener, or writing ECS
    /// components. The caller encodes a draw, not another scene update.
    @_spi(Backend) public func renderViewport<T>(_ id: String, _ body: () -> T) -> T? {
        guard let viewport = resolvedViewports.first(where: { $0.id == id }) else { return nil }
        let oldSize = size, oldCamera = camera
        let oldSurfaceSize = viewportRenderSurfaceSize
        let oldBackground = backgroundContext
        let selected = viewportCamera(viewport)
        let frame = viewport.frame.rect(in: viewportCanvasSize)
        defer {
            restoreBackgroundPresentation()
            size = oldSize; camera = oldCamera; viewportRenderSurfaceSize = oldSurfaceSize
            if let oldBackground { applyBackgroundPresentation(camera: oldBackground.camera, size: oldBackground.size) }
        }
        viewportRenderSurfaceSize = viewportCanvasSize
        size = frame.size
        camera = selected
        return withRenderVisibility(visibilityMask(inViewport: id) ?? .none) {
            applyBackgroundPresentation(camera: selected, size: frame.size)
            return body()
        }
    }

    /// A camera used in multiple views follows/clamps using the first declared
    /// usable rectangle. Every camera's smoothing and shake advances once per frame.
    func viewportSize(for camera: Entity) -> SIMD2<Float> {
        let viewport = resolvedViewports.first { ($0.camera ?? activeCamera?.id) == camera.id }
        let dimensions = viewport?.frame.rect(in: viewportCanvasSize).size ?? viewportCanvasSize
        return [Float(dimensions.width), Float(dimensions.height)]
    }

    private func viewportCamera(_ viewport: GameViewport) -> SKCameraNode? {
        let entity: Entity?
        if let id = viewport.camera {
            entity = world.entity(withID: id).flatMap {
                $0.isActive && $0.components[CameraComponent.self]?.isActive == true ? $0 : nil
            }
        } else { entity = activeCamera }
        return entity.flatMap { node(for: $0)?.childNode(withName: Self.cameraNodeName) as? SKCameraNode }
    }
}

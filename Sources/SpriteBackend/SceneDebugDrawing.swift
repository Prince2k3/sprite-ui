import ECSCore
import Foundation
import SpriteKit

extension SpriteRenderer {
    func removeDebugLayer() {
        debugLayer?.removeFromParent(); debugLayer = nil; debugDrawNodes.removeAll()
    }

    /// Geometry is batched by color into at most seven private path nodes. The
    /// layer is a scene child, never an entity child or part of a cropped subtree.
    func updateDebugDrawing(entities: [Entity], selected: Entity?, options: SceneDebugOptions) {
        var paths: [String: CGMutablePath] = [:]
        let cameraMatrix = camera.map { displayedCollisionMatrix(for: $0) }
        let units = CGFloat(max(0.01, min(1000, cameraMatrix.map { hypot($0.a, $0.b) } ?? 1)))
        func path(_ key: String) -> CGMutablePath {
            if let existing = paths[key] { return existing }
            let result = CGMutablePath(); paths[key] = result; return result
        }
        func finite(_ point: SIMD2<Float>) -> Bool { point.x.isFinite && point.y.isFinite }
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, key: String) {
            guard finite(a), finite(b) else { return }
            path(key).move(to: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
            path(key).addLine(to: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
        }
        func append(_ outline: CGPath, matrix: AffineTransform2D, key: String) {
            guard matrix.inverted() != nil else { return }
            var transform = CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b), c: CGFloat(matrix.c),
                                              d: CGFloat(matrix.d), tx: CGFloat(matrix.tx), ty: CGFloat(matrix.ty))
            guard let transformed = outline.copy(using: &transform) else { return }
            let box = transformed.boundingBoxOfPath
            guard [box.minX, box.minY, box.maxX, box.maxY].allSatisfy({ Float($0).isFinite }) else { return }
            path(key).addPath(transformed)
        }
        func circle(_ center: SIMD2<Float>, radius: CGFloat, key: String) {
            guard finite(center), radius.isFinite, radius > 0 else { return }
            append(CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil),
                   matrix: .init(tx: center.x, ty: center.y), key: key)
        }
        func targetFrame(_ target: ConstraintTarget, owner: Entity) -> AffineTransform2D? {
            switch target {
            case .entity(let id): return world.entity(withID: id).flatMap { node(for: $0) }.map(displayedCollisionMatrix)
            case .named(let name): return world.root.findEntity(named: name).flatMap { node(for: $0) }.map(displayedCollisionMatrix)
            case .point(let point, let space):
                var matrix = space == .parent ? presentedSceneMatrix(of: owner.parent) : .identity
                let point = matrix.apply(to: point); matrix.tx = point.x; matrix.ty = point.y; return matrix
            }
        }
        for entity in entities.dropFirst() where entity.isActive {
            guard let node = node(for: entity) else { continue }
            let matrix = displayedCollisionMatrix(for: node), origin = matrix.apply(to: .zero)
            guard matrix.inverted() != nil else { continue }
            if options.contains(.origins) {
                line(origin, matrix.apply(to: [14, 0]), key: "x")
                line(origin, matrix.apply(to: [0, 14]), key: "y")
            }
            if options.contains(.collisionShapes), let collider = entity.queryCollider, collider.isEnabled,
               let shape = debugCollisionPath(collider.shape) {
                append(shape, matrix: matrix * AffineTransform2D(tx: collider.offset.x, ty: collider.offset.y), key: "collision")
            }
            if options.contains(.bounds) {
                for bounds in debugVisualBounds(node) {
                    append(CGPath(rect: bounds, transform: nil), matrix: matrix, key: "bounds")
                }
            }
            if options.contains(.joints), let geometry = debugJointAnchors(for: entity) {
                line(geometry.0, geometry.1, key: "joints")
                circle(geometry.0, radius: 4 * units, key: "joints")
                circle(geometry.1, radius: 4 * units, key: "joints")
            }
            if options.contains(.constraintTargets), let model = entity.components[TransformConstraintComponent.self], model.isEnabled {
                for rule in model.constraints where rule.isEnabled && rule.behavior.isValid {
                    switch rule.behavior {
                    case .follow(let target, let offset, let space, _):
                        if let frame = targetFrame(target, owner: entity) {
                            let point = SIMD2(frame.tx, frame.ty) + (space == .target ? frame.apply(toDirection: offset) : offset)
                            line(origin, point, key: "constraints"); circle(point, radius: 4 * units, key: "constraints")
                        }
                    case .lookAt(let target, _, _), .distance(let target, _):
                        if let frame = targetFrame(target, owner: entity) {
                            let point = SIMD2(frame.tx, frame.ty)
                            line(origin, point, key: "constraints"); circle(point, radius: 4 * units, key: "constraints")
                        }
                    case .positionBounds(let min, let max, let space):
                        let rect = CGRect(x: CGFloat(min.x), y: CGFloat(min.y), width: CGFloat(max.x) - CGFloat(min.x), height: CGFloat(max.y) - CGFloat(min.y))
                        append(CGPath(rect: rect, transform: nil), matrix: space == .parent ? presentedSceneMatrix(of: entity.parent) : .identity, key: "constraints")
                    case .rotationLimits(let limits, let space):
                        let frame = space == .parent ? presentedSceneMatrix(of: entity.parent) : .identity
                        for angle in [limits.lowerBound, limits.upperBound] {
                            line(origin, origin + frame.apply(toDirection: [cos(angle), sin(angle)]) * Float(24 * units), key: "constraints")
                        }
                    }
                }
            }
        }
        if options.contains(.selection), let selected, let node = node(for: selected) {
            let matrix = displayedCollisionMatrix(for: node)
            let bounds = debugVisualBounds(node)
            for box in bounds { append(CGPath(rect: box.insetBy(dx: -3 * units, dy: -3 * units), transform: nil), matrix: matrix, key: "selection") }
            if let collider = selected.queryCollider, let outline = debugCollisionPath(collider.shape) {
                append(outline, matrix: matrix * AffineTransform2D(tx: collider.offset.x, ty: collider.offset.y), key: "selection")
            }
            circle(matrix.apply(to: .zero), radius: 9 * units, key: "selection")
        }
        guard !paths.isEmpty else { removeDebugLayer(); return }
        if debugLayer == nil {
            let layer = SKNode(); layer.name = "__sceneDebug"; layer.zPosition = 1_000_000_000
            addChild(layer); debugLayer = layer
        }
        for key in Array(debugDrawNodes.keys) where paths[key] == nil { debugDrawNodes.removeValue(forKey: key)?.removeFromParent() }
        let colors: [String: SKColor] = ["x": .red, "y": .green, "collision": .cyan, "bounds": .gray,
                                        "joints": .yellow, "constraints": .magenta, "selection": .white]
        for (key, outline) in paths {
            let drawing: SKShapeNode
            if let existing = debugDrawNodes[key] { drawing = existing }
            else {
                drawing = SKShapeNode(); drawing.name = "__debug.\(key)"; drawing.fillColor = .clear
                drawing.strokeColor = colors[key] ?? .white; drawing.isAntialiased = true
                drawing.zPosition = key == "selection" ? 1 : 0
                debugLayer?.addChild(drawing); debugDrawNodes[key] = drawing
            }
            drawing.lineWidth = (key == "selection" ? 2 : 1) * units; drawing.path = outline
        }
    }
}

/// Own visual bounds only: descendants have independent outlines. Native bounds
/// include the visual's anchor/stroke but not ancestor clipping or filter halos.
@MainActor private func debugVisualBounds(_ entityNode: SKNode) -> [CGRect] {
    let content = SpriteRenderer.contentRoot(entityNode)
    let names: Set<String> = ["__sprite", "__text", "__shape", "__tilemap"]
    return content.children.compactMap { child in
        guard let name = child.name, names.contains(name) else { return nil }
        let bounds = child.calculateAccumulatedFrame()
        guard !bounds.isNull, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        return bounds
    }
}

private func debugCollisionPath(_ shape: CollisionShape) -> CGPath? {
    guard shape.isValid else { return nil }
    switch shape {
    case .circle(let radius):
        let r = CGFloat(radius); return CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
    case .rectangle(let size): return CGPath(rect: CGRect(x: -CGFloat(size.x) / 2, y: -CGFloat(size.y) / 2, width: CGFloat(size.x), height: CGFloat(size.y)), transform: nil)
    case .polygon(let points), .edgeLoop(let points), .edgeChain(let points):
        let path = CGMutablePath(); path.addLines(between: points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        if case .edgeChain = shape {} else { path.closeSubpath() }
        return path
    }
}

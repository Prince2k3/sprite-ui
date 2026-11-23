import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#else
import AppKit
private typealias PlatformFont = NSFont
#endif

@MainActor @Suite struct TextShapeTests {
    private func content(_ label: SKLabelNode) -> String? {
        label.attributedText?.string ?? label.text
    }

    private func colorsMatch(_ a: Color, _ b: Color) -> Bool {
        zip(ColorCoding.components(of: a), ColorCoding.components(of: b)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    private func color(_ native: SKColor) -> Color {
        #if canImport(UIKit)
        Color(uiColor: native)
        #else
        Color(nsColor: native)
        #endif
    }

    @Test func systemFontUsesTheActualPlatformFontAndIsHittable() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: TextComponent("System caption", font: .system(size: 28, weight: .bold)), InputTargetComponent())
        world.addEntity(entity); renderer.flush()
        let root = try #require(renderer.node(for: entity))
        let label = try #require(root.childNode(withName: "__text") as? SKLabelNode)
        let attributed = try #require(label.attributedText)
        let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        let expected = PlatformFont.systemFont(ofSize: 28, weight: .bold)
        #expect(attributed.string == "System caption")
        #expect(font.fontName == expected.fontName && abs(font.pointSize - 28) < 0.001)
        let foreground = try #require(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? SKColor)
        #expect(colorsMatch(color(foreground), .white))
        #expect(!label.frame.isEmpty)
        let point = root.convert(CGPoint(x: label.frame.midX, y: label.frame.midY), to: renderer)
        #expect(renderer.inputTarget(at: point) === entity)
    }

    @Test func labelLayoutEditsAndRemovalPreserveRootChildrenAndPhysics() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let bodyValue = PhysicsBodyComponent(shape: .circle(radius: 7), affectedByGravity: false, velocity: [3, 4])
        let entity = Entity(components: TextComponent("First caption", font: .named("Helvetica", size: 18), color: .cyan,
            horizontalAlignment: .left, verticalAlignment: .top, maxWidth: 120, numberOfLines: 2,
            lineBreak: .truncateTail, opacity: 0.75, blendMode: .add), bodyValue)
        let child = Entity(name: "authored-child"); child.position = [4, 9]; entity.addChild(child)
        world.addEntity(entity); renderer.flush()
        let root = try #require(renderer.node(for: entity)), body = try #require(root.physicsBody)
        let childNode = try #require(renderer.node(for: child))
        let label = try #require(root.childNode(withName: "__text") as? SKLabelNode)
        #expect(content(label) == "First caption")
        #expect(label.horizontalAlignmentMode == .left && label.verticalAlignmentMode == .top)
        #expect(label.preferredMaxLayoutWidth == 120 && label.numberOfLines == 2 && label.lineBreakMode == .byTruncatingTail)
        #expect(label.alpha == 0.75 && label.blendMode == .add && label.physicsBody == nil)
        entity.components.set(TextComponent("Edited caption", font: .system(size: 22, weight: .medium), color: .orange,
            horizontalAlignment: .right, verticalAlignment: .bottom, maxWidth: 80, numberOfLines: 0, lineBreak: .characterWrap))
        renderer.flush()
        #expect(root.childNode(withName: "__text") === label && renderer.node(for: entity) === root)
        #expect(content(label) == "Edited caption")
        #expect(label.horizontalAlignmentMode == .right && label.verticalAlignmentMode == .bottom)
        #expect(label.preferredMaxLayoutWidth == 80 && label.numberOfLines == 0 && label.lineBreakMode == .byCharWrapping)
        entity.components.remove(TextComponent.self); renderer.flush()
        #expect(root.childNode(withName: "__text") == nil && label.parent == nil)
        #expect(renderer.node(for: entity) === root && root.physicsBody === body)
        #expect(childNode.parent === root && childNode.position == CGPoint(x: 4, y: 9))
        #expect(entity.components[PhysicsBodyComponent.self] == bodyValue)
    }

    private func curvedPath() -> VectorPath {
        var path = VectorPath()
        path.move(to: [5, 7]); path.addLine(to: [30, 7])
        path.addQuadCurve(to: [40, 20], control: [45, 7])
        path.addCurve(to: [5, 30], control1: [40, 45], control2: [5, 45])
        path.closeSubpath()
        return path
    }

    @Test func shapeCurvesCenteredPrimitivesAndStyleEditsPreserveNodes() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let path = curvedPath()
        let entity = Entity(components: ShapeComponent(.path(path), fill: .red, stroke: .blue,
            lineWidth: 4, glowWidth: 3, lineCap: .round, lineJoin: .bevel, miterLimit: 6,
            isAntialiased: false, opacity: 0.5, blendMode: .add))
        world.addEntity(entity); renderer.flush()
        let root = try #require(renderer.node(for: entity))
        let shape = try #require(root.childNode(withName: "__shape") as? SKShapeNode)
        #expect(VectorPath(try #require(shape.path)) == path)
        #expect(colorsMatch(color(shape.fillColor), .red) && colorsMatch(color(shape.strokeColor), .blue))
        #expect(shape.lineWidth == 4 && shape.glowWidth == 3 && shape.lineCap == .round && shape.lineJoin == .bevel)
        #expect(shape.miterLimit == 6 && !shape.isAntialiased && shape.alpha == 0.5 && shape.blendMode == .add)
        #expect(root.physicsBody == nil && shape.physicsBody == nil)
        let primitives: [(ShapeGeometry, CGRect)] = [
            (.circle(radius: 10), CGRect(x: -10, y: -10, width: 20, height: 20)),
            (.rectangle(size: [40, 20]), CGRect(x: -20, y: -10, width: 40, height: 20)),
            (.roundedRectangle(size: [40, 20], cornerRadius: 4), CGRect(x: -20, y: -10, width: 40, height: 20)),
            (.ellipse(size: [40, 20]), CGRect(x: -20, y: -10, width: 40, height: 20))
        ]
        for (geometry, bounds) in primitives {
            entity.components[ShapeComponent.self]?.geometry = geometry; renderer.flush()
            #expect(root.childNode(withName: "__shape") === shape)
            #expect(shape.path?.boundingBoxOfPath == bounds)
        }
        entity.components[ShapeComponent.self]?.fill = .green
        entity.components[ShapeComponent.self]?.lineCap = .square; renderer.flush()
        #expect(colorsMatch(color(shape.fillColor), .green) && shape.lineCap == .square)
        entity.components.remove(ShapeComponent.self); renderer.flush()
        #expect(shape.parent == nil && root.childNode(withName: "__shape") == nil)
        #expect(renderer.node(for: entity) === root && root.physicsBody == nil)
    }

    @Test func fillStrokeCapsAndContourWindingDetermineHitsWithoutGlow() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(name: "shape", components: ShapeComponent(.circle(radius: 20), fill: .clear,
            stroke: .white, lineWidth: 4, glowWidth: 20), InputTargetComponent())
        world.addEntity(entity); renderer.flush()
        #expect(renderer.entities(at: .zero).isEmpty)
        #expect(renderer.inputTarget(at: CGPoint(x: 20, y: 0)) === entity)
        #expect(renderer.entities(at: CGPoint(x: 28, y: 0)).isEmpty)
        entity.components[ShapeComponent.self]?.fill = .red; renderer.flush()
        #expect(renderer.inputTarget(at: .zero) === entity)

        var line = VectorPath(); line.move(to: [0, 0]); line.addLine(to: [20, 0])
        entity.components.set(ShapeComponent(.path(line), stroke: .white, lineWidth: 10, lineCap: .round))
        renderer.flush()
        #expect(renderer.inputTarget(at: CGPoint(x: -3, y: 0)) === entity)
        #expect(renderer.entities(at: CGPoint(x: -4, y: 4)).isEmpty)
        entity.components[ShapeComponent.self]?.lineCap = .butt; renderer.flush()
        #expect(renderer.entities(at: CGPoint(x: -3, y: 0)).isEmpty)

        // Opposite winding cuts a hole; matching winding fills the inner contour.
        for reversed in [true, false] {
            var contours = VectorPath()
            for points: [SIMD2<Float>] in [
                [[-30, -30], [30, -30], [30, 30], [-30, 30]],
                reversed ? [[-10, -10], [-10, 10], [10, 10], [10, -10]] : [[-10, -10], [10, -10], [10, 10], [-10, 10]]
            ] {
                contours.move(to: points[0])
                for point in points.dropFirst() { contours.addLine(to: point) }
                contours.closeSubpath()
            }
            entity.components.set(ShapeComponent(.path(contours), fill: .white, stroke: .clear)); renderer.flush()
            #expect(renderer.inputTarget(at: CGPoint(x: 20, y: 0)) === entity)
            #expect(renderer.entities(at: .zero).isEmpty == reversed)
        }
    }

    @Test func transformedCameraInputMixedVisualOrderingAndColliderPrecedence() throws {
        let world = World(), renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
        let camera = Entity(components: CameraComponent(zoom: 2)); camera.position = [100, 50]; world.addEntity(camera)
        let parent = Entity(components: InputTargetComponent())
        parent.position = [100, 50]; parent.rotation = .pi / 2; parent.scale = [2, 1]
        let shape = Entity(name: "shape", components: ShapeComponent(.rectangle(size: [12, 12]), fill: .white))
        shape.position = [10, 0]
        let text = Entity(name: "text", components: TextComponent("Hi", font: .system(size: 14)))
        text.position = [-10, 0]; parent.addChild(shape); parent.addChild(text); world.addEntity(parent); renderer.flush()
        for (viewPoint, target) in [(CGPoint(x: 100, y: 10), shape), (CGPoint(x: 100, y: 90), text)] {
            let point = renderer.scenePoint(fromView: viewPoint)
            #expect(renderer.inputTarget(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) === target)
        }
        let back = Entity(name: "back", components: ShapeComponent(.circle(radius: 10), fill: .red))
        back.position = [100, 70]; back.zPosition = 1; world.addEntity(back)
        shape.components.set(SpriteComponent(color: .blue, size: [10, 10]))
        shape.components.set(TextComponent("Mix", font: .system(size: 10))); shape.zPosition = 2; renderer.flush()
        #expect(renderer.entities(at: CGPoint(x: 100, y: 70)).map(\.name) == ["shape", "back"])
        let root = try #require(renderer.node(for: shape))
        root.childNode(withName: "__shape")?.zPosition = -5
        #expect(renderer.entities(at: CGPoint(x: 100, y: 70)).first === shape)

        shape.components.set(CollisionComponent(shape: .circle(radius: 2))); renderer.flush()
        #expect(!renderer.entities(at: CGPoint(x: 100, y: 78)).contains { $0 === shape })
        shape.components[CollisionComponent.self]?.isEnabled = false; renderer.flush()
        #expect(!renderer.entities(at: CGPoint(x: 100, y: 70)).contains { $0 === shape })
        shape.components.remove(CollisionComponent.self)
        parent.components.set(CollisionComponent(shape: .circle(radius: 3))); renderer.flush()
        #expect(renderer.entities(at: CGPoint(x: 100, y: 70)).map(\.name) == ["back"])
        #expect(renderer.inputTarget(at: CGPoint(x: 100, y: 50)) === parent)
        shape.components.set(CollisionComponent(shape: .circle(radius: 3))); renderer.flush()
        #expect(renderer.inputTarget(at: CGPoint(x: 100, y: 70)) === shape)
    }

    @Test func invalidDimensionsAndInvisibleTextDoNotHit() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: ShapeComponent(.circle(radius: 10), fill: .white))
        world.addEntity(entity)
        var invalidPath = VectorPath(); invalidPath.move(to: [0, 0]); invalidPath.addLine(to: [.nan, 5])
        for geometry: ShapeGeometry in [.circle(radius: -1), .circle(radius: .infinity), .rectangle(size: [0, 10]),
            .ellipse(size: [10, .nan]), .roundedRectangle(size: [-2, 4], cornerRadius: 1), .path(invalidPath), .path(VectorPath())] {
            entity.components[ShapeComponent.self]?.geometry = geometry; renderer.flush()
            let native = try #require(renderer.node(for: entity)?.childNode(withName: "__shape") as? SKShapeNode)
            #expect(native.path == nil || native.path?.isEmpty == true)
            #expect(renderer.entities(at: .zero).isEmpty)
        }
        entity.components.remove(ShapeComponent.self)
        for font: TextFont in [.system(size: 0), .system(size: -10), .system(size: .nan), .named("Helvetica", size: .infinity)] {
            entity.components.set(TextComponent("Invisible", font: font)); renderer.flush()
            #expect(renderer.entities(at: .zero).isEmpty)
        }
        for value in [TextComponent(""), TextComponent("Hidden", color: .clear), TextComponent("Hidden", opacity: 0),
                      TextComponent("Hidden", opacity: .nan)] {
            entity.components.set(value); renderer.flush()
            #expect(renderer.entities(at: .zero).isEmpty)
        }
        entity.components.set(TextComponent("Valid", font: .named("not-an-installed-font", size: 16),
            maxWidth: -.infinity, numberOfLines: -3)); renderer.flush()
        let label = try #require(renderer.node(for: entity)?.childNode(withName: "__text") as? SKLabelNode)
        #expect(content(label) == "Valid" && !label.frame.isEmpty)
        #expect(label.preferredMaxLayoutWidth == 0 && label.numberOfLines == 0)
    }

    @Test func opacityAndTransformsAnimateWhileFontLayoutAndGeometryApplyImmediately() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: TextComponent("Before"), ShapeComponent(.circle(radius: 10), fill: .red))
        world.addEntity(entity); renderer.flush()
        let root = try #require(renderer.node(for: entity))
        let label = try #require(root.childNode(withName: "__text") as? SKLabelNode)
        let shape = try #require(root.childNode(withName: "__shape") as? SKShapeNode)
        withAnimation(.linear(duration: 1)) {
            entity.position = [100, 20]; entity.rotation = 1; entity.scale = [2, 3]
            entity.components[TextComponent.self]?.opacity = 0.25
            entity.components[TextComponent.self]?.text = "After"
            entity.components[TextComponent.self]?.font = .system(size: 30, weight: .bold)
            entity.components[TextComponent.self]?.maxWidth = 80
            entity.components[ShapeComponent.self]?.opacity = 0.5
            entity.components[ShapeComponent.self]?.geometry = .rectangle(size: [40, 20])
            entity.components[ShapeComponent.self]?.fill = .blue
        }
        renderer.flush()
        #expect(label.action(forKey: "text.opacity") != nil && shape.action(forKey: "shape.opacity") != nil)
        #expect(root.action(forKey: "transform.position") != nil && root.action(forKey: "transform.rotation") != nil)
        #expect(root.action(forKey: "transform.scale") != nil)
        #expect(label.alpha == 1 && shape.alpha == 1 && root.position == .zero)
        #expect(entity.presentation[TextComponent.self]?.opacity == 1 && entity.presentation[ShapeComponent.self]?.opacity == 1)
        #expect(entity.presentation.position == .zero && entity.position == [100, 20])
        #expect(content(label) == "After" && label.preferredMaxLayoutWidth == 80)
        let attributed = try #require(label.attributedText)
        let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #expect(font.pointSize == 30)
        #expect(shape.path?.boundingBoxOfPath == CGRect(x: -20, y: -10, width: 40, height: 20))
        #expect(colorsMatch(color(shape.fillColor), .blue))
        entity.components[TextComponent.self]?.opacity = 0.75
        entity.components[ShapeComponent.self]?.opacity = 0.8; renderer.flush()
        #expect(label.action(forKey: "text.opacity") == nil && shape.action(forKey: "shape.opacity") == nil)
        #expect(abs(label.alpha - 0.75) < 0.001 && abs(shape.alpha - 0.8) < 0.001)
        #expect(root.action(forKey: "transform.position") != nil)
    }

    private func expectValues(_ entity: Entity, text: TextComponent, shape: ShapeComponent) throws {
        let actualText = try #require(entity.components[TextComponent.self]), expectedText = text
        let actualShape = try #require(entity.components[ShapeComponent.self]), expectedShape = shape
        #expect(colorsMatch(actualText.color, text.color))
        #expect(colorsMatch(actualShape.fill, shape.fill) && colorsMatch(actualShape.stroke, shape.stroke))
        #expect(actualText.text == expectedText.text && actualText.font == expectedText.font)
        #expect(actualText.horizontalAlignment == expectedText.horizontalAlignment && actualText.verticalAlignment == expectedText.verticalAlignment)
        #expect(actualText.maxWidth == expectedText.maxWidth && actualText.numberOfLines == expectedText.numberOfLines)
        #expect(actualText.lineBreak == expectedText.lineBreak)
        #expect(actualText.blendMode == expectedText.blendMode)
        #expect(abs(actualText.opacity - expectedText.opacity) < 0.001)
        #expect(actualShape.geometry == expectedShape.geometry)
        #expect(actualShape.lineWidth == expectedShape.lineWidth && actualShape.glowWidth == expectedShape.glowWidth)
        #expect(actualShape.lineCap == expectedShape.lineCap && actualShape.lineJoin == expectedShape.lineJoin)
        #expect(actualShape.miterLimit == expectedShape.miterLimit && actualShape.isAntialiased == expectedShape.isAntialiased)
        #expect(abs(actualShape.opacity - expectedShape.opacity) < 0.001)
        #expect(actualShape.blendMode == expectedShape.blendMode)
    }

    @Test func archiveLoadAndWorldSnapshotPreserveStyleLocalCurvesAndChildTransforms() throws {
        let scene = SKScene(size: CGSize(width: 200, height: 100)); scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let label = SKLabelNode(fontNamed: "Helvetica")
        label.name = "label"; label.text = "Archived caption"; label.fontSize = 19; label.fontColor = .cyan
        label.horizontalAlignmentMode = .right; label.verticalAlignmentMode = .top
        label.preferredMaxLayoutWidth = 90; label.numberOfLines = 2; label.lineBreakMode = .byTruncatingMiddle
        label.alpha = 0.75; label.blendMode = .add; label.position = CGPoint(x: 30, y: -10)
        label.zRotation = 0.25; label.xScale = 1.5; label.yScale = 0.75; label.zPosition = 4
        let path = curvedPath(), nativeShape = SKShapeNode(path: try #require(path.native))
        nativeShape.name = "shape"; nativeShape.fillColor = .red; nativeShape.strokeColor = .green
        nativeShape.lineWidth = 3; nativeShape.glowWidth = 2; nativeShape.lineCap = .round; nativeShape.lineJoin = .bevel
        nativeShape.miterLimit = 7; nativeShape.isAntialiased = false; nativeShape.alpha = 0.5; nativeShape.blendMode = .add
        nativeShape.position = CGPoint(x: -8, y: 12); nativeShape.zRotation = -0.5
        nativeShape.xScale = 2; nativeShape.yScale = 0.5; nativeShape.zPosition = 3
        let child = SKNode(); child.name = "child"; child.position = CGPoint(x: 6, y: 9); child.zRotation = 0.4
        nativeShape.addChild(child); label.addChild(nativeShape); scene.addChild(label)
        let direct = SceneLoader().entity(from: label)
        #expect(direct.components[TextComponent.self]?.lineBreak == .truncateMiddle)
        #expect(direct.components[TextComponent.self]?.blendMode == .add)
        #expect(direct.children.first?.components[ShapeComponent.self]?.blendMode == .add)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TextShapeTests-\(UUID().uuidString).sks")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try NSKeyedArchiver.archivedData(withRootObject: scene, requiringSecureCoding: false)
        try data.write(to: url)
        // SpriteKit itself omits some style fields from its archive. Compare the
        // loader with the actual decoded archive, rather than blaming conversion.
        let archived = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: SKNode.self, from: data))
        let archivedLabel = try #require(archived.childNode(withName: "label") as? SKLabelNode)
        let archivedShape = try #require(archivedLabel.childNode(withName: "shape") as? SKShapeNode)
        #expect(archivedLabel.lineBreakMode == .byTruncatingTail)
        let loaded = try Entity.load(contentsOf: url)
        let caption = try #require(loaded.findEntity(named: "label")), outline = try #require(loaded.findEntity(named: "shape"))
        let expectedText = TextComponent("Archived caption", font: .named("Helvetica", size: 19), color: color(try #require(label.fontColor)),
            horizontalAlignment: .right, verticalAlignment: .top, maxWidth: 90, numberOfLines: 2,
            lineBreak: .truncateTail,
            opacity: 0.75, blendMode: SpriteBlendMode(archivedLabel.blendMode))
        let expectedShape = ShapeComponent(.path(path), fill: color(nativeShape.fillColor), stroke: color(nativeShape.strokeColor), lineWidth: 3, glowWidth: 2,
            lineCap: .round, lineJoin: .bevel, miterLimit: 7, isAntialiased: false, opacity: 0.5,
            blendMode: SpriteBlendMode(archivedShape.blendMode))
        // Put both values on one entity as well, exercising mixed-component snapshots.
        caption.components.set(expectedShape); outline.components.set(expectedText)
        try expectValues(caption, text: expectedText, shape: expectedShape)
        try expectValues(outline, text: expectedText, shape: expectedShape)
        #expect(caption.transform == Transform(translation: [30, -10], rotation: 0.25, scale: [1.5, 0.75], zPosition: 4))
        #expect(outline.transform == Transform(translation: [-8, 12], rotation: -0.5, scale: [2, 0.5], zPosition: 3))
        #expect(outline.children.first?.position == [6, 9] && outline.children.first?.rotation == 0.4)
        let world = World(), renderer = SpriteRenderer(world: world)
        loaded.components.set(InputTargetComponent()); world.addEntity(loaded); renderer.flush()
        #expect(outline.isActive && outline.isInputTarget)
        let node = try #require(renderer.node(for: outline))
        let point = node.convert(CGPoint(x: 20, y: 15), to: renderer)
        #expect(renderer.entities(at: point).contains { $0 === outline })
        #expect(renderer.inputTarget(at: point) != nil)
        var snapshotText = expectedText, snapshotShape = expectedShape
        snapshotText.lineBreak = .truncateMiddle; snapshotText.blendMode = .add; snapshotShape.blendMode = .add
        outline.components.set(snapshotText); outline.components.set(snapshotShape); renderer.flush()
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData())
        world.restore(snapshot); renderer.flush()
        let restored = try #require(world.entity(withID: outline.id))
        try expectValues(restored, text: snapshotText, shape: snapshotShape)
        #expect(restored !== outline && restored.transform == outline.transform)
        #expect(restored.children.first?.position == [6, 9])
        #expect(renderer.node(for: restored) !== node)
    }

    @Test func clonePrefabAndPoolKeepIndependentValuesAndReuseNativeNodes() throws {
        let text = TextComponent("Template", font: .system(size: 21, weight: .semibold), color: .orange)
        let shape = ShapeComponent(.path(curvedPath()), fill: .blue, stroke: .yellow, lineWidth: 3)
        let source = Entity(components: text, shape), clone = source.clone()
        clone.components[TextComponent.self]?.text = "Clone"
        clone.components[ShapeComponent.self]?.geometry = .circle(radius: 4)
        try expectValues(source, text: text, shape: shape)
        let prefab = PrefabResource(root: source)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TextShapeTests-\(UUID().uuidString).prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try prefab.write(to: url)
        let diskPrefab = try PrefabResource.read(Data(contentsOf: url), from: url)
        try expectValues(diskPrefab.instantiate(), text: text, shape: shape)
        let first = prefab.instantiate(), second = prefab.instantiate()
        first.components[TextComponent.self]?.font.size = 100
        first.components[ShapeComponent.self]?.geometry = .rectangle(size: [2, 2])
        try expectValues(second, text: text, shape: shape)
        try expectValues(prefab.instantiate(), text: text, shape: shape)

        let world = World(), renderer = SpriteRenderer(world: world)
        let pool = try EntityPool(prefab: prefab, scene: world, capacity: 2, prewarm: 2,
            onAcquire: { entity in entity.components.set(text); entity.components.set(shape) })
        let a = try #require(try pool.acquire()), b = try #require(try pool.acquire()); renderer.flush()
        let root = try #require(renderer.node(for: a)), label = try #require(root.childNode(withName: "__text"))
        let nativeShape = try #require(root.childNode(withName: "__shape"))
        withAnimation(.linear(duration: 2)) {
            a.components[TextComponent.self]?.opacity = 0
            a.components[ShapeComponent.self]?.opacity = 0
        }
        a.components[TextComponent.self]?.text = "Lease"
        a.components[ShapeComponent.self]?.geometry = .circle(radius: 9); renderer.flush()
        try expectValues(b, text: text, shape: shape)
        #expect(try pool.release(a))
        let again = try #require(try pool.acquire()); renderer.flush()
        #expect(again === a && renderer.node(for: again) === root)
        #expect(root.childNode(withName: "__text") === label && root.childNode(withName: "__shape") === nativeShape)
        #expect(!label.hasActions() && !nativeShape.hasActions() && label.alpha == 1 && nativeShape.alpha == 1)
        try expectValues(again, text: text, shape: shape)
        try expectValues(source, text: text, shape: shape)
    }
}

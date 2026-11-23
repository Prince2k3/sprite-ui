import SpriteUI
import SwiftUI

/// Opts into the unified debug UI with a view-owned SceneDebugController.
/// Diagnostic drawings add no hit targets or physics bodies. GameView supplies
/// picking, the collapsible inspector, statistics and simulation controls;
/// omitting its debug argument leaves those tools out of production scenes.
struct DebugDemoView: View {
    @State private var debug = SceneDebugController(options: .all)
    @State private var scene = DebugDemoScene()

    var body: some View {
        VStack(spacing: 8) {
            GameView(debug: debug) { content in
                let companion = scene.build(in: content)
                debug.select(companion)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.resize($0) }

            HStack {
                Button(debug.options.contains(.bounds) ? "Hide drawings" : "Show drawings") {
                    if debug.options.contains(.bounds) {
                        debug.options.subtract([.collisionShapes, .origins, .bounds, .joints, .constraintTargets])
                    } else {
                        debug.options.formUnion([.collisionShapes, .origins, .bounds, .joints, .constraintTargets])
                    }
                }
                Button(scene.targetMissing ? "Restore target" : "Remove target") {
                    scene.toggleTarget()
                    debug.select(scene.unresolvedCompanion)
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            .disabled(!scene.isReady)

            Text("Expand Debug → Pick entity, then tap artwork.\nFind Disabled actor in the hierarchy. Pause, then step to advance motion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(.cyan)
    }
}

@MainActor @Observable private final class DebugDemoScene {
    private(set) var targetMissing = true
    private(set) var isReady = false
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var viewport = CGSize(width: 402, height: 600)
    @ObservationIgnored private var recoveryTarget: Entity?
    @ObservationIgnored private(set) var unresolvedCompanion: Entity?

    func build(in content: GameViewContent) -> Entity {
        world = content.scene
        content.scene.physics.gravity = [0, -2]
        let camera = Entity(name: "Debug camera", components: CameraComponent(smoothing: 0))
        self.camera = camera
        content.add(camera)
        resize(viewport)

        let room = Entity(name: "Physics room", components:
            ShapeComponent(.rectangle(size: [300, 300]), fill: .white.opacity(0.025), stroke: .white.opacity(0.25)),
            PhysicsBodyComponent(shape: .edgeLoop(rectangle: [300, 300]), categoryBitMask: 1, collisionBitMask: 2))
        content.add(room)
        addLabel("DEBUG PLAYGROUND", at: [0, 168], to: room)
        addBalls(to: room)
        addPendulum(to: room)

        let patrol = shape("Cyan patrol · animated", .circle(radius: 11), color: .cyan)
        patrol.position = [25, 72]
        room.addChild(patrol)
        let companion = shape("Pink companion · follows patrol", .roundedRectangle(size: [20, 20], cornerRadius: 5), color: .pink)
        companion.position = [5, 32]
        companion.components.set(TransformConstraintComponent([
            TransformConstraint(.follow(.entity(patrol.id), offset: [-20, -40], offsetSpace: .scene, smoothing: 0.15), name: "Follow patrol"),
            TransformConstraint(.lookAt(.entity(patrol.id)), name: "Face patrol")
        ]))
        room.addChild(companion)

        let unresolved = shape("Missing target · restore with button", .circle(radius: 10), color: .orange)
        unresolved.position = [-92, -88]
        unresolved.components.set(TransformConstraintComponent([
            TransformConstraint(.follow(.named("Recovery beacon"), offset: [0, -30], offsetSpace: .scene, smoothing: 0.2), name: "Recoverable follow")
        ]))
        room.addChild(unresolved)
        unresolvedCompanion = unresolved
        let beacon = shape("Recovery beacon", .circle(radius: 6), color: .mint)
        beacon.position = [-55, -38]
        recoveryTarget = beacon // Intentionally absent: inspector starts with missingTarget.
        addLabel("TARGET LINK", at: [-82, -113], to: room, color: .orange)

        let disabled = shape("Disabled actor", .rectangle(size: [22, 22]), color: .gray)
        disabled.position = [112, 120]
        disabled.isEnabled = false
        let child = shape("Child of disabled actor", .circle(radius: 5), color: .white)
        child.position = [0, 18]
        disabled.addChild(child)
        room.addChild(disabled)

        let sweep = addClippedWindow(to: room)
        // SpriteUI actions share the simulation clock, so pause/step also applies
        // to these continuous animations and their dependent constraints.
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            patrol.position = [105, 98]
            sweep.position.x = 65
        }
        isReady = true
        return companion
    }

    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport = size
        // Reserve top/bottom space for GameView's tools; keep the art centered
        // when the inspector expands or the containing window changes size.
        camera?.components[CameraComponent.self]?.zoom = Float(max(0.1, min((size.width - 24) / 340, (size.height - 180) / 350)))
    }

    func toggleTarget() {
        guard let world, let recoveryTarget else { return }
        if targetMissing { world.addEntity(recoveryTarget) }
        else { recoveryTarget.removeFromParent() }
        targetMissing.toggle()
    }

    private func addBalls(to room: Entity) {
        for index in 0..<4 {
            let radius = Float(10 + index * 2)
            let ball = shape("Ball \(index + 1) · physics", .circle(radius: radius), color: index.isMultiple(of: 2) ? .mint : .yellow)
            ball.position = [Float(-105 + index * 65), Float(-5 - index * 16)]
            ball.components.set(PhysicsBodyComponent(shape: .circle(radius: radius), mass: 0.4,
                friction: 0, restitution: 1, linearDamping: 0, angularDamping: 0,
                affectedByGravity: false, usesPreciseCollisionDetection: true,
                categoryBitMask: 2, collisionBitMask: 3,
                velocity: [index.isMultiple(of: 2) ? 65 : -55, Float(45 + index * 12)]))
            room.addChild(ball)
        }
    }

    private func addPendulum(to room: Entity) {
        let pivot = shape("Pendulum pivot", .circle(radius: 5), color: .orange)
        pivot.position = [-78, 112]
        pivot.components.set(PhysicsBodyComponent(shape: .circle(radius: 5), isDynamic: false,
            categoryBitMask: 4, collisionBitMask: 0))
        room.addChild(pivot)
        let rod = shape("Pendulum arm · physics", .roundedRectangle(size: [12, 86], cornerRadius: 5), color: .cyan)
        rod.position = [-78, 69]
        rod.components.set(PhysicsBodyComponent(shape: .rectangle(size: [12, 86]), mass: 1,
            linearDamping: 0, angularDamping: 0, categoryBitMask: 4, collisionBitMask: 0,
            angularVelocity: 1.5))
        room.addChild(rod)
        let bob = shape("Pendulum bob", .circle(radius: 13), color: .cyan)
        bob.position = [0, -37]
        rod.addChild(bob)
        room.addChild(Entity(name: "Pendulum pin joint", components: PhysicsJointComponent(
            bodyA: pivot.id, bodyB: rod.id, constraint: .pin(angleLimits: -1.1...1.1))))
    }

    private func addClippedWindow(to room: Entity) -> Entity {
        let window = Entity(name: "Clipped window", components:
            MaskComponent(shape: .roundedRectangle(size: [112, 36], cornerRadius: 8)))
        window.position = [70, -92]
        room.addChild(window)
        let sweep = shape("Clipped animated bar", .rectangle(size: [110, 22]), color: .purple)
        sweep.position = [-65, 0]
        window.addChild(sweep)
        let frame = Entity(name: "Window frame", components: ShapeComponent(
            .roundedRectangle(size: [112, 36], cornerRadius: 8), stroke: .purple.opacity(0.7)))
        frame.position = window.position
        room.addChild(frame)
        addLabel("CLIPPED ACTION", at: [70, -123], to: room, color: .purple)
        return sweep
    }

    private func shape(_ name: String, _ geometry: ShapeGeometry, color: Color) -> Entity {
        Entity(name: name, components: ShapeComponent(geometry, fill: color.opacity(0.8), stroke: color, lineWidth: 1.5))
    }

    private func addLabel(_ text: String, at point: SIMD2<Float>, to parent: Entity, color: Color = .white.opacity(0.65)) {
        let label = Entity(name: text, components: TextComponent(text, font: .system(size: 10, weight: .semibold), color: color))
        label.position = point
        parent.addChild(label)
    }
}

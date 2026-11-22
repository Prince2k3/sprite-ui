import SpriteUI
import SwiftUI
import simd

struct JointDemoView: View {
    @State private var scene = JointDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { scene.build(in: $0) }
                .overlay(alignment: .top) {
                    Text(scene.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                Picker("Joint", selection: $scene.mode) {
                    ForEach(JointDemoScene.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Button("Kick") { scene.kick() }
                    Toggle("Connected", isOn: $scene.connected).toggleStyle(.button)
                    Button("Rebuild body") { scene.rebuildBody() }
                }
                HStack {
                    Button("Reset") { scene.reset() }
                    Button("Save") { scene.save() }
                    Button("Load") { scene.load() }.disabled(!scene.hasSave)
                }
                Text(scene.mode.hint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: scene.mode) { scene.resetIfNeeded() }
            .onChange(of: scene.connected) { scene.setConnected() }
    }
}

private struct JointDemoMetadata: Component, Codable { var mode: JointDemoScene.Mode }
private struct JointDemoRuntime: Component { weak var scene: JointDemoScene? }
private struct JointDemoPresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    mutating func update(context: UpdateContext) { context.world.root.components[JointDemoRuntime.self]?.scene?.refresh() }
}

@MainActor @Observable private final class JointDemoScene {
    enum Mode: String, CaseIterable, Codable {
        case pin = "Pin", fixed = "Fixed", spring = "Spring", slide = "Slide", chain = "Chain"
        var hint: String {
            switch self {
            case .pin: "A pendulum rotates around a pin. Kick to swing it."
            case .fixed: "Two pieces are welded together and swing from a pin."
            case .spring: "A spring platform stretches and settles. Save while stretched, then Load."
            case .slide: "A platform slides along a rail, limited to ±120 points."
            case .chain: "Distance limits connect a chain. Disconnect to release it."
            }
        }
    }
    var mode = Mode.pin
    var connected = true
    var hasSave = false
    var summary = "Preparing joints"
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var builtMode: Mode?
    @ObservationIgnored private var drawing = Entity(name: "joint drawing")
    @ObservationIgnored private var lines: [Entity.ID: Entity] = [:]
    @ObservationIgnored private var message = ""
    private var saveURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("joints-demo.json") }

    func build(in content: GameViewContent) {
        world = content.scene
        content.scene.root.components.set(JointDemoRuntime(scene: self))
        content.scene.addSystem(JointDemoPresentation.self)
        JointDemoMetadata.registerComponent(named: "demo.joint-mode")
        hasSave = FileManager.default.fileExists(atPath: saveURL.path)
        reset()
    }
    func resetIfNeeded() { if builtMode != mode { reset() } }
    func reset() {
        guard let world else { return }
        for entity in world.entities { entity.removeFromParent() }
        builtMode = mode; connected = true; message = ""
        world.physics.gravity = [0, -4]
        let metadata = Entity(components: JointDemoMetadata(mode: mode)); world.addEntity(metadata)
        let room = Entity(components: PhysicsBodyComponent(shape: .edgeLoop(rectangle: [340, 440]), categoryBitMask: 1, collisionBitMask: 2))
        world.addEntity(room)
        drawing = Entity(name: "joint drawing"); drawing.zPosition = -1; lines = [:]; world.addEntity(drawing)
        switch mode {
        case .pin:
            let post = body(at: [0, 170], size: [10, 10], color: .orange, dynamic: false)
            let rod = body(at: [0, 100], size: [18, 140], color: .cyan)
            joint(post, rod, .pin(angleLimits: -1.2...1.2, frictionTorque: 0.02))
        case .fixed:
            let post = body(at: [0, 170], size: [10, 10], color: .orange, dynamic: false)
            let beam = body(at: [0, 110], size: [18, 120], color: .cyan)
            let block = body(at: [45, 60], size: [70, 20], color: .mint)
            joint(post, beam, .pin())
            joint(beam, block, .fixed(anchor: [5, -50]))
        case .spring:
            let post = body(at: [0, 160], size: [10, 10], color: .orange, dynamic: false)
            let platform = body(at: [0, 50], size: [110, 18], color: .cyan)
            platform.components[PhysicsBodyComponent.self]?.allowsRotation = false
            joint(post, platform, .spring(frequency: 1.5, damping: 0.15))
        case .slide:
            let rail = Entity(components: SpriteComponent(color: .gray, size: [280, 3])); rail.position = [0, 80]; world.addEntity(rail)
            let post = body(at: [0, 80], size: [8, 8], color: .orange, dynamic: false)
            let platform = body(at: [0, 80], size: [60, 24], color: .cyan)
            joint(post, platform, .sliding(axis: [1, 0], distanceLimits: -120...120))
        case .chain:
            var previous = body(at: [-80, 180], size: [10, 10], color: .orange, dynamic: false)
            for i in 0..<5 {
                let link = body(at: [Float(-60 + i * 20), Float(125 - i * 55)], size: [25, 25], color: i.isMultiple(of: 2) ? .cyan : .mint)
                joint(previous, link, .limit(maxLength: 64)); previous = link
            }
        }
        kick()
    }
    @discardableResult private func body(at point: SIMD2<Float>, size: SIMD2<Float>, color: Color, dynamic: Bool = true) -> Entity {
        let entity = Entity(name: dynamic ? "moving" : "post", components: SpriteComponent(color: color, size: size), PhysicsBodyComponent(shape: .rectangle(size: size), isDynamic: dynamic, mass: 1, restitution: 0.3, linearDamping: 0.05, categoryBitMask: dynamic ? 2 : 4, collisionBitMask: dynamic ? 1 : 0))
        entity.position = point; world?.addEntity(entity); return entity
    }
    private func joint(_ a: Entity, _ b: Entity, _ constraint: PhysicsJointConstraint) {
        world?.addEntity(Entity(name: "joint", components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: constraint)))
    }
    func kick() {
        for entity in world?.entities ?? [] where entity.name == "moving" {
            entity.applyImpulse(mode == .spring ? [30, -140] : [180, 0])
        }
    }
    func setConnected() {
        for entity in world?.entities ?? [] where entity.components.has(PhysicsJointComponent.self) {
            entity.components[PhysicsJointComponent.self]?.isEnabled = connected
        }
    }
    func rebuildBody() {
        guard let entity = world?.entities.first(where: { $0.name == "moving" }) else { return }
        if case .circle = entity.components[PhysicsBodyComponent.self]?.shape {
            entity.components[PhysicsBodyComponent.self]?.shape = .rectangle(size: [40, 24])
            entity.components.set(SpriteComponent(color: .cyan, size: [40, 24]))
        } else {
            entity.components[PhysicsBodyComponent.self]?.shape = .circle(radius: 18)
            entity.components.set(SpriteComponent(image: .disc(diameter: 40), size: [36, 36], tint: .cyan, tintAmount: 1))
        }
        message = "Body replaced"
    }
    func save() {
        do {
            guard let world else { return }
            try world.snapshot(including: { $0 !== drawing }).write(to: saveURL)
            hasSave = true; message = "Saved"
        } catch { message = "Save failed" }
    }
    func load() {
        do {
            guard let world else { return }
            world.restore(try WorldSnapshot(contentsOf: saveURL))
            if let saved = world.entities.compactMap({ $0.components[JointDemoMetadata.self] }).first {
                builtMode = saved.mode; mode = saved.mode
            }
            connected = world.entities.compactMap { $0.components[PhysicsJointComponent.self] }.allSatisfy(\.isEnabled)
            drawing = Entity(name: "joint drawing"); drawing.zPosition = -1; lines = [:]; world.addEntity(drawing)
            message = "Loaded"
        } catch { message = "Load failed" }
    }
    func refresh() {
        guard let world else { return }
        let joints = world.entities.filter { $0.components.has(PhysicsJointComponent.self) }
        let active = joints.filter { $0.physicsJointStatus == .active }.count
        for owner in joints {
            guard let model = owner.components[PhysicsJointComponent.self], let a = world.entity(withID: model.bodyA), let b = world.entity(withID: model.bodyB) else { continue }
            let line: Entity
            if let existing = lines[owner.id] { line = existing }
            else { line = Entity(components: SpriteComponent(color: .yellow, size: [1, 2])); drawing.addChild(line); lines[owner.id] = line }
            let delta = b.scenePosition - a.scenePosition
            line.position = (a.scenePosition + b.scenePosition) / 2; line.rotation = atan2(delta.y, delta.x)
            line.components[SpriteComponent.self]?.size = [simd_length(delta), 2]
            line.components[SpriteComponent.self]?.opacity = model.isEnabled ? 0.7 : 0
        }
        var text = "\(active)/\(joints.count) joints active"
        if mode == .spring, let platform = world.entities.first(where: { $0.name == "moving" }), let post = world.entities.first(where: { $0.name == "post" }) {
            text += " · span \(Int(simd_distance(platform.scenePosition, post.scenePosition))) pt"
        }
        if !message.isEmpty { text += " · \(message)" }
        if summary != text { summary = text }
    }
}

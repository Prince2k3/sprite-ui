import Observation
import SpriteUI
import SwiftUI

@MainActor @Observable
final class ManipulationTutorialScene {
    let free = Entity(name: "Free", components:
        SpriteComponent(color: .cyan, size: [48, 32]),
        InputTargetComponent(), ManipulationComponent())
    let child = Entity(name: "Rail", components:
        SpriteComponent(color: .mint, size: [28, 28]),
        InputTargetComponent(), ManipulationComponent(
            translationAxes: .x,
            translationBounds: .init(min: [-80, -20], max: [80, 20]),
            translationSnap: [20, 20], rotationSnap: .pi / 12))
    let body = Entity(name: "Body", components:
        SpriteComponent(color: .orange, size: [32, 32]),
        InputTargetComponent(), ManipulationComponent(),
        PhysicsBodyComponent(shape: .rectangle(size: [32, 32]), restitution: 0.1))
    var selected = 0
    var enabled = true
    var snapping = true
    var zoom = 1.0
    var status = "Drag a sprite or use the buttons"
    var bodyStatus = "Body: configured dynamic"
    private var renderer: SpriteRenderer?
    private var subscriptions: [EventSubscription] = []
    private let camera = Entity(components: CameraComponent(smoothing: 0))
    private var viewport = CGSize(width: 320, height: 340)
    var targets: [Entity] { [free, child, body] }

    func install(in content: GameViewContent) {
        free.position = [-75, 95]
        content.add(free)
        let parent = Entity(components: ShapeComponent(
            .rectangle(size: [200, 60]), fill: .mint.opacity(0.08), stroke: .mint))
        parent.rotation = .pi / 6
        parent.scale = [1.1, 1.1]
        for x in stride(from: -80, through: 80, by: 20) {
            let mark = Entity(components: SpriteComponent(color: .mint.opacity(0.3), size: [1, 60]))
            mark.position.x = Float(x)
            parent.addChild(mark)
        }
        child.position = [-40, 0]
        parent.addChild(child)
        content.add(parent)
        renderer = content.renderer
        content.renderer.gravity = [0, -9.8]
        content.add(camera)
        body.position = [70, -85]
        content.add(body)
        let floor = Entity(components:
            SpriteComponent(color: .gray, size: [280, 10]),
            PhysicsBodyComponent(shape: .rectangle(size: [280, 10]), isDynamic: false))
        floor.position = [0, -150]
        content.add(floor)
        applyCamera()
        subscriptions = [
            content.subscribe(to: ManipulationEvents.Began.self) { [weak self] event in
                self?.record("Began", event.entity)
                if event.entity === self?.body { self?.bodyStatus = "Body: captured; simulation suspended" }
            },
            content.subscribe(to: ManipulationEvents.Changed.self) { [weak self] event in
                self?.record("Changed", event.entity)
            },
            content.subscribe(to: ManipulationEvents.Ended.self) { [weak self] event in
                self?.record("Ended", event.entity)
                if event.entity === self?.body { self?.bodyStatus = "Body: dynamics restored; zero release velocity" }
            },
            content.subscribe(to: ManipulationEvents.Cancelled.self) { [weak self] event in
                self?.record("Cancelled: \(event.reason.rawValue)", event.entity)
                if event.entity === self?.body { self?.bodyStatus = "Body: cancelled; dynamics restored" }
            }
        ]
    }

    func configure() {
        cancel()
        for entity in targets { entity.components[ManipulationComponent.self]?.isEnabled = enabled }
        child.components[ManipulationComponent.self]?.translationSnap = snapping ? [20, 20] : nil
        child.components[ManipulationComponent.self]?.rotationSnap = snapping ? .pi / 12 : nil
    }

    func adjust(rotation: Float = 0, scale: Float = 1) {
        guard let renderer else { return }
        let entity = targets[selected]
        let scenePoint = entity.scenePosition
        let operations: ManipulationComponent.Operations = rotation == 0 ? .scale : .rotation
        guard let session = renderer.beginManipulation(of: entity, at: scenePoint, operations: operations) else {
            status = "Cannot begin manipulation"
            return
        }
        if session.update(translation: .zero, rotation: rotation, scale: scale) { session.end() }
        else { session.cancel() }
    }

    func reset() {
        cancel()
        free.transform = Transform(translation: [-75, 95])
        child.transform = Transform(translation: [-40, 0])
        body.transform = Transform(translation: [70, -85])
        body.components[PhysicsBodyComponent.self]?.velocity = .zero
        body.components[PhysicsBodyComponent.self]?.angularVelocity = 0
        zoom = 1
        applyCamera()
        status = "Reset"
        bodyStatus = "Body: configured dynamic"
    }

    func resize(_ size: CGSize) { viewport = size; applyCamera() }
    func applyCamera() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        camera.components[CameraComponent.self]?.zoom = Float(min(viewport.width / 320, viewport.height / 340) * zoom)
    }
    func cancel() { renderer?.cancelManipulations() }

    private func record(_ phase: String, _ entity: Entity) {
        if let index = targets.firstIndex(where: { $0 === entity }) { selected = index }
        status = "\(phase) · \(entity.name)"
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = ManipulationTutorialScene()

    var body: some View {
        VStack(spacing: 10) {
            GameView { scene.install(in: $0) }
                .frame(minWidth: 280, minHeight: 200)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.resize($0) }
            ScrollView {
                VStack(spacing: 8) {
                    Text(scene.status).font(.caption.monospaced())
                    Text(scene.bodyStatus).font(.caption)
                    Picker("Button target", selection: $scene.selected) {
                        Text("Free").tag(0)
                        Text("Rail").tag(1)
                        Text("Body").tag(2)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button("Rotate left 15°") { scene.adjust(rotation: .pi / 12) }
                        Button("Rotate right 15°") { scene.adjust(rotation: -.pi / 12) }
                    }
                    .disabled(!scene.enabled)
                    HStack {
                        Button("Smaller") { scene.adjust(scale: 0.8) }
                        Button("Larger") { scene.adjust(scale: 1.25) }
                    }
                    .disabled(!scene.enabled)
                    HStack {
                        Toggle("Enabled", isOn: $scene.enabled)
                        Toggle("Snapping", isOn: $scene.snapping)
                        Button("Reset") { scene.reset() }
                    }
                    HStack {
                        Text("Camera zoom")
                        Slider(value: $scene.zoom, in: 0.7...1.5).accessibilityLabel("Camera zoom")
                    }
                    Text("Drag orange above the floor, then release. Capture suspends native physics; configuration stays dynamic. Release resumes gravity without throwing.")
                        .font(.caption)
                }
            }
            .frame(maxHeight: 300)
        }
        .padding()
        .onChange(of: scene.enabled) { scene.configure() }
        .onChange(of: scene.snapping) { scene.configure() }
        .onChange(of: scene.zoom) { scene.applyCamera() }
        .onDisappear { scene.cancel() }
    }
}

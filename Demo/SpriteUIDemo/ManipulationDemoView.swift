import SpriteUI
import SwiftUI

struct ManipulationDemoView: View {
    @State private var model = ManipulationDemoScene()

    var body: some View {
        VStack(spacing: 8) {
            GameView { model.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .frame(minHeight: 200)
            ScrollView {
                VStack(spacing: 8) {
                    Text("Cyan: free · Mint: parent-local X rail · Orange: body")
                        .font(.caption).multilineTextAlignment(.center)
                    Text(model.status).font(.caption.monospaced()).accessibilityIdentifier("manipulation-status")
                    Text(model.physicsStatus).font(.caption).foregroundStyle(.secondary)
                    Picker("Button target", selection: $model.selection) {
                        ForEach(ManipulationDemoScene.Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Toggle("Enabled", isOn: $model.enabled)
                        Toggle("Snapping", isOn: $model.snapping)
                        Button("Reset") { model.reset() }
                    }
                    .toggleStyle(.button)
                    HStack {
                        Text("Camera zoom").font(.caption)
                        Slider(value: $model.zoom, in: 0.7...1.5)
                            .accessibilityLabel("Camera zoom")
                        Text(model.zoom, format: .number.precision(.fractionLength(1)))
                            .font(.caption.monospacedDigit())
                    }
                    ViewThatFits {
                        HStack { manipulationButtons }
                        VStack { manipulationButtons }
                    }
                    .disabled(!model.enabled)
                    Text("Drag a sprite; pinch and rotate with touch or a trackpad. Buttons apply the same sessions to the chosen target. The mint child moves only along its tilted parent’s X axis; snapping uses a 20-point grid and 15° steps.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Orange pauses simulation while captured, then resumes without a throw. Placement does not avoid collisions. No system writes these poses during capture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 300)
        }
        .padding(.vertical, 8)
        .buttonStyle(.bordered)
        .font(.footnote)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(.cyan)
        .onChange(of: model.enabled) { model.applyConfiguration() }
        .onChange(of: model.snapping) { model.applyConfiguration() }
        .onChange(of: model.zoom) { model.applyCamera() }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var manipulationButtons: some View {
        Button("Rotate left") { model.adjust(rotation: .pi / 12) }
            .accessibilityHint("Rotates the button target counterclockwise by 15 degrees")
        Button("Rotate right") { model.adjust(rotation: -.pi / 12) }
            .accessibilityHint("Rotates the button target clockwise by 15 degrees")
        Button("Smaller") { model.adjust(scale: 1 / 1.25) }
            .accessibilityHint("Scales the button target down uniformly")
        Button("Larger") { model.adjust(scale: 1.25) }
            .accessibilityHint("Scales the button target up uniformly")
    }
}

@MainActor @Observable private final class ManipulationDemoScene {
    enum Target: String, CaseIterable { case free = "Free", rail = "Rail", body = "Body" }

    var selection = Target.free
    var enabled = true
    var snapping = true
    var zoom = 1.0
    private(set) var status = "Drag a sprite or use the buttons"
    private(set) var physicsStatus = "Body: configured dynamic; gravity active"

    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var targets: [Target: Entity] = [:]
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 440)
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    func build(in content: GameViewContent) {
        renderer = content.renderer
        content.renderer.gravity = [0, -9.8]
        let camera = Entity(components: CameraComponent(smoothing: 0))
        content.add(camera)
        self.camera = camera

        let free = sprite("Free", color: .cyan, size: [52, 36])
        free.position = [-90, 130]
        content.add(free)
        targets[.free] = free
        let freeLabel = label("FREE · drag / rotate / scale", color: .cyan)
        freeLabel.position = [0, 182]
        content.add(freeLabel)

        let parent = Entity(name: "rotated-scaled-parent")
        parent.rotation = .pi / 9
        parent.scale = [1.15, 1.15]
        parent.components.set(ShapeComponent(.rectangle(size: [200, 70]),
            fill: .mint.opacity(0.04), stroke: .mint.opacity(0.4)))
        for x in stride(from: -80, through: 80, by: 20) {
            let line = Entity(components: ShapeComponent(.rectangle(size: [1, 70]), fill: .mint.opacity(0.18), stroke: .clear))
            line.position.x = Float(x)
            parent.addChild(line)
        }
        let rail = Entity(components: ShapeComponent(.rectangle(size: [180, 2]), fill: .mint.opacity(0.65), stroke: .clear))
        parent.addChild(rail)
        let child = sprite("Rail", color: .mint, size: [28, 28])
        child.position = [-40, 0]
        parent.addChild(child)
        content.add(parent)
        targets[.rail] = child
        let railLabel = label("PARENT ×1.15 / 20° · local X only", color: .mint)
        railLabel.position = [0, 65]
        content.add(railLabel)

        let body = sprite("Body", color: .orange, size: [38, 38])
        body.position = [80, -105]
        body.components.set(PhysicsBodyComponent(shape: .rectangle(size: [38, 38]),
            friction: 0.6, restitution: 0.1))
        content.add(body)
        targets[.body] = body
        let floor = Entity(name: "floor", components:
            SpriteComponent(color: .gray, size: [340, 12]),
            PhysicsBodyComponent(shape: .rectangle(size: [340, 12]), isDynamic: false, friction: 0.6))
        floor.position = [0, -190]
        content.add(floor)
        let bodyLabel = label("BODY · capture / release above floor", color: .orange)
        bodyLabel.position = [0, -65]
        content.add(bodyLabel)

        subscriptions = [
            content.subscribe(to: ManipulationEvents.Began.self) { [weak self] event in
                self?.record("Began", entity: event.entity, transform: event.transform)
                if event.entity === self?.targets[.body] {
                    self?.physicsStatus = "Body: captured; native simulation suspended (configuration stays dynamic)"
                }
            },
            content.subscribe(to: ManipulationEvents.Changed.self) { [weak self] event in
                self?.record("Changed", entity: event.entity, transform: event.transform)
            },
            content.subscribe(to: ManipulationEvents.Ended.self) { [weak self] event in
                self?.record("Ended", entity: event.entity, transform: event.transform)
                if event.entity === self?.targets[.body] {
                    self?.physicsStatus = "Body: released; configured dynamics restored, zero release velocity"
                }
            },
            content.subscribe(to: ManipulationEvents.Cancelled.self) { [weak self] event in
                self?.record("Cancelled: \(event.reason.rawValue)", entity: event.entity, transform: event.transform)
                if event.entity === self?.targets[.body] {
                    self?.physicsStatus = "Body: cancelled; configured dynamics restored, zero release velocity"
                }
            }
        ]
        applyConfiguration()
        applyCamera()
    }

    func applyConfiguration() {
        cancel()
        for (target, entity) in targets {
            var configuration = ManipulationComponent(isEnabled: enabled)
            // Keep the free sprite unconstrained so the snapping toggle is easy to compare.
            if target == .rail {
                configuration.translationAxes = .x
                configuration.translationBounds = .init(min: [-80, -25], max: [80, 25])
                configuration.translationSnap = snapping ? [20, 20] : nil
                configuration.rotationSnap = snapping ? .pi / 12 : nil
            }
            entity.components.set(configuration)
        }
    }

    func adjust(rotation: Float = 0, scale: Float = 1) {
        guard let renderer, let entity = targets[selection] else { return }
        let operations: ManipulationComponent.Operations = rotation == 0 ? .scale : .rotation
        let scenePoint = entity.scenePosition
        guard let session = renderer.beginManipulation(of: entity, at: scenePoint, operations: operations) else {
            status = "Cannot begin: target disabled, already captured, or driven elsewhere"
            return
        }
        if session.update(translation: .zero, rotation: rotation, scale: scale) {
            session.end()
        } else {
            session.cancel()
        }
    }

    func reset() {
        cancel()
        targets[.free]?.transform = Transform(translation: [-90, 130])
        targets[.rail]?.transform = Transform(translation: [-40, 0])
        targets[.body]?.transform = Transform(translation: [80, -105])
        targets[.body]?.components[PhysicsBodyComponent.self]?.velocity = .zero
        targets[.body]?.components[PhysicsBodyComponent.self]?.angularVelocity = 0
        zoom = 1
        applyCamera()
        status = "Reset · drag a sprite or use the buttons"
        physicsStatus = "Body: configured dynamic; gravity active"
    }

    func cancel() { renderer?.cancelManipulations() }
    func resize(_ size: CGSize) { viewport = size; applyCamera() }

    func applyCamera() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        camera?.components[CameraComponent.self]?.zoom = Float(min(viewport.width / 380, viewport.height / 440) * zoom)
    }

    private func record(_ phase: String, entity: Entity, transform: Transform) {
        if let target = targets.first(where: { $0.value === entity })?.key { selection = target }
        let p = transform.translation
        let degrees = Int((transform.rotation * 180 / .pi).rounded())
        let scale = (transform.scale.x * 100).rounded() / 100
        status = "\(phase) · \(entity.name) · local (\(Int(p.x)), \(Int(p.y))) · \(degrees)° · ×\(scale)"
    }

    private func sprite(_ name: String, color: Color, size: SIMD2<Float>) -> Entity {
        let entity = Entity(name: name, components: SpriteComponent(color: color, size: size),
            InputTargetComponent(), ManipulationComponent())
        let heading = Entity(components: SpriteComponent(color: .white, size: [5, 5]))
        heading.position = [size.x / 2 - 6, 0]
        entity.addChild(heading)
        return entity
    }

    private func label(_ text: String, color: Color) -> Entity {
        Entity(components: TextComponent(text, font: .system(size: 11), color: color))
    }
}

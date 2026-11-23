import SpriteUI
import SwiftUI

struct ConstraintDemoView: View {
    @State private var model = ConstraintDemoScene()
    @State private var statusHeight: CGFloat = 96

    var body: some View {
        VStack(spacing: 8) {
            GameView { model.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { model.drag(toView: $0.location) }
                    .onEnded { _ in model.endDrag() })
                .padding(.top, statusHeight + 8)
                .overlay(alignment: .topLeading) {
                    statuses
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusHeight = $0 }
                }
            controls
        }
        .padding(.vertical, 8)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(.orange)
        .onChange(of: model.followEnabled) { model.applyFollow() }
        .onChange(of: model.aimEnabled) { model.applyAim() }
        .onChange(of: model.paused) { model.applyPause() }
        .onDisappear { model.endDrag() }
        .task {
            // Diagnostics are renderer results; sample them independently of simulation,
            // including while paused. No demo system evaluates constraints itself.
            while !Task.isCancelled {
                model.refreshStatuses()
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
        }
    }

    private var statuses: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TRANSFORM CONSTRAINTS").font(.caption.weight(.bold))
                Spacer()
                Text(model.paused ? "Paused" : "Live").font(.caption)
            }
            statusRow("Target", detail: model.targetStatus, color: .cyan)
            statusRow("Companion", detail: model.companionStatus, color: .pink)
            statusRow("Turret", detail: model.turretStatus, color: .orange)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }

    private func statusRow(_ title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(color).frame(width: 76, alignment: .leading)
            Text(detail).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2.monospaced())
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle("Patrol", isOn: $model.patrol)
                Toggle("Follow", isOn: $model.followEnabled)
                Toggle("Aim", isOn: $model.aimEnabled)
            }
            .toggleStyle(.button)
            HStack {
                Toggle("Pause", isOn: $model.paused).toggleStyle(.button)
                Button("Reset") { model.reset() }
            }
            Text("Drag cyan; turn Patrol off to park it.\nPink follows at 45–90 pt. Orange aims within 36°–144°.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
    }
}

private struct ConstraintDemoRuntime: Component {
    weak var model: ConstraintDemoScene?
    func cloned() -> Self? { nil }
}

private struct ConstraintDemoPatrol: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.resources[ConstraintDemoRuntime.self]?.model?.step(context.deltaTime)
    }
}

@MainActor @Observable private final class ConstraintDemoScene {
    var patrol = true
    var followEnabled = true
    var aimEnabled = true
    var paused = false
    var targetStatus = "bounds: notRendered"
    var companionStatus = "follow: notRendered · distance: notRendered"
    var turretStatus = "aim: notRendered · limits: notRendered"

    @ObservationIgnored private var world: World?
    @ObservationIgnored private var scenePoint: ((CGPoint) -> SIMD2<Float>)?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var target: Entity?
    @ObservationIgnored private var companion: Entity?
    @ObservationIgnored private var turret: Entity?
    @ObservationIgnored private var viewport = CGSize(width: 390, height: 440)
    @ObservationIgnored private var time = 0.0
    @ObservationIgnored private var dragging = false

    private static let aimRange: ClosedRange<Float> = (.pi / 5)...(4 * .pi / 5)
    private static let targetMin = SIMD2<Float>(-115, -85)
    private static let targetMax = SIMD2<Float>(115, 105)

    func build(in content: GameViewContent) {
        world = content.scene
        // Capture the public coordinate conversion, without native input or node access.
        scenePoint = { content.scenePoint(fromView: $0) }
        content.scene.resources.set(ConstraintDemoRuntime(model: self))
        content.scene.addSystem(ConstraintDemoPatrol.self)

        let camera = Entity(name: "constraint-camera", components: CameraComponent(smoothing: 0))
        self.camera = camera
        content.add(camera)
        resize(viewport)

        let arena = shape(.roundedRectangle(size: [230, 190], cornerRadius: 8),
                          fill: .cyan.opacity(0.035), stroke: .cyan.opacity(0.4))
        arena.position = [0, 10]
        arena.zPosition = -10
        content.add(arena)
        let boundsLabel = label("TARGET BOUNDS", color: .cyan.opacity(0.75), size: 12)
        boundsLabel.position = [0, 121]
        content.add(boundsLabel)

        let target = shape(.circle(radius: 13), fill: .cyan.opacity(0.25), stroke: .cyan, width: 2)
        target.name = "constraint-target"
        target.zPosition = 5
        target.components.set(TransformConstraintComponent([
            TransformConstraint(.positionBounds(min: Self.targetMin, max: Self.targetMax, relativeTo: .scene), name: "bounds")
        ]))
        // A heading mark makes target-space follow offsets visible as patrol turns.
        let heading = shape(.path(VectorPath(elements: [.move(to: [0, 0]), .line(to: [21, 0])])),
                            stroke: .cyan, width: 3)
        target.addChild(heading)
        content.add(target)
        self.target = target

        let companion = shape(.path(VectorPath(elements: [
            .move(to: [0, 12]), .line(to: [12, 0]), .line(to: [0, -12]),
            .line(to: [-12, 0]), .close
        ])), fill: .pink.opacity(0.25), stroke: .pink, width: 2)
        companion.name = "constraint-companion"
        companion.zPosition = 4
        companion.components.set(TransformConstraintComponent([
            TransformConstraint(.follow(.entity(target.id), offset: [-60, 40], offsetSpace: .target, smoothing: 0.2), name: "follow"),
            TransformConstraint(.distance(to: .entity(target.id), range: 45...90), name: "distance")
        ]))
        content.add(companion)
        self.companion = companion

        let pivot = SIMD2<Float>(0, -160)
        let sector = shape(.path(Self.sectorPath(radius: 170, range: Self.aimRange)),
                           fill: .orange.opacity(0.07), stroke: .orange.opacity(0.5))
        sector.position = pivot
        sector.zPosition = -5
        content.add(sector)
        let base = shape(.circle(radius: 21), fill: .orange.opacity(0.12), stroke: .orange.opacity(0.5), width: 2)
        base.position = pivot
        content.add(base)

        let turret = shape(.roundedRectangle(size: [42, 12], cornerRadius: 4), fill: .orange, stroke: .orange)
        turret.name = "constraint-turret"
        turret.position = pivot
        turret.zPosition = 2
        turret.components.set(TransformConstraintComponent([
            TransformConstraint(.lookAt(.named("constraint-target"), smoothing: 0.12), name: "aim"),
            TransformConstraint(.rotationLimits(Self.aimRange, relativeTo: .scene), name: "limits")
        ]))
        // A vector beam shares the constrained pose. A point light has no aim axis.
        let beam = shape(.path(VectorPath(elements: [
            .move(to: [22, 0]), .line(to: [220, 14]), .line(to: [220, -14]), .close
        ])), fill: .orange.opacity(0.1), stroke: .orange.opacity(0.2))
        beam.zPosition = -1
        turret.addChild(beam)
        content.add(turret)
        self.turret = turret

        let caption = label("TURRET  /  36°–144°", color: .orange, size: 13)
        caption.position = [0, -197]
        content.add(caption)
        reset()
    }

    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport = size
        camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 420, size.height / 430))
    }

    func step(_ delta: TimeInterval) {
        guard patrol, !dragging, !paused else { return }
        time += delta
        let phase = Float(time * 0.65)
        target?.position = [sin(phase) * 108, 15 + sin(phase * 2) * 75]
        target?.rotation = atan2(150 * cos(phase * 2), 108 * cos(phase))
    }

    func drag(toView point: CGPoint) {
        guard !paused, let scenePoint else { return }
        dragging = true
        // Bounds are applied by the renderer, so dragging past the outline visibly
        // demonstrates positionBounds rather than a hand-written input clamp.
        target?.position = scenePoint(point)
    }

    func endDrag() { dragging = false }

    func applyFollow() {
        companion?.components[TransformConstraintComponent.self]?.setEnabled(followEnabled, named: "follow")
        refreshStatuses()
    }

    func applyAim() {
        turret?.components[TransformConstraintComponent.self]?.setEnabled(aimEnabled, named: "aim")
        refreshStatuses()
    }

    func applyPause() {
        world?.isPaused = paused
        dragging = false
        refreshStatuses()
    }

    func reset() {
        time = 0
        dragging = false
        patrol = true
        followEnabled = true
        aimEnabled = true
        paused = false
        target?.position = [0, 15]
        target?.rotation = 0
        companion?.position = [-60, 55]
        companion?.rotation = 0
        turret?.rotation = .pi / 2
        applyFollow()
        applyAim()
        applyPause()
    }

    func refreshStatuses() {
        let targetValue = statuses(of: target)
        let companionValue = statuses(of: companion)
        let turretValue = statuses(of: turret)
        if targetStatus != targetValue { targetStatus = targetValue }
        if companionStatus != companionValue { companionStatus = companionValue }
        if turretStatus != turretValue { turretStatus = turretValue }
    }

    private func statuses(of entity: Entity?) -> String {
        guard let rules = entity?.components[TransformConstraintComponent.self]?.constraints,
              let statuses = entity?.transformConstraintStatuses else { return "Awaiting renderer" }
        return zip(rules, statuses).map { rule, status in
            "\(rule.name ?? "rule"): \(status.rawValue)"
        }.joined(separator: " · ")
    }

    private func shape(_ geometry: ShapeGeometry, fill: Color = .clear, stroke: Color, width: Float = 1) -> Entity {
        Entity(components: ShapeComponent(geometry, fill: fill, stroke: stroke, lineWidth: width))
    }

    private func label(_ text: String, color: Color, size: Float) -> Entity {
        Entity(components: TextComponent(text, font: .system(size: size, weight: .semibold), color: color))
    }

    private static func sectorPath(radius: Float, range: ClosedRange<Float>) -> VectorPath {
        var path = VectorPath(elements: [.move(to: .zero)])
        for index in 0...48 {
            let angle = range.lowerBound + (range.upperBound - range.lowerBound) * Float(index) / 48
            path.addLine(to: [cos(angle) * radius, sin(angle) * radius])
        }
        path.closeSubpath()
        return path
    }
}

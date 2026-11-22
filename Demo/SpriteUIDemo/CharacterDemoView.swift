import SpriteUI
import SwiftUI
import simd

struct CharacterDemoView: View {
    @State private var scene = CharacterDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { scene.build(in: $0) }
                .gesture(DragGesture(minimumDistance: 0).onChanged { scene.aim(at: $0.location) })
                .overlay(alignment: .top) {
                    Text(scene.summary).font(.caption.monospaced()).padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                Picker("Shape", selection: $scene.shape) {
                    Text("Circle").tag(false); Text("Box").tag(true)
                }.pickerStyle(.segmented)
                HStack {
                    Text("Speed \(Int(scene.speed))").font(.caption).frame(width: 80)
                    Slider(value: $scene.speed, in: 60...1800)
                }
                HStack {
                    Button("Reset") { scene.reset() }
                    Button("Embed in wall") { scene.embed() }
                    Button("Dash") { scene.dash() }
                }.buttonStyle(.bordered)
                Text("Touch to move. Dash tests thin walls; Embed tests overlap recovery.").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: scene.shape) { scene.changeShape() }
    }
}

@MainActor @Observable private final class CharacterDemoScene {
    var summary = "Touch to move"
    var speed: Float = 160
    var shape = false
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var character: Entity?
    @ObservationIgnored private var marker: Entity?
    @ObservationIgnored private var normals = Entity()
    @ObservationIgnored private var subscription: EventSubscription?
    private var goal = SIMD2<Float>(-120, -160)
    private let walls = CollisionGroup(rawValue: 1), actors = CollisionGroup(rawValue: 2)

    func build(in content: GameViewContent) {
        renderer = content.renderer
        for (point, size, angle): (SIMD2<Float>, SIMD2<Float>, Float) in [([0, 0], [4, 200], 0), ([65, 100], [130, 4], 0), ([-85, 65], [75, 8], 0.4)] {
            let entity = Entity(components: CollisionComponent(shape: .rectangle(size: size), filter: .init(group: walls)), SpriteComponent(color: .blue, size: size))
            entity.position = point; entity.rotation = angle; content.add(entity)
        }
        let boundary = Entity(components: CollisionComponent(shape: .edgeLoop(rectangle: [330, 400]), filter: .init(group: walls)))
        content.add(boundary)
        for point: SIMD2<Float> in [[-165, 0], [165, 0]] {
            let line = Entity(components: SpriteComponent(color: .gray, size: [1, 400])); line.position = point; content.add(line)
        }
        for point: SIMD2<Float> in [[0, -200], [0, 200]] {
            let line = Entity(components: SpriteComponent(color: .gray, size: [330, 1])); line.position = point; content.add(line)
        }
        let character = Entity(components: CharacterControllerComponent(shape: .circle(radius: 14), filter: .init(group: actors, mask: walls)), SpriteComponent(image: .disc(diameter: 40), size: [28, 28], tint: .cyan, tintAmount: 1))
        content.add(character); self.character = character
        let marker = Entity(components: SpriteComponent(image: .disc(diameter: 16), size: [8, 8], tint: .orange, tintAmount: 1))
        content.add(marker); self.marker = marker; content.add(normals)
        subscription = content.scene.subscribe(to: WorldEvents.Update.self) { [weak self] in self?.step(Float($0.deltaTime)) }
        reset()
    }
    func aim(at point: CGPoint) {
        guard let renderer else { return }
        let p = renderer.scenePoint(fromView: point)
        goal = simd_clamp(p, [-150, -185], [150, 185]); marker?.position = goal
    }
    func reset() {
        character?.position = [-120, -160]; goal = [-120, -160]; marker?.position = goal
        summary = "Touch to move"; for child in normals.children { child.removeFromParent() }
    }
    func embed() {
        character?.position = [0, 0]; goal = .zero; marker?.position = goal
        move(.zero)
        if let character { goal = character.position; marker?.position = goal }
    }
    func dash() {
        character?.position = [-120, -50]; goal = [140, 80]; marker?.position = goal
        move([1200, 600])
        if let character { goal = character.position; marker?.position = goal }
    }
    func changeShape() {
        character?.components[CharacterControllerComponent.self]?.shape = shape ? .rectangle(size: [28, 28]) : .circle(radius: 14)
        if shape { character?.components.set(SpriteComponent(color: .cyan, size: [28, 28])) }
        else { character?.components.set(SpriteComponent(image: .disc(diameter: 40), size: [28, 28], tint: .cyan, tintAmount: 1)) }
        move(.zero)
    }
    private func step(_ dt: Float) {
        guard let character else { return }
        let delta = goal - character.position, length = simd_length(delta)
        if length > 0.5 { move(delta * min(1, speed * dt / length)) }
    }
    private func move(_ delta: SIMD2<Float>) {
        guard let character else { return }
        do {
            let result = try character.moveCharacter(by: delta)
            summary = "\(Int(simd_length(result.displacement))) pt · \(result.contacts.count) contacts" + (simd_length(result.recoveryTranslation) > 0 ? " · recovered" : "") + (result.isOverlapping ? " · trapped" : "")
            for child in normals.children { child.removeFromParent() }
            for hit in result.contacts {
                let line = Entity(components: SpriteComponent(color: .yellow, size: [30, 2]))
                line.position = hit.position + hit.normal * 15; line.rotation = atan2(hit.normal.y, hit.normal.x); normals.addChild(line)
            }
        } catch { summary = "Move rejected: \(error)" }
    }
}

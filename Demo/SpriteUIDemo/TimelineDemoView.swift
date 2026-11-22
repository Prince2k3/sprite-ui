import SpriteUI
import SwiftUI

struct TimelineDemoView: View {
    @State private var model = TimelineDemoScene()
    @State private var scenePaused = false
    var body: some View {
        VStack(spacing: 12) {
            GameView { model.build(in: $0) } update: { $0.scene.isPaused = scenePaused }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .overlay(alignment: .top) {
                    Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                HStack {
                    Button("Play 3") { model.play() }
                    Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                    Button("Stop") { model.stop() }
                    Button("Recycle") { model.recycle() }
                }
                HStack {
                    Toggle("Loop", isOn: $model.loop)
                    Toggle("Pool enabled", isOn: $model.enabled)
                    Toggle("Scene pause", isOn: $scenePaused)
                }.toggleStyle(.button)
                HStack {
                    Text("Seek").font(.caption)
                    Slider(value: Binding(get: { model.progress }, set: { model.seek($0) }), in: 0...1)
                    Text("\(model.progress * 100, specifier: "%.0f")%").font(.caption.monospaced()).frame(width: 40)
                }
                HStack {
                    Text("Speed").font(.caption)
                    Slider(value: $model.speed, in: 0.5...2)
                    Text("\(model.speed, specifier: "%.1f")×").font(.caption.monospaced()).frame(width: 40)
                }
                Text("One shared timeline, three pooled characters. Seeking pauses the clips and samples their poses without firing markers.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: model.enabled) { model.applyEnabled() }
            .onChange(of: model.speed) { model.applySpeed() }
    }
}

private struct TimelineDemoRuntime: Component {
    weak var scene: TimelineDemoScene?
    func cloned() -> Self? { nil }
}
private struct TimelineDemoPresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    mutating func update(context: UpdateContext) { context.world.resources[TimelineDemoRuntime.self]?.scene?.refresh() }
}

@MainActor @Observable private final class TimelineDemoScene {
    var summary = "Preparing timeline"
    var loop = true
    var enabled = true
    var speed = 1.0
    private(set) var progress = 0.0
    private(set) var isPaused = false
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var clip: AnimationResource?
    @ObservationIgnored private var controllers: [AnimationPlaybackController] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 450)
    @ObservationIgnored private var markers = 0
    @ObservationIgnored private var completions = 0
    @ObservationIgnored private var lastMarker = "ready"

    func build(in content: GameViewContent) {
        let world = content.scene
        world.resources.set(TimelineDemoRuntime(scene: self)); world.addSystem(TimelineDemoPresentation.self)
        let camera = Entity(components: CameraComponent(smoothing: 0)); self.camera = camera; content.add(camera); resize(viewport)
        for y: Float in [-100, 0, 100] {
            let lane = Entity(components: SpriteComponent(color: .gray.opacity(0.4), size: [300, 2]))
            lane.position = [0, y - 24]; content.add(lane)
        }
        do {
            let spawn = try AnimationResource.group([.scale(from: [0.2, 0.2], to: .one, duration: 0.6, curve: .easeOut), .fade(from: 0, to: 1, duration: 0.6)])
            let attack = try AnimationResource.group([
                .rotate(from: 0, to: .pi * 2, duration: 0.8),
                .sequence([.scale(to: [1.5, 1.5], duration: 0.4), .scale(to: .one, duration: 0.4)])
            ])
            clip = try AnimationResource.sequence([
                spawn, .move(from: [-110, 0], to: [110, 0], duration: 1.8, curve: .easeInOut),
                attack, .move(to: [-110, 0], duration: 1.8, curve: .easeInOut),
                .group([.fade(to: 0, duration: 0.6), .scale(to: [0.2, 0.2], duration: 0.6)])
            ], name: "spawn-run-attack-return-despawn")
                .addingMarker("spawn", at: 0).addingMarker("run", at: 0.6)
                .addingMarker("attack", at: 2.4).addingMarker("return", at: 3.2)
                .addingMarker("despawn", at: 5).addingMarker("end", at: 5.6)
            let root = Entity(name: "character")
            let actor = Entity(name: "actor", components: SpriteComponent(color: .mint, size: [34, 34]))
            actor.position = [-110, 0]
            let eye = Entity(components: SpriteComponent(color: .black, size: [6, 6])); eye.position = [8, 6]; actor.addChild(eye)
            root.addChild(actor)
            pool = try EntityPool(prefab: PrefabResource(root: root), scene: world, capacity: 3, prewarm: 3)
            subscriptions = [
                world.subscribe(to: PlaybackEvents.MarkerReached.self) { [weak self] event in
                    self?.markers += 1; self?.lastMarker = event.marker.name; self?.refresh()
                },
                world.subscribe(to: PlaybackEvents.Completed.self) { [weak self] event in
                    guard let self, let root = event.entity.parent else { return }
                    completions += 1
                    do { try pool?.release(root) } catch { summary = "Recycle failed: \(error)" }
                    refresh()
                },
                world.subscribe(to: PlaybackEvents.Failed.self) { [weak self] event in self?.summary = "Playback failed: \(event.error)" }
            ]
            play()
        } catch { summary = "Timeline error: \(error)" }
    }
    func resize(_ size: CGSize) {
        viewport = size
        if size.width > 0 && size.height > 0 { camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 360, size.height / 390)) }
    }
    func play() {
        guard let pool, let clip else { return }
        recycle(); markers = 0; completions = 0; lastMarker = "ready"
        do {
            for index in 0..<3 {
                guard let root = try pool.acquire(configure: { root in
                    root.position = [0, Float(index - 1) * 100]
                    let actor = root.findEntity(named: "actor")!
                    actor.transform = Transform(translation: [-110, 0])
                    actor.components[SpriteComponent.self]?.opacity = 0
                    actor.components[SpriteComponent.self]?.color = [Color.mint, .orange, .pink][index]
                }), let actor = root.findEntity(named: "actor") else { continue }
                controllers.append(try actor.playAnimation(clip, options: .init(repeatMode: loop ? .forever : .once, speed: speed)))
            }
            refresh()
        } catch { summary = "Playback error: \(error)" }
    }
    func togglePause() {
        if isPaused { for controller in controllers { controller.resume() } }
        else { for controller in controllers { controller.pause() } }
        refresh()
    }
    func stop() { for controller in controllers { controller.stop() }; refresh() }
    func recycle() {
        do { for root in pool?.leasedEntities ?? [] { try pool?.release(root) } }
        catch { summary = "Recycle error: \(error)" }
        controllers = []; refresh()
    }
    func seek(_ fraction: Double) {
        do {
            for controller in controllers where controller.state == .playing || controller.state == .paused {
                controller.pause(); try controller.seek(to: controller.duration * fraction)
            }
            refresh()
        } catch { summary = "Seek error: \(error)" }
    }
    func applyEnabled() { pool?.container.isEnabled = enabled; refresh() }
    func applySpeed() { for controller in controllers { controller.speed = speed }; refresh() }
    func refresh() {
        let current = controllers.first
        progress = (current?.currentTime ?? 0) / (clip?.duration ?? 1)
        isPaused = current?.state == .paused
        let text = "\(pool?.leasedCount ?? 0)/3 leased · \(markers) markers · \(completions) completed\n\(current?.state.rawValue ?? "ready") · last: \(lastMarker)"
        if summary != text { summary = text }
    }
}

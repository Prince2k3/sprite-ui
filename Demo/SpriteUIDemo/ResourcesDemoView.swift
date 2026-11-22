import SpriteUI
import SwiftUI

/// Loads the procedural Runner.atlas and WAV made by make-playback-resources.py.
struct ResourcesDemoView: View {
    @State private var model = ResourceDemoScene()
    @State private var paused = false
    @State private var speed = 1.0
    @State private var looping = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 14) {
            GameView { content in await model.build(in: content) } update: { content in
                content.scene.isPaused = paused
                content.scene.timeScale = speed
            }
            .overlay(alignment: .top) {
                Text(model.message).font(.caption.monospaced()).padding(10).background(.ultraThinMaterial, in: Capsule())
            }
            VStack(spacing: 12) {
                Text("Clip: \(model.animation?.state.rawValue ?? "ready") · \(model.animation?.currentTime ?? 0, specifier: "%.2f")s")
                HStack {
                    Button("Play clip") { model.playClip(loop: looping) }
                    Button(model.animation?.state == .paused ? "Resume clip" : "Pause clip") { model.toggleClip() }
                }
                HStack {
                    Button("Play sound") { model.playSound(loop: looping) }
                    Button(model.audio?.state == .paused ? "Resume sound" : "Pause sound") { model.toggleSound() }
                }
                Text("Sound: \(model.audio?.state.rawValue ?? "ready") · \(model.audio?.currentTime ?? 0, specifier: "%.2f")s")
                HStack {
                    Toggle("Loop", isOn: $looping)
                    Toggle("Scene paused", isOn: $paused)
                }.toggleStyle(.button)
                HStack {
                    Text("Scene speed").font(.caption)
                    Slider(value: $speed, in: 0.5...2)
                    Text("\(speed, specifier: "%.1f")×").monospacedDigit().frame(width: 40)
                }
                HStack {
                    Button("Stop all") { model.stop() }
                    Text("\(model.completions) completions").font(.caption.monospaced())
                }
            }.buttonStyle(.bordered).disabled(model.clip == nil).padding(.horizontal)
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { paused = true } }
        .padding(.vertical).background(Color.black).tint(.orange).preferredColorScheme(.dark)
    }
}

@MainActor @Observable
private final class ResourceDemoScene {
    var message = "Loading atlas and audio…"
    var clip: AnimationResource?
    var animation: AnimationPlaybackController?
    var audio: AudioPlaybackController?
    var completions = 0
    @ObservationIgnored private var sound: AudioResource?
    @ObservationIgnored private var hero: Entity?
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private let library = ResourceLibrary()

    func build(in content: GameViewContent) async {
        do {
            let atlas = try await library.atlas(named: "Runner")
            sound = try await library.audio(named: "playback-demo.wav")
            clip = try atlas.animation(named: "run", frames: atlas.textureNames, framesPerSecond: 8)
            guard let clip else { return }
            let hero = Entity(name: "runner", components: SpriteComponent(texture: clip.frames[0], size: [160, 160]))
            content.add(hero); self.hero = hero
            subscriptions = [
                content.subscribe(to: PlaybackEvents.Completed.self) { [weak self] _ in self?.completions += 1 },
                content.subscribe(to: PlaybackEvents.Failed.self) { [weak self] event in self?.message = "Playback failed: \(event.error)" },
            ]
            message = "\(atlas.textureNames.count) cached frames · shared clips · independent voices"
            playClip(loop: true)
        } catch { message = "Couldn’t load resources: \(error.localizedDescription)" }
    }
    func playClip(loop: Bool) {
        guard let hero, let clip else { return }
        animation = try? hero.playAnimation(clip, options: .init(repeatMode: loop ? .forever : .once))
    }
    func playSound(loop: Bool) {
        guard let hero, let sound else { return }
        do { audio = try hero.playAudio(sound, options: .init(repeatMode: loop ? .forever : .once), volume: 0.4) }
        catch { message = "Couldn’t play audio: \(error.localizedDescription)" }
    }
    func toggleClip() { if animation?.state == .paused { animation?.resume() } else { animation?.pause() } }
    func toggleSound() { if audio?.state == .paused { audio?.resume() } else { audio?.pause() } }
    func stop() { hero?.stopAllPlayback() }
}

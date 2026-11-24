import Observation
import SpriteUI
import SwiftUI

// Replace ContentView.swift with this entire file; keep the app entry point.
@MainActor
struct ContentView: View {
    @State private var scene = RenderScene()
    @State private var monitor = GameRenderMonitor()
    @State private var scale = 1.0
    @State private var fps = 60

    private var configuration: GameRenderConfiguration {
        GameRenderConfiguration(resolutionScale: scale, preferredFramesPerSecond: fps,
                                maximumRenderPixels: 4_000_000, maximumTextureDimension: 2048,
                                adaptsToSystemPressure: true)
    }

    private var arena: some View {
        GameView(rendering: configuration, renderMonitor: monitor) { scene.install(in: $0) } attachments: {
            GameAttachment(id: "label") { Text("Native SwiftUI label").font(.caption.bold()) }
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in scene.taps += 1 })
        .frame(height: 240)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bounded rendering · stage 1").font(.headline)
                HStack {
                    Text("Requested scale \(scale, specifier: "%.2f")")
                    Slider(value: $scale, in: 0.1...1)
                }
                Picker("Preferred FPS", selection: $fps) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }.pickerStyle(.segmented)
                arena
                RenderReadout(monitor: monitor)
                Text("World updates \(scene.updates) · Time \(scene.sceneTime, specifier: "%.2f")s")
                Text("Contacts \(scene.contacts) · Taps \(scene.taps) · Max delta \(scene.largestDelta, specifier: "%.3f")s")
                    .font(.caption.monospacedDigit())
                Text("Tap the cyan sprite in the primary. Quality changes pixels, not point geometry.")
                    .font(.caption)
            }
            .padding()
        }
        .background(.black).preferredColorScheme(.dark)
    }
}

@MainActor @Observable
private final class RenderScene {
    let leftCamera = Entity(components: CameraComponent(smoothing: 0))
    let rightCamera = Entity(components: CameraComponent(smoothing: 0))
    var updates = 0
    var sceneTime = 0.0
    var largestDelta = 0.0
    var contacts = 0
    var taps = 0
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    var viewports: [GameViewport] {
        [GameViewport(id: "left", camera: leftCamera.id,
                      frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
         GameViewport(id: "right", camera: rightCamera.id,
                      frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
    }

    func install(in content: GameViewContent) {
        leftCamera.position = [-90, 0]
        rightCamera.position = [90, 0]
        content.add(leftCamera); content.add(rightCamera)
        let player = Entity(name: "Moving player", components:
            SpriteComponent(color: .cyan, size: [40, 40]),
            CollisionComponent(shape: .rectangle(size: [48, 48])), InputTargetComponent())
        player.addChild(Entity(components: AttachmentComponent(id: "label", offset: [0, 36])))
        content.add(player)
        let wall = Entity(components: PhysicsBodyComponent(
            shape: .edgeLoop(rectangle: [180, 50]), friction: 0, restitution: 1,
            categoryBitMask: 1, collisionBitMask: 2))
        wall.position = [0, -70]
        content.add(wall)
        let probe = Entity(components:
            SpriteComponent(color: .orange, size: [14, 14]),
            PhysicsBodyComponent(shape: .circle(radius: 7), friction: 0, restitution: 1,
                                 linearDamping: 0, affectedByGravity: false, allowsRotation: false,
                                 categoryBitMask: 2, collisionBitMask: 1, contactTestBitMask: 1,
                                 velocity: [90, 0]))
        probe.position = [0, -70]
        content.add(probe)
        subscriptions = [
            content.subscribe(to: WorldEvents.Update.self) { [weak self, weak player] event in
                guard let self else { return }
                updates += 1
                sceneTime += event.deltaTime
                largestDelta = max(largestDelta, event.deltaTime)
                player?.position.x = Float(sin(sceneTime) * 100)
            },
            content.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] _ in
                self?.contacts += 1
            }
        ]
    }
}

@MainActor
private struct RenderReadout: View {
    let monitor: GameRenderMonitor
    var body: some View {
        if let stats = monitor.latest {
            VStack(alignment: .leading) {
                Text("Points \(Int(stats.logicalSize.width)) × \(Int(stats.logicalSize.height)) · Pixels \(Int(stats.drawableSize.width)) × \(Int(stats.drawableSize.height))")
                Text("Panes \(stats.renderedViewportCount) · Planned pixels \(stats.renderPixels)")
                Text("Target reservation estimate \(stats.estimatedRenderTargetBytes) bytes")
                Text("Effective scale \(stats.effectiveResolutionScale, specifier: "%.2f") · Preferred FPS \(stats.preferredFramesPerSecond)")
                Text("Primary frame \(stats.frameNumber) · Published \(stats.presentationFrameCount) · Drops \(stats.droppedPresentationFrames)")
            }
            .font(.caption.monospacedDigit())
        } else {
            Text("Waiting for render statistics").font(.caption)
        }
    }
}

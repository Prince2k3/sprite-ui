import Observation
import SpriteUI
import SwiftUI

private extension RenderLayer {
    static let map = RenderLayer(rawValue: 1 << 1)
}

@MainActor @Observable
private final class LayerScene {
    var hidden = false
    var contacts = 0
    var elapsed: TimeInterval = 0
    @ObservationIgnored let worldCamera = Entity(components:
        CameraComponent(smoothing: 0, cullingMask: .default))
    @ObservationIgnored let mapCamera = Entity(components:
        CameraComponent(smoothing: 0, cullingMask: .map))
    @ObservationIgnored private var bodies: [Entity] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    var viewports: [GameViewport] {
        [GameViewport(id: "world", camera: worldCamera.id,
                      frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
         GameViewport(id: "map", camera: mapCamera.id,
                      frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
    }

    func install(in content: GameViewContent) {
        content.renderer.backgroundColor = .black
        let room = Entity(components:
            PhysicsBodyComponent(shape: .edgeLoop(rectangle: [130, 210]), friction: 0,
                                 restitution: 1, categoryBitMask: 1, collisionBitMask: 2))
        // These untagged walls remain visible in both cameras.
        for y in [Float(-105), 105] {
            let wall = Entity(components: SpriteComponent(color: .gray, size: [130, 1]))
            wall.position = [0, y]; room.addChild(wall)
        }
        for x in [Float(-65), 65] {
            let wall = Entity(components: SpriteComponent(color: .gray, size: [1, 210]))
            wall.position = [x, 0]; room.addChild(wall)
        }
        content.add(room)
        for index in 0..<2 {
            let object = Entity(name: index == 0 ? "Comet" : "Kite", components:
                VisibilityComponent(layers: [.default, .map]),
                PhysicsBodyComponent(shape: .circle(radius: 14), friction: 0, restitution: 1,
                                     linearDamping: 0, affectedByGravity: false, allowsRotation: false,
                                     categoryBitMask: 2, collisionBitMask: 1, contactTestBitMask: 1,
                                     velocity: index == 0 ? [43, 61] : [-37, -53]))
            object.position = index == 0 ? [-30, -45] : [30, 45]
            let square = Entity(components:
                SpriteComponent(color: index == 0 ? .cyan : .orange, size: [28, 28]),
                VisibilityComponent(layers: .default))
            let diamond = Entity(components:
                SpriteComponent(color: index == 0 ? .mint : .yellow, size: [12, 12]),
                VisibilityComponent(layers: .map))
            diamond.rotation = .pi / 4
            object.addChild(square); object.addChild(diamond)
            bodies.append(object); content.add(object)
        }
        content.add(worldCamera); content.add(mapCamera)
        applyVisibility()
        subscriptions = [
            content.subscribe(to: WorldEvents.Update.self) { [weak self] event in
                self?.elapsed += event.deltaTime
            },
            content.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] _ in
                self?.contacts += 1
            }
        ]
    }

    func applyVisibility() {
        for object in bodies { object.components[VisibilityComponent.self]?.isVisible = !hidden }
    }
}

@MainActor
private struct Activity: View {
    let scene: LayerScene
    var body: some View {
        Text("Bounces \(scene.contacts) · Time \(scene.elapsed, specifier: "%.1f")s")
            .font(.caption.monospacedDigit())
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = LayerScene()
    var body: some View {
        VStack(spacing: 12) {
            Text("WORLD                          MAP").font(.caption.bold())
            GameView(viewports: scene.viewports) { scene.install(in: $0) }
                .frame(height: 280)
                .overlay {
                    Rectangle().fill(.gray).frame(width: 1).allowsHitTesting(false)
                }
            Toggle("Hide both objects", isOn: $scene.hidden)
            Activity(scene: scene)
            Text("Wait while hidden. Bounces continue; show the objects to see their new positions.")
                .font(.caption)
        }
        .padding(12).background(.black).preferredColorScheme(.dark)
        .onChange(of: scene.hidden) { _, _ in scene.applyVisibility() }
    }
}

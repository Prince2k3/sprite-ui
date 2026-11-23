import SpriteUI
import SwiftUI
import Observation

@MainActor
@Observable
final class FirstSceneModel {
    let player = Entity(name: "player", components:
        SpriteComponent(color: .cyan, size: [36, 36]))
    let marker = Entity(name: "destination", components:
        SpriteComponent(color: .orange, size: [16, 16]))
    var usesWarmColor = false

    func install(in content: GameViewContent) {
        player.position = [-80, 0]
        marker.position = [80, 0]
        content.add(marker)
        content.add(player)
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = FirstSceneModel()

    var body: some View {
        VStack {
            GameView { content in
                scene.install(in: content)
            } update: { _ in
                scene.player.components[SpriteComponent.self]?.color =
                    scene.usesWarmColor ? .orange : .cyan
            }
            .frame(height: 320)
            Button("Change player color") {
                scene.usesWarmColor.toggle()
            }
        }
    }
}

import SpriteUI
import SwiftUI
import Observation

@MainActor
@Observable
final class FirstSceneModel {
    let player = Entity(name: "player", components:
        SpriteComponent(color: .cyan, size: [36, 36]))

    func install(in content: GameViewContent) {
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
            }
            .frame(height: 320)
        }
    }
}

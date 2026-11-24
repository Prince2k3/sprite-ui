import Observation
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model = HingeReadoutScene()
    @State private var hinge: GameHingeState?

    var body: some View {
        VStack(spacing: 12) {
            GameView { content in
                model.install(in: content)
            } update: { content in
                // Last observed telemetry drives an effect, never layout or action readiness.
                let amount = Float(content.hingeState?.openness ?? 0)
                model.sprite.scale = [1 + amount, 1]
            } attachments: {
                GameAttachment(id: "hinge-label") { HingeAttachmentLabel() }
            }
            .onGameHingeChange { hinge = $0 }
            .frame(height: 260)
            if let hinge {
                Text("Last angle: \(hinge.angle, specifier: "%.3f") rad")
                Text("Last openness: \(hinge.openness, specifier: "%.2f")")
                Text("Last OS status: \(String(describing: hinge.status))")
            } else {
                Text("Live hinge unavailable")
            }
            Text("Hinge events: \(model.changes)")
            Text("Last observed telemetry is retained while observation pauses. Layout follows surface geometry.")
                .font(.caption)
        }
        .padding().preferredColorScheme(.dark)
    }
}

@MainActor
private struct HingeAttachmentLabel: View {
    @Environment(\.gameHingeState) private var hinge

    var body: some View {
        Text(hinge == nil ? "No live hinge" : "Last hinge sample")
            .font(.caption).padding(4).background(.black.opacity(0.8))
    }
}

@MainActor @Observable
private final class HingeReadoutScene {
    let sprite = Entity(components: SpriteComponent(color: .cyan, size: [40, 40]))
    var changes = 0
    @ObservationIgnored private var subscription: EventSubscription?

    func install(in content: GameViewContent) {
        content.add(sprite)
        if let label = content.attachments.entity(for: "hinge-label") {
            label.position = [0, 44]
            sprite.addChild(label)
        }
        subscription = content.subscribe(to: GameHingeEvents.DidChange.self) { [weak self] _ in
            self?.changes += 1
        }
    }
}

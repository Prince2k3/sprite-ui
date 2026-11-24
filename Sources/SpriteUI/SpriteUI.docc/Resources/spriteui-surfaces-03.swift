import Observation
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model = SurfacePlayers()
    @State private var layout = SurfaceLayout.book
    @State private var surface = GameSurfaceGeometry(size: .zero)
    @Environment(\.scenePhase) private var scenePhase
    private let hudSize = CGSize(width: 156, height: 44)

    var body: some View {
        VStack(spacing: 12) {
            Picker("Surface fixture", selection: $layout) {
                ForEach(SurfaceLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            GeometryReader { proxy in
                GameView(viewports: model.scene.viewports,
                         surfaceRegions: layout.regions(in: proxy.size)) { content in
                    model.install(in: content)
                } update: { content in
                    model.scene.beacon.isEnabled = content.surfaceGeometry.largestUsableRegion.width >= 120
                } attachments: {
                    GameAttachment(id: "player-label") { SurfacePlayerLabel() }
                }
                .onGameSurfaceChange { next in
                    if surface.size != next.size || surface.safeBounds != next.safeBounds
                        || surface.usableRegions() != next.usableRegions() {
                        model.release()
                    }
                    surface = next
                }
                .overlay { SurfaceOutline(geometry: surface) }
                .overlay(alignment: .topLeading) {
                    if let rect = surface.placement(of: hudSize, anchor: [1, 1]) {
                        Button(model.held ? "Stop P1" : "Move P1 right") { model.toggle() }
                            .buttonStyle(.borderedProminent)
                            .frame(width: hudSize.width, height: hudSize.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(height: 320)
            .gameInput(model.hub)
            Button("Stop P1") { model.release() }
            Text("\(surface.usableRegions().count) usable · \(model.surfaceChanges) surface events")
                .font(.caption)
            Text(model.status).font(.caption)
            Text("Tap Move to hold. Change fixture or resize: the virtual control releases and the player stays in the world.")
                .font(.caption)
        }
        .padding().background(.black).preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.release() }
        }
        .onDisappear { model.release() }
    }
}

@MainActor
private struct SurfacePlayerLabel: View {
    // This view is an attachment descendant, so the host supplies this environment.
    @Environment(\.gameSurfaceGeometry) private var surface
    var body: some View {
        Text("P1 · \(surface.usableRegions().count) regions")
            .font(.caption).padding(4).background(.black.opacity(0.85))
            .frame(width: 120)
    }
}

private struct SurfaceDriver: Component {
    let input: InputController
    @MainActor func cloned() -> Self? { nil }
}

@MainActor
private struct SurfaceMovement: System {
    private let query = EntityQuery(where: .has(SurfaceDriver.self))
    init(world: World) {}
    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard let driver = entity.components[SurfaceDriver.self] else { continue }
            entity.position += driver.input.value(for: SurfacePlayers.move).vector
                * 70 * Float(context.deltaTime)
        }
    }
}

@MainActor @Observable
private final class SurfacePlayers {
    static let move = InputAction("move", kind: .axis2D)
    let scene = SurfaceScene()
    let hub = PlayerInputHub()
    let pad = InputDevice.virtual("surface-pad")
    let player: PlayerInputSession
    var held = false
    var surfaceChanges = 0
    var status = "One player session; layout changes preserve its device assignment."
    @ObservationIgnored private var subscription: EventSubscription?

    init() {
        player = hub.addPlayer(named: "P1", contexts: [
            InputActionMap(name: "Play", bindings: [
                InputBinding(Self.move, control: .virtual("right"), scale: [1, 0])
            ])
        ])
        hub.connect(InputDeviceInfo(id: pad, name: "Surface pad"))
        do { try hub.assign(pad, to: player) }
        catch { status = "Pad assignment failed: \(error)" }
    }

    func install(in content: GameViewContent) {
        scene.install(in: content)
        scene.first.components.set(SurfaceDriver(input: player.input))
        if let label = content.attachments.entity(for: "player-label") {
            label.position = [0, 36]
            label.components.set(AttachmentComponent(id: "player-label", viewportID: "p1",
                                                     avoidsReservedRegions: true))
            scene.first.addChild(label)
        }
        do { try content.world.systems.add(SurfaceMovement.self) }
        catch { status = "Movement setup failed: \(error)" }
        subscription = content.subscribe(to: GameSurfaceEvents.DidChange.self) { [weak self] _ in
            self?.surfaceChanges += 1
        }
    }

    func toggle() {
        held.toggle()
        hub.submit([(.virtual("right"), .button(held))], device: pad)
    }

    func release() {
        held = false
        hub.submit([(.virtual("right"), .button(false))], device: pad)
    }
}

@MainActor
private final class SurfaceScene {
    let first = Entity(name: "P1", components: SpriteComponent(color: .cyan, size: [32, 32]))
    let second = Entity(name: "P2", components: SpriteComponent(color: .orange, size: [32, 32]))
    let firstCamera = Entity(components: CameraComponent(target: .named("P1"), smoothing: 0))
    let secondCamera = Entity(components: CameraComponent(target: .named("P2"), smoothing: 0))
    let beacon = Entity(components: SpriteComponent(color: .mint, size: [20, 48]))

    var viewports: [GameViewport] {
        [GameViewport(id: "p1", camera: firstCamera.id, region: .usable(0)),
         GameViewport(id: "p2", camera: secondCamera.id, region: .usable(1))]
    }

    func install(in content: GameViewContent) {
        first.position = [-80, 0]; second.position = [80, 0]
        firstCamera.position = first.position; secondCamera.position = second.position
        beacon.position = [0, 60]
        for entity in [first, second, firstCamera, secondCamera, beacon] { content.add(entity) }
    }
}

private enum SurfaceLayout: String, CaseIterable {
    case native = "Native", clear = "Clear", book = "Book", tabletop = "Tabletop", inactive = "Inactive"

    func regions(in size: CGSize) -> [GameSurfaceGeometry.ReservedRegion]? {
        switch self {
        case .native: return nil
        case .clear: return []
        case .book, .inactive:
            return [.init(id: "demo-spine", kind: .division,
                          frame: CGRect(x: max(0, size.width / 2 - 10), y: 0,
                                        width: 20, height: size.height),
                          isActive: self != .inactive)]
        case .tabletop:
            return [.init(id: "demo-fold", kind: .division,
                          frame: CGRect(x: 0, y: max(0, size.height / 2 - 10),
                                        width: size.width, height: 20))]
        }
    }
}

@MainActor
private struct SurfaceOutline: View {
    let geometry: GameSurfaceGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(geometry.reservedRegions, id: \.id) { region in
                Rectangle()
                    .fill(region.isActive ? Color.red.opacity(0.5) : Color.yellow.opacity(0.25))
                    .frame(width: region.frame.width, height: region.frame.height)
                    .position(x: region.frame.midX, y: region.frame.midY)
            }
            ForEach(Array(geometry.usableRegions().enumerated()), id: \.offset) { item in
                Rectangle().strokeBorder(.mint, lineWidth: 2)
                    .overlay(alignment: .topLeading) {
                        Text("Usable \(item.offset)").font(.caption2).padding(4)
                    }
                    .frame(width: item.element.width, height: item.element.height)
                    .position(x: item.element.midX, y: item.element.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

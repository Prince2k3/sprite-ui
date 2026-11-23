import Observation
import SpriteUI
import SwiftUI

/// One world, two independently driven players, and three native camera passes.
@MainActor
struct ViewportDemoView: View {
    @State private var model = ViewportDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Picker("Viewport layout", selection: $model.layout) {
                    ForEach(ViewportDemoLayout.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("viewport-layout")

                GameView(viewports: model.viewports) { model.install(in: $0) } attachments: {
                    GameAttachment(id: "name") { context in
                        Text(context.entity.parent?.name ?? "Player")
                            .font(.system(size: context.viewportID == "map" ? 8 : 12, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.8), in: Capsule())
                    }
                    GameAttachment(id: "selection") { context in
                        Text("Selected · \(context.viewportID ?? "legacy")")
                            .font(.caption2.bold()).padding(4)
                            .background(.yellow, in: Capsule()).foregroundStyle(.black)
                    }
                }
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded {
                    model.select($0.entity, in: $0.viewportID)
                })
                .overlay { ViewportDemoFrames(viewports: model.viewports) }
                .frame(height: 360)
                .clipped()
                .gameInput(model.hub)
                .accessibilityLabel("Shared arena. Tap a player or landmark in either player viewport to select it")
                .accessibilityIdentifier("viewport-arena")

                ViewportDemoCounters(model: model)
                ForEach(0..<2, id: \.self) { index in
                    ViewportDemoPad(model: model, index: index)
                }
                Text("Tap an arrow to keep moving; Stop releases it. Tap a sprite to select in that pane. Map ignores taps.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ViewportDemoSelection(model: model)
                DisclosureGroup("Optional keyboard / controller assignment") {
                    ForEach(model.hub.devices.filter { !model.pads.contains($0.id) && $0.id != .pointer }, id: \.id) { device in
                        HStack {
                            Text("\(device.name) → \(model.hub.owner(of: device.id)?.name ?? "unassigned")")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(model.hub.players) { player in
                                Button(player.name) { model.assign(device.id, to: player) }
                                    .accessibilityLabel("Assign \(device.name) to \(player.name)")
                            }
                        }
                        .font(.caption).buttonStyle(.bordered)
                    }
                    Text("Assign Keyboard, focus the arena, then use WASD. Controllers use the left stick. Virtual pads need no hardware.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption)
                if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.red) }
            }
            .padding(10)
        }
        .background(.black).preferredColorScheme(.dark)
        .onChange(of: model.layout) { _, _ in model.releasePads() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.releasePads() }
        }
        .onDisappear { model.releasePads() }
    }
}

private enum ViewportDemoLayout: String, CaseIterable {
    case sideBySide = "Side by side", stacked = "Stacked", single = "Single"
}

@MainActor
private struct ViewportDemoFrames: View {
    let viewports: [GameViewport]

    var body: some View {
        GeometryReader { geometry in
            ForEach(viewports) { viewport in
                let rect = viewport.frame.rect(in: geometry.size)
                Rectangle()
                    .strokeBorder(viewport.id == "p1" ? Color.cyan : viewport.id == "p2" ? .orange : .white,
                                  lineWidth: 2)
                    .overlay(alignment: .topLeading) {
                        Text(viewport.id == "map" ? "MAP · view only" : viewport.id.uppercased())
                            .font(.caption2.bold()).padding(4).background(.black.opacity(0.85))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Keep frame-rate observation out of the GameView's configuration evaluation.
@MainActor
private struct ViewportDemoCounters: View {
    let model: ViewportDemoModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("World updates \(model.updates) · Finished \(model.finishedFrames)")
            Text("Contacts \(model.contacts) · Scene time \(model.sceneTime, specifier: "%.1f")s")
        }
        .font(.caption.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("viewport-world-counts")
    }
}

@MainActor
private struct ViewportDemoSelection: View {
    let model: ViewportDemoModel
    var body: some View {
        Text("P1: \(model.selections["p1"] ?? "no selection") · P2: \(model.selections["p2"] ?? "no selection")")
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("viewport-selections")
    }
}

@MainActor
private struct ViewportDemoPad: View {
    let model: ViewportDemoModel
    let index: Int
    private var color: Color { index == 0 ? .cyan : .orange }

    var body: some View {
        HStack(spacing: 4) {
            Text("P\(index + 1)").font(.subheadline.bold()).foregroundStyle(color).frame(width: 28)
            ForEach(ViewportDemoModel.directions, id: \.name) { direction in
                Button { model.move(index, direction: direction.name) } label: {
                    Image(systemName: direction.symbol).frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Move P\(index + 1) \(direction.name); keeps moving until Stop")
                .background(model.heldDirections[index] == direction.name ? color.opacity(0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
            }
            Button { model.move(index, direction: nil) } label: {
                Text("Stop").font(.caption.bold()).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Stop P\(index + 1)")
        }
        .buttonStyle(.plain).tint(color)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ViewportDemoDriver: Component {
    let input: InputController
    @MainActor func cloned() -> Self? { nil }
}

@MainActor
private struct ViewportDemoMovement: System {
    private let query = EntityQuery(where: .has(ViewportDemoDriver.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard let driver = entity.components[ViewportDemoDriver.self] else { continue }
            entity.position += driver.input.value(for: ViewportDemoModel.moveAction).vector
                * 90 * Float(context.deltaTime)
            entity.position.x = min(300, max(-300, entity.position.x))
            entity.position.y = min(170, max(-170, entity.position.y))
        }
    }
}

@MainActor @Observable
private final class ViewportDemoModel {
    static let moveAction = InputAction("move", kind: .axis2D)
    static let directions: [(name: String, symbol: String, vector: SIMD2<Float>)] = [
        ("left", "arrow.left", [-1, 0]), ("right", "arrow.right", [1, 0]),
        ("up", "arrow.up", [0, 1]), ("down", "arrow.down", [0, -1])
    ]
    let hub = PlayerInputHub()
    let pads = [InputDevice.virtual("viewport-p1"), .virtual("viewport-p2")]
    var layout = ViewportDemoLayout.sideBySide
    var heldDirections: [Int: String] = [:]
    var selections: [String: String] = [:]
    var updates = 0
    var finishedFrames = 0
    var contacts = 0
    var sceneTime: TimeInterval = 0
    var status = ""
    @ObservationIgnored private let cameras = [
        Entity(name: "P1 camera", components: CameraComponent(target: .named("P1"), smoothing: 0.12)),
        Entity(name: "P2 camera", components: CameraComponent(target: .named("P2"), smoothing: 0.12)),
        Entity(name: "Map camera", components: CameraComponent(zoom: 0.14, smoothing: 0))
    ]
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var selectionAnchors: [String: Entity] = [:]

    var viewports: [GameViewport] {
        let first: ViewportRect
        let second: ViewportRect
        switch layout {
        case .sideBySide:
            first = .init(x: 0, y: 0, width: 0.5, height: 1)
            second = .init(x: 0.5, y: 0, width: 0.5, height: 1)
        case .stacked:
            first = .init(x: 0, y: 0, width: 1, height: 0.5)
            second = .init(x: 0, y: 0.5, width: 1, height: 0.5)
        case .single:
            first = .full
            second = .init(x: 0, y: 0, width: 0, height: 0)
        }
        var result = [GameViewport(id: "p1", camera: cameras[0].id, frame: first)]
        if layout != .single { result.append(GameViewport(id: "p2", camera: cameras[1].id, frame: second)) }
        result.append(GameViewport(id: "map", camera: cameras[2].id,
                                   frame: .init(x: 0.68, y: 0.04, width: 0.28, height: 0.24),
                                   isInteractive: false))
        return result
    }

    init() {
        let map = InputActionMap(name: "Viewport play", bindings: Self.directions.map {
            InputBinding(Self.moveAction, control: .virtual($0.name), scale: $0.vector)
        } + [
            InputBinding(Self.moveAction, control: .key("a"), scale: [-1, 0]),
            InputBinding(Self.moveAction, control: .key("d"), scale: [1, 0]),
            InputBinding(Self.moveAction, control: .key("w"), scale: [0, 1]),
            InputBinding(Self.moveAction, control: .key("s"), scale: [0, -1]),
            InputBinding(Self.moveAction, control: .gamepadAxis(.leftStick), deadZone: 0.2)
        ])
        for index in 0..<2 {
            let player = hub.addPlayer(named: "P\(index + 1)", contexts: [map])
            hub.connect(InputDeviceInfo(id: pads[index], name: "P\(index + 1) virtual pad"))
            do { try hub.assign(pads[index], to: player) }
            catch { status = "Pad setup failed: \(error)" }
        }
        cameras[0].position = [-100, 40]
        cameras[1].position = [100, 40]
    }

    func install(in content: GameViewContent) {
        content.renderer.backgroundColor = .black
        for x in stride(from: -360, through: 360, by: 60) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.12), size: [1, 440]))
            line.position = [Float(x), 0]; line.zPosition = -10; content.add(line)
        }
        for y in stride(from: -220, through: 220, by: 55) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.12), size: [720, 1]))
            line.position = [0, Float(y)]; line.zPosition = -10; content.add(line)
        }
        for (index, player) in hub.players.enumerated() {
            let entity = Entity(name: player.name, components:
                SpriteComponent(color: index == 0 ? .cyan : .orange, size: [32, 32]),
                CollisionComponent(shape: .rectangle(size: [44, 44])), InputTargetComponent(),
                ViewportDemoDriver(input: player.input))
            entity.position = [index == 0 ? -100 : 100, 40]
            // Nil viewportID projects this same label in both panes and the map.
            entity.addChild(Entity(components: AttachmentComponent(id: "name", offset: [0, 30])))
            content.add(entity)
        }
        let landmark = Entity(name: "Shared beacon", components:
            SpriteComponent(color: .mint, size: [24, 48]),
            CollisionComponent(shape: .rectangle(size: [36, 56])), InputTargetComponent())
        landmark.position = [0, 75]; content.add(landmark)
        for camera in cameras { content.add(camera) }
        addContactProbe(in: content)
        do { try content.world.systems.add(ViewportDemoMovement.self) }
        catch { status = "Movement setup failed: \(error)" }
        subscriptions = [
            content.subscribe(to: WorldEvents.Update.self) { [weak self] event in
                self?.updates += 1
                self?.sceneTime += event.deltaTime
            },
            content.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in self?.finishedFrames += 1 },
            content.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] _ in self?.contacts += 1 }
        ]
    }

    private func addContactProbe(in content: GameViewContent) {
        let chamber = Entity(name: "Contact chamber", components:
            PhysicsBodyComponent(shape: .edgeLoop(rectangle: [120, 54]), friction: 0, restitution: 1,
                                 categoryBitMask: 1, collisionBitMask: 2))
        chamber.position = [0, -90]
        for y in [Float(-27), 27] {
            let line = Entity(components: SpriteComponent(color: .gray, size: [120, 2]))
            line.position = [0, y]; chamber.addChild(line)
        }
        for x in [Float(-60), 60] {
            let line = Entity(components: SpriteComponent(color: .gray, size: [2, 54]))
            line.position = [x, 0]; chamber.addChild(line)
        }
        let ball = Entity(name: "Contact probe", components:
            SpriteComponent(color: .yellow, size: [14, 14]),
            CollisionComponent(shape: .circle(radius: 10)), InputTargetComponent(),
            PhysicsBodyComponent(shape: .circle(radius: 7), friction: 0, restitution: 1, linearDamping: 0,
                                 affectedByGravity: false, allowsRotation: false,
                                 categoryBitMask: 2, collisionBitMask: 1, contactTestBitMask: 1,
                                 velocity: [90, 0]))
        ball.position = [0, -90]
        content.add(chamber); content.add(ball)
    }

    func move(_ index: Int, direction: String?) {
        heldDirections[index] = direction
        hub.submit(Self.directions.map { (.virtual($0.name), .button($0.name == direction)) }, device: pads[index])
    }

    func assign(_ device: InputDevice, to player: PlayerInputSession) {
        do { try hub.assign(device, to: player) }
        catch { status = "Assignment failed: \(error)" }
    }

    func releasePads() {
        for index in 0..<2 { move(index, direction: nil) }
        hub.cancelAll()
    }

    func select(_ entity: Entity, in viewportID: String?) {
        guard let viewportID, viewportID == "p1" || viewportID == "p2" else { return }
        selections[viewportID] = entity.name.isEmpty ? "Entity \(entity.id)" : entity.name
        let anchor = selectionAnchors[viewportID] ?? Entity(components:
            AttachmentComponent(id: "selection", offset: [0, -32], viewportID: viewportID))
        anchor.removeFromParent()
        entity.addChild(anchor)
        selectionAnchors[viewportID] = anchor
    }
}

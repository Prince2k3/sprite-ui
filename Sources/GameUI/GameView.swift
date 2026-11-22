import ECSCore
import SpriteBackend
import SpriteKit
import SwiftUI

/// What `GameView`'s closures get: the world to add entities to.
@MainActor
public struct GameViewContent {
    public let world: World
    /// The scene being presented. `world` remains available for existing code.
    public var scene: World { world }
    /// The SpriteKit renderer, for things the ECS doesn't cover yet.
    public let renderer: SpriteRenderer

    public var entities: [Entity] { world.entities }

    public func add(_ entity: Entity) { world.addEntity(entity) }
    public func remove(_ entity: Entity) { world.removeEntity(entity) }

    /// The scene-space point under a point in the view (SwiftUI coordinates, origin at
    /// the top left), following the active ``CameraComponent`` if there is one.
    public func scenePoint(fromView point: CGPoint) -> SIMD2<Float> {
        renderer.scenePoint(fromView: point)
    }

    public func subscribe<E: Event>(
        to type: E.Type,
        on entity: Entity? = nil,
        _ handler: @escaping @MainActor (E) -> Void
    ) -> EventSubscription {
        world.subscribe(to: type, on: entity, handler)
    }
}

/// Hosts a game world in SwiftUI, in the style of `RealityView`.
///
/// ```swift
/// GameView { content in
///     let player = Entity(components: SpriteComponent(color: .blue, size: [40, 40]))
///     content.add(player)
/// } update: { content in
///     // Runs when SwiftUI state read here changes.
/// }
/// ```
public struct GameView: View {
    public typealias Make = @MainActor (inout GameViewContent) async -> Void
    public typealias Update = @MainActor (inout GameViewContent) -> Void

    private let make: Make
    private let update: Update?
    private let showsStatistics: Bool

    @State private var host = GameHost()
    @Environment(\.scenePhase) private var scenePhase

    public init(
        showsStatistics: Bool = false,
        make: @escaping Make,
        update: Update? = nil
    ) {
        self.make = make
        self.update = update
        self.showsStatistics = showsStatistics
    }

    public var body: some View {
        SKViewHost(host: host, update: update, showsStatistics: showsStatistics)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { host.viewFrame = $0 }
            .preference(key: GameHostPreferenceKey.self, value: [GameHostReference(id: host.inputHostID, host: host)])
            .onDisappear { host.cancelInputs() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { host.cancelInputs() } }
            .task {
                guard !host.isReady else { return }
                var content = host.content
                await make(&content)
                host.isReady = true
                host.runUpdate(update)
            }
    }
}

@MainActor
final class GameHost {
    let world = World()
    lazy var renderer = SpriteRenderer(world: world)
    var content: GameViewContent { GameViewContent(world: world, renderer: renderer) }
    var isReady = false

    /// The latest `update:` closure SwiftUI handed us.
    private var update: GameView.Update?

    /// Runs `update`, re-running it when `@Observable` state it reads changes.
    func runUpdate(_ update: GameView.Update?) {
        self.update = update
        guard isReady, let update else { return }
        withObservationTracking {
            var content = content
            update(&content)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduledUpdate() }
        }
    }

    private func scheduledUpdate() {
        runUpdate(update)
    }

    // MARK: Targeted input

    var viewFrame = CGRect.zero
    let inputHostID = UUID()
    var nextInputID: UInt64 = 0
    var inputContacts: [UInt64: InputContact] = [:]
    var lastMouseTimestamp: TimeInterval?
    var mouseContact: UInt64?

}

/// An `SKView` that notes which entity a touch starts on, before SwiftUI's gestures see it.
final class GameSKView: SKView {
    weak var host: GameHost?

#if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, let superview, let event = NSApp.currentEvent,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           host?.lastMouseTimestamp != event.timestamp {
            if let previous = host?.mouseContact { host?.endInput(previous) }
            host?.lastMouseTimestamp = event.timestamp
            var local = convert(point, from: superview)
            if !isFlipped { local.y = bounds.height - local.y }
            host?.mouseContact = host?.beginInput(at: local)
        }
        return hit
    }

#endif
}

#if os(iOS) || os(tvOS) || os(visionOS)
private struct SKViewHost: UIViewRepresentable {
    let host: GameHost
    let update: GameView.Update?
    let showsStatistics: Bool

    func makeUIView(context: Context) -> SKView { makeView(host: host) }

    func updateUIView(_ view: SKView, context: Context) {
        configure(view, showsStatistics: showsStatistics)
        host.runUpdate(update)
    }
}
#elseif os(macOS)
private struct SKViewHost: NSViewRepresentable {
    let host: GameHost
    let update: GameView.Update?
    let showsStatistics: Bool

    func makeNSView(context: Context) -> SKView { makeView(host: host) }

    func updateNSView(_ view: SKView, context: Context) {
        configure(view, showsStatistics: showsStatistics)
        host.runUpdate(update)
    }
}
#endif

@MainActor
private func makeView(host: GameHost) -> SKView {
    let view = GameSKView()
    view.host = host
#if os(iOS) || os(tvOS) || os(visionOS)
    let tracking = GameInputRecognizer(target: nil, action: nil)
    tracking.host = host
    tracking.cancelsTouchesInView = false
    tracking.delaysTouchesBegan = false
    tracking.delaysTouchesEnded = false
    view.addGestureRecognizer(tracking)
#endif
    view.ignoresSiblingOrder = true
    view.presentScene(host.renderer)
    return view
}

@MainActor
private func configure(_ view: SKView, showsStatistics: Bool) {
    view.showsFPS = showsStatistics
    view.showsNodeCount = showsStatistics
    view.showsDrawCount = showsStatistics
}

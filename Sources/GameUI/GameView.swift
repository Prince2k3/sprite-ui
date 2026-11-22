import ECSCore
import SpriteBackend
import SpriteKit
import SwiftUI

/// What `GameView`'s closures get: the world to add entities to.
@MainActor
public struct GameViewContent {
    public let world: World
    /// The SpriteKit renderer, for things the ECS doesn't cover yet.
    public let renderer: SpriteRenderer

    public var entities: [Entity] { world.entities }

    public func add(_ entity: Entity) { world.addEntity(entity) }
    public func remove(_ entity: Entity) { world.removeEntity(entity) }

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

    struct TouchTarget {
        weak var host: GameHost?
        weak var entity: Entity?
    }

    /// The game view and entity under the most recent touch-down, across all game views.
    /// Targeted gestures read it; SwiftUI only reports locations.
    static var touchTarget: TouchTarget?

    func recordTouch(at viewPoint: CGPoint, in view: SKView) {
        guard view.scene === renderer else { return }
        let scenePoint = renderer.convertPoint(fromView: viewPoint)
        Self.touchTarget = TouchTarget(host: self, entity: renderer.inputTarget(at: scenePoint))
    }
}

/// An `SKView` that notes which entity a touch starts on, before SwiftUI's gestures see it.
final class GameSKView: SKView {
    weak var host: GameHost?

#if os(iOS) || os(tvOS) || os(visionOS)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches {
            host?.recordTouch(at: point, in: self)
        }
        return hit
    }
#elseif os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, let superview {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                host?.recordTouch(at: convert(point, from: superview), in: self)
            default:
                break
            }
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

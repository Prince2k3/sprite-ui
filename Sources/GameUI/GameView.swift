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
    public let attachments: GameViewAttachments

    public var entities: [Entity] { world.entities }

    public func add(_ entity: Entity) { world.addEntity(entity) }
    public func remove(_ entity: Entity) { world.removeEntity(entity) }

    /// The scene-space point under a point in the view (SwiftUI coordinates, origin at
    /// the top left), following the active ``CameraComponent`` if there is one.
    public func scenePoint(fromView point: CGPoint) -> SIMD2<Float> {
        renderer.scenePoint(fromView: point)
    }
    public func viewPoint(fromScene point: SIMD2<Float>) -> CGPoint? { renderer.viewPoint(from: point) }

    /// Converts a global surface point through a specific viewport camera. Returns
    /// nil if that view is unavailable; captured drags may extend outside its rect.
    public func scenePoint(fromView point: CGPoint, inViewport id: String) -> SIMD2<Float>? {
        renderer.scenePoint(fromView: point, inViewport: id)
    }
    /// Projects a scene point into this GameView's top-left coordinate space.
    public func viewPoint(fromScene point: SIMD2<Float>, inViewport id: String) -> CGPoint? {
        renderer.viewPoint(from: point, inViewport: id)
    }
    /// The front-most interactive viewport. Gaps and noninteractive overlays
    /// return nil instead of allowing interaction with an obscured viewport.
    public func viewport(at point: CGPoint) -> GameViewport? { renderer.viewport(at: point) }

    public func subscribe<E: Event>(
        to type: E.Type,
        on entity: Entity? = nil,
        _ handler: @escaping @MainActor (E) -> Void
    ) -> EventSubscription {
        world.subscribe(to: type, on: entity, handler)
    }
}

/// Hosts a game world in SwiftUI, in the style of `RealityView`.
/// Pass a view-scoped `debug` controller to enable collapsible diagnostics and
/// simulation controls. Explicit debug picking suppresses entity-targeted game
/// input; arbitrary ancestor gestures follow normal SwiftUI gesture arbitration.
/// Pass `viewports` to draw one shared scene through multiple cameras. All views
/// share one simulation clock; omitting it retains the original single-view host.
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
    private let viewports: [GameViewport]?
    private let debug: SceneDebugController?
    private let makeAttachments: @MainActor () -> [GameAttachment]

    @State private var host = GameHost()
    @Environment(\.scenePhase) private var scenePhase

    public init(
        viewports: [GameViewport]? = nil,
        debug: SceneDebugController? = nil,
        showsStatistics: Bool = false,
        make: @escaping Make,
        update: Update? = nil
    ) {
        self.make = make
        self.update = update
        self.showsStatistics = showsStatistics
        self.viewports = viewports
        self.debug = debug
        self.makeAttachments = { [] }
    }

    /// Defines view-scoped content to reference from AttachmentComponents. IDs
    /// must be unique within this GameView. Use makeEntity(for:) for multiple
    /// instances, or clone attachment anchors inside a prefab.
    ///
    /// ```swift
    /// GameView { content in
    ///     if let label = content.attachments.entity(for: "name") {
    ///         label.position = [0, 30]; player.addChild(label)
    ///     }
    ///     content.add(player)
    /// } attachments: {
    ///     GameAttachment(id: "name") { Text("Player") }
    /// }
    /// ```
    public init(viewports: [GameViewport]? = nil, debug: SceneDebugController? = nil, showsStatistics: Bool = false, make: @escaping Make, update: Update? = nil,
                @GameAttachmentBuilder attachments: @escaping @MainActor () -> [GameAttachment]) {
        self.make = make; self.update = update; self.showsStatistics = showsStatistics
        self.viewports = viewports
        self.debug = debug
        makeAttachments = attachments
    }

    public var body: some View {
        let definitions = makeAttachments()
        let ids = definitions.map(\.id)
        return SKViewHost(host: host, update: update, showsStatistics: showsStatistics, debug: debug, viewports: viewports)
            .overlay {
                if let debug { SceneDebugOverlay(controller: debug, host: host) }
            }
            .overlay { AttachmentOverlay(store: host.attachmentStore, definitions: definitions) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { host.viewFrame = $0 }
            .preference(key: GameHostPreferenceKey.self, value: [GameHostReference(id: host.inputHostID, host: host)])
            .onAppear {
                host.startPresentation()
                host.attachmentStore.setVisible(true)
                host.setDebugVisible(true)
                host.configureDebugController(debug)
            }
            .onDisappear { host.stopPresentation() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase != .active { host.cancelInputs() }
                host.attachmentStore.setAppActive(phase == .active)
                host.setDebugInputActive(phase == .active)
                host.setPresentationAppActive(phase == .active)
            }
            .onChange(of: ids, initial: true) { _, ids in host.attachmentStore.configure(ids) }
            .task {
                host.attachmentStore.configure(ids)
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
    lazy var attachmentStore = AttachmentStore(host: self)
    var content: GameViewContent { GameViewContent(world: world, renderer: renderer, attachments: GameViewAttachments(store: attachmentStore)) }
    var isReady = false
    let debugInput = SceneDebugInputState()
    private var requestedDebugController: SceneDebugController?
    private var debugVisible = true
    private(set) var configuredViewports: [GameViewport]?
    private var viewportConfigurationRevision: UInt64 = 0
    weak var nativeView: GameSKView?
    private var presentationVisible = true
    private var presentationAppActive = true
    var isPresentationActive: Bool { presentationVisible && presentationAppActive }

    func configureViewports(_ viewports: [GameViewport]?) {
        guard configuredViewports != viewports else { return }
        viewportConfigurationRevision &+= 1
        let revision = viewportConfigurationRevision
        configuredViewports = viewports
        renderer.viewports = viewports ?? []
        cancelInputs()
        guard revision == viewportConfigurationRevision else { return }
        nativeView?.configurePresentation()
    }

    func startPresentation() {
        presentationVisible = true
        nativeView?.updateViewportActivity()
    }

    func setPresentationAppActive(_ active: Bool) {
        presentationAppActive = active
        nativeView?.updateViewportActivity()
    }

    var activeDebugController: SceneDebugController? {
        guard debugVisible, let controller = requestedDebugController,
              renderer.debugController === controller, controller.scene === world else { return nil }
        return controller
    }

    func configureDebugController(_ controller: SceneDebugController?) {
        if requestedDebugController !== controller {
            debugInput.reset(); cancelInputs()
        }
        requestedDebugController = controller
        guard debugVisible else { return }
        if !renderer.setDebugController(controller) {
            // A rejected replacement must not leave the previous controller's
            // drawings/profiling running behind a panel owned by another scene.
            renderer.setDebugController(nil)
        }
    }

    func setDebugVisible(_ visible: Bool) {
        debugVisible = visible
        if visible {
            configureDebugController(requestedDebugController)
        } else {
            debugInput.reset(); cancelInputs()
            renderer.setDebugController(nil)
        }
    }

    func setDebugInputActive(_ active: Bool) {
        debugInput.isActive = active
        if !active { debugInput.reset(); cancelInputs() }
    }

    /// Shared by SwiftUI disappearance and native-view dismantling.
    func stopPresentation() {
        presentationVisible = false
        nativeView?.updateViewportActivity()
        attachmentStore.setVisible(false)
        setDebugVisible(false)
    }

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
    weak var actionInput: InputController?
    var manipulationInput: GameManipulationInput?
    weak var nativeInputSession: GameInputSession?
    var isCancellingInputs = false
    var nextInputID: UInt64 = 0
    var inputContacts: [UInt64: InputContact] = [:]
    var mouseContact: UInt64?

}

/// An `SKView` that notes which entity a touch starts on, before SwiftUI's gestures see it.
final class GameSKView: SKView {
    weak var host: GameHost?
    private var viewportRendering: ViewportRendering?

    func configurePresentation() {
        guard let host else { return }
        if host.configuredViewports != nil {
            if scene != nil { presentScene(nil) }
            if viewportRendering == nil { viewportRendering = ViewportRendering(host: host, container: self) }
            updateViewportActivity()
        } else {
            viewportRendering?.stop()
            viewportRendering = nil
            if scene !== host.renderer { presentScene(host.renderer) }
        }
    }

    func updateViewportActivity() {
        viewportRendering?.setActive(host?.isPresentationActive == true && window != nil)
    }

    func configureStatistics(_ enabled: Bool) { viewportRendering?.setShowsStatistics(enabled) }

    func stopTrackingInput() {
        host?.manipulationInput?.detach()
        host?.stopPresentation()
        viewportRendering?.stop()
        viewportRendering = nil
        if host?.nativeView === self { host?.nativeView = nil }
        presentScene(nil)
#if os(macOS)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
#else
        if let observer = contactObserver {
            observer.cancelTrackedContacts(); observer.view?.removeGestureRecognizer(observer); contactObserver = nil
        }
#endif
    }

#if os(macOS)
    override func layout() {
        super.layout()
        viewportRendering?.synchronizeGeometry()
    }
    private var mouseMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateViewportActivity()
        host?.manipulationInput?.windowChanged()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let id = host?.mouseContact { host?.endInput(id, cancelled: true); host?.mouseContact = nil }
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let host = self.host, event.window === self.window else { return }
                if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) {
                    if let id = host.mouseContact { host.endInput(id); host.mouseContact = nil }
                } else if host.attachmentStore.acceptsInput, !self.isHiddenOrHasHiddenAncestor {
                    var local = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(local) {
                        if let previous = host.mouseContact { host.endInput(previous, cancelled: true) }
                        let root = self.window?.contentView
                        let hitPoint = root?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                        let hit = root?.hitTest(hitPoint)
                        let sceneHit = hit === self || hit?.isDescendant(of: self) == true
                        if !self.isFlipped { local.y = self.bounds.height - local.y }
                        host.mouseContact = host.beginInput(at: local, sceneTargetAllowed: sceneHit)
                    }
                }
            }
            return event
        }
    }
#elseif os(iOS) || os(tvOS) || os(visionOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        viewportRendering?.synchronizeGeometry()
    }
    private var contactObserver: GameInputRecognizer?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateViewportActivity()
        host?.manipulationInput?.windowChanged()
        if let observer = contactObserver {
            observer.cancelTrackedContacts(); observer.view?.removeGestureRecognizer(observer)
            contactObserver = nil
        }
        guard let window else { return }
        // Observe the window so SwiftUI controls above the SKView also create
        // contacts (with no scene target), including multi-pointer ambiguity.
        let observer = GameInputRecognizer(target: nil, action: nil)
        observer.host = host; observer.coordinateView = self; observer.delegate = observer
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
        window.addGestureRecognizer(observer); contactObserver = observer
    }
#endif
}

#if os(iOS) || os(tvOS) || os(visionOS)
private struct SKViewHost: UIViewRepresentable {
    let host: GameHost
    let update: GameView.Update?
    let showsStatistics: Bool
    let debug: SceneDebugController?
    let viewports: [GameViewport]?

    func makeUIView(context: Context) -> SKView {
        host.configureViewports(viewports)
        return makeView(host: host, debug: debug)
    }

    func updateUIView(_ view: SKView, context: Context) {
        host.configureViewports(viewports)
        configure(view, showsStatistics: showsStatistics)
        host.configureDebugController(debug)
        host.runUpdate(update)
    }
    static func dismantleUIView(_ view: SKView, coordinator: ()) { (view as? GameSKView)?.stopTrackingInput() }
}
#elseif os(macOS)
private struct SKViewHost: NSViewRepresentable {
    let host: GameHost
    let update: GameView.Update?
    let showsStatistics: Bool
    let debug: SceneDebugController?
    let viewports: [GameViewport]?

    func makeNSView(context: Context) -> SKView {
        host.configureViewports(viewports)
        return makeView(host: host, debug: debug)
    }

    func updateNSView(_ view: SKView, context: Context) {
        host.configureViewports(viewports)
        configure(view, showsStatistics: showsStatistics)
        host.configureDebugController(debug)
        host.runUpdate(update)
    }
    static func dismantleNSView(_ view: SKView, coordinator: ()) { (view as? GameSKView)?.stopTrackingInput() }
}
#endif

@MainActor
private func makeView(host: GameHost, debug: SceneDebugController?) -> SKView {
    let view = GameSKView()
    view.host = host
    host.nativeView = view
    view.ignoresSiblingOrder = true
    view.configurePresentation()
    host.manipulationInput?.detach()
    let manipulation = GameManipulationInput(host: host)
    host.manipulationInput = manipulation
    manipulation.attach(to: view)
    host.setDebugVisible(true)
    host.configureDebugController(debug)
    return view
}

@MainActor
private func configure(_ view: SKView, showsStatistics: Bool) {
    view.showsFPS = showsStatistics
    view.showsNodeCount = showsStatistics
    view.showsDrawCount = showsStatistics
    (view as? GameSKView)?.configureStatistics(showsStatistics)
}

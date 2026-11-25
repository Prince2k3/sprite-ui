import ECSCore
@_spi(Backend) import SpriteBackend
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
    /// Loads levels in this same world and preserves the native input session.
    public let levels: LevelCoordinator
    private let presentation: GameLevelPresentation
    private let surfaceState: GameSurfaceState
    private let hingeStore: GameHingeStore

    /// Live geometry of this GameView in local top-left points. Reading this in
    /// `update:` observes resizing, safe-area changes, and reserved regions.
    public var surfaceGeometry: GameSurfaceGeometry { surfaceState.geometry }
    /// The last native hinge sample, or nil for an unsupported/detached hierarchy.
    /// Native samples require a physical hinge with an OS-supported sensor.
    /// Sampling pauses with presentation; angle is measured in radians.
    public var hingeState: GameHingeState? { hingeStore.state }

    init(world: World, renderer: SpriteRenderer, levels: LevelCoordinator,
         attachments: GameViewAttachments, presentation: GameLevelPresentation, surfaceState: GameSurfaceState,
         hingeStore: GameHingeStore) {
        self.world = world; self.renderer = renderer; self.levels = levels
        self.attachments = attachments; self.presentation = presentation
        self.surfaceState = surfaceState
        self.hingeStore = hingeStore
    }

    /// Captures the last game surface, excluding SwiftUI attachments.
    /// Throws when the host is hidden or has not produced a usable frame.
    public func capturePresentation() throws -> SpriteImage {
        try presentation.captureLevelPresentation()
    }
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
/// Supplying `rendering`, `renderMonitor`, or `presentation` retains a Metal
/// presentation driver for this host's lifetime. Read-only presentation views
/// consume completed frames without owning another world or input session.
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
    private let rendering: GameRenderConfiguration?
    private let renderMonitor: GameRenderMonitor?
    private let presentationSource: GamePresentationSource?
    private let surfaceRegions: [GameSurfaceGeometry.ReservedRegion]?
    private let debug: SceneDebugController?
    private let makeAttachments: @MainActor () -> [GameAttachment]

    @State private var host = GameHost()
    @Environment(\.scenePhase) private var scenePhase

    public init(
        viewports: [GameViewport]? = nil,
        rendering: GameRenderConfiguration? = nil,
        renderMonitor: GameRenderMonitor? = nil,
        presentation: GamePresentationSource? = nil,
        surfaceRegions: [GameSurfaceGeometry.ReservedRegion]? = nil,
        debug: SceneDebugController? = nil,
        showsStatistics: Bool = false,
        make: @escaping Make,
        update: Update? = nil
    ) {
        self.make = make
        self.update = update
        self.showsStatistics = showsStatistics
        self.viewports = viewports
        self.rendering = rendering; self.renderMonitor = renderMonitor; self.presentationSource = presentation
        self.surfaceRegions = surfaceRegions
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
    public init(viewports: [GameViewport]? = nil, rendering: GameRenderConfiguration? = nil,
                renderMonitor: GameRenderMonitor? = nil, presentation: GamePresentationSource? = nil,
                surfaceRegions: [GameSurfaceGeometry.ReservedRegion]? = nil, debug: SceneDebugController? = nil, showsStatistics: Bool = false, make: @escaping Make, update: Update? = nil,
                @GameAttachmentBuilder attachments: @escaping @MainActor () -> [GameAttachment]) {
        self.make = make; self.update = update; self.showsStatistics = showsStatistics
        self.viewports = viewports
        self.rendering = rendering; self.renderMonitor = renderMonitor; self.presentationSource = presentation
        self.surfaceRegions = surfaceRegions
        self.debug = debug
        makeAttachments = attachments
    }

    public var body: some View {
        let definitions = makeAttachments()
        let ids = definitions.map(\.id)
        return SKViewHost(host: host, update: update, showsStatistics: showsStatistics, debug: debug,
                          viewports: viewports, surfaceRegions: surfaceRegions, rendering: rendering,
                          renderMonitor: renderMonitor, presentationSource: presentationSource)
            .overlay {
                if let debug { SceneDebugOverlay(controller: debug, host: host) }
            }
            .overlay { AttachmentOverlay(store: host.attachmentStore, definitions: definitions) }
            .overlay { LevelPresentationOverlay(levels: host.levels) }
            .environment(\.gameSurfaceGeometry, host.surfaceState.geometry)
            .environment(\.gameHingeState, host.hingeStore.state)
            .preference(key: GameSurfacePreferenceKey.self, value: host.surfaceState.geometry)
            .preference(key: GameHingePreferenceKey.self, value: host.hingeStore.state)
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
    let surfaceState = GameSurfaceState()
    let hingeStore = GameHingeStore()
    var publishedHingeState: GameHingeState?
    var isUpdatingHinge = false
    var surfaceRegions: [GameSurfaceGeometry.ReservedRegion]?
    var isUpdatingSurface = false
    var publishedSurfaceGeometry = GameSurfaceGeometry(size: .zero)
    lazy var renderer = SpriteRenderer(world: world)
    lazy var attachmentStore = AttachmentStore(host: self)
    lazy var levelPresentation = GameLevelPresentation(host: self)
    lazy var levels: LevelCoordinator = {
        let coordinator = LevelCoordinator(world: world)
        coordinator.presentation = levelPresentation
        return coordinator
    }()
    var levelInputBlocked: Bool { levelPresentation.blocksInput }
    var content: GameViewContent { GameViewContent(world: world, renderer: renderer, levels: levels, attachments: GameViewAttachments(store: attachmentStore), presentation: levelPresentation, surfaceState: surfaceState, hingeStore: hingeStore) }
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
    var renderConfiguration: GameRenderConfiguration?
    var renderMonitor: GameRenderMonitor?
    var requestedPresentationSource: GamePresentationSource?
    var activePresentationSource: GamePresentationSource?
    let presentationOwner = UUID()
    var renderingRevision: UInt64 = 0
    var hasAdvancedRendering = false
    var requiresViewportRendering: Bool { configuredViewports != nil || hasAdvancedRendering }

    isolated deinit { activePresentationSource?.detach(owner: presentationOwner) }

    func configureViewports(_ viewports: [GameViewport]?) {
        guard configuredViewports != viewports else { return }
        viewportConfigurationRevision &+= 1
        let revision = viewportConfigurationRevision
        configuredViewports = viewports
        renderer.viewports = viewports ?? []
        cancelInputs(preservingHinge: true)
        guard revision == viewportConfigurationRevision else { return }
        nativeView?.configurePresentation()
    }

    func startPresentation() {
        presentationVisible = true
        activatePresentationSource()
        nativeView?.updateViewportActivity()
    }

    func setPresentationAppActive(_ active: Bool) {
        presentationAppActive = active
        if !active { suspendPresentationSource() }
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
        suspendPresentationSource()
        levels.cancel()
        // Cancellation after commit may finish its visuals asynchronously, but
        // an offscreen view must release its input lease immediately.
        levelPresentation.levelInputDidChange(blocked: false)
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
    weak var actionInput: InputController? {
        didSet { levelPresentation.synchronizeInputSuppression() }
    }
    var manipulationInput: GameManipulationInput?
    weak var nativeInputSession: GameInputSession? {
        didSet { levelPresentation.synchronizeInputSuppression() }
    }
    var isCancellingInputs = false
    var nextInputID: UInt64 = 0
    var inputContacts: [UInt64: InputContact] = [:]
    var mouseContact: UInt64?

}

/// An `SKView` that notes which entity a touch starts on, before SwiftUI's gestures see it.
final class GameSKView: SKView, @preconcurrency SKViewDelegate {
    weak var host: GameHost?
    private(set) var viewportRendering: ViewportRendering?
    private var hasLegacyFrame = false
    private var legacyFramePending = false

    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        synchronizeSurfaceGeometry()
        // The previous native frame has returned before SpriteKit requests the
        // next one. Capture itself never asks SpriteKit to perform an update.
        hasLegacyFrame = legacyFramePending
        legacyFramePending = true
        return true
    }

    /// A visible surface can fade before its first native frame is drawn.
    var isLevelPresentationAvailable: Bool {
        guard let host, host.isPresentationActive, !host.renderer.isUpdatingPresentation, window != nil,
              bounds.width > 0, bounds.height > 0 else { return false }
        return isNativeSurfaceVisible
    }

    var isNativeSurfaceVisible: Bool {
#if os(macOS)
        guard !isHiddenOrHasHiddenAncestor else { return false }
        var ancestor: NSView? = self
        while let view = ancestor {
            guard view.alphaValue > 0 else { return false }
            ancestor = view.superview
        }
#else
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return false }
            ancestor = view.superview
        }
#endif
        return true
    }

    /// Cross-fade capture additionally needs a previously completed game frame.
    var isLevelCaptureAvailable: Bool {
        guard isLevelPresentationAvailable, let host else { return false }
        if let viewportRendering { return viewportRendering.hasCaptureFrame }
        return scene === host.renderer && hasLegacyFrame
    }

    func captureLevelPresentation() throws -> SpriteImage {
        guard isLevelCaptureAvailable, let host else { throw LevelLoadingError.presentationUnavailable }
        if let viewportRendering { return try viewportRendering.capturePresentation() }
#if os(macOS)
        let scale = window?.backingScaleFactor ?? 1
#else
        let scale = contentScaleFactor
#endif
        return try LevelPresentationPixels.captureLegacy(scene: host.renderer, logicalSize: bounds.size, scale: scale)
    }

    func configurePresentation() {
        guard let host else { return }
        if host.requiresViewportRendering {
            if scene != nil { presentScene(nil) }
            delegate = nil
            hasLegacyFrame = false; legacyFramePending = false
            if viewportRendering == nil { viewportRendering = ViewportRendering(host: host, container: self) }
            updateViewportActivity()
        } else {
            viewportRendering?.stop()
            viewportRendering = nil
            if scene !== host.renderer {
                hasLegacyFrame = false; legacyFramePending = false
                delegate = self
                presentScene(host.renderer)
            }
        }
    }

    func updateViewportActivity() {
        updateHingeObservationActivity()
        if host?.isPresentationActive != true || window == nil { host?.suspendPresentationSource() }
        viewportRendering?.setActive(host?.isPresentationActive == true && window != nil)
        viewportRendering?.synchronizeVisibility()
    }

    func synchronizeRendering() { viewportRendering?.synchronizeGeometry() }

    func configureStatistics(_ enabled: Bool) { viewportRendering?.setShowsStatistics(enabled) }

    func stopTrackingInput() {
        stopHingeObservation()
        host?.manipulationInput?.detach()
        host?.stopPresentation()
        host?.releasePresentationSource()
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
    override var isHidden: Bool { didSet { updateViewportActivity() } }
    override var alphaValue: CGFloat { didSet { updateViewportActivity() } }
    override func layout() {
        super.layout()
        updateViewportActivity()
        synchronizeSurfaceGeometry()
        viewportRendering?.synchronizeGeometry()
    }
    private var mouseMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeSurfaceGeometry()
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
    var hingeObservation: (any UIInteraction)?
    var hingeObservationRevision: UInt64 = 0
    var nativeRegionIDs: [AnyHashable: String] = [:]
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        synchronizeSurfaceGeometry()
    }
    override var isHidden: Bool { didSet { updateViewportActivity() } }
    override var alpha: CGFloat { didSet { updateViewportActivity() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateViewportActivity()
        synchronizeSurfaceGeometry()
        viewportRendering?.synchronizeGeometry()
    }
    private var contactObserver: GameInputRecognizer?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronizeSurfaceGeometry()
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
    let surfaceRegions: [GameSurfaceGeometry.ReservedRegion]?
    let rendering: GameRenderConfiguration?
    let renderMonitor: GameRenderMonitor?
    let presentationSource: GamePresentationSource?

    func makeUIView(context: Context) -> SKView {
        // Establish the retained driver before removing any previous pane list.
        host.configureRendering(rendering, monitor: renderMonitor, presentation: presentationSource)
        host.configureViewports(viewports)
        host.surfaceRegions = surfaceRegions
        return makeView(host: host, debug: debug)
    }

    func updateUIView(_ view: SKView, context: Context) {
        // Establish the retained driver before removing any previous pane list.
        host.configureRendering(rendering, monitor: renderMonitor, presentation: presentationSource)
        host.configureViewports(viewports)
        host.surfaceRegions = surfaceRegions
        (view as? GameSKView)?.synchronizeSurfaceGeometry()
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
    let surfaceRegions: [GameSurfaceGeometry.ReservedRegion]?
    let rendering: GameRenderConfiguration?
    let renderMonitor: GameRenderMonitor?
    let presentationSource: GamePresentationSource?

    func makeNSView(context: Context) -> SKView {
        // Establish the retained driver before removing any previous pane list.
        host.configureRendering(rendering, monitor: renderMonitor, presentation: presentationSource)
        host.configureViewports(viewports)
        host.surfaceRegions = surfaceRegions
        return makeView(host: host, debug: debug)
    }

    func updateNSView(_ view: SKView, context: Context) {
        // Establish the retained driver before removing any previous pane list.
        host.configureRendering(rendering, monitor: renderMonitor, presentation: presentationSource)
        host.configureViewports(viewports)
        host.surfaceRegions = surfaceRegions
        (view as? GameSKView)?.synchronizeSurfaceGeometry()
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
    view.startHingeObservation()
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

@_spi(Backend) import ECSCore
import Foundation
import Observation

/// Opt-in diagnostics. Drawing uses presented scene coordinates, outside masks
/// and render groups. These helpers never create entities, colliders or targets.
/// Bounds are unclipped visual bounds; collision outlines show query geometry,
/// not SpriteKit's internal contact manifold. Disable unused options to avoid work.
public struct SceneDebugOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let collisionShapes = Self(rawValue: 1 << 0)
    public static let origins = Self(rawValue: 1 << 1)
    public static let bounds = Self(rawValue: 1 << 2)
    public static let joints = Self(rawValue: 1 << 3)
    public static let constraintTargets = Self(rawValue: 1 << 4)
    public static let selection = Self(rawValue: 1 << 5)
    public static let statistics = Self(rawValue: 1 << 6)
    public static let inspector = Self(rawValue: 1 << 7)
    public static let simulationControls = Self(rawValue: 1 << 8)
    public static let all: Self = [.collisionShapes, .origins, .bounds, .joints, .constraintTargets, .selection, .statistics, .inspector, .simulationControls]
}

/// A bounded, read-only component description. Large images/resources and custom
/// reference graphs are not expanded. The inspector never invokes Codable hooks.
public struct SceneDebugComponent: Equatable, Sendable {
    public let name: String
    public let summary: String
}

/// A value snapshot, not a retained entity. Transform is the model target;
/// presentedTransform and scenePosition describe the rendered pose.
public struct SceneDebugEntity: Identifiable, Equatable, Sendable {
    public let id: Entity.ID
    public let name: String
    public let parentID: Entity.ID?
    public let childIDs: [Entity.ID]
    public let isEnabled: Bool
    public let isActive: Bool
    public let transform: Transform
    public let presentedTransform: Transform
    public let scenePosition: SIMD2<Float>
    public let components: [SceneDebugComponent]
    public let diagnostics: [String]
}

/// Latest debug sample. UI samples are throttled to ten per second; call refresh
/// for immediate inspection after a command. Counts include disabled entities but
/// exclude the hidden world root. Node count includes private game render nodes,
/// excluding the scene and the separate debug layer. Playback counts nonterminal
/// controllers (including paused ones). Timing covers systems only, not GPU or
/// physics cost. FPS measures callback cadence, not GPU throughput.
public struct SceneDebugSnapshot: Equatable, Sendable {
    public let frameNumber: UInt64
    public let simulationFrameNumber: UInt64
    public let framesPerSecond: Double
    public let entityCount: Int
    public let activeEntityCount: Int
    public let nodeCount: Int
    public let overlayNodeCount: Int
    public let activePlaybackCount: Int
    public let systems: [SystemTiming]
    /// Hierarchy order, at most 500 rows plus the selection if outside that range.
    /// The hidden world root is included for resource/hierarchy inspection.
    public let entities: [SceneDebugEntity]
    public let inspectionTruncated: Bool
    public let isPaused: Bool
    public let timeScale: Double

    static let empty = Self(frameNumber: 0, simulationFrameNumber: 0, framesPerSecond: 0, entityCount: 0,
                            activeEntityCount: 0, nodeCount: 0, overlayNodeCount: 0, activePlaybackCount: 0,
                            systems: [], entities: [], inspectionTruncated: false, isPaused: false, timeScale: 1)
}

/// View-scoped debug configuration and controls, without SpriteKit access.
/// Pass an instance to GameView(debug:). A controller binds to one renderer at a
/// time; sharing one across two mounted GameViews is rejected, never retargeted.
/// Debug state is transient and does not enter snapshots, clones or prefabs.
///
/// ```swift
/// @State private var debug = SceneDebugController(options: [.collisionShapes, .statistics, .inspector, .simulationControls])
/// // GameView(debug: debug) { content in ... }
/// // debug.isPaused = true; debug.stepFrame()
/// ```
@MainActor @Observable public final class SceneDebugController {
    public var options: SceneDebugOptions { didSet { if options != oldValue { renderer?.debugOptionsDidChange() } } }
    public private(set) var snapshot: SceneDebugSnapshot = .empty
    public private(set) var selectedEntityID: Entity.ID?
    private var connectionRevision: UInt64 = 0
    public var isAttached: Bool { _ = connectionRevision; return renderer != nil }
    public private(set) var isStepPending = false
    @ObservationIgnored weak var renderer: SpriteRenderer?
    @ObservationIgnored private weak var selectedEntity: Entity?
    @ObservationIgnored private var selectionRevision: UInt64?

    public init(options: SceneDebugOptions = .all) { self.options = options }
    /// The current scene, or nil while detached. Reading snapshot/isAttached also
    /// makes scene changes observable in views using this computed property.
    public var scene: World? { _ = isAttached; return renderer?.world }
    public var isPaused: Bool {
        get { _ = snapshot.isPaused; return scene?.isPaused ?? false }
        set { scene?.isPaused = newValue; if !newValue { renderer?.cancelDebugStep() }; refresh() }
    }
    public var timeScale: Double {
        get { _ = snapshot.timeScale; return scene?.timeScale ?? 1 }
        set { scene?.timeScale = newValue; refresh() }
    }
    public var canStep: Bool { isAttached && isPaused && !isStepPending && scene?.root.isActive == true }

    /// Queues one renderer frame at 1x while paused, preserving isPaused and
    /// timeScale. Repeated requests coalesce. Uses the next frame's normal capped
    /// interval, not a deterministic fixed timestep. Audio voices stay suspended.
    /// A zero-speed render callback primes SpriteKit's resumed action clock before
    /// the simulation frame. Audio remains paused, and priming runs no systems or physics.
    @discardableResult public func stepFrame() -> Bool {
        guard canStep, let renderer, renderer.requestDebugStep() else { return false }
        isStepPending = true; return true
    }

    /// Selects a scene entity, including disabled or invisible entities. Foreign
    /// objects are rejected without changing selection. Removal, replacement or
    /// activation/reuse invalidates a selection; choose an inactive row to inspect it.
    @discardableResult public func select(_ entity: Entity?) -> Bool {
        guard let entity else { clearSelection(); return true }
        guard let renderer, entity.world === renderer.world else { return false }
        selectedEntity = entity; selectedEntityID = entity.id; selectionRevision = entity.activationRevision
        refresh(); return true
    }
    /// Picks displayed colliders or visuals front-to-back, including clipping,
    /// without requiring InputTargetComponent. Unlike game input, visible children
    /// remain independently inspectable beneath a collider ancestor, and disabled
    /// colliders do not hide visible artwork. Empty space clears the selection.
    @discardableResult public func select(atScene point: SIMD2<Float>) -> Entity.ID? {
        guard point.x.isFinite, point.y.isFinite, let renderer else { return nil }
        let entity = renderer.inspectedEntities(at: .init(x: CGFloat(point.x), y: CGFloat(point.y))).first
        _ = select(entity); return selectedEntityID
    }
    @discardableResult public func select(atView point: CGPoint) -> Entity.ID? {
        guard let renderer else { return nil }
        return select(atScene: renderer.scenePoint(fromView: point))
    }
    public func clearSelection() {
        selectedEntity = nil; selectedEntityID = nil; selectionRevision = nil; refresh()
    }
    /// Refreshes only diagnostics and drawings; never advances simulation.
    public func refresh() { renderer?.refreshDebugging(force: true) }

    func attach(to renderer: SpriteRenderer) -> Bool {
        guard self.renderer == nil || self.renderer === renderer else { return false }
        self.renderer = renderer; connectionRevision &+= 1; isStepPending = false; return true
    }
    func detach(from renderer: SpriteRenderer) {
        guard self.renderer === renderer else { return }
        rendererWasDestroyed()
    }
    func rendererWasDestroyed() {
        self.renderer = nil; connectionRevision &+= 1; isStepPending = false
        selectedEntity = nil; selectedEntityID = nil; selectionRevision = nil; snapshot = .empty
    }
    func validateSelection() -> Entity? {
        guard let entity = selectedEntity, let renderer, entity.world === renderer.world,
              renderer.world.entity(withID: entity.id) === entity, selectionRevision == entity.activationRevision else {
            selectedEntity = nil; selectedEntityID = nil; selectionRevision = nil; return nil
        }
        return entity
    }
    func removed(_ entity: Entity) {
        if selectedEntity === entity { selectedEntity = nil; selectedEntityID = nil; selectionRevision = nil }
    }
    func setPendingStep(_ value: Bool) { isStepPending = value }
    func publish(_ sample: SceneDebugSnapshot) { if snapshot != sample { snapshot = sample } }
}

@_spi(Backend) import ECSCore
import SpriteBackend
import SpriteKit
import SwiftUI

/// A reference to a named GameView attachment. This value component clones and
/// snapshots normally; SwiftUI views, controls and their state are view-scoped.
/// Put it on a child entity to position UI relative to a character or prefab.
/// GameView registers the component. Before standalone file I/O, call
/// AttachmentComponent.registerComponent() explicitly.
/// Attachments overlay SpriteKit content; zPosition orders attachments against
/// each other, not against sprites. They do not participate in physics/occlusion.
public struct AttachmentComponent: Component, Equatable, Codable, Sendable {
    public enum Sizing: String, Codable, Sendable {
        /// Upright content in view points, independent of entity/camera scale.
        case screen
        /// Content follows the full presented scene transform (including shear).
        case scene
    }
    public var attachmentID: String
    /// Offset in this entity's local scene units, with +y up.
    public var offset: SIMD2<Float>
    /// The content point placed at the offset. Uses SwiftUI's top-left origin.
    public var anchor: UnitPoint
    public var sizing: Sizing
    /// Labels pass input through by default. Enable for buttons and controls.
    public var isInteractive: Bool
    public var isEnabled: Bool

    public init(id: String, offset: SIMD2<Float> = .zero, anchor: UnitPoint = .center,
                sizing: Sizing = .screen, isInteractive: Bool = false, isEnabled: Bool = true) {
        attachmentID = id; self.offset = offset; self.anchor = anchor; self.sizing = sizing
        self.isInteractive = isInteractive; self.isEnabled = isEnabled
    }
    private enum CodingKeys: String, CodingKey { case attachmentID, offset, anchor, sizing, isInteractive, isEnabled }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attachmentID = try c.decode(String.self, forKey: .attachmentID)
        offset = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .offset) ?? .zero
        let point = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .anchor) ?? [0.5, 0.5]
        anchor = UnitPoint(x: point.x, y: point.y)
        sizing = try c.decodeIfPresent(Sizing.self, forKey: .sizing) ?? .screen
        isInteractive = try c.decodeIfPresent(Bool.self, forKey: .isInteractive) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(attachmentID, forKey: .attachmentID); try c.encode(offset, forKey: .offset)
        try c.encode(SIMD2(Double(anchor.x), Double(anchor.y)), forKey: .anchor)
        try c.encode(sizing, forKey: .sizing); try c.encode(isInteractive, forKey: .isInteractive)
        try c.encode(isEnabled, forKey: .isEnabled)
    }
}

/// One named SwiftUI content template. Several entities can use the same template.
/// Read observable app/model state in content as in any SwiftUI view. Plain ECS
/// component reads do not themselves establish SwiftUI observation.
/// Content uses its ideal size; give scrolling or wrapping content an explicit
/// frame. An interactive attachment reserves its entire content rectangle.
@MainActor
public struct GameAttachment: Identifiable {
    public let id: String
    let content: @MainActor (AttachmentContext) -> AnyView
    public init<Content: View>(id: String, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id; self.content = { _ in AnyView(content()) }
    }
    public init<Content: View>(id: String, @ViewBuilder content: @escaping @MainActor (AttachmentContext) -> Content) {
        self.id = id; self.content = { AnyView(content($0)) }
    }
}

@resultBuilder public enum GameAttachmentBuilder {
    public static func buildExpression(_ expression: GameAttachment) -> [GameAttachment] { [expression] }
    public static func buildBlock(_ parts: [GameAttachment]...) -> [GameAttachment] { parts.flatMap { $0 } }
    public static func buildOptional(_ value: [GameAttachment]?) -> [GameAttachment] { value ?? [] }
    public static func buildEither(first: [GameAttachment]) -> [GameAttachment] { first }
    public static func buildEither(second: [GameAttachment]) -> [GameAttachment] { second }
    public static func buildArray(_ values: [[GameAttachment]]) -> [GameAttachment] { values.flatMap { $0 } }
    public static func buildLimitedAvailability(_ value: [GameAttachment]) -> [GameAttachment] { value }
}

/// An attachment's current entity and view-scoped action context. A context from
/// before removal, deactivation/reuse or definition replacement becomes invalid.
/// Use perform for entity-mutating button actions, including actions invoked
/// asynchronously after an attachment view has disappeared.
@MainActor
public struct AttachmentContext {
    public let entity: Entity
    private weak var store: AttachmentStore?
    private let identity: AttachmentIdentity
    init(entity: Entity, store: AttachmentStore, identity: AttachmentIdentity) {
        self.entity = entity; self.store = store; self.identity = identity
    }
    public var isValid: Bool { store?.isValid(entity, identity: identity) == true }
    @discardableResult public func perform(_ action: @MainActor (Entity) -> Void) -> Bool {
        guard isValid, entity.components[AttachmentComponent.self]?.isInteractive == true else { return false }; action(entity); return true
    }
}

/// Access to the definitions on this GameView only. `entity(for:)` returns one
/// shared anchor per ID; `makeEntity(for:)` creates another independent anchor.
/// Unknown IDs return nil. Anchor components may also be authored directly or
/// cloned in prefabs; every instance gets separate SwiftUI state.
@MainActor
public struct GameViewAttachments {
    let store: AttachmentStore
    public func entity(for id: String) -> Entity? { store.entity(for: id, shared: true) }
    public func makeEntity(for id: String) -> Entity? { store.entity(for: id, shared: false) }
}

struct AttachmentIdentity: Hashable {
    let entityID: Entity.ID
    let instance: ObjectIdentifier
    let activation: UInt64
    let definition: UInt64
}

struct AttachmentProjection: Identifiable, Equatable {
    let id: AttachmentIdentity
    let definitionID: String
    weak var entity: Entity?
    let position: CGPoint
    let basis: CGAffineTransform
    let anchor: UnitPoint
    let opacity: Double
    let zIndex: Double
    let interactive: Bool
    let viewport: CGSize

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.definitionID == b.definitionID && a.position == b.position && a.basis == b.basis &&
            a.anchor == b.anchor && a.opacity == b.opacity && a.zIndex == b.zIndex && a.interactive == b.interactive && a.viewport == b.viewport
    }
    func transform(for size: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: basis.a, b: basis.b, c: basis.c, d: basis.d,
            tx: position.x - basis.a * size.width * anchor.x - basis.c * size.height * anchor.y,
            ty: position.y - basis.b * size.width * anchor.x - basis.d * size.height * anchor.y)
    }
    func contains(_ point: CGPoint, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let local = point.applying(transform(for: size).inverted())
        return CGRect(origin: .zero, size: size).contains(local)
    }
    func hitPath(for size: CGSize) -> Path {
        guard size.width > 0, size.height > 0 else { return Path() }
        let inverse = transform(for: size).inverted()
        let polygon = [CGPoint.zero, CGPoint(x: viewport.width, y: 0), CGPoint(x: viewport.width, y: viewport.height), CGPoint(x: 0, y: viewport.height)]
            .map { $0.applying(inverse) }
        guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return Path() }
        let clip = Path { path in path.addLines(polygon); path.closeSubpath() }
        return Path(CGRect(origin: .zero, size: size)).intersection(clip)
    }
}

@MainActor @Observable
final class AttachmentStore {
    private weak var host: GameHost?
    private var definitions: [String: UInt64] = [:]
    private var nextDefinition: UInt64 = 0
    private var visible = true
    private var appActive = true
    var acceptsInput: Bool { visible && appActive }
    private struct WeakEntity { weak var value: Entity? }
    private var shared: [String: WeakEntity] = [:]
    @ObservationIgnored private var sizes: [AttachmentIdentity: CGSize] = [:]
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    private(set) var presentations: [AttachmentProjection] = []
    init(host: GameHost) {
        self.host = host
        AttachmentComponent.registerComponent()
        subscriptions = [
            host.world.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in self?.refresh() },
            host.world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { [weak self] _ in self?.refresh() },
            host.world.subscribe(to: WorldEvents.DidAddEntity.self) { [weak self] _ in self?.refresh() },
            host.world.subscribe(to: WorldEvents.WillRemoveEntity.self) { [weak self] event in
                guard let self, presentations.contains(where: { $0.entity === event.entity }) else { return }
                presentations.removeAll { $0.entity === event.entity }; pruneSizes()
            }
        ]
    }
    func configure(_ ids: [String]) {
        precondition(Set(ids).count == ids.count, "GameAttachment IDs must be unique within a GameView.")
        let allowed = Set(ids)
        for id in Array(definitions.keys) where !allowed.contains(id) { definitions[id] = nil; shared[id] = nil }
        for id in ids where definitions[id] == nil { nextDefinition &+= 1; definitions[id] = nextDefinition }
        refresh()
    }
    func entity(for id: String, shared wantsShared: Bool) -> Entity? {
        guard definitions[id] != nil, let host else { return nil }
        if wantsShared, let existing = shared[id]?.value, existing.world == nil || existing.world === host.world {
            // A restore may keep IDs while replacing objects. Never hand out the
            // detached old anchor whose ID is now occupied by its restored copy.
            if let restored = host.world.entity(withID: existing.id), restored !== existing {
                if restored.components[AttachmentComponent.self]?.attachmentID == id {
                    shared[id] = WeakEntity(value: restored); return restored
                }
            } else { return existing }
        }
        let entity = Entity(name: "attachment-\(id)", components: AttachmentComponent(id: id))
        if wantsShared { shared[id] = WeakEntity(value: entity) }
        return entity
    }
    func isValid(_ entity: Entity, identity: AttachmentIdentity) -> Bool {
        guard visible, appActive, let host, entity.world === host.world, entity.isActive,
              entity.id == identity.entityID, ObjectIdentifier(entity) == identity.instance, entity.activationRevision == identity.activation,
              let component = entity.components[AttachmentComponent.self], component.isEnabled,
              definitions[component.attachmentID] == identity.definition else { return false }
        return true
    }
    func reportSize(_ size: CGSize, for identity: AttachmentIdentity) {
        guard size.width.isFinite, size.height.isFinite, presentations.contains(where: { $0.id == identity }) else { return }
        sizes[identity] = size
    }
    private func pruneSizes() { let live = Set(presentations.map(\.id)); sizes = sizes.filter { live.contains($0.key) } }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }; visible = value
        if !value { invalidateContexts() }; refresh()
    }
    func setAppActive(_ value: Bool) {
        guard appActive != value else { return }; appActive = value
        if !value { invalidateContexts() }; refresh()
    }
    private func invalidateContexts() {
        for id in Array(definitions.keys) { nextDefinition &+= 1; definitions[id] = nextDefinition }
    }
    func blocksInput(at point: CGPoint) -> Bool {
        guard let host, CGRect(origin: .zero, size: host.renderer.size).contains(point) else { return false }
        return presentations.contains { projection in
            guard projection.interactive, let entity = projection.entity,
                  entity.components[AttachmentComponent.self]?.isInteractive == true,
                  isValid(entity, identity: projection.id) else { return false }
            return projection.contains(point, size: sizes[projection.id] ?? .zero)
        }
    }
    func refresh() {
        guard let host else { return }
        guard visible, appActive, !definitions.isEmpty else {
            if !presentations.isEmpty { presentations = [] }
            if !sizes.isEmpty { sizes.removeAll() }
            return
        }
        let renderer = host.renderer
        var next: [AttachmentProjection] = []
        for entity in host.world.performQuery(EntityQuery(where: .has(AttachmentComponent.self))) {
            guard let component = entity.components[AttachmentComponent.self], component.isEnabled,
                  let definition = definitions[component.attachmentID], let node = renderer.node(for: entity),
                  component.anchor.x.isFinite, component.anchor.y.isFinite,
                  (0...1).contains(component.anchor.x), (0...1).contains(component.anchor.y),
                  let origin = renderer.viewPoint(from: component.offset, relativeTo: entity),
                  let x = renderer.viewPoint(from: component.offset + [1, 0], relativeTo: entity),
                  let y = renderer.viewPoint(from: component.offset + [0, -1], relativeTo: entity) else { continue }
            var opacity: CGFloat = 1, z: CGFloat = 0, current: SKNode? = node, visible = true
            while let ancestor = current, ancestor !== renderer {
                if ancestor.isHidden { visible = false; break }
                opacity *= ancestor.alpha; z += ancestor.zPosition; current = ancestor.parent
            }
            guard visible, opacity.isFinite, opacity > 0.001, z.isFinite else { continue }
            let raw = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: 0, ty: 0)
            let determinant = raw.a * raw.d - raw.b * raw.c
            guard determinant.isFinite, abs(determinant) > 1e-12 else { continue }
            let identity = AttachmentIdentity(entityID: entity.id, instance: ObjectIdentifier(entity), activation: entity.activationRevision, definition: definition)
            next.append(AttachmentProjection(id: identity, definitionID: component.attachmentID, entity: entity,
                position: origin, basis: component.sizing == .screen ? .identity : raw, anchor: component.anchor,
                opacity: Double(min(1, max(0, opacity))), zIndex: Double(z), interactive: component.isInteractive, viewport: renderer.size))
        }
        next.sort { $0.zIndex == $1.zIndex ? $0.id.entityID < $1.id.entityID : $0.zIndex < $1.zIndex }
        if next != presentations { presentations = next; pruneSizes() }
    }
}

private struct AttachmentPlacement: GeometryEffect {
    let projection: AttachmentProjection
    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(projection.transform(for: size)) }
}
private struct AttachmentHitShape: Shape {
    let projection: AttachmentProjection
    func path(in rect: CGRect) -> Path { projection.hitPath(for: rect.size) }
}

@MainActor
struct AttachmentOverlay: View {
    let store: AttachmentStore
    let definitions: [GameAttachment]
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.presentations) { projection in
                if let entity = projection.entity, let definition = definitions.first(where: { $0.id == projection.definitionID }) {
                    let context = AttachmentContext(entity: entity, store: store, identity: projection.id)
                    definition.content(context)
                        .fixedSize()
                        .contentShape(AttachmentHitShape(projection: projection))
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { store.reportSize($0, for: projection.id) }
                        .modifier(AttachmentPlacement(projection: projection))
                        .opacity(projection.opacity)
                        .allowsHitTesting(projection.interactive && context.isValid)
                        .zIndex(projection.zIndex)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

import ECSCore
import Foundation
import SpriteKit

/// Independent render categories. Define application names with bits 1...63;
/// bit zero is `default`. These do not affect collision groups or lighting masks.
public struct RenderLayer: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let `default` = Self(rawValue: 1)
    public static let all = Self(rawValue: .max)
    public static let none = Self([])
}

/// Visual subtree policy, independent of activation, systems, physics and audio.
/// Untagged entities are unrestricted. Every explicit ancestor must be visible
/// and have a layer in the camera's effective mask; a child cannot escape its
/// parent's restriction. Use a neutral container for separate world/map artwork.
public struct VisibilityComponent: Component, Hashable, Codable, Sendable {
    public var layers: RenderLayer
    public var isVisible: Bool
    public init(layers: RenderLayer = .default, isVisible: Bool = true) {
        self.layers = layers; self.isVisible = isVisible
    }
}

public enum VisibilityEvents {
    /// Immutable visual policy at one transition. Retained snapshots let later
    /// subscribers observe hiding even if an earlier callback immediately shows it.
    public struct Policy: Equatable, Sendable {
        public let visibility: VisibilityComponent?
        public let cameraCullingMask: RenderLayer?
        public let isCameraActive: Bool?
    }

    /// A visual policy or camera's culling/availability changed. Does not indicate
    /// activation or a physics change. Published after the new model is available.
    public struct DidChange: Event {
        public let entity: Entity
        public let revision: UInt64
        public let previousPolicy: Policy
        public let policy: Policy

        /// Evaluates both sides of this immutable transition. Reentrant handlers
        /// may have changed the live model before a later observer receives it.
        @_spi(Backend) @MainActor
        public func excludes(_ entity: Entity, inViewport id: String? = nil, renderer: SpriteRenderer) -> Bool {
            let viewport = id.flatMap { id in renderer.resolvedViewports.first { $0.id == id } }
            let cameraID = viewport?.camera ?? renderer.activeCamera?.id
            let changesCamera = cameraID == self.entity.id
            let changesAncestor = entity === self.entity || entity.isDescendant(of: self.entity)
            guard changesCamera || changesAncestor else { return false }
            guard let currentMask = renderer.visibilityMask(inViewport: id) else { return true }
            for snapshot in [previousPolicy, policy] {
                let mask: RenderLayer
                if changesCamera {
                    guard snapshot.isCameraActive == true, let cameraMask = snapshot.cameraCullingMask else { return true }
                    mask = cameraMask.intersection(viewport?.cullingMask ?? .all)
                } else { mask = currentMask }
                if mask.isEmpty { return true }
                var current: Entity? = entity
                while let ancestor = current {
                    let gate = ancestor === self.entity ? snapshot.visibility : ancestor.components[VisibilityComponent.self]
                    if let gate, !gate.isVisible || gate.layers.isDisjoint(with: mask) { return true }
                    current = ancestor.parent
                }
            }
            return false
        }
    }
}

extension SpriteRenderer {
    /// Capture-time watermark for ordering immutable transition events. Unlike a
    /// subject's policy stamp, this includes unrelated changes and never resets
    /// when entities or cameras are replaced within this renderer's lifetime.
    @_spi(Backend) public var visibilityEventRevision: UInt64 { nextVisibilityRevision }

    struct VisibilityOverride {
        let node: SKNode
        let hidden: Bool
    }
    struct CameraVisibility: Equatable {
        let mask: RenderLayer
        let active: Bool
    }

    /// Effective camera mask, optionally narrowed by a viewport. Nil identifies
    /// the world's primary camera; an unavailable explicit viewport returns nil.
    public func visibilityMask(inViewport id: String? = nil) -> RenderLayer? {
        let viewport: GameViewport?
        if let id {
            guard let found = resolvedViewports.first(where: { $0.id == id }) else { return nil }
            viewport = found
        } else { viewport = nil }
        let cameraEntity = viewport?.camera.flatMap { world.entity(withID: $0) } ?? activeCamera
        let cameraMask = cameraEntity?.components[CameraComponent.self]?.cullingMask ?? .all
        return cameraMask.intersection(viewport?.cullingMask ?? .all)
    }

    /// Whether this entity's subtree policy permits presentation in a view.
    /// This includes activation/native ancestor hiding, but not screen bounds,
    /// opacity, or pixel coverage of masks. Physics queries remain independent.
    public func isVisible(_ entity: Entity, inViewport id: String? = nil) -> Bool {
        guard entity.world === world, entity.isActive, let mask = visibilityMask(inViewport: id),
              !mask.isEmpty, node(for: entity) != nil else { return false }
        var current: Entity? = entity
        while let item = current {
            if let policy = item.components[VisibilityComponent.self],
               !policy.isVisible || policy.layers.isDisjoint(with: mask) { return false }
            current = item.parent
        }
        var native: SKNode? = node(for: entity)
        while let item = native, item !== self {
            if isPresentationHidden(item) { return false }
            native = item.parent
        }
        return true
    }

    /// Native escape-hatch hiding with the renderer's temporary camera filtering
    /// removed. Backends must use this instead of reading a filtered isHidden.
    public func isPresentationHidden(_ node: SKNode) -> Bool {
        renderVisibilityOverrides[ObjectIdentifier(node)]?.hidden ?? node.isHidden
    }

    /// A policy-change stamp for this entity's ancestors and selected camera.
    /// Within the same hierarchy/camera lifetime, hide/show changes this stamp
    /// even when the final values match. Combine it with object identity,
    /// activation, hierarchy and viewport generations; it is not an identity
    /// token across reparenting, removal or camera replacement.
    @_spi(Backend) public func visibilityRevision(of entity: Entity, inViewport id: String? = nil) -> UInt64? {
        guard entity.world === world, visibilityMask(inViewport: id) != nil else { return nil }
        var result: UInt64 = 0
        var current: Entity? = entity
        while let item = current {
            result = max(result, visibilityRevisions[item.id, default: 0])
            current = item.parent
        }
        let cameraID = id.flatMap { id in resolvedViewports.first(where: { $0.id == id })?.camera } ?? activeCamera?.id
        if let cameraID { result = max(result, visibilityRevisions[cameraID, default: 0]) }
        return result
    }

    func restoreRenderVisibility() {
        let previous = renderVisibilityOverrides
        renderVisibilityOverrides.removeAll(keepingCapacity: true)
        activeRenderVisibilityMask = nil
        for entry in previous.values { entry.node.isHidden = entry.hidden }
    }

    func applyRenderVisibility(_ mask: RenderLayer) {
        restoreRenderVisibility()
        activeRenderVisibilityMask = mask
        func visit(_ entity: Entity, allowed: Bool) {
            guard let node = node(for: entity) else { return }
            let policy = entity.components[VisibilityComponent.self]
            let permitted = allowed && !node.isHidden && entity.isEnabledInHierarchy
                && (policy.map { $0.isVisible && !$0.layers.isDisjoint(with: mask) } ?? true)
            if !permitted, !node.isHidden {
                renderVisibilityOverrides[ObjectIdentifier(node)] = .init(node: node, hidden: node.isHidden)
                node.isHidden = true
            }
            for child in entity.children { visit(child, allowed: permitted) }
        }
        visit(world.root, allowed: !mask.isEmpty)
    }

    func withRenderVisibility<T>(_ mask: RenderLayer, _ body: () -> T) -> T {
        let previous = activeRenderVisibilityMask
        applyRenderVisibility(mask)
        defer {
            restoreRenderVisibility()
            if let previous { applyRenderVisibility(previous) }
        }
        return body()
    }

    func recordVisibilityChange(_ entity: Entity, type: any Component.Type) {
        func policy() -> VisibilityEvents.Policy {
            .init(visibility: knownVisibility[entity.id],
                  cameraCullingMask: knownCameraVisibility[entity.id]?.mask,
                  isCameraActive: knownCameraVisibility[entity.id]?.active)
        }
        let previous = policy()
        let changed: Bool
        if type == VisibilityComponent.self {
            let value = entity.components[VisibilityComponent.self]
            changed = knownVisibility[entity.id] != value
            knownVisibility[entity.id] = value
        } else if type == CameraComponent.self {
            let value = entity.components[CameraComponent.self].map { CameraVisibility(mask: $0.cullingMask, active: $0.isActive) }
            changed = knownCameraVisibility[entity.id] != value
            knownCameraVisibility[entity.id] = value
        } else { return }
        guard changed else { return }
        nextVisibilityRevision &+= 1
        let revision = nextVisibilityRevision
        visibilityRevisions[entity.id] = revision
        // Retain both policies before cancellation callbacks can reverse the
        // transition. Later observers evaluate the immutable event, rather than
        // accidentally treating a reentrant show as continuous visibility.
        guard entity.world === world else { return }
        let event = VisibilityEvents.DidChange(entity: entity, revision: revision, previousPolicy: previous, policy: policy())
        validateManipulations()
        world.publish(event, from: entity)
    }
}

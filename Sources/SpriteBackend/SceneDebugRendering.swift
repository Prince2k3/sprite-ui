@_spi(Backend) import ECSCore
import Foundation
import SpriteKit

extension SpriteRenderer {
    /// The optional controller attached to this renderer. GameView normally owns
    /// attachment; direct renderer clients can use setDebugController themselves.
    public var debugController: SceneDebugController? { attachedDebugController }

    /// Binds a view-scoped controller without silently stealing it from another
    /// scene. Returns false if already bound elsewhere. Nil removes every helper
    /// node and restores the prior profiling setting, without editing entities.
    @discardableResult public func setDebugController(_ controller: SceneDebugController?) -> Bool {
        if attachedDebugController === controller { return true }
        if let controller, !controller.attach(to: self) { return false }
        if let old = attachedDebugController { old.detach(from: self) }
        cancelDebugStep(); removeDebugLayer(); restoreDebugProfiling()
        attachedDebugController = controller
        debugLastSampleTime = -.infinity
        debugOptionsDidChange()
        return true
    }

    func debugOptionsDidChange() {
        guard let controller = attachedDebugController else { return }
        if controller.options.contains(.statistics) {
            if debugPriorProfiling == nil { debugPriorProfiling = world.isProfilingEnabled; world.isProfilingEnabled = true }
        } else { restoreDebugProfiling() }
        if controller.options.intersection([.collisionShapes, .origins, .bounds, .joints, .constraintTargets, .selection]).isEmpty { removeDebugLayer() }
        refreshDebugging(force: true)
    }
    private func restoreDebugProfiling() {
        if let prior = debugPriorProfiling { world.isProfilingEnabled = prior; debugPriorProfiling = nil }
    }
    func requestDebugStep() -> Bool {
        guard world.isPaused, world.root.isActive, !pendingDebugStep, !steppingThisFrame else { return false }
        pendingDebugStep = true; return true
    }
    func cancelDebugStep() {
        let wasPrimed = debugStepPrimed
        debugStepPrimed = false
        pendingDebugStep = false; attachedDebugController?.setPendingStep(false)
        if wasPrimed { worldSimulationDidChange(world) }
    }
    func finishDebugFrame() {
        if steppingThisFrame {
            steppingThisFrame = false
            worldSimulationDidChange(world)
            for entity in world.allEntities {
                for controller in entity.components[PlaybackStorage.self]?.controllers ?? [] where controller is AnimationPlaybackController { controller.synchronizeSuspension() }
            }
            attachedDebugController?.setPendingStep(false)
        }
        refreshDebugging()
    }
    func recordDebugFrame(interval: TimeInterval, simulated: Bool) {
        guard attachedDebugController != nil else { return }
        debugFrameNumber &+= 1
        if simulated { debugSimulationFrameNumber &+= 1 }
        if interval.isFinite, interval > 0 {
            let fps = 1 / interval
            if fps.isFinite { debugFPS = debugFPS == 0 ? fps : debugFPS * 0.9 + fps * 0.1 }
        }
    }

    /// A refresh reads only. All helper nodes are outside the ECS, masks and
    /// render groups, so enabling diagnostics cannot alter hit or physics queries.
    func refreshDebugging(force: Bool = false) {
        guard let controller = attachedDebugController else { return }
        let selected = controller.validateSelection()
        if controller.options.isEmpty { removeDebugLayer(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let needsSample = force || now - debugLastSampleTime >= 0.1
        let drawsWorld = !controller.options.intersection([.collisionShapes, .origins, .bounds, .joints, .constraintTargets]).isEmpty
        let draws = drawsWorld || (controller.options.contains(.selection) && selected != nil)
        if !draws { removeDebugLayer() }
        guard draws || needsSample else { return }
        var entities: [Entity] = []
        if drawsWorld || needsSample { world.root.visit { entities.append($0) } }
        if draws { updateDebugDrawing(entities: entities, selected: selected, options: controller.options) }
        guard needsSample else { return }
        debugLastSampleTime = now
        let inspected: [Entity]
        if controller.options.contains(.inspector) {
            var prefix = Array(entities.prefix(500))
            if let selected, !prefix.contains(where: { $0 === selected }) { prefix.append(selected) }
            inspected = prefix
        } else { inspected = [] }
        var nodes = 0, playback = 0
        if let root = node(for: world.root) {
            var pending = [root]
            while let next = pending.popLast() { nodes += 1; pending.append(contentsOf: next.children) }
        }
        for entity in entities {
            playback += entity.components[PlaybackStorage.self]?.controllers.filter { !$0.isTerminal }.count ?? 0
        }
        let snapshot = SceneDebugSnapshot(frameNumber: debugFrameNumber, simulationFrameNumber: debugSimulationFrameNumber,
            framesPerSecond: debugFPS, entityCount: max(0, entities.count - 1),
            activeEntityCount: entities.dropFirst().filter(\.isActive).count, nodeCount: nodes,
            overlayNodeCount: debugLayer.map { $0.children.count + 1 } ?? 0, activePlaybackCount: playback,
            systems: controller.options.contains(.statistics) ? world.lastSystemTimings : [],
            entities: inspected.map(debugEntity), inspectionTruncated: controller.options.contains(.inspector) && entities.count > 500,
            isPaused: world.isPaused, timeScale: world.timeScale)
        controller.publish(snapshot)
    }

    private func debugEntity(_ entity: Entity) -> SceneDebugEntity {
        let components = entity.componentKeys.compactMap { entity.component(forKey: $0) }.map { component in
            SceneDebugComponent(name: String(reflecting: type(of: component)), summary: debugSummary(component))
        }.sorted { $0.name < $1.name }
        var diagnostics: [String] = []
        if !entity.isEnabled { diagnostics.append("Disabled locally") }
        else if !entity.isActive { diagnostics.append("Disabled by an ancestor") }
        if world.isPaused { diagnostics.append("Scene paused") }
        if world.timeScale == 0 { diagnostics.append("Scene time scale is zero") }
        if let mask = entity.components[MaskComponent.self] {
            diagnostics.append(mask.isEnabled ? "Mask clips visuals and input; physics is independent" : "Mask bypassed")
        }
        if let collider = entity.queryCollider {
            if !collider.isEnabled { diagnostics.append("Collision shape disabled") }
            if !collider.shape.isValid { diagnostics.append("Invalid collision shape") }
        }
        if entity.sceneTransformMatrix.inverted() == nil { diagnostics.append("Singular or nonfinite transform") }
        if let statuses = entity.transformConstraintStatuses {
            let rules = entity.components[TransformConstraintComponent.self]?.constraints ?? []
            diagnostics += statuses.enumerated().map { index, status in "Constraint \(index < rules.count ? rules[index].name ?? String(index + 1) : String(index + 1)): \(status.rawValue)" }
        }
        if let status = entity.physicsJointStatus { diagnostics.append("Joint: \(String(describing: status))") }
        var ancestor: Entity? = entity.parent
        while let current = ancestor {
            if current.components[MaskComponent.self]?.isEnabled == true { diagnostics.append("Inside mask: \(current.name.isEmpty ? String(current.id) : current.name)") }
            ancestor = current.parent
        }
        return SceneDebugEntity(id: entity.id, name: entity.name, parentID: entity.parent?.id, childIDs: entity.children.map(\.id),
            isEnabled: entity.isEnabled, isActive: entity.isActive, transform: entity.transform,
            presentedTransform: entity.presentation.transform, scenePosition: presentedSceneMatrix(of: entity).apply(to: .zero),
            components: components, diagnostics: diagnostics)
    }
}

/// Shallow primitive fields make custom components useful without recursively
/// expanding entity references, textures or arbitrary user CustomStringConvertible.
private func debugSummary(_ component: any Component) -> String {
    func scalar(_ value: Any) -> String? {
        switch value {
        case let value as String: return String(value.prefix(80))
        case let value as Bool: return value ? "true" : "false"
        case let value as Int: return String(value)
        case let value as UInt64: return String(value)
        case let value as UInt32: return String(value)
        case let value as Float: return String(format: "%.3g", Double(value))
        case let value as Double: return String(format: "%.3g", value)
        case let value as SIMD2<Float>: return String(format: "[%.3g, %.3g]", Double(value.x), Double(value.y))
        default: return nil
        }
    }
    let fields = Mirror(reflecting: component).children.prefix(10).compactMap { field -> String? in
        guard let label = field.label, let value = scalar(field.value) else { return nil }
        return "\(label): \(value)"
    }
    return fields.isEmpty ? "Value component" : String(fields.joined(separator: " · ").prefix(320))
}

@_spi(Backend) import ECSCore
import SpriteKit

extension SpriteRenderer {
    /// Periodic census of the engine's native subtree, including inactive nodes.
    /// Debug drawings live outside it. This does not ask the GPU to render again.
    func sampleProfileWorkload(_ token: EngineProfileToken) {
        guard world.profiler.needsWorkloadSample else { return }
        var nodes = 0, sprites = 0, bodies = 0, emitters = 0
        var pending = node(for: world.root).map { [$0] } ?? []
        while let next = pending.popLast() {
            nodes += 1
            if next is SKSpriteNode { sprites += 1 }
            if next.physicsBody != nil { bodies += 1 }
            if next is SKEmitterNode { emitters += 1 }
            pending.append(contentsOf: next.children)
        }
        var entities = 0, active = 0
        for entity in world.allEntities { entities += 1; if entity.isActive { active += 1 } }
        world.profiler.recordWorkload(.init(sampledAt: world.profiler.elapsedRecordingTime(),
            entityCount: entities, activeEntityCount: active, nodeCount: nodes,
            spriteNodeCount: sprites, physicsBodyCount: bodies, emitterCount: emitters), token: token)
    }
}

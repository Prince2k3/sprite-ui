import ECSCore
import Foundation
@testable import SpriteBackend
import SpriteKit
import Testing

private func constraintClose(_ actual: SIMD2<Float>, _ expected: SIMD2<Float>, tolerance: Float = 0.001) -> Bool {
    abs(actual.x - expected.x) < tolerance && abs(actual.y - expected.y) < tolerance
}

@MainActor @Suite struct TransformConstraintTests {
    private func evaluate(_ renderer: SpriteRenderer, deltaTime: TimeInterval = 0) {
        renderer.flush()
        renderer.updateTransformConstraints(deltaTime: deltaTime)
        renderer.flush()
    }

    @Test func followUsesFullTargetTransformAndSceneAlignedOffsets() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        world.root.transform = Transform(translation: [30, -20], rotation: 0.3, scale: [2, 1])
        let targetParent = Entity(), ownerParent = Entity(), target = Entity()
        targetParent.transform = Transform(translation: [10, 20], rotation: -0.7, scale: [-2, 3])
        ownerParent.transform = Transform(translation: [-40, 10], rotation: 0.8, scale: [3, -2])
        target.transform = Transform(translation: [4, 5], rotation: 0.4, scale: [2, 0.5])
        targetParent.addChild(target)
        let localOffset = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.entity(target.id), offset: [6, -3]))
        ]))
        let sceneOffset = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.entity(target.id), offset: [6, -3], offsetSpace: .scene))
        ]))
        ownerParent.addChild(localOffset); ownerParent.addChild(sceneOffset)
        world.addEntity(ownerParent); world.addEntity(targetParent)
        evaluate(renderer)
        let targetNode = try #require(renderer.node(for: target))
        let offset = targetNode.convert(CGPoint(x: 6, y: -3), to: renderer)
        let origin = targetNode.convert(.zero, to: renderer)
        #expect(constraintClose(localOffset.scenePosition, [Float(offset.x), Float(offset.y)]))
        #expect(constraintClose(sceneOffset.scenePosition, [Float(origin.x) + 6, Float(origin.y) - 3]))
        #expect(localOffset.transformConstraintStatuses == [.active])
        #expect(sceneOffset.transformConstraintStatuses == [.active])
    }

    @Test func pointTargetsRespectParentAndSceneFrames() {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity()
        world.root.transform = Transform(translation: [20, 10], rotation: 0.2, scale: [2, 3])
        parent.transform = Transform(translation: [40, -10], rotation: .pi / 2, scale: [-2, 3])
        let local = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.point([3, 4], relativeTo: .parent), offset: [1, 2]))
        ]))
        let scene = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.point([3, 4]), offset: [1, 2]))
        ]))
        parent.addChild(local); parent.addChild(scene); world.addEntity(parent)
        evaluate(renderer)
        #expect(constraintClose(local.position, [4, 6]))
        #expect(constraintClose(scene.scenePosition, [4, 6]))
    }

    @Test func followAndShortestArcSmoothingAreFramePartitionIndependent() {
        func result(steps: [Double]) -> (SIMD2<Float>, Float) {
            let world = World(), renderer = SpriteRenderer(world: world)
            let owner = Entity(components: TransformConstraintComponent([
                TransformConstraint(.follow(.point([100, 40]), smoothing: 0.5)),
                TransformConstraint(.lookAt(.point([-1000, -10]), smoothing: 0.5))
            ]))
            owner.rotation = .pi - 0.02
            world.addEntity(owner)
            // Test rotation independently of moving the look-at origin.
            owner.components[TransformConstraintComponent.self]?.constraints[1].isEnabled = false
            for step in steps { evaluate(renderer, deltaTime: step) }
            let position = owner.position
            owner.position = .zero
            owner.components[TransformConstraintComponent.self]?.constraints[0].isEnabled = false
            owner.components[TransformConstraintComponent.self]?.constraints[1].isEnabled = true
            for step in steps { evaluate(renderer, deltaTime: step) }
            return (position, owner.rotation)
        }
        let full = result(steps: [0.5]), partitioned = result(steps: [0.1, 0.15, 0.25])
        let factor = Float(1 - exp(-1.0))
        #expect(constraintClose(full.0, SIMD2<Float>(100, 40) * factor))
        #expect(constraintClose(partitioned.0, full.0))
        let desired = Float.pi + atan2(Float(10), Float(1000))
        let expected = Float.pi - 0.02 + (desired - (Float.pi - 0.02)) * factor
        #expect(abs(full.1 - expected) < 0.001)
        #expect(abs(partitioned.1 - full.1) < 0.001)
        #expect(full.1 > Float.pi - 0.02)
    }

    @Test func lookAtAccountsForReflectionsNonuniformAncestorsAndArtworkForward() throws {
        let world = World(), renderer = SpriteRenderer(world: world), outer = Entity(), parent = Entity()
        outer.transform = Transform(translation: [30, -20], rotation: 0.6, scale: [-2, 3])
        parent.transform = Transform(translation: [10, 5], rotation: -0.4, scale: [3, 0.5])
        outer.addChild(parent); world.addEntity(outer)
        for forward: Float in [0, .pi / 2, 0.7] {
            let owner = Entity(components: TransformConstraintComponent([
                TransformConstraint(.lookAt(.point([90, 110]), forwardAngle: forward))
            ]))
            owner.transform = Transform(translation: [4, -8], rotation: -2, scale: [-1.5, 2], zPosition: 7)
            parent.addChild(owner); evaluate(renderer)
            let node = try #require(renderer.node(for: owner))
            let origin = node.convert(.zero, to: renderer)
            let tip = node.convert(CGPoint(x: Double(cos(forward)), y: Double(sin(forward))), to: renderer)
            let axis = SIMD2<Float>(Float(tip.x - origin.x), Float(tip.y - origin.y))
            let direction = SIMD2<Float>(90 - Float(origin.x), 110 - Float(origin.y))
            let length = hypot(axis.x, axis.y), distance = hypot(direction.x, direction.y)
            #expect(constraintClose(axis / length, direction / distance))
            #expect(owner.position == [4, -8] && owner.scale == [-1.5, 2] && owner.zPosition == 7)
            #expect(owner.transformConstraintStatuses == [.active])
        }
    }

    @Test func orderedBoundsDistanceAndRotationLimitsUseTheirDeclaredSpaces() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let owner = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.point([100, 80]))),
            TransformConstraint(.positionBounds(min: [-20, -20], max: [30, 40])),
            TransformConstraint(.distance(to: .point(.zero), range: 0...10)),
            TransformConstraint(.lookAt(.point([6, 100]))),
            TransformConstraint(.rotationLimits(-0.25...0.25))
        ]))
        world.addEntity(owner); evaluate(renderer)
        #expect(constraintClose(owner.position, [6, 8]))
        #expect(abs(owner.rotation - 0.25) < 0.001)
        #expect(owner.transformConstraintStatuses == Array(repeating: .active, count: 5))
        owner.components[TransformConstraintComponent.self]?.constraints.swapAt(0, 2)
        evaluate(renderer)
        #expect(constraintClose(owner.position, [100, 80]))

        let parent = Entity()
        parent.transform = Transform(translation: [40, 20], rotation: 0.8, scale: [-2, 3])
        let sceneLimited = Entity(components: TransformConstraintComponent([
            TransformConstraint(.positionBounds(min: [-10, -5], max: [10, 5], relativeTo: .scene)),
            TransformConstraint(.rotationLimits(-0.2...0.2, relativeTo: .scene))
        ]))
        parent.addChild(sceneLimited); world.addEntity(parent); evaluate(renderer)
        #expect(constraintClose(sceneLimited.scenePosition, [10, 5]))
        let axis = sceneLimited.sceneTransformMatrix.apply(toDirection: [1, 0])
        #expect(abs(atan2(axis.y, axis.x) + 0.2) < 0.001)
        sceneLimited.rotation = 8
        sceneLimited.components.set(TransformConstraintComponent([TransformConstraint(.rotationLimits(6...7))]))
        evaluate(renderer)
        #expect(sceneLimited.rotation == 7)
        sceneLimited.components.set(TransformConstraintComponent([TransformConstraint(.distance(to: .point(sceneLimited.scenePosition), range: 5...10))]))
        let origin = sceneLimited.scenePosition
        evaluate(renderer)
        #expect(constraintClose(sceneLimited.scenePosition, origin + SIMD2<Float>(5, 0)))
    }

    @Test func targetChainsAndConstrainedAncestorsIgnoreInsertionOrder() {
        for reversed in [false, true] {
            let world = World(), renderer = SpriteRenderer(world: world)
            let parent = Entity(components: TransformConstraintComponent([TransformConstraint(.follow(.point([30, 20])))]))
            let target = Entity(); target.position = [7, 9]; parent.addChild(target)
            let middle = Entity(components: TransformConstraintComponent([
                TransformConstraint(.follow(.entity(target.id), offset: [3, -4], offsetSpace: .scene))
            ]))
            let follower = Entity(components: TransformConstraintComponent([TransformConstraint(.follow(.entity(middle.id)))]))
            let localFollower = Entity(components: TransformConstraintComponent([TransformConstraint(.follow(.point([80, 60])))]))
            parent.addChild(localFollower)
            let roots = [follower, middle, parent]
            for entity in reversed ? Array(roots.reversed()) : roots { world.addEntity(entity) }
            evaluate(renderer)
            #expect(constraintClose(parent.position, [30, 20]))
            #expect(constraintClose(middle.scenePosition, [40, 25]))
            #expect(constraintClose(follower.scenePosition, [40, 25]))
            #expect(constraintClose(localFollower.position, [50, 40]))
            #expect(follower.transformConstraintStatuses == [.active])
        }
    }

    @Test func overlappingCyclesRejectEveryMemberAndTheirDownstreamThenRetry() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let a = Entity(), b = Entity(), c = Entity(), downstream = Entity(), selfTarget = Entity()
        a.components.set(TransformConstraintComponent([
            TransformConstraint(.follow(.entity(b.id))), TransformConstraint(.follow(.entity(c.id))),
            TransformConstraint(.positionBounds(min: [5, 5], max: [10, 10]))
        ]))
        b.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(a.id)))]))
        c.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(b.id)))]))
        downstream.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(c.id)))]))
        selfTarget.components.set(TransformConstraintComponent([TransformConstraint(.lookAt(.entity(selfTarget.id)))]))
        for entity in [downstream, c, a, selfTarget, b] { world.addEntity(entity) }
        evaluate(renderer)
        #expect(a.transformConstraintStatuses == [.cycle, .cycle, .cycle])
        #expect(b.transformConstraintStatuses == [.cycle] && c.transformConstraintStatuses == [.cycle])
        #expect(downstream.transformConstraintStatuses == [.dependencyFailed])
        #expect(selfTarget.transformConstraintStatuses == [.cycle])
        #expect(a.position == .zero && downstream.position == .zero)
        b.components.set(TransformConstraintComponent([TransformConstraint(.follow(.point([20, 30])))]))
        evaluate(renderer)
        #expect(a.transformConstraintStatuses == [.active, .active, .active])
        #expect(c.transformConstraintStatuses == [.active] && downstream.transformConstraintStatuses == [.active])
        #expect(constraintClose(downstream.position, [20, 30]))
    }

    @Test func missingInactiveAndNamedTargetsRetryAndDiagnosticsInvalidateOnEdits() {
        let world = World(), renderer = SpriteRenderer(world: world), target = Entity(name: "target")
        target.position = [15, 25]
        let owner = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.entity(target.id))),
            TransformConstraint(.follow(.named("target"))),
            TransformConstraint(.positionBounds(min: [1, 2], max: [3, 4]))
        ]))
        world.addEntity(owner)
        #expect(owner.transformConstraintStatuses == [.notRendered, .notRendered, .notRendered])
        evaluate(renderer)
        #expect(owner.transformConstraintStatuses == [.missingTarget, .missingTarget, .active])
        #expect(owner.position == [1, 2])
        target.isEnabled = false; world.addEntity(target); evaluate(renderer)
        #expect(owner.transformConstraintStatuses == [.inactiveTarget, .inactiveTarget, .active])
        target.isEnabled = true
        owner.components[TransformConstraintComponent.self]?.constraints.removeLast()
        #expect(owner.transformConstraintStatuses == [.notRendered, .notRendered])
        evaluate(renderer)
        #expect(owner.position == [15, 25] && owner.transformConstraintStatuses == [.active, .active])
        world.removeEntity(target); evaluate(renderer)
        #expect(owner.transformConstraintStatuses == [.missingTarget, .missingTarget])
        world.addEntity(target); evaluate(renderer)
        #expect(owner.transformConstraintStatuses == [.active, .active])
        owner.components.set(TransformConstraintComponent([TransformConstraint(.follow(.named("root")))]))
        evaluate(renderer)
        #expect(owner.position == .zero && owner.transformConstraintStatuses == [.active])
    }

    @Test func dynamicAndCharacterSubtreesRejectOwnersButAllowChildrenOfControllers() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let rule = TransformConstraintComponent([TransformConstraint(.follow(.point([10, 20])))])
        for character in [false, true] {
            let parent = Entity(components: rule), body = Entity(), child = Entity(components: rule)
            if character { body.components.set(CharacterControllerComponent(shape: .circle(radius: 2))) }
            else { body.components.set(PhysicsBodyComponent(shape: .circle(radius: 2))) }
            parent.addChild(body); body.addChild(child); world.addEntity(parent)
            body.components.set(rule)
            evaluate(renderer)
            let rejection: TransformConstraintStatus = character ? .characterControlled : .dynamicBody
            #expect(parent.transformConstraintStatuses == [rejection])
            #expect(body.transformConstraintStatuses == [rejection])
            #expect(parent.position == .zero && body.position == .zero)
            #expect(child.transformConstraintStatuses == [.active])
            #expect(constraintClose(child.scenePosition, [10, 20]))
            if character { body.components.remove(CharacterControllerComponent.self) }
            else { body.components[PhysicsBodyComponent.self]?.isDynamic = false }
            evaluate(renderer)
            #expect(parent.transformConstraintStatuses == [.active], "character=\(character), statuses=\(String(describing: parent.transformConstraintStatuses))")
            #expect(body.transformConstraintStatuses == [.active], "character=\(character), statuses=\(String(describing: body.transformConstraintStatuses))")
        }
    }

    @Test func invalidRulesAndSingularParentsNeverPartiallyWriteInvalidPoses() {
        let world = World(), renderer = SpriteRenderer(world: world), owner = Entity()
        let invalid: [TransformConstraintBehavior] = [
            .follow(.entity(owner.id), smoothing: -.infinity),
            .follow(.point([Float.nan, 0])),
            .lookAt(.point([10, 0]), forwardAngle: .nan),
            .distance(to: .point(.zero), range: -1...2),
            .positionBounds(min: [5, 0], max: [1, 2]),
            .rotationLimits(-4...4, relativeTo: .scene)
        ]
        owner.components.set(TransformConstraintComponent(invalid.map { TransformConstraint($0) } + [
            TransformConstraint(.positionBounds(min: [5, 6], max: [10, 12]))
        ]))
        world.addEntity(owner); evaluate(renderer)
        #expect(invalid.allSatisfy { !$0.isValid })
        #expect(owner.transformConstraintStatuses == Array(repeating: .invalidConfiguration, count: invalid.count) + [.active])
        #expect(owner.position == [5, 6] && owner.rotation.isFinite)
        let singular = Entity(), constrained = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.point([20, 30]))), TransformConstraint(.lookAt(.point([40, 50])))
        ]))
        constrained.transform = Transform(translation: [3, 4], rotation: 0.7, scale: [2, 3], zPosition: 8)
        let original = constrained.transform
        singular.scale = [0, 1]; singular.addChild(constrained); world.addEntity(singular)
        evaluate(renderer)
        #expect(constrained.transformConstraintStatuses == [.invalidTransform, .invalidTransform])
        #expect(constrained.transform == original)
        singular.scale = .one; evaluate(renderer)
        #expect(constrained.transformConstraintStatuses == [.active, .active])
        #expect(constraintClose(constrained.position, [20, 30]))
        for delta in [Double.nan, Double.infinity, -1] {
            renderer.updateTransformConstraints(deltaTime: delta)
            #expect(constraintClose(constrained.position, [20, 30]))
        }
    }

    @Test func frameCallbacksHonorPauseTimeScaleActivationAndPresentedActionChannels() throws {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity()
        let target = Entity(), owner = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.entity(target.id), smoothing: 0.5), name: "track")
        ]))
        parent.addChild(owner); world.addEntity(parent); world.addEntity(target)
        renderer.update(0); renderer.didFinishUpdate()
        withAnimation(.linear(duration: 1)) {
            target.position = [100, 80]
            owner.rotation = 2; owner.scale = [4, 5]; owner.zPosition = 9
        }
        renderer.flush()
        let targetNode = try #require(renderer.node(for: target)), ownerNode = try #require(renderer.node(for: owner))
        targetNode.position = CGPoint(x: 25, y: 15)
        ownerNode.zRotation = 0.3; ownerNode.xScale = 1.2; ownerNode.yScale = 1.3; ownerNode.zPosition = 3
        world.timeScale = 2
        renderer.update(0.02); renderer.didFinishUpdate()
        let first = SIMD2<Float>(25, 15) * Float(1 - exp(-0.04 / 0.5))
        #expect(constraintClose(owner.position, first))
        #expect(owner.rotation == 2 && owner.scale == [4, 5] && owner.zPosition == 9)
        #expect(abs(ownerNode.zRotation - 0.3) < 0.001 && abs(ownerNode.xScale - 1.2) < 0.001)
        #expect(ownerNode.zPosition == 3 && target.position == [100, 80])
        #expect(targetNode.action(forKey: "transform.position") != nil)
        #expect(ownerNode.action(forKey: "transform.rotation") != nil)
        world.isPaused = true
        renderer.update(0.04); renderer.didFinishUpdate()
        #expect(constraintClose(owner.position, first))
        world.isPaused = false; world.timeScale = 0
        renderer.update(0.06); renderer.didFinishUpdate()
        #expect(constraintClose(owner.position, first))
        world.timeScale = 1; parent.isEnabled = false
        renderer.update(0.08); renderer.didFinishUpdate()
        #expect(owner.transformConstraintStatuses == [.disabled])
        #expect(constraintClose(owner.position, first))
        parent.isEnabled = true
        renderer.update(0.10); renderer.didFinishUpdate()
        let expected = first + (SIMD2<Float>(25, 15) - first) * Float(1 - exp(-0.02 / 0.5))
        #expect(constraintClose(owner.position, expected))
        #expect(owner.transformConstraintStatuses == [.active])
        #expect(owner.components[TransformConstraintComponent.self]?.setEnabled(false, named: "track") == true)
        renderer.update(0.12); renderer.didFinishUpdate()
        #expect(owner.transformConstraintStatuses == [.disabled] && constraintClose(owner.position, expected))
    }

    @Test func cloneSnapshotPrefabAndPoolingPreserveAndRemapReferences() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let root = Entity(name: "rig"), target = Entity(name: "target"), external = Entity(name: "external")
        target.position = [30, 40]
        let rules = TransformConstraintComponent([
            TransformConstraint(.follow(.entity(target.id)), name: "track"),
            TransformConstraint(.lookAt(.named("target")), isEnabled: false),
            TransformConstraint(.distance(to: .entity(target.id), range: 0...100)),
            TransformConstraint(.follow(.entity(external.id)), isEnabled: false),
            TransformConstraint(.follow(.named("outside")), isEnabled: false),
            TransformConstraint(.follow(.point([3, 4])), isEnabled: false)
        ])
        let owner = Entity(name: "owner", components: rules)
        root.addChild(owner); root.addChild(target); world.addEntity(root); world.addEntity(external)
        evaluate(renderer)
        #expect(owner.transformConstraintStatuses == [.active, .disabled, .active, .disabled, .disabled, .disabled])
        let headless = World(), headlessOwner = Entity(components: rules)
        headless.addEntity(headlessOwner); headless.update(deltaTime: 1)
        #expect(headlessOwner.position == .zero)
        #expect(headlessOwner.transformConstraintStatuses == [.notRendered, .disabled, .notRendered, .disabled, .disabled, .disabled])
        #expect(try JSONDecoder().decode(TransformConstraintComponent.self, from: JSONEncoder().encode(rules)) == rules)
        #expect(ComponentRegistry.isRegistered(TransformConstraintComponent.self))
        let saved = try WorldSnapshot(data: world.snapshot().jsonData())
        let copy = root.clone(), snapshotCopy = root.snapshot().makeEntity()
        let prefab = PrefabResource(root: root)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try prefab.write(to: url)
        let loaded = try PrefabResource.read(Data(contentsOf: url), from: url)
        for instance in [copy, snapshotCopy, prefab.instantiate(), loaded.instantiate()] {
            let copiedTarget = try #require(instance.findEntity(named: "target"))
            let copiedOwner = try #require(instance.findEntity(named: "owner"))
            let component = try #require(copiedOwner.components[TransformConstraintComponent.self])
            #expect(component.constraints.map(\.behavior) == [
                .follow(.entity(copiedTarget.id)), .lookAt(.entity(copiedTarget.id)),
                .distance(to: .entity(copiedTarget.id), range: 0...100), .follow(.entity(external.id)),
                .follow(.named("outside")), .follow(.point([3, 4]))
            ])
            world.addEntity(instance)
            #expect(copiedOwner.transformConstraintStatuses == [.notRendered, .disabled, .notRendered, .disabled, .disabled, .disabled])
            copiedTarget.position = [50, 60]; evaluate(renderer)
            #expect(constraintClose(copiedOwner.position, [50, 60]))
        }
        #expect(owner.components[TransformConstraintComponent.self] == rules && target.position == [30, 40])
        let pool = try EntityPool(prefab: prefab, scene: world, capacity: 1, prewarm: 1)
        let lease = try #require(try pool.acquire())
        let pooledOwner = try #require(lease.findEntity(named: "owner")), pooledTarget = try #require(lease.findEntity(named: "target"))
        let oldNode = renderer.node(for: pooledOwner)
        pooledTarget.position = [70, 80]; evaluate(renderer)
        #expect(pooledOwner.position == [70, 80])
        #expect(try pool.release(lease))
        #expect(pooledOwner.transformConstraintStatuses == Array(repeating: .disabled, count: 6))
        let reacquired = try #require(try pool.acquire { $0.findEntity(named: "target")?.position = [90, 100] })
        evaluate(renderer)
        #expect(reacquired === lease && renderer.node(for: pooledOwner) === oldNode)
        #expect(pooledOwner.position == [90, 100])
        #expect(pooledOwner.components[TransformConstraintComponent.self]?.constraints[0].behavior == .follow(.entity(pooledTarget.id)))
        let restored = world.restore(saved), restoredOwner = try #require(restored[owner.id])
        #expect(restoredOwner.components[TransformConstraintComponent.self] == rules)
        #expect(restoredOwner.transformConstraintStatuses == [.notRendered, .disabled, .notRendered, .disabled, .disabled, .disabled])
        evaluate(renderer)
        #expect(restoredOwner.position == [30, 40])
    }
}

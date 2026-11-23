@_spi(Backend) import ECSCore
@_spi(Backend) @testable import SpriteBackend
import Foundation
import SpriteKit
import Testing

@MainActor @Suite struct VisibilityTests {
    private let map = RenderLayer(rawValue: 1 << 1)
    private let privateLayer = RenderLayer(rawValue: 1 << 63)
    private func fixture() -> (World, SpriteRenderer, Entity, Entity, Entity) {
        let world = World()
        let camera = Entity(components: CameraComponent(cullingMask: .default))
        let mapCamera = Entity(components: CameraComponent(cullingMask: map))
        let target = Entity(components: SpriteComponent(color: .red, size: [20, 20]),
                            CollisionComponent(shape: .rectangle(size: [20, 20])), InputTargetComponent(),
                            VisibilityComponent(layers: .default))
        world.addEntity(camera); world.addEntity(mapCamera); world.addEntity(target)
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
        renderer.viewports = [
            .init(id: "world", camera: camera.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            .init(id: "map", camera: mapCamera.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        return (world, renderer, camera, mapCamera, target)
    }

    @Test func layerSetOperationsAndAll64BitsRoundTrip() throws {
        let layers: RenderLayer = [.default, map, privateLayer]
        #expect(layers.contains(.default) && layers.contains(map) && layers.contains(privateLayer))
        #expect(layers.intersection(map) == map)
        #expect(RenderLayer.all.contains(layers) && RenderLayer.none.isEmpty)
        #expect(try JSONDecoder().decode(RenderLayer.self, from: JSONEncoder().encode(layers)) == layers)
        #expect(try JSONDecoder().decode(RenderLayer.self, from: JSONEncoder().encode(RenderLayer.all)) == .all)
    }

    @Test func untaggedContentIsUnrestrictedAndMasksAreIndependent() {
        let (world, renderer, camera, _, target) = fixture()
        let untagged = Entity(); world.addEntity(untagged)
        #expect(renderer.isVisible(untagged, inViewport: "world"))
        #expect(renderer.isVisible(untagged, inViewport: "map"))
        #expect(renderer.isVisible(target, inViewport: "world"))
        #expect(!renderer.isVisible(target, inViewport: "map"))
        #expect(renderer.visibilityMask(inViewport: "unknown") == nil)
        camera.components[CameraComponent.self]?.cullingMask = .none
        #expect(!renderer.isVisible(untagged, inViewport: "world"))
        #expect(!renderer.isVisible(target))
    }

    @Test func viewportMasksNarrowRatherThanOverrideCameraMasks() {
        let (_, renderer, _, _, target) = fixture()
        renderer.viewports.append(.init(id: "restricted", camera: renderer.activeCamera?.id, cullingMask: map))
        #expect(renderer.visibilityMask(inViewport: "restricted") == RenderLayer.none)
        #expect(!renderer.isVisible(target, inViewport: "restricted"))
        #expect(renderer.visibilityMask(inViewport: "world") == .default)
        #expect(renderer.visibilityMask(inViewport: "map") == map)
    }

    @Test func explicitAncestorGatesCannotBeEscapedByChildren() {
        let (world, renderer, _, mapCamera, target) = fixture()
        let parent = Entity(components: VisibilityComponent(layers: .default))
        world.addEntity(parent); parent.addChild(target)
        target.components[VisibilityComponent.self]?.layers = map
        #expect(!renderer.isVisible(target, inViewport: "map"))
        parent.components[VisibilityComponent.self]?.layers = [.default, map]
        #expect(renderer.isVisible(target, inViewport: "map"))
        #expect(!renderer.isVisible(target, inViewport: "world"))
        // Each explicit ancestor gates the camera independently; a camera with
        // both categories can see differently tagged parent and child content.
        mapCamera.components[CameraComponent.self]?.cullingMask = [.default, map]
        parent.components[VisibilityComponent.self]?.layers = .default
        #expect(renderer.isVisible(target, inViewport: "map"))
        parent.components[VisibilityComponent.self]?.isVisible = false
        #expect(!renderer.isVisible(target, inViewport: "map"))
    }

    @Test func nativeFilteringRestoresBetweenCamerasAndPreservesBaseHiding() throws {
        let (world, renderer, _, _, target) = fixture()
        let mapItem = Entity(components: VisibilityComponent(layers: map)); world.addEntity(mapItem)
        let targetNode = try #require(renderer.node(for: target))
        let mapNode = try #require(renderer.node(for: mapItem))
        renderer.didFinishUpdate()
        #expect(!targetNode.isHidden && mapNode.isHidden)
        #expect(!renderer.isPresentationHidden(mapNode))
        renderer.renderViewport("map") {
            #expect(targetNode.isHidden && !mapNode.isHidden)
            #expect(renderer.isVisible(mapItem, inViewport: "map"))
            #expect(!renderer.isVisible(target, inViewport: "map"))
        }
        #expect(!targetNode.isHidden && mapNode.isHidden)
        renderer.restoreRenderVisibility()
        targetNode.isHidden = true
        renderer.renderViewport("world") { #expect(targetNode.isHidden) }
        #expect(targetNode.isHidden)
        #expect(!renderer.isVisible(target, inViewport: "world"))
    }

    @Test func cameraScopesDoNotDirtyComponentsOrChangeActivationAndBodies() throws {
        let (world, renderer, _, _, target) = fixture()
        target.components.set(PhysicsBodyComponent(shape: .rectangle(size: [20, 20])))
        renderer.flush()
        let native = try #require(renderer.node(for: target)?.physicsBody)
        let revision = target.activationRevision
        let snapshot = try world.snapshot().jsonData()
        renderer.renderViewport("map") {
            #expect(target.isActive && target.activationRevision == revision)
            #expect(native.isDynamic)
        }
        #expect(native.isDynamic)
        #expect(try world.snapshot().jsonData() == snapshot)
    }

    @Test func hiddenEntitiesStillParticipateInModelSpacePhysicsQueries() {
        let (world, renderer, _, _, target) = fixture()
        target.components[VisibilityComponent.self]?.isVisible = false
        renderer.didFinishUpdate()
        #expect(renderer.inputTarget(at: .zero, inViewport: "world") == nil)
        #expect(world.raycast(from: [-30, 0], to: [30, 0]).first?.entity === target)
        #expect(target.isActive && world.performQuery(EntityQuery(where: .has(CollisionComponent.self))).contains { $0 === target })
    }

    @Test func hitTestingUsesPanePolicyEvenWhenPrimaryFlagsHideOtherContent() {
        let (world, renderer, _, _, worldItem) = fixture()
        let mapItem = Entity(components: SpriteComponent(color: .green, size: [20, 20]),
                             CollisionComponent(shape: .rectangle(size: [20, 20])), InputTargetComponent(),
                             VisibilityComponent(layers: map))
        mapItem.zPosition = 10; world.addEntity(mapItem)
        renderer.didFinishUpdate()
        #expect(renderer.node(for: mapItem)?.isHidden == true)
        #expect(renderer.inputTarget(at: .zero, inViewport: "map") === mapItem)
        #expect(renderer.inputTarget(at: .zero, inViewport: "world") === worldItem)
        #expect(renderer.inputTarget(at: .zero) === worldItem)
        #expect(renderer.entities(at: .zero, inViewport: "missing").isEmpty)
    }

    @Test func policyChangesHaveStickyRevisionsButShakeAndZoomDoNot() throws {
        let (_, renderer, camera, _, target) = fixture()
        let before = try #require(renderer.visibilityRevision(of: target, inViewport: "world"))
        target.components[VisibilityComponent.self]?.isVisible = false
        target.components[VisibilityComponent.self]?.isVisible = true
        let after = try #require(renderer.visibilityRevision(of: target, inViewport: "world"))
        #expect(after > before)
        camera.components[CameraComponent.self]?.trauma = 0.5
        camera.components[CameraComponent.self]?.zoom = 2
        #expect(renderer.visibilityRevision(of: target, inViewport: "world") == after)
        camera.components[CameraComponent.self]?.cullingMask = .all
        #expect(try #require(renderer.visibilityRevision(of: target, inViewport: "world")) > after)
    }

    @Test func visibilityEventsOnlyReportActualPolicyChanges() {
        let (world, renderer, camera, _, target) = fixture()
        defer { withExtendedLifetime(renderer) {} }
        var seen: [Entity.ID] = []
        let token = world.subscribe(to: VisibilityEvents.DidChange.self) { seen.append($0.entity.id) }
        target.components.set(VisibilityComponent(layers: .default))
        camera.components[CameraComponent.self]?.trauma = 0.5
        #expect(seen.isEmpty)
        target.components[VisibilityComponent.self]?.isVisible = false
        camera.components[CameraComponent.self]?.cullingMask = .none
        #expect(seen == [target.id, camera.id])
        token.cancel()
    }

    @Test func oldCameraPayloadsDecodeWithAllLayersAndNewValuesRoundTrip() throws {
        let old = Data(#"{"zoom":2,"smoothing":0.25,"isActive":true,"offset":[1,2],"trauma":0.3,"traumaDecay":2,"maxShake":8}"#.utf8)
        let camera = try JSONDecoder().decode(CameraComponent.self, from: old)
        #expect(camera.cullingMask == .all && camera.zoom == 2 && camera.offset == [1, 2])
        var tagged = camera; tagged.cullingMask = [map, privateLayer]
        #expect(try JSONDecoder().decode(CameraComponent.self, from: JSONEncoder().encode(tagged)) == tagged)
    }

    @Test func visibilitySnapshotsAndClonesPreserveAllBitsAndHierarchy() throws {
        SpriteRenderer.registerComponents()
        let original = Entity(components: VisibilityComponent(layers: [.default, privateLayer], isVisible: false))
        let child = Entity(components: VisibilityComponent(layers: map)); original.addChild(child)
        let clone = original.clone()
        #expect(clone.components[VisibilityComponent.self] == original.components[VisibilityComponent.self])
        let restored = try JSONDecoder().decode(EntitySnapshot.self, from: JSONEncoder().encode(original.snapshot())).makeEntity()
        #expect(restored.components[VisibilityComponent.self] == original.components[VisibilityComponent.self])
        #expect(restored.children.first?.components[VisibilityComponent.self]?.layers == map)
    }

    @Test func activationAndRemovalCannotBeUndoneByRestoringVisibilityOverrides() throws {
        let (_, renderer, _, _, target) = fixture()
        target.components[VisibilityComponent.self]?.isVisible = false
        renderer.didFinishUpdate()
        let node = try #require(renderer.node(for: target))
        target.isEnabled = false
        renderer.restoreRenderVisibility()
        #expect(node.isHidden && !target.isActive)
        target.isEnabled = true
        #expect(!node.isHidden && target.isActive)
        renderer.didFinishUpdate()
        target.removeFromParent()
        renderer.restoreRenderVisibility()
        #expect(node.parent == nil)
    }

    @Test func programmaticManipulationUsesItsSelectedViewportAndCancelsWhenHidden() throws {
        let (_, renderer, _, _, target) = fixture()
        target.components.set(ManipulationComponent())
        #expect(renderer.beginManipulation(of: target, at: .zero, inViewport: "map") == nil)
        let session = try #require(renderer.beginManipulation(of: target, at: .zero, inViewport: "world"))
        #expect(session.isActive)
        target.components[VisibilityComponent.self]?.isVisible = false
        #expect(!session.isActive)
        target.components[VisibilityComponent.self]?.isVisible = true
        #expect(!session.isActive)
    }

    @Test func inspectorPickingRespectsTheClickedViewportLayers() {
        let (world, renderer, _, _, target) = fixture()
        let mapItem = Entity(components: SpriteComponent(color: .green, size: [20, 20]), VisibilityComponent(layers: map))
        world.addEntity(mapItem)
        let debug = SceneDebugController()
        #expect(renderer.setDebugController(debug))
        #expect(debug.select(atView: CGPoint(x: 50, y: 50)) == target.id)
        #expect(debug.select(atView: CGPoint(x: 150, y: 50)) == mapItem.id)
    }

    @Test func cancellationCallbacksCannotEraseAVisibilityTransition() throws {
        let (world, renderer, _, _, target) = fixture()
        target.components.set(ManipulationComponent())
        let session = try #require(renderer.beginManipulation(of: target, at: .zero, inViewport: "world"))
        let before = try #require(renderer.visibilityRevision(of: target, inViewport: "world"))
        var policies: [(UInt64, Bool)] = []
        let visibility = world.subscribe(to: VisibilityEvents.DidChange.self) { event in
            guard event.entity === target else { return }
            policies.append((event.revision, event.policy.visibility!.isVisible))
        }
        let cancellation = world.subscribe(to: ManipulationEvents.Cancelled.self) { _ in
            target.components[VisibilityComponent.self]?.isVisible = true
        }
        target.components[VisibilityComponent.self]?.isVisible = false
        #expect(!session.isActive)
        #expect(target.components[VisibilityComponent.self]?.isVisible == true)
        #expect(policies.sorted { $0.0 < $1.0 }.map(\.1) == [false, true])
        #expect(try #require(renderer.visibilityRevision(of: target, inViewport: "world")) >= before + 2)
        visibility.cancel(); cancellation.cancel()
    }

    @Test func removalCallbacksCannotLeaveDetachedVisibilityCaches() throws {
        let (world, renderer, _, _, target) = fixture()
        target.components.set(ManipulationComponent())
        let session = try #require(renderer.beginManipulation(of: target, at: .zero, inViewport: "world"))
        let cancellation = world.subscribe(to: ManipulationEvents.Cancelled.self) { _ in
            target.components[VisibilityComponent.self]?.isVisible = false
        }
        target.removeFromParent()
        #expect(!session.isActive && target.world == nil)
        #expect(renderer.knownVisibility[target.id] == nil)
        #expect(renderer.knownCameraVisibility[target.id] == nil)
        #expect(renderer.visibilityRevisions[target.id] == nil)
        cancellation.cancel()
    }
}

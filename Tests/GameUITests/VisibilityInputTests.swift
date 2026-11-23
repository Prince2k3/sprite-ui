import ECSCore
@testable import GameUI
import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct VisibilityInputTests {
    private let map = RenderLayer(rawValue: 1 << 1)
    private let left = CGPoint(x: 50, y: 100)
    private let right = CGPoint(x: 150, y: 100)

    private func fixture() -> (GameHost, Entity, Entity, Entity, Entity) {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        let camera = Entity(components: CameraComponent(cullingMask: .default))
        let mapCamera = Entity(components: CameraComponent(cullingMask: map))
        host.world.addEntity(camera); host.world.addEntity(mapCamera); host.world.activeCamera = camera
        let art = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent(),
                         ManipulationComponent(), VisibilityComponent(layers: .default))
        let mapArt = Entity(components: SpriteComponent(color: .green, size: [40, 40]), InputTargetComponent(),
                            ManipulationComponent(), VisibilityComponent(layers: map))
        mapArt.transform.zPosition = 10
        host.world.addEntity(art); host.world.addEntity(mapArt)
        host.renderer.viewports = [
            GameViewport(id: "world", camera: camera.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            GameViewport(id: "map", camera: mapCamera.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        host.renderer.flush(); host.renderer.didFinishUpdate()
        return (host, art, mapArt, camera, mapCamera)
    }

    @Test func legacyUnmarkedEntitiesRemainPickableAcrossCameraLayers() {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        let camera = Entity(components: CameraComponent(cullingMask: map))
        let target = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent())
        host.world.addEntity(camera); host.world.addEntity(target); host.renderer.flush()
        let center = CGPoint(x: 100, y: 100)
        host.beginInput(at: center)
        #expect(host.contact(startingAt: center)?.hit === target)
        #expect(host.contact(startingAt: center)?.viewportID == nil)
        host.cancelInputs()
        target.components.set(VisibilityComponent())
        host.beginInput(at: center)
        #expect(host.contact(startingAt: center)?.hit == nil)
        host.cancelInputs(); target.components.remove(VisibilityComponent.self)
        camera.components[CameraComponent.self]?.cullingMask = .none
        host.beginInput(at: center)
        #expect(host.contact(startingAt: center)?.hit == nil)
    }

    @Test func startsUsePaneVisibilityEvenWhenPrimaryPresentationHidesTheMapArt() throws {
        let (host, art, mapArt, _, _) = fixture()
        #expect(try #require(host.renderer.node(for: mapArt)).isHidden)
        #expect(!host.renderer.isPresentationHidden(try #require(host.renderer.node(for: mapArt))))
        host.beginInput(at: left); host.beginInput(at: right)
        let world = try #require(TargetedInputCapture<Int>().resolve(1, start: left, host: host, resolver: { $0 }))
        let overview = try #require(TargetedInputCapture<Int>().resolve(1, start: right, host: host, resolver: { $0 }))
        #expect(world.entity === art && world.viewportID == "world")
        #expect(overview.entity === mapArt && overview.viewportID == "map")
        #expect(overview.convertIfAvailable(right, to: .scene) == .zero)
    }

    @Test func retainedConversionObservesHiddenStateAndCannotReviveAfterShowing() throws {
        let (host, _, art, _, _) = fixture()
        host.beginInput(at: right)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: right, host: host, resolver: { $0 }))
        art.components[VisibilityComponent.self]?.isVisible = false
        // No flush: cancellation follows the model, not the last native frame.
        #expect(value.convertIfAvailable(right, to: .scene) == nil)
        art.components[VisibilityComponent.self]?.isVisible = true
        #expect(value.convertIfAvailable(right, to: .scene) == nil)
        #expect(capture.resolve(2, start: right, host: host, resolver: { $0 }) == nil)
        host.beginInput(at: right)
        #expect(TargetedInputCapture<Int>().resolve(3, start: right, host: host, resolver: { $0 })?.entity === art)
    }

    @Test func frameObservationCancelsOnlyCapturesHiddenByCameraMaskChanges() throws {
        let (host, _, _, camera, _) = fixture()
        host.beginInput(at: left); host.beginInput(at: right)
        let a = TargetedInputCapture<Int>(), b = TargetedInputCapture<Int>()
        let world = try #require(a.resolve(1, start: left, host: host, resolver: { $0 }))
        let overview = try #require(b.resolve(1, start: right, host: host, resolver: { $0 }))
        camera.components[CameraComponent.self]?.cullingMask = map
        host.renderer.didFinishUpdate()
        camera.components[CameraComponent.self]?.cullingMask = .default
        #expect(world.convertIfAvailable(left, to: .scene) == nil)
        #expect(a.resolve(2, start: left, host: host, resolver: { $0 }) == nil)
        #expect(overview.convertIfAvailable(right, to: .scene) != nil)
        #expect(b.resolve(2, start: right, host: host, resolver: { $0 }) != nil)
    }

    @Test func ancestorGatesAndPaneRestrictionsApplyToInputAndManipulation() {
        let (host, _, art, _, _) = fixture()
        let parent = Entity(components: VisibilityComponent(layers: .default))
        host.world.addEntity(parent); parent.addChild(art); host.renderer.flush()
        host.beginInput(at: right)
        #expect(host.contact(startingAt: right)?.hit == nil)
        let input = GameManipulationInput(host: host)
        #expect(!input.admitContact(1, at: right))
        parent.components[VisibilityComponent.self]?.layers = [.default, map]
        #expect(input.admitContact(2, at: right))
        #expect(input.begin(.pan, contacts: [2]))
        parent.components[VisibilityComponent.self]?.isVisible = false
        #expect(!input.change(.pan, translation: CGPoint(x: 10, y: 0)))
        #expect(input.session == nil)
        parent.components[VisibilityComponent.self]?.isVisible = true
        host.renderer.viewports[1].cullingMask = .default
        #expect(!input.admitContact(3, at: right))
    }

    @Test func manipulationBeginsInItsPaneAndObservedHiddenAdmissionCannotResume() throws {
        let (host, _, art, _, mapCamera) = fixture()
        let input = GameManipulationInput(host: host)
        #expect(input.admitContact(1, at: right))
        #expect(input.begin(.pan, contacts: [1]))
        let session = try #require(input.session)
        #expect(session.entity === art)
        #expect(input.change(.pan, translation: CGPoint(x: 10, y: 0)))
        #expect(art.position == [10, 0])
        mapCamera.components[CameraComponent.self]?.cullingMask = .default
        host.renderer.didFinishUpdate()
        #expect(!session.isActive && input.session == nil)
        mapCamera.components[CameraComponent.self]?.cullingMask = map
        #expect(!input.begin(.pan, contacts: [1]))
        #expect(input.admitContact(2, at: right))
        art.components[VisibilityComponent.self]?.isVisible = false
        host.renderer.didFinishUpdate()
        art.components[VisibilityComponent.self]?.isVisible = true
        #expect(!input.begin(.pan, contacts: [2]))
    }

    @Test func typedGateAdditionAndPaneDescriptorChangesPermanentlyCancelContacts() throws {
        let (host, art, _, _, _) = fixture()
        art.components.remove(VisibilityComponent.self)
        host.beginInput(at: left)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: left, host: host, resolver: { $0 }))
        art.components.set(VisibilityComponent(isVisible: false))
        art.components.remove(VisibilityComponent.self)
        #expect(value.convertIfAvailable(left, to: .scene) == nil)
        host.beginInput(at: left)
        let next = try #require(TargetedInputCapture<Int>().resolve(2, start: left, host: host, resolver: { $0 }))
        host.renderer.viewports[0].cullingMask = .all
        #expect(next.convertIfAvailable(left, to: .scene) == nil)
        host.renderer.viewports[0].cullingMask = nil
        #expect(next.convertIfAvailable(left, to: .scene) == nil)
    }

    @Test func cancellationCallbackCannotReviveALaterGestureObserver() throws {
        let (host, _, art, _, _) = fixture()
        // Register native manipulation before pointer/gesture observers.
        let input = GameManipulationInput(host: host)
        host.beginInput(at: right)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: right, host: host, resolver: { $0 }))
        let token = host.world.subscribe(to: ManipulationEvents.Cancelled.self) { event in
            if event.entity === art { art.components[VisibilityComponent.self]?.isVisible = true }
        }
        defer { token.cancel() }
        #expect(input.admitContact(1, at: right))
        #expect(input.begin(.pan, contacts: [1]))
        art.components[VisibilityComponent.self]?.isVisible = false
        #expect(art.components[VisibilityComponent.self]?.isVisible == true)
        #expect(input.session == nil)
        #expect(value.convertIfAvailable(right, to: .scene) == nil)
        #expect(capture.resolve(2, start: right, host: host, resolver: { $0 }) == nil)
        host.beginInput(at: right)
        #expect(TargetedInputCapture<Int>().resolve(3, start: right, host: host, resolver: { $0 })?.entity === art)
    }

    @Test func earlierVisibilitySubscriberCannotReviveContactsAfterReentrantShow() throws {
        let (host, _, art, _, _) = fixture()
        let token = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
            if event.entity === art, art.components[VisibilityComponent.self]?.isVisible == false {
                art.components[VisibilityComponent.self]?.isVisible = true
            }
        }
        defer { token.cancel() }
        host.beginInput(at: right)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: right, host: host, resolver: { $0 }))
        var checkedDuringShow = false
        var convertedDuringShow = false
        let later = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
            if event.entity === art, art.components[VisibilityComponent.self]?.isVisible == true {
                checkedDuringShow = true
                convertedDuringShow = convertedDuringShow || value.convertIfAvailable(right, to: .scene) != nil
            }
        }
        defer { later.cancel() }
        art.components[VisibilityComponent.self]?.isVisible = false
        #expect(art.components[VisibilityComponent.self]?.isVisible == true)
        #expect(checkedDuringShow && !convertedDuringShow)
        #expect(value.convertIfAvailable(right, to: .scene) == nil)
        #expect(capture.resolve(2, start: right, host: host, resolver: { $0 }) == nil)
    }

    @Test func continuouslyVisibleCameraPolicyChangesKeepGestureAndManipulationCaptures() throws {
        let (host, _, art, _, camera) = fixture()
        host.beginInput(at: right)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: right, host: host, resolver: { $0 }))
        let input = GameManipulationInput(host: host)
        #expect(input.admitContact(1, at: right))
        #expect(input.begin(.pan, contacts: [1]))
        camera.components[CameraComponent.self]?.cullingMask = [.default, map]
        camera.components[CameraComponent.self]?.cullingMask = map
        #expect(value.convertIfAvailable(right, to: .scene) != nil)
        #expect(capture.resolve(2, start: right, host: host, resolver: { $0 })?.entity === art)
        #expect(input.session?.isActive == true)
        #expect(input.change(.pan, translation: CGPoint(x: 5, y: 0)))
        input.cancel()
    }

    @Test func reentrantCameraMaskRestorationCancelsOnlyTheHiddenPane() throws {
        let (host, _, _, _, camera) = fixture()
        let token = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
            if event.entity === camera, camera.components[CameraComponent.self]?.cullingMask == RenderLayer.none {
                camera.components[CameraComponent.self]?.cullingMask = map
            }
        }
        defer { token.cancel() }
        host.beginInput(at: left); host.beginInput(at: right)
        let a = TargetedInputCapture<Int>(), b = TargetedInputCapture<Int>()
        let world = try #require(a.resolve(1, start: left, host: host, resolver: { $0 }))
        let overview = try #require(b.resolve(1, start: right, host: host, resolver: { $0 }))
        camera.components[CameraComponent.self]?.cullingMask = .none
        #expect(world.convertIfAvailable(left, to: .scene) != nil)
        #expect(overview.convertIfAvailable(right, to: .scene) == nil)
        #expect(a.resolve(2, start: left, host: host, resolver: { $0 }) != nil)
        #expect(b.resolve(2, start: right, host: host, resolver: { $0 }) == nil)
    }

    @Test func reentrantContinuouslyVisibleCameraChangesDoNotCancelGestureCapture() throws {
        let (host, _, _, _, camera) = fixture()
        let token = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
            if event.entity === camera, camera.components[CameraComponent.self]?.cullingMask == RenderLayer.all {
                camera.components[CameraComponent.self]?.cullingMask = map
            }
        }
        defer { token.cancel() }
        host.beginInput(at: right)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: right, host: host, resolver: { $0 }))
        camera.components[CameraComponent.self]?.cullingMask = .all
        #expect(value.convertIfAvailable(right, to: .scene) != nil)
        #expect(capture.resolve(2, start: right, host: host, resolver: { $0 }) != nil)
    }
}

import ECSCore
@testable import GameUI
import SpriteBackend
import SwiftUI
import Testing

@MainActor @Suite struct ViewportInputTests {
    private let left = CGPoint(x: 50, y: 100)
    private let right = CGPoint(x: 150, y: 100)

    private func fixture(sharedTarget: Bool = false) -> (GameHost, Entity, Entity, Entity, Entity) {
        let host = GameHost()
        host.renderer.size = CGSize(width: 200, height: 200)
        let a = Entity(components: CameraComponent()), b = Entity(components: CameraComponent())
        a.position = sharedTarget ? .zero : [-200, 0]
        b.position = sharedTarget ? .zero : [200, 0]
        host.world.addEntity(a); host.world.addEntity(b)
        let first = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent(), ManipulationComponent())
        let second = Entity(components: SpriteComponent(color: .blue, size: [40, 40]), InputTargetComponent(), ManipulationComponent())
        first.position = a.position; second.position = b.position
        host.world.addEntity(first)
        if !sharedTarget { host.world.addEntity(second) }
        host.renderer.viewports = [
            GameViewport(id: "left", camera: a.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            GameViewport(id: "right", camera: b.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        host.renderer.flush()
        return (host, first, second, a, b)
    }

    @Test func legacyContactsAndValuesKeepNilViewportAndOriginalConstructors() throws {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        let entity = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent())
        host.world.addEntity(entity)
        let point = CGPoint(x: 100, y: 100)
        host.beginInput(at: point)
        #expect(host.contact(startingAt: point)?.viewportID == nil)
        #expect(InputContact(id: 99, start: point, hit: entity).viewportID == nil)
        let value = try #require(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 }))
        #expect(value.entity === entity && value.viewportID == nil)
        #expect(value.convertIfAvailable(point, to: .scene) == .zero)
        #expect(EntityTargetValue(entity: entity, gestureValue: 1, host: host).viewportID == nil)
    }

    @Test func pointersInDifferentPanesCaptureIndependentTargetsAndCameraIDs() throws {
        let (host, a, b, firstCamera, secondCamera) = fixture()
        host.beginInput(at: left); host.beginInput(at: right)
        let first = try #require(TargetedInputCapture<Int>().resolve(1, start: left, host: host, resolver: { $0 }))
        let second = try #require(TargetedInputCapture<Int>().resolve(1, start: right, host: host, resolver: { $0 }))
        #expect(first.entity === a && first.viewportID == "left")
        #expect(second.entity === b && second.viewportID == "right")
        #expect(first.viewportLatch?.cameraID == firstCamera.id)
        #expect(second.viewportLatch?.cameraID == secondCamera.id)
    }

    @Test func explicitlyConfiguredEmptyListCapturesMainAndCancelsRetainedConversions() throws {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        host.configureViewports([])
        let entity = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent())
        host.world.addEntity(entity)
        let point = CGPoint(x: 100, y: 100)
        host.beginInput(at: point)
        let value = try #require(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 }))
        #expect(value.viewportID == "main" && value.convertIfAvailable(point, to: .scene) == .zero)
        host.cancelInputs()
        #expect(value.convertIfAvailable(point, to: .scene) == nil)
    }

    @Test func nearbyContactsAcrossTheSplitAreMatchedOnlyWithinTheirStartingPane() throws {
        let (host, entity, _, _, _) = fixture(sharedTarget: true)
        entity.components[SpriteComponent.self]?.size = [200, 200]
        host.renderer.flush()
        let a = CGPoint(x: 95, y: 100), b = CGPoint(x: 105, y: 100)
        host.beginInput(at: a); host.beginInput(at: b)
        #expect(try #require(TargetedInputCapture<Int>().resolve(1, start: a, host: host, resolver: { $0 })).viewportID == "left")
        #expect(try #require(TargetedInputCapture<Int>().resolve(1, start: b, host: host, resolver: { $0 })).viewportID == "right")
        #expect(TargetedInputCapture<Int>().resolve(1, start: nil, host: host, resolver: { $0 }) == nil)
    }

    @Test func guttersAndNoninteractiveFrontPanesCannotClickThrough() {
        let (host, _, _, camera, _) = fixture(sharedTarget: true)
        host.renderer.viewports = [GameViewport(id: "back", camera: camera.id),
            GameViewport(id: "map", camera: camera.id, frame: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5), isInteractive: false)]
        let center = CGPoint(x: 100, y: 100)
        host.beginInput(at: center)
        #expect(host.contact(startingAt: nil)?.hit == nil)
        #expect(TargetedInputCapture<Int>().resolve(1, start: center, host: host, resolver: { $0 }) == nil)
        let input = GameManipulationInput(host: host)
        #expect(!input.admitContact(1, at: center))
        host.cancelInputs()
        host.renderer.viewports = [
            GameViewport(id: "left", frame: .init(x: 0, y: 0, width: 0.4, height: 1)),
            GameViewport(id: "right", frame: .init(x: 0.6, y: 0, width: 0.4, height: 1))]
        host.beginInput(at: center)
        #expect(host.contact(startingAt: nil)?.hit == nil)
        #expect(!input.admitContact(2, at: center))
    }

    @Test func crossingTheSplitUsesTheLatchedCameraAndGestureOffset() throws {
        let (host, entity, _, _, _) = fixture()
        host.beginInput(at: left)
        let capture = TargetedInputCapture<Int>()
        var value = try #require(capture.resolve(1, start: left, host: host, resolver: { $0 }))
        value.viewOffset = CGPoint(x: 20, y: 30)
        let crossing = CGPoint(x: 170, y: 130)
        #expect(value.convertIfAvailable(crossing, to: .scene) == [-100, 0])
        #expect(value.convertIfAvailable(crossing, to: entity) == [100, 0])
        #expect(host.renderer.scenePoint(fromView: right) == [200, 0])
        #expect(capture.resolve(2, start: left, host: host, resolver: { $0 })?.entity === entity)
    }

    @Test func conversionsFollowMotionAndZoomOfTheSameCamera() throws {
        let (host, _, _, camera, _) = fixture()
        host.beginInput(at: left)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: left, host: host, resolver: { $0 }))
        camera.position = [-180, 20]; camera.components[CameraComponent.self]?.zoom = 2
        host.renderer.flush()
        #expect(value.convertIfAvailable(right, to: .scene) == [-130, 20])
        #expect(capture.resolve(2, start: left, host: host, resolver: { $0 })?.viewportID == "left")
    }

    @Test func removedOrInactiveCamerasInvalidateExistingCaptures() throws {
        for remove in [false, true] {
            let (host, _, _, camera, _) = fixture()
            host.beginInput(at: left)
            let capture = TargetedInputCapture<Int>()
            let value = try #require(capture.resolve(1, start: left, host: host, resolver: { $0 }))
            if remove { camera.removeFromParent() } else { camera.isEnabled = false }
            #expect(value.convertIfAvailable(left, to: .scene) == nil)
            #expect(capture.resolve(2, start: left, host: host, resolver: { $0 }) == nil)
            if remove { host.world.addEntity(camera) } else { camera.isEnabled = true }
            host.renderer.flush()
            #expect(capture.resolve(3, start: left, host: host, resolver: { $0 }) == nil)
        }
    }

    @Test func switchingAutomaticCameraCancelsInsteadOfJumpingToAnotherCamera() throws {
        let (host, _, _, camera, replacement) = fixture()
        host.renderer.viewports[0].camera = nil
        host.world.activeCamera = camera
        host.beginInput(at: left)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: left, host: host, resolver: { $0 }))
        host.world.activeCamera = replacement
        #expect(value.convertIfAvailable(left, to: .scene) == nil)
        #expect(capture.resolve(2, start: left, host: host, resolver: { $0 }) == nil)
        host.world.activeCamera = camera
        #expect(capture.resolve(3, start: left, host: host, resolver: { $0 }) == nil)
    }

    @Test func changedPaneDescriptorsAndHostCancellationInvalidateRetainedValues() throws {
        let (host, _, _, _, _) = fixture()
        host.beginInput(at: left)
        let capture = TargetedInputCapture<Int>()
        let value = try #require(capture.resolve(1, start: left, host: host, resolver: { $0 }))
        host.renderer.viewports[0].frame = .full
        #expect(capture.resolve(2, start: left, host: host, resolver: { $0 }) == nil)
        #expect(value.convertIfAvailable(left, to: .scene) == nil)
        host.cancelInputs()
        #expect(host.inputContacts.isEmpty)
    }

    @Test func equalEntityAndGestureValuesInDifferentPanesHaveDifferentIdentity() {
        let (host, entity, _, _, _) = fixture(sharedTarget: true)
        let first = EntityTargetValue(entity: entity, gestureValue: 1, host: host, viewportID: "left")
        let second = EntityTargetValue(entity: entity, gestureValue: 1, host: host, viewportID: "right")
        #expect(first != second)
    }

    @Test func manipulationContactsCannotShareAnEntityAcrossPanesEvenBetweenChannels() {
        let (host, _, _, _, _) = fixture(sharedTarget: true)
        let input = GameManipulationInput(host: host)
        #expect(input.admitContact(1, at: left))
        #expect(!input.admitContact(2, at: right))
        #expect(!input.begin(.scale, contacts: [1, 2]))
        #expect(input.begin(.pan, contacts: [1]))
        input.releaseContact(1)
        #expect(!input.admitContact(3, at: right))
        input.cancel()
        #expect(input.admitContact(4, at: right))
        #expect(input.begin(.pan, contacts: [4]))
        input.cancel()
    }

    @Test func manipulationCrossesTheSplitAndReprojectsThroughItsOriginalMovingCamera() {
        let (host, entity, _, camera, _) = fixture()
        let input = GameManipulationInput(host: host)
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        #expect(input.change(.pan, translation: CGPoint(x: 100, y: 0)))
        #expect(entity.position == [-100, 0])
        camera.position = [-180, 20]; camera.components[CameraComponent.self]?.zoom = 2
        host.renderer.flush()
        input.refreshCapture()
        #expect(entity.position == [-130, 20])
        input.cancel()
    }

    @Test func automaticCameraSwitchAndCameraRemovalCancelManipulation() {
        for remove in [false, true] {
            let (host, _, _, camera, replacement) = fixture()
            host.renderer.viewports[0].camera = remove ? camera.id : nil
            host.world.activeCamera = camera
            let input = GameManipulationInput(host: host)
            #expect(input.admitContact(1, at: left))
            #expect(input.begin(.pan, contacts: [1]))
            if remove { camera.removeFromParent() } else { host.world.activeCamera = replacement }
            #expect(!input.refreshCapture())
            #expect(input.session == nil && input.activeChannels.isEmpty)
        }
    }
}

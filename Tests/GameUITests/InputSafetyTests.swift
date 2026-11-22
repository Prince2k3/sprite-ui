import ECSCore
@testable import GameUI
import SpriteBackend
import SwiftUI
import Testing

@MainActor @Suite struct InputSafetyTests {
    func host() -> (GameHost, Entity, Entity) {
        let host = GameHost()
        host.renderer.size = CGSize(width: 200, height: 200)
        let a = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent())
        let b = Entity(components: SpriteComponent(color: .blue, size: [40, 40]), InputTargetComponent())
        a.position = [-50, 0]; b.position = [50, 0]
        host.world.addEntity(a); host.world.addEntity(b)
        return (host, a, b)
    }

    @Test func completedGestureCannotRecaptureAnEndedContact() {
        let (host, a, _) = host()
        let point = CGPoint(x: 50, y: 100)
        let id = host.beginInput(at: point)
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: point, host: host, resolver: { $0 })?.entity === a)
        host.endInput(id); capture.end()
        #expect(capture.resolve(1, start: point, host: host, resolver: { $0 }) == nil)
        host.beginInput(at: point)
        #expect(capture.resolve(2, start: point, host: host, resolver: { $0 })?.entity === a)
    }

    @Test func releaseKeepsItsOriginalTargetWhenAnotherFingerIsNearby() {
        let (host, a, b) = host()
        a.position = [-70, 0]; b.position = [-49, 0]
        a.components[SpriteComponent.self]?.size = [18, 18]
        b.components[SpriteComponent.self]?.size = [18, 18]
        host.renderer.flush()
        let start = CGPoint(x: 30, y: 100)
        let first = host.beginInput(at: start)
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: start, host: host, resolver: { $0 })?.entity === a)
        host.beginInput(at: CGPoint(x: 51, y: 100))
        host.endInput(first)
        #expect(capture.resolve(2, start: start, host: host, resolver: { $0 })?.entity === a)
    }

    @Test func rapidReleasedTapsDoNotBlockEachOther() {
        let (host, a, _) = host()
        let start = CGPoint(x: 50, y: 100)
        let capture = TargetedInputCapture<Int>()
        for index in 0..<10 {
            let input = host.beginInput(at: start)
            host.endInput(input) // UIKit can record release before SwiftUI's tap.
            #expect(capture.resolve(index, start: start, host: host, resolver: { $0 })?.entity === a)
            capture.end()
        }
    }

    @Test func twoFingersKeepIndependentTargets() {
        let (host, a, b) = host()
        let first = host.beginInput(at: CGPoint(x: 50, y: 100))
        let second = host.beginInput(at: CGPoint(x: 150, y: 100))
        let left = TargetedInputCapture<Int>(), right = TargetedInputCapture<Int>()
        #expect(left.resolve(1, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 })?.entity === a)
        #expect(right.resolve(1, start: CGPoint(x: 150, y: 100), host: host, resolver: { $0 })?.entity === b)
        host.endInput(second)
        #expect(left.resolve(2, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 })?.entity === a)
        host.endInput(first)
    }

    @Test func separateViewsCannotCaptureEachOthersTouches() {
        let (first, a, _) = host(); let (second, b, _) = host()
        first.beginInput(at: CGPoint(x: 50, y: 100))
        second.beginInput(at: CGPoint(x: 50, y: 100))
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: CGPoint(x: 50, y: 100), host: first, resolver: { $0 })?.entity === a)
        #expect(capture.resolve(2, start: CGPoint(x: 50, y: 100), host: second, resolver: { $0 }) == nil)
        #expect(a !== b)
    }

    @Test func ambiguousContactsAreNotArbitrarilyAssigned() {
        let (host, _, _) = host()
        host.beginInput(at: CGPoint(x: 50, y: 100)); host.beginInput(at: CGPoint(x: 150, y: 100))
        #expect(TargetedInputCapture<Int>().resolve(1, start: nil, host: host, resolver: { $0 }) == nil)
    }

    @Test func removalAndDisabledInputCancelAnExistingCapture() {
        let (host, a, _) = host()
        host.beginInput(at: CGPoint(x: 50, y: 100))
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 }) != nil)
        a.components[InputTargetComponent.self]?.isEnabled = false
        #expect(capture.resolve(2, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 }) == nil)
        a.removeFromParent()
        #expect(capture.resolve(3, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 }) == nil)
    }

    @Test func cancellationDoesNotPoisonTheNextGesture() {
        let (host, a, _) = host()
        let id = host.beginInput(at: CGPoint(x: 50, y: 100))
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 })?.entity === a)
        host.endInput(id, cancelled: true)
        #expect(capture.resolve(2, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 }) == nil)
        host.beginInput(at: CGPoint(x: 50, y: 100))
        #expect(capture.resolve(3, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 })?.entity === a)
        host.cancelInputs()
        #expect(capture.resolve(4, start: CGPoint(x: 50, y: 100), host: host, resolver: { $0 }) == nil)
    }

    @Test func aMissDoesNotSwitchToAnEntityThatMovesUnderThePointer() {
        let (host, a, _) = host()
        host.beginInput(at: CGPoint(x: 100, y: 100))
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: CGPoint(x: 100, y: 100), host: host, resolver: { $0 }) == nil)
        a.position = .zero; host.renderer.flush()
        #expect(capture.resolve(2, start: CGPoint(x: 100, y: 100), host: host, resolver: { $0 }) == nil)
    }

    @Test func conversionsUseTheDisplayedCameraAndGestureViewOffset() throws {
        let (host, a, _) = host()
        let camera = Entity(components: CameraComponent(zoom: 2)); camera.position = [300, 100]
        host.world.addEntity(camera)
        var value = EntityTargetValue(entity: a, gestureValue: 1, host: host)
        value.viewOffset = CGPoint(x: 20, y: 30)
        #expect(value.convertIfAvailable(CGPoint(x: 120, y: 130), to: .scene) == [300, 100])
        let point = try #require(value.convertIfAvailable(CGPoint(x: 120, y: 130), to: a))
        #expect(abs(point.x - 350) < 0.001 && abs(point.y - 100) < 0.001)
        a.removeFromParent()
        #expect(value.convertIfAvailable(CGPoint(x: 120, y: 130), to: a) == nil)
    }
}

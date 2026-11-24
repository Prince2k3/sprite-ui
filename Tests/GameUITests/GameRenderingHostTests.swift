@_spi(Backend) import ECSCore
@_spi(Backend) @testable import SpriteBackend
@testable import GameUI
import Foundation
import MetalKit
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif

@MainActor @Suite struct GameRenderingHostTests {
    /// Change each input independently, then replace and remove them together.
    private func configurations() -> [(configuration: GameRenderConfiguration?,
                                      monitor: GameRenderMonitor?, source: GamePresentationSource?)] {
        let full = GameRenderConfiguration()
        let reduced = GameRenderConfiguration(resolutionScale: 0.5, preferredFramesPerSecond: 30,
                                              maximumRenderPixels: 1_048_576)
        let firstMonitor = GameRenderMonitor(), secondMonitor = GameRenderMonitor()
        let firstSource = GamePresentationSource(), secondSource = GamePresentationSource(viewportID: "main")
        return [
            (full, nil, nil), (reduced, nil, nil),
            (reduced, firstMonitor, nil), (reduced, secondMonitor, nil),
            (reduced, secondMonitor, firstSource), (reduced, secondMonitor, secondSource),
            (full, firstMonitor, firstSource), (nil, nil, nil)
        ]
    }

    @Test func renderingChangesPreserveWorldRendererEntitiesAndNodesWithoutSimulation() throws {
        let host = GameHost(), world = host.world, renderer = host.renderer
        let player = Entity(name: "player", components: SpriteComponent(color: .cyan, size: [20, 20]))
        let camera = Entity(components: CameraComponent(target: .entity(player.id), smoothing: 0))
        player.position = [45, 30]
        world.addEntity(player); world.addEntity(camera); renderer.flush()
        let node = try #require(renderer.node(for: player))
        let cameraNode = try #require(renderer.node(for: camera))
        var updates = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { token.cancel(); host.releasePresentationSource() }

        for change in configurations() {
            host.configureRendering(change.configuration, monitor: change.monitor, presentation: change.source)
            #expect(host.world === world)
            #expect(host.renderer === renderer && world.observer === renderer)
            #expect(world.entity(withID: player.id) === player && player.world === world)
            #expect(world.entity(withID: camera.id) === camera && camera.world === world)
            #expect(renderer.node(for: player) === node)
            #expect(renderer.node(for: camera) === cameraNode)
            #expect(player.position == [45, 30])
            #expect(host.renderConfiguration == change.configuration)
            #expect(host.renderMonitor === change.monitor)
            #expect(host.requestedPresentationSource === change.source)
            #expect(host.activePresentationSource === change.source)
            #expect(updates == 0)
        }
    }

    @Test func renderingChangesDoNotCancelLivePointerCaptureOrHingeInput() throws {
        let host = GameHost()
        host.updateSurfaceGeometry(.init(size: CGSize(width: 200, height: 200)))
        let target = Entity(components: SpriteComponent(color: .cyan, size: [40, 40]), InputTargetComponent())
        host.world.addEntity(target); host.renderer.flush()
        let pointer = InputAction("pointer"), fold = InputAction("fold", kind: .axis)
        let input = InputController(contexts: [.init(name: "play", bindings: [
            .init(pointer, control: .pointerButton(0)), .init(fold, control: .hinge)
        ])])
        let session = GameInputSession()
        session.configure(input, hub: nil)
        session.hinge.configure(.init(smoothing: 0))
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        session.bind([.init(id: host.inputHostID, host: host)])
        defer { session.stop(); host.releasePresentationSource() }
        let neutral = GameHingeState(angle: .pi, status: .fullyOpen)
        let held = GameHingeState(angle: .pi / 2, status: .partiallyOpen)
        host.updateHingeState(neutral); host.updateHingeState(held)
        session.router.pointer(0, pressed: true)
        let point = CGPoint(x: 100, y: 100)
        let id = host.beginInput(at: point)
        let contact = try #require(host.inputContacts[id])
        let capture = TargetedInputCapture<Int>()
        try #require(capture.resolve(0, start: point, host: host, resolver: { $0 })?.entity === target)
        try #require(input.value(for: pointer).isPressed)
        try #require(input.value(for: fold) == .axis(1))
        var cancellations = 0
        let token = input.observe { event in
            if event.phase == .cancelled { cancellations += 1 }
        }
        defer { token.cancel() }

        for (index, change) in configurations().enumerated() {
            host.configureRendering(change.configuration, monitor: change.monitor, presentation: change.source)
            session.refresh()
            #expect(host.actionInput === input)
            #expect(host.inputContacts[id] === contact && !contact.cancelled)
            #expect(contact.endedAt == nil && contact.hit === target)
            #expect(capture.resolve(index + 1, start: point, host: host, resolver: { $0 })?.entity === target)
            #expect(input.value(for: pointer).isPressed)
            #expect(input.value(for: fold) == .axis(1))
            #expect(host.hingeStore.hasCurrentSample && host.content.hingeState == held)
            #expect(session.router.isActive && cancellations == 0)
        }

        session.router.pointer(0, pressed: false)
        host.endInput(id)
        host.updateHingeState(neutral)
        #expect(input.state(for: pointer).phase == .released)
        #expect(input.value(for: fold) == .axis(0))
        #expect(cancellations == 0)
        // A fresh physical press must still work without a cancellation/rearm gate.
        session.router.pointer(0, pressed: true)
        host.updateHingeState(held)
        #expect(input.value(for: pointer).isPressed && input.value(for: fold) == .axis(1))
    }

    @Test func competingHostCannotStealSuspendOrReleaseSourceAndCanRetryAfterRelease() {
        let owner = GameHost(), contender = GameHost(), source = GamePresentationSource()
        owner.configureRendering(nil, monitor: nil, presentation: source)
        var invalidations = 0
        let token = source.observeFrames { invalidations += 1 }
        defer {
            source.removeFrameObserver(token)
            owner.releasePresentationSource(); contender.releasePresentationSource()
        }

        for _ in 0..<2 {
            contender.configureRendering(nil, monitor: nil, presentation: source)
            #expect(contender.requestedPresentationSource === source)
            #expect(contender.activePresentationSource == nil)
            #expect(owner.activePresentationSource === source)
            contender.suspendPresentationSource()
            contender.releasePresentationSource()
            #expect(invalidations == 0)
            #expect(!source.attach(owner: contender.presentationOwner))
        }

        owner.releasePresentationSource()
        #expect(invalidations == 1 && owner.activePresentationSource == nil)
        // The request is unchanged; configureRendering must retry ownership anyway.
        contender.configureRendering(nil, monitor: nil, presentation: source)
        #expect(contender.activePresentationSource === source)
        #expect(source.attach(owner: contender.presentationOwner))
        #expect(!source.attach(owner: owner.presentationOwner))
        owner.releasePresentationSource()
        #expect(invalidations == 1)
    }

    @Test func sourceReplacementDetachesOldPublisherAndNilDetachesReplacement() {
        let host = GameHost(), first = GamePresentationSource(), second = GamePresentationSource()
        host.configureRendering(nil, monitor: nil, presentation: first)
        var firstInvalidations = 0, secondInvalidations = 0
        let firstToken = first.observeFrames { firstInvalidations += 1 }
        let secondToken = second.observeFrames { secondInvalidations += 1 }
        let probe = UUID()
        defer {
            first.removeFrameObserver(firstToken); second.removeFrameObserver(secondToken)
            first.detach(owner: probe); second.detach(owner: probe)
            host.releasePresentationSource()
        }

        host.configureRendering(nil, monitor: nil, presentation: second)
        #expect(firstInvalidations == 1 && secondInvalidations == 0)
        #expect(host.requestedPresentationSource === second && host.activePresentationSource === second)
        #expect(first.attach(owner: probe))
        #expect(!second.attach(owner: probe))
        host.configureRendering(nil, monitor: nil, presentation: second)
        #expect(firstInvalidations == 1 && secondInvalidations == 0)

        host.configureRendering(nil, monitor: nil, presentation: nil)
        #expect(host.requestedPresentationSource == nil && host.activePresentationSource == nil)
        #expect(firstInvalidations == 1 && secondInvalidations == 1)
        #expect(second.attach(owner: probe))
    }

    @Test func suspensionRetainsOwnershipWhileReleasePermitsSameRequestToReattach() {
        let host = GameHost(), source = GamePresentationSource()
        host.configureRendering(nil, monitor: nil, presentation: source)
        var invalidations = 0
        let token = source.observeFrames { invalidations += 1 }
        defer { source.removeFrameObserver(token); host.releasePresentationSource() }

        host.suspendPresentationSource()
        #expect(invalidations == 1)
        #expect(host.activePresentationSource === source && host.requestedPresentationSource === source)
        #expect(!source.isAvailable && source.pixelSize == .zero && source.frameNumber == 0)
        #expect(!source.attach(owner: UUID()))
        host.activatePresentationSource()
        host.configureRendering(nil, monitor: nil, presentation: source)
        #expect(host.activePresentationSource === source && invalidations == 1)

        host.releasePresentationSource()
        #expect(host.activePresentationSource == nil && host.requestedPresentationSource === source)
        #expect(invalidations == 2)
        host.releasePresentationSource()
        #expect(invalidations == 2)
        host.configureRendering(nil, monitor: nil, presentation: source)
        #expect(host.activePresentationSource === source)
        #expect(source.attach(owner: host.presentationOwner))
        #expect(!source.attach(owner: UUID()))
        #expect(invalidations == 2)
    }

    @Test(arguments: [false, true])
    func reentrantInvalidationConfigurationWinsOverSourceReplacementOrRemoval(removing: Bool) {
        let host = GameHost(), original = GamePresentationSource()
        let superseded = GamePresentationSource(), newest = GamePresentationSource(viewportID: "main")
        let oldMonitor = GameRenderMonitor(), newestMonitor = GameRenderMonitor()
        let oldConfiguration = GameRenderConfiguration()
        let newestConfiguration = GameRenderConfiguration(resolutionScale: 0.25, preferredFramesPerSecond: 120)
        host.configureRendering(oldConfiguration, monitor: oldMonitor, presentation: original)
        var invalidations = 0
        let token = original.observeFrames {
            invalidations += 1
            host.configureRendering(newestConfiguration, monitor: newestMonitor, presentation: newest)
        }
        let probe = UUID()
        defer {
            original.removeFrameObserver(token)
            original.detach(owner: probe); superseded.detach(owner: probe)
            host.releasePresentationSource()
        }

        host.configureRendering(.init(resolutionScale: 0.5), monitor: nil,
                                presentation: removing ? nil : superseded)
        #expect(invalidations == 1)
        #expect(host.renderConfiguration == newestConfiguration)
        #expect(host.renderMonitor === newestMonitor)
        #expect(host.requestedPresentationSource === newest && host.activePresentationSource === newest)
        #expect(original.attach(owner: probe))
        #expect(superseded.attach(owner: probe))
        #expect(!newest.attach(owner: probe))
        // Repeating the winning request is idempotent and does not revive the stale source.
        host.configureRendering(newestConfiguration, monitor: newestMonitor, presentation: newest)
        #expect(host.activePresentationSource === newest && invalidations == 1)
    }

    @Test(arguments: [false, true])
    func reentrantInvalidationCanReplaceSourceDuringSuspendOrRelease(releasing: Bool) {
        let host = GameHost(), original = GamePresentationSource(), newest = GamePresentationSource()
        host.configureRendering(nil, monitor: nil, presentation: original)
        var invalidations = 0
        let token = original.observeFrames {
            invalidations += 1
            // Suspending keeps ownership, so replacing it also detaches it.
            // Only the first notification initiates the reentrant configuration.
            if invalidations == 1 { host.configureRendering(nil, monitor: nil, presentation: newest) }
        }
        defer { original.removeFrameObserver(token); host.releasePresentationSource() }

        if releasing { host.releasePresentationSource() }
        else { host.suspendPresentationSource() }
        #expect(invalidations == (releasing ? 1 : 2))
        #expect(host.requestedPresentationSource === newest && host.activePresentationSource === newest)
        #expect(!newest.attach(owner: UUID()))
    }

    @Test(arguments: [0, 1, 2])
    func advancedRenderingRemainsEnabledAfterLastOptInIsRemoved(optIn: Int) {
        let host = GameHost()
        #expect(!host.hasAdvancedRendering && !host.requiresViewportRendering)
        switch optIn {
        case 0: host.configureRendering(.init(), monitor: nil, presentation: nil)
        case 1: host.configureRendering(nil, monitor: GameRenderMonitor(), presentation: nil)
        default: host.configureRendering(nil, monitor: nil, presentation: GamePresentationSource())
        }
        #expect(host.hasAdvancedRendering && host.requiresViewportRendering)
        host.configureRendering(nil, monitor: nil, presentation: nil)
        #expect(host.renderConfiguration == nil && host.renderMonitor == nil)
        #expect(host.requestedPresentationSource == nil && host.activePresentationSource == nil)
        #expect(host.configuredViewports == nil)
        #expect(host.hasAdvancedRendering && host.requiresViewportRendering)
    }

    #if os(macOS)
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"),
          arguments: [0, 1, 2])
    func removingViewportsWithFirstAdvancedOptInPreservesNativeDriverAndClock(optIn: Int) throws {
        _ = NSApplication.shared
        let host = GameHost(), renderer = host.renderer
        host.configureViewports([.init(id: "main")])
        let view = GameSKView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        view.host = host; host.nativeView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.stopTrackingInput(); window.contentView = nil }
        view.configurePresentation()
        let canvas = try #require(view.subviews.compactMap { $0 as? MTKView }.first)
        let driver = try #require(view.viewportRendering)
        try #require(canvas.delegate === driver)
        try #require(view.window === window && !canvas.isPaused)
        try #require(view.scene == nil && !host.hasAdvancedRendering)
        try #require(host.requiresViewportRendering)

        renderer.update(100); renderer.didFinishUpdate()
        renderer.update(100 + 1.0 / 60); renderer.didFinishUpdate()
        let clock = try #require(renderer.presentationClockTime)
        var deltas: [TimeInterval] = []
        let token = host.world.subscribe(to: WorldEvents.Update.self) { deltas.append($0.deltaTime) }
        defer { token.cancel() }

        // A representable update must apply rendering before removing its old
        // viewport list. Reversing these two calls briefly presents the legacy
        // scene, destroys the Metal driver, and resets the existing clock.
        switch optIn {
        case 0: host.configureRendering(.init(resolutionScale: 0.5), monitor: nil, presentation: nil)
        case 1: host.configureRendering(nil, monitor: GameRenderMonitor(), presentation: nil)
        default: host.configureRendering(nil, monitor: nil, presentation: GamePresentationSource())
        }
        #expect(view.scene == nil && canvas.delegate === driver)
        #expect(renderer.presentationClockTime == clock)
        host.configureViewports(nil)

        #expect(host.nativeView === view && host.renderer === renderer)
        #expect(host.configuredViewports == nil && renderer.viewports.isEmpty)
        #expect(host.hasAdvancedRendering && host.requiresViewportRendering)
        #expect(view.scene == nil)
        #expect(view.subviews.compactMap { $0 as? MTKView }.count == 1)
        #expect(view.subviews.contains { $0 === canvas })
        #expect(view.viewportRendering === driver)
        #expect(canvas.delegate === driver && !canvas.isPaused)
        #expect(renderer.presentationClockTime == clock && deltas.isEmpty)

        // Removing the last advanced option must retain this same driver too.
        host.configureRendering(nil, monitor: nil, presentation: nil)
        #expect(view.scene == nil && canvas.delegate === driver)
        #expect(view.subviews.contains { $0 === canvas })
        #expect(renderer.presentationClockTime == clock && deltas.isEmpty)
        renderer.update(clock + 1.0 / 60); renderer.didFinishUpdate()
        #expect(deltas.count == 1)
        #expect(abs((deltas.first ?? 0) - 1.0 / 60) < 0.000_001)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"),
          // macOS SKView ignores its own alphaValue setter (it remains 1).
          // A transparent NSView ancestor is the supported fade fixture.
          arguments: [0, 1, 3])
    func nativeHiddenOrTransparentSurfaceClearsSourceAndResumesSameDriver(visibilityChange: Int) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let host = GameHost(), source = GamePresentationSource()
        host.configureRendering(.init(), monitor: nil, presentation: source)

        // Publish before mounting the native view so its automatic display loop
        // cannot race this known completed-frame fixture.
        let lease = try #require(source.beginFrame(owner: host.presentationOwner, device: device, width: 8, height: 4))
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = lease.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 1, 1)
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding()
        lease.complete(commandBuffer: command, frameNumber: 42)
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed)
        let deadline = ContinuousClock.now + .seconds(5)
        while !lease.isFinished && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(lease.isFinished && source.isAvailable && source.frameNumber == 42)

        _ = NSApplication.shared
        let ancestor = NSView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        let view = GameSKView(frame: ancestor.bounds)
        view.host = host; host.nativeView = view
        ancestor.addSubview(view)
        let window = NSWindow(contentRect: ancestor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = ancestor
        defer { view.stopTrackingInput(); window.contentView = nil }
        view.configurePresentation()
        let driver = try #require(view.viewportRendering)
        let canvas = try #require(view.subviews.compactMap { $0 as? MTKView }.first)
        try #require(view.window === window && view.isNativeSurfaceVisible)
        try #require(canvas.delegate === driver && !canvas.isPaused)
        try #require(source.isAvailable && source.pixelSize == CGSize(width: 8, height: 4))

        host.renderer.update(100); host.renderer.didFinishUpdate()
        try #require(host.renderer.presentationClockTime == 100)
        var deltas: [TimeInterval] = []
        let updateToken = host.world.subscribe(to: WorldEvents.Update.self) { deltas.append($0.deltaTime) }
        var invalidations = 0
        let frameToken = source.observeFrames { invalidations += 1 }
        defer { updateToken.cancel(); source.removeFrameObserver(frameToken) }

        switch visibilityChange {
        case 0: view.isHidden = true
        case 1: ancestor.isHidden = true
        case 2: view.alphaValue = 0
        default: ancestor.alphaValue = 0
        }
        view.updateViewportActivity()
        #expect(!view.isNativeSurfaceVisible && !view.isLevelPresentationAvailable)
        #expect(!source.isAvailable && source.pixelSize == .zero && source.frameNumber == 0)
        #expect(source.acquireFrame() == nil && invalidations == 1)
        #expect(host.renderer.presentationClockTime == nil && deltas.isEmpty)
        #expect(host.activePresentationSource === source && host.requestedPresentationSource === source)
        #expect(!source.attach(owner: UUID()))
        #expect(view.viewportRendering === driver && canvas.delegate === driver)
        #expect(view.scene == nil && !canvas.isPaused, "Keep the visibility callback loop alive for ancestor restoration")

        // Rechecking an unchanged hidden ancestor must not repeatedly invalidate.
        view.updateViewportActivity()
        #expect(invalidations == 1 && deltas.isEmpty)
        switch visibilityChange {
        case 0: view.isHidden = false
        case 1: ancestor.isHidden = false
        case 2: view.alphaValue = 1
        default: ancestor.alphaValue = 1
        }
        view.updateViewportActivity()
        #expect(view.isNativeSurfaceVisible && view.isLevelPresentationAvailable)
        #expect(view.viewportRendering === driver && canvas.delegate === driver)
        #expect(view.subviews.contains { $0 === canvas } && !canvas.isPaused)
        #expect(host.renderer.presentationClockTime == nil && deltas.isEmpty)
        #expect(!source.isAvailable && invalidations == 1, "Restoring visibility must await a newly completed frame")
        #expect(host.activePresentationSource === source)

        // The first resumed tick rebases rather than simulating the hidden gap.
        host.renderer.update(200); host.renderer.didFinishUpdate()
        host.renderer.update(200 + 1.0 / 60); host.renderer.didFinishUpdate()
        #expect(deltas.count == 2)
        #expect(deltas.first == 0)
        #expect(abs((deltas.last ?? 0) - 1.0 / 60) < 0.000_001)
    }
    #endif

    @Test func legacyNilConfigurationIsANoOpAndExplicitViewportsRemainIndependent() {
        let host = GameHost(), world = host.world, renderer = host.renderer
        let revision = host.renderingRevision
        host.configureRendering(nil, monitor: nil, presentation: nil)
        host.configureRendering(nil, monitor: nil, presentation: nil)
        #expect(host.renderingRevision == revision)
        #expect(host.world === world && host.renderer === renderer)
        #expect(host.renderConfiguration == nil && host.renderMonitor == nil)
        #expect(host.requestedPresentationSource == nil && host.activePresentationSource == nil)
        #expect(host.configuredViewports == nil && renderer.viewports.isEmpty)
        #expect(!host.hasAdvancedRendering && !host.requiresViewportRendering)

        host.configureViewports([.init(id: "main")])
        host.configureRendering(nil, monitor: nil, presentation: nil)
        #expect(!host.hasAdvancedRendering && host.requiresViewportRendering)
        #expect(host.configuredViewports?.map(\.id) == ["main"])
        host.configureViewports(nil)
        #expect(!host.hasAdvancedRendering && !host.requiresViewportRendering)
    }
}

@_spi(Backend) import ECSCore
@testable import GameUI
import Metal
@_spi(Backend) import SpriteBackend
import SpriteKit
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Suite struct LevelPresentationTests {
    @Test func readbackConvertsStraightRGBAWithoutFlippingRows() {
        let image = LevelPresentationPixels.image(bgra: [25, 50, 100, 128, 200, 100, 50, 255,
                                                        0, 0, 0, 0, 20, 40, 60, 255], width: 2, height: 2)
        #expect(image.pixels == [199, 100, 50, 128, 50, 100, 200, 255,
                                0, 0, 0, 0, 60, 40, 20, 255])
        #expect(LevelPresentationPixels.cgImage(image)?.width == 2)
    }

    @Test func contentUsesStableCoordinatorAndCaptureRejectsUnpresentedHost() async throws {
        let host = GameHost(), first = host.content, second = host.content
        #expect(first.levels === second.levels)
        #expect(first.levels.world === host.world)
        #expect(!host.levelPresentation.isLevelPresentationAvailable)
        #expect(throws: LevelLoadingError.presentationUnavailable) { try first.capturePresentation() }
        // A surface attached to a window can run its first fade even though no
        // native scene has been presented and no capture frame exists yet.
        let view = GameSKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.host = host; host.nativeView = view
#if os(macOS)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
#else
        let window = UIWindow(frame: view.frame)
        window.addSubview(view); window.isHidden = false
        defer { view.removeFromSuperview(); window.isHidden = true }
#endif
        #expect(view.isLevelPresentationAvailable && host.levelPresentation.isLevelPresentationAvailable)
        host.renderer.update(0)
        #expect(!view.isLevelPresentationAvailable && !host.levelPresentation.isLevelPresentationAvailable)
        host.renderer.didFinishUpdate()
        #expect(view.isLevelPresentationAvailable && host.levelPresentation.isLevelPresentationAvailable)
        #expect(!view.isLevelCaptureAvailable)
        #expect(throws: LevelLoadingError.presentationUnavailable) { try first.capturePresentation() }
        var updates = 0
        let token = host.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let root = try await first.levels.load(id: "first", transition: .fade(duration: 0.001)) { _ in Entity() }
        #expect(first.levels.currentRoot === root && first.levels.phase == .idle)
        await #expect(throws: LevelLoadingError.presentationUnavailable) {
            try await first.levels.load(id: "second", transition: .crossFade(duration: 0.001)) { _ in Entity() }
        }
        #expect(first.levels.currentRoot === root && !first.levels.blocksInput)
        #expect(updates == 0 && !view.isLevelCaptureAvailable)
        view.isHidden = true
        #expect(!view.isLevelPresentationAvailable)
        view.isHidden = false
        host.levelPresentation.levelInputDidChange(blocked: true)
        host.stopPresentation()
        #expect(first.levels.currentRoot === root)
        #expect(!host.levelInputBlocked)
        #expect(throws: LevelLoadingError.presentationUnavailable) { try second.capturePresentation() }
        withExtendedLifetime(token) {}
    }

    @Test func transitionGatesTargetedManipulationAttachmentAndDirectInput() throws {
        let host = GameHost()
        host.renderer.size = CGSize(width: 100, height: 100)
        let target = Entity(components: CollisionComponent(shape: .circle(radius: 20)), InputTargetComponent())
        host.world.addEntity(target)
        host.attachmentStore.configure(["button"])
        let anchor = try #require(host.content.attachments.makeEntity(for: "button"))
        anchor.components[AttachmentComponent.self]?.isInteractive = true
        host.world.addEntity(anchor)
        host.renderer.flush(); host.attachmentStore.refresh()
        let projection = try #require(host.attachmentStore.presentations.first)
        let context = AttachmentContext(entity: anchor, store: host.attachmentStore, identity: projection.id)
        let action = InputAction("fire"), control = InputControl.virtual("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(action, control: control)])])
        host.actionInput = input
        let point = CGPoint(x: 50, y: 50)
        _ = host.beginInput(at: point)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 })?.entity === target)
        input.setValue(.button(true), for: control, device: .virtual("touch"))
        #expect(input.value(for: action).isPressed)
        host.levelPresentation.levelInputDidChange(blocked: true)
        #expect(host.inputContacts.isEmpty)
        #expect(!host.attachmentStore.acceptsInput)
        #expect(host.attachmentStore.presentations.count == 1)
        #expect(!context.perform { _ in Issue.record("Blocked attachment ran") })
        #expect(TargetedInputCapture<Int>().resolve(2, start: point, host: host, resolver: { $0 }) == nil)
        #expect(input.isEnabled && !input.value(for: action).isPressed)
        input.setValue(.button(true), for: control, device: .virtual("touch"))
        #expect(!input.value(for: action).isPressed)
        host.levelPresentation.levelInputDidChange(blocked: false)
        input.setValue(.button(true), for: control, device: .virtual("touch"))
        #expect(!input.value(for: action).isPressed)
        input.setValue(.button(false), for: control, device: .virtual("touch"))
        input.setValue(.button(true), for: control, device: .virtual("touch"))
        #expect(input.value(for: action).isPressed)
        #expect(context.perform { _ in })
        // Teardown must release a lease even after the bridge loses its host.
        var temporary: GameHost? = GameHost()
        temporary?.actionInput = input
        temporary?.levelPresentation.levelInputDidChange(blocked: true)
        weak var bridge = temporary?.levelPresentation
        temporary = nil
        #expect(bridge == nil)
        input.setValue(.button(false), for: control, device: .virtual("touch"))
        input.setValue(.button(true), for: control, device: .virtual("touch"))
        #expect(input.value(for: action).isPressed)
    }

    @Test func transitionKeepsNativeHubLeaseAssignmentsAndSuppressesNewPlayers() throws {
        let host = GameHost(), session = GameInputSession(), hub = PlayerInputHub()
        let action = InputAction("fire"), control = InputControl.key("space")
        let maps: [InputActionMap] = [.init(name: "play", bindings: [.init(action, control: control)])]
        let player = hub.addPlayer(named: "Player", contexts: maps)
        session.configure(nil, hub: hub)
        session.availability = .init(visible: true, focused: true, sceneActive: true, scopeActive: true, windowActive: true)
        session.bind([GameHostReference(id: host.inputHostID, host: host)])
        defer { session.stop() }
        try hub.assign(.keyboard, to: player)
        session.router.key("space", pressed: false)
        #expect(session.router.key("space", pressed: true))
        let identity = player.id
        host.levelPresentation.levelInputDidChange(blocked: true)
        #expect(session.router.hasBackendLease)
        #expect(hub.owner(of: .keyboard) === player && player.id == identity)
        #expect(hub.isEnabled && player.isEnabled && !session.router.isActive)
        let late = hub.addPlayer(named: "Late", contexts: maps)
        late.input.setValue(.button(true), for: control, device: .virtual("late"))
        #expect(!late.input.value(for: action).isPressed)
        host.levelPresentation.levelInputDidChange(blocked: false)
        #expect(session.router.hasBackendLease && session.router.isActive)
        session.router.key("space", pressed: true, isRepeat: true)
        #expect(!player.input.value(for: action).isPressed)
        session.router.key("space", pressed: false)
        session.router.key("space", pressed: true)
        #expect(player.input.value(for: action).isPressed)
        host.levelPresentation.levelInputDidChange(blocked: true)
        let replacement = GameHost()
        session.bind([GameHostReference(id: replacement.inputHostID, host: replacement)])
        #expect(session.router.hasBackendLease && session.router.isActive)
        session.router.key("space", pressed: false)
        session.router.key("space", pressed: true)
        #expect(player.input.value(for: action).isPressed)
        #expect(hub.owner(of: .keyboard) === player)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func cachedViewportCaptureKeepsLastPixelsGeometryAndOrderWithoutUpdating() throws {
        let device = try #require(MTLCreateSystemDefaultDevice()), world = World()
        world.physics.gravity = .zero
        let scene = SpriteRenderer(world: world, size: CGSize(width: 64, height: 64))
        let frames = try ViewportFrameRenderer(scene: scene, device: device)
        #expect(throws: LevelLoadingError.presentationUnavailable) { try frames.capturePresentation() }
        let red = Entity(components: SpriteComponent(color: .red, size: [64, 64]))
        let green = Entity(components: SpriteComponent(color: .green, size: [64, 64]))
        red.position = [-100, 0]; green.position = [100, 0]
        world.addEntity(red); world.addEntity(green)
        let a = Entity(components: CameraComponent(smoothing: 0)), b = Entity(components: CameraComponent(smoothing: 0))
        a.position = [-100, 0]; b.position = [100, 0]
        world.addEntity(a); world.addEntity(b)
        scene.viewports = [
            .init(id: "red", camera: a.id, frame: .init(x: 0, y: 0, width: 0.75, height: 0.75)),
            .init(id: "green", camera: b.id, frame: .init(x: 0.25, y: 0.25, width: 0.75, height: 0.75))
        ]
        let output = try LevelPresentationPixels.makeTexture(device: device, width: 64, height: 64)
        var updates = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        for time in [1.0, 1.016] {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: scene.size, into: output, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            try #require(command.status == .completed)
        }
        let displayed = LevelPresentationPixels.image(from: output)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(displayed.pixels[((y * 64 + x) * 4)..<((y * 64 + x) * 4 + 4)]) }
        #expect(pixel(8, 8)[0] > 240) // Top-left red pane, not vertically flipped.
        #expect(pixel(32, 32)[1] > 120) // Later green pane covers the overlap.
        let node = try #require(scene.node(for: red))
        node.run(.moveBy(x: 20, y: 0, duration: 1))
        let position = node.position, count = updates
        // Edits after the last frame must not affect cached composition.
        scene.viewports.reverse(); scene.backgroundColor = .white
        a.position = .zero; red.position = [800, 800]
        world.isPaused = true
        let captured = try frames.capturePresentation()
        #expect(captured == displayed)
        #expect(updates == count && node.position == position)
        withExtendedLifetime(token) {}
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func freshLegacyRendererCapturesCameraParityWithoutSimulationActionsOrPhysics() throws {
        let device = try #require(MTLCreateSystemDefaultDevice()), world = World()
        world.physics.gravity = .zero
        let scene = SpriteRenderer(world: world, size: CGSize(width: 64, height: 64))
        scene.scaleMode = .fill
        let sprite = Entity(components: SpriteComponent(color: .red, size: [52, 44]))
        let marker = Entity(components: SpriteComponent(color: .blue, size: [12, 8]))
        marker.position = [8, 23]; marker.zPosition = 1
        let body = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 2),
            affectedByGravity: false, velocity: [10, 0]))
        let camera = Entity(components: CameraComponent(smoothing: 0))
        world.addEntity(sprite); world.addEntity(marker); world.addEntity(body); world.addEntity(camera)
        scene.update(0)
        #expect(scene.isUpdatingPresentation)
        #expect(throws: LevelLoadingError.presentationUnavailable) {
            try LevelPresentationPixels.captureLegacy(scene: scene, logicalSize: scene.size, scale: 1)
        }
        scene.didFinishUpdate()
        #expect(!scene.isUpdatingPresentation)
        let live = SKRenderer(device: device); live.scene = scene; live.ignoresSiblingOrder = true
        let queue = try #require(device.makeCommandQueue())
        let texture = try LevelPresentationPixels.makeTexture(device: device, width: 64, height: 64)
        var updates = 0
        var referenceClearColor = MTLClearColorMake(0, 0, 0, 1)
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        @MainActor func frame(_ time: TimeInterval) throws {
            live.update(atTime: time)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = referenceClearColor
            let command = try #require(queue.makeCommandBuffer())
            live.render(withViewport: CGRect(x: 0, y: 0, width: 64, height: 64), commandBuffer: command, renderPassDescriptor: pass)
            command.commit(); command.waitUntilCompleted()
            try #require(command.status == .completed)
        }
        try frame(1)
        try frame(1.016)
        let node = try #require(scene.node(for: sprite))
        node.run(.moveBy(x: 20, y: 0, duration: 1), withKey: "capture-action")
        var previous: SpriteImage?
        for (index, zoom) in [Float(1), Float(1.6)].enumerated() {
            camera.components[CameraComponent.self]?.zoom = zoom
            camera.position = index == 0 ? .zero : [8, -3]
            camera.rotation = index == 0 ? 0 : 0.4
            try frame(1.032 + Double(index) * 0.016)
            let displayed = LevelPresentationPixels.image(from: texture)
            #expect(stride(from: 0, to: displayed.pixels.count, by: 4).contains { displayed.pixels[$0] > 200 })
            let position = node.position, bodyPosition = body.position, count = updates
            let image = try LevelPresentationPixels.captureLegacy(scene: scene, logicalSize: scene.size, scale: 1)
            #expect(image == displayed, "Legacy capture must match the reference frame")
            #expect(node.position == position && body.position == bodyPosition && updates == count)
            #expect(node.action(forKey: "capture-action") != nil)
            if let previous { #expect(image != previous) }
            previous = image
        }
        // Match the native driver's explicit scene-color clear, including a
        // translucent background. Use an empty surface to verify every pixel.
        sprite.isEnabled = false; marker.isEnabled = false
        for (index, alpha) in [1.0, 0.5].enumerated() {
            scene.backgroundColor = SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha)
            referenceClearColor = MTLClearColorMake(0.2 * alpha, 0.4 * alpha, 0.6 * alpha, alpha)
            try frame(1.064 + Double(index) * 0.016)
            let displayed = LevelPresentationPixels.image(from: texture)
            let count = updates, position = node.position, bodyPosition = body.position
            let image = try LevelPresentationPixels.captureLegacy(scene: scene, logicalSize: scene.size, scale: 1)
            #expect(image == displayed, "Legacy capture must match the reference frame")
            #expect(updates == count && node.position == position && body.position == bodyPosition)
            #expect(abs(Int(image.pixels[0]) - 51) <= 2)
            #expect(abs(Int(image.pixels[1]) - 102) <= 2)
            #expect(abs(Int(image.pixels[2]) - 153) <= 2)
            #expect(abs(Int(image.pixels[3]) - Int((255 * alpha).rounded())) <= 1)
        }
        withExtendedLifetime(token) {}
    }
}

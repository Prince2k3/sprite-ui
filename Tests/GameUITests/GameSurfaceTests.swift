@_spi(Backend) import ECSCore
@_spi(Backend) @testable import SpriteBackend
@testable import GameUI
import Foundation
import Metal
import SwiftUI
import Testing

@MainActor @Suite struct GameSurfaceHostTests {
    private let size = CGSize(width: 800, height: 600)
    private var book: GameSurfaceGeometry {
        GameSurfaceGeometry(size: size, safeAreaInsets: .init(left: 10, right: 30), reservedRegions: [
            .init(id: "fold", kind: .division, frame: CGRect(x: 390, y: 0, width: 20, height: 600))
        ])
    }

    @Test func surfaceChangesPreserveWorldNodesCameraAndPlayerIdentity() {
        let host = GameHost()
        let player = Entity(components: SpriteComponent(color: .red, size: [20, 20]))
        let camera = Entity(components: CameraComponent(target: .entity(player.id), smoothing: 0))
        player.position = [75, 25]
        host.world.addEntity(player); host.world.addEntity(camera)
        host.configureViewports([.init(id: "game", camera: camera.id, region: .largestUsable)])
        let renderer = host.renderer, node = renderer.node(for: player)
        var updates = 0
        let token = host.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        host.updateSurfaceGeometry(book)
        #expect(host.renderer === renderer && host.world.observer === renderer)
        #expect(renderer.node(for: player) === node)
        #expect(host.world.entity(withID: player.id) === player)
        #expect(host.world.entity(withID: camera.id) === camera)
        #expect(host.content.surfaceGeometry == book && renderer.surfaceGeometry == book)
        #expect(updates == 0)
        renderer.updateCameras(deltaTime: 0, time: 0)
        #expect(camera.position == player.position)
        token.cancel()
    }

    @Test func reservedRegionChangesCancelCapturesEvenWithoutResizing() {
        let host = GameHost()
        host.configureViewports([.init(id: "game", region: .largestUsable)])
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        let fire = InputAction("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(fire, control: .key("space"))])])
        host.actionInput = input
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        let id = host.beginInput(at: CGPoint(x: 50, y: 50))
        let contact = host.inputContacts[id]
        host.updateSurfaceGeometry(book)
        #expect(host.inputContacts.isEmpty && contact?.cancelled == true)
        #expect(input.state(for: fire).phase == .cancelled)
        #expect(host.actionInput === input)
    }

    @Test func identicalGeometryAndScaleOnlyChangesDoNotReleaseInput() {
        let host = GameHost()
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        let id = host.beginInput(at: CGPoint(x: 50, y: 50))
        var events = 0
        let token = host.world.subscribe(to: GameSurfaceEvents.DidChange.self) { _ in events += 1 }
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        #expect(events == 0 && host.inputContacts[id] != nil)
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size, displayScale: 3))
        #expect(events == 1 && host.inputContacts[id]?.cancelled == false)
        token.cancel()
    }

    @Test func cancelledCallbackCannotPublishSupersededGeometry() {
        let host = GameHost()
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        let action = InputAction("move")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(action, control: .key("w"))])])
        host.actionInput = input
        let newest = GameSurfaceGeometry(size: CGSize(width: 333, height: 444))
        let observation = input.observe { event in
            if event.phase == .cancelled { host.updateSurfaceGeometry(newest) }
        }
        var geometries: [GameSurfaceGeometry] = []
        let token = host.world.subscribe(to: GameSurfaceEvents.DidChange.self) { geometries.append($0.geometry) }
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        host.updateSurfaceGeometry(book)
        #expect(host.content.surfaceGeometry == newest)
        #expect(host.renderer.surfaceGeometry == newest && host.renderer.size == newest.size)
        #expect(geometries == [newest])
        observation.cancel(); token.cancel()
    }

    @Test func retainedContentReadsLiveSurfaceAndEnvironmentHasEmptyFallback() {
        let host = GameHost(), content = host.content
        #expect(content.surfaceGeometry.size == .zero)
        host.updateSurfaceGeometry(book)
        #expect(content.surfaceGeometry == book)
        #expect(EnvironmentValues().gameSurfaceGeometry.size == .zero)
        _ = GameView(surfaceRegions: []) { _ in }.onGameSurfaceChange { _ in }
        _ = GameView(viewports: [.init(id: "game", region: .safeArea)], surfaceRegions: []) { _ in } attachments: {
            GameAttachment(id: "test") { Text("Test") }
        }
    }

    @Test func reentrantMetadataChangeKeepsOriginalLayoutDeltaAndInvalidatesAttachments() throws {
        let host = GameHost()
        let initial = GameSurfaceGeometry(size: size)
        host.updateSurfaceGeometry(initial)
        host.attachmentStore.configure(["label"])
        let entity = Entity(components: AttachmentComponent(id: "label", isInteractive: true))
        host.world.addEntity(entity); host.renderer.flush(); host.attachmentStore.refresh()
        let projection = try #require(host.attachmentStore.presentations.first)
        let context = AttachmentContext(entity: entity, store: host.attachmentStore, identity: projection.id)
        let action = InputAction("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(action, control: .key("space"))])])
        host.actionInput = input
        let newest = GameSurfaceGeometry(size: book.size, displayScale: 3,
            safeAreaInsets: book.safeAreaInsets, reservedRegions: book.reservedRegions)
        let observation = input.observe { event in
            if event.phase == .cancelled { host.updateSurfaceGeometry(newest) }
        }
        var events: [GameSurfaceEvents.DidChange] = []
        let token = host.world.subscribe(to: GameSurfaceEvents.DidChange.self) { events.append($0) }
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        host.updateSurfaceGeometry(book)
        #expect(events.count == 1)
        #expect(events.first?.previous == initial && events.first?.geometry == newest)
        #expect(!context.isValid)
        #expect(host.renderer.surfaceGeometry == newest)
        observation.cancel(); token.cancel()
    }

    @Test func inactiveMetadataDoesNotCancelCapturesOrAttachmentContexts() throws {
        let host = GameHost()
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        host.attachmentStore.configure(["label"])
        let entity = Entity(components: AttachmentComponent(id: "label"))
        host.world.addEntity(entity); host.renderer.flush(); host.attachmentStore.refresh()
        let projection = try #require(host.attachmentStore.presentations.first)
        let context = AttachmentContext(entity: entity, store: host.attachmentStore, identity: projection.id)
        let id = host.beginInput(at: CGPoint(x: 50, y: 50))
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size, displayScale: 2, reservedRegions: [
            .init(id: "inactive", kind: .division, frame: CGRect(x: 390, y: 0, width: 20, height: 600), isActive: false)
        ]))
        #expect(host.inputContacts[id]?.cancelled == false)
        #expect(context.isValid)
    }

    @Test func attachmentsClipReservedRegionsAndRetireOldContexts() throws {
        let host = GameHost()
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: size))
        host.attachmentStore.configure(["control"])
        let entity = Entity(components: AttachmentComponent(id: "control", isInteractive: true))
        host.world.addEntity(entity); host.renderer.flush(); host.attachmentStore.refresh()
        let old = try #require(host.attachmentStore.presentations.first)
        let context = AttachmentContext(entity: entity, store: host.attachmentStore, identity: old.id)
        #expect(context.isValid)
        host.updateSurfaceGeometry(book)
        #expect(!context.isValid)
        let p = try #require(host.attachmentStore.presentations.first)
        let bounds = CGSize(width: 500, height: 200)
        #expect(p.contains(CGPoint(x: 350, y: 300), size: bounds))
        #expect(!p.contains(CGPoint(x: 400, y: 300), size: bounds))
        let hole = CGPoint(x: 400, y: 300).applying(p.transform(for: bounds).inverted())
        #expect(!p.hitPath(for: bounds).contains(hole))
        entity.components[AttachmentComponent.self]?.avoidsReservedRegions = false
        host.attachmentStore.refresh()
        let unrestricted = try #require(host.attachmentStore.presentations.first)
        #expect(unrestricted.contains(CGPoint(x: 400, y: 300), size: bounds))
    }

    @Test func attachmentPolicyDecodesOldSnapshotsAndRoundTripsOptOut() throws {
        let old = try JSONDecoder().decode(AttachmentComponent.self, from: Data(#"{"attachmentID":"label"}"#.utf8))
        #expect(old.avoidsReservedRegions)
        let optedOut = AttachmentComponent(id: "label", avoidsReservedRegions: false)
        #expect(try JSONDecoder().decode(AttachmentComponent.self, from: JSONEncoder().encode(optedOut)) == optedOut)
    }
}

@MainActor @Suite struct GameSurfaceViewportTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func nativeEncoderLeavesReservedDivisionEmptyAndTicksOnce() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = SpriteRenderer(world: World(), size: CGSize(width: 128, height: 64))
        let frames = try ViewportFrameRenderer(scene: scene, device: device)
        scene.world.addEntity(Entity(components: SpriteComponent(color: .red, size: [300, 300])))
        scene.setSurfaceGeometry(GameSurfaceGeometry(size: scene.size, reservedRegions: [
            .init(id: "fold", kind: .division, frame: CGRect(x: 56, y: 0, width: 16, height: 64))
        ]))
        scene.viewports = [.init(id: "left", region: .usable(0)), .init(id: "right", region: .usable(1))]
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 64, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        var updates = 0
        let token = scene.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        for time in [100.0, 100 + 1.0 / 60] {
            updates = 0
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: scene.size, into: output, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
        }
        func pixel(_ x: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, 32, 1, 1), mipmapLevel: 0)
            return bytes
        }
        #expect(pixel(28)[2] > 240 && pixel(100)[2] > 240)
        #expect(pixel(64).prefix(3).allSatisfy { $0 == 0 })
        #expect(updates == 1)
        #expect(scene.size == CGSize(width: 128, height: 64))
        token.cancel()
    }

    @Test func adaptiveRectsDriveDrawingProjectionPickingAndCameraBoundsTogether() throws {
        let renderer = SpriteRenderer(world: World())
        let camera = Entity(components: CameraComponent(target: .named("player"), smoothing: 0,
            bounds: .init(center: .zero, size: [1000, 1000])))
        let player = Entity(name: "player"); player.position = [500, 500]
        renderer.world.addEntity(camera); renderer.world.addEntity(player)
        renderer.size = CGSize(width: 800, height: 600)
        renderer.setSurfaceGeometry(GameSurfaceGeometry(size: renderer.size, reservedRegions: [
            .init(id: "hinge", kind: .division, frame: CGRect(x: 390, y: 0, width: 20, height: 600))
        ]))
        renderer.viewports = [.init(id: "game", camera: camera.id, region: .usable(0)),
                              .init(id: "map", camera: camera.id, isInteractive: false, region: .usable(1))]
        #expect(renderer.viewportRect(id: "game") == CGRect(x: 0, y: 0, width: 390, height: 600))
        #expect(renderer.viewportRect(id: "map") == CGRect(x: 410, y: 0, width: 390, height: 600))
        #expect(renderer.viewport(at: CGPoint(x: 400, y: 300)) == nil)
        #expect(renderer.viewport(at: CGPoint(x: 600, y: 300)) == nil)
        renderer.flush(); renderer.updateCameras(deltaTime: 0, time: 0)
        #expect(camera.position == [305, 200])
        let rect = try #require(renderer.viewportRect(id: "game"))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        #expect(renderer.scenePoint(fromView: center, inViewport: "game") == camera.position)
        #expect(renderer.viewPoint(from: camera.position, inViewport: "game") == center)
        renderer.renderViewport("game") {
            #expect(renderer.size == rect.size)
            #expect(renderer.viewportRect(id: "map")?.minX == 410)
        }
        #expect(renderer.size == CGSize(width: 800, height: 600))
    }

    @Test func unavailableRegionHidesViewportInsteadOfDrawingAcrossFold() {
        let renderer = SpriteRenderer(world: World(), size: CGSize(width: 200, height: 300))
        renderer.viewports = [.init(id: "missing", region: .usable(2))]
        #expect(renderer.resolvedViewports.isEmpty)
        #expect(renderer.viewportRect(id: "missing") == nil)
        #expect(renderer.viewport(at: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func framesAreRelativeToSelectedRegionAndLatchesNoticeGeometryChanges() {
        let renderer = SpriteRenderer(world: World(), size: CGSize(width: 400, height: 300))
        renderer.setSurfaceGeometry(GameSurfaceGeometry(size: renderer.size, safeAreaInsets: .init(top: 20, left: 40, bottom: 30, right: 60)))
        let viewport = GameViewport(id: "game", frame: .init(x: 0.5, y: 0, width: 0.5, height: 1), region: .safeArea)
        renderer.viewports = [viewport]
        #expect(renderer.viewportRect(id: "game") == CGRect(x: 190, y: 20, width: 150, height: 250))
        let latch = InputViewportLatch(viewport: viewport, renderer: renderer)
        #expect(latch.isValid(in: renderer))
        renderer.setSurfaceGeometry(GameSurfaceGeometry(size: renderer.size))
        #expect(!latch.isValid(in: renderer))
    }
}

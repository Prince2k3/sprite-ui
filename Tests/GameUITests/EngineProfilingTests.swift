import ECSCore
import Foundation
@testable import GameUI
import SpriteBackend
import SwiftUI
import Testing

@MainActor @Suite struct EngineProfilingTests {
    private func fixture() -> (GameHost, Entity, SceneDebugController) {
        let host = GameHost()
        host.renderer.size = CGSize(width: 402, height: 874)
        host.viewFrame = CGRect(x: 30, y: 60, width: 402, height: 874)
        let target = Entity(name: "target", components:
            SpriteComponent(color: .blue, size: [100, 100]), InputTargetComponent())
        host.world.addEntity(target)
        let controller = SceneDebugController(options: [.profiling])
        host.configureDebugController(controller)
        host.renderer.flush()
        return (host, target, controller)
    }

    @Test func profilingOnlyPanelBlocksNativeAndTargetedGestures() {
        let (host, target, controller) = fixture()
        let point = CGPoint(x: 201, y: 437)
        host.beginInput(at: point)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 })?.entity === target)
        host.cancelInputs()

        host.reportDebugPanel(CGRect(x: 220, y: 480, width: 80, height: 60))
        #expect(host.debugPanelContains(point))
        #expect(!host.isDebugPicking)
        #expect(TargetedInputCapture<Int>().resolve(2, start: point, host: host, resolver: { $0 }) == nil)
        host.beginInput(at: point)
        #expect(host.contact(startingAt: point)?.hit == nil)

        controller.options = []
        #expect(!host.debugBlocksInput(at: point))
        host.configureDebugController(nil)
        #expect(host.debugInput.panelFrame == nil)
    }

    @Test func openingAndDetachingProfilingDoesNotRecordOrChangeSimulation() {
        let host = GameHost()
        host.world.isPaused = true
        host.world.timeScale = 0.5
        let controller = SceneDebugController(options: [.profiling])
        host.configureDebugController(controller)
        _ = SceneDebugOverlay(controller: controller, host: host)
        controller.refresh()
        #expect(controller.scene?.profiler === host.world.profiler)
        #expect(!host.world.profiler.isRecording)
        #expect(host.world.profiler.capturedFrameCount == 0)
        #expect(host.world.isPaused && host.world.timeScale == 0.5)

        host.configureDebugController(nil)
        #expect(controller.scene == nil)
        #expect(!host.world.profiler.isRecording)
        #expect(host.world.isPaused && host.world.timeScale == 0.5)
    }

    @Test func inspectionControllerCanTakePriorityWithoutStoppingARecording() {
        let (host, _, profiling) = fixture()
        let profiler = host.world.profiler
        profiler.start()
        let inspection = SceneDebugController(options: [.selection, .inspector, .simulationControls])
        host.configureDebugController(inspection)
        #expect(!profiling.isAttached && inspection.scene?.profiler === profiler)
        #expect(profiler.isRecording)
        host.configureDebugController(profiling)
        #expect(!inspection.isAttached && profiling.scene?.profiler === profiler)
        #expect(profiler.isRecording)
        profiler.stop()
    }

    @Test func exportDocumentFreezesJSONBeforeTheLiveCaptureIsReset() throws {
        let world = World()
        world.profiler.start()
        world.update(deltaTime: 1.0 / 60)
        let capture = world.profiler.capture()
        let document = try EngineProfileDocument(capture: capture)
        #expect(world.profiler.isRecording)
        #expect(document.data == (try capture.jsonData(prettyPrinted: true)))

        world.profiler.reset()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(EngineProfileCapture.self, from: document.data)
        #expect(exported.frames.count == 1)
        #expect(exported.frames == capture.frames)
        #expect(world.profiler.capture().frames.isEmpty)
    }
}

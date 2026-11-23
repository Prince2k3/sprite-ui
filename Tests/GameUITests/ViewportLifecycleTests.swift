@_spi(Backend) import ECSCore
import Foundation
@testable import GameUI
import SpriteBackend
import SwiftUI
import Testing

@MainActor @Suite struct ViewportLifecycleTests {
    @Test func bothViewInitializersKeepLegacyDefaultsAndAcceptExplicitViewports() {
        _ = GameView { _ in }
        _ = GameView(viewports: []) { _ in }
        _ = GameView(viewports: [.init(id: "main")]) { _ in } attachments: {
            GameAttachment(id: "label") { Text("Label") }
        }
    }

    @Test func layoutChangesCancelInputWithoutReplacingWorldEntitiesOrBackend() {
        let host = GameHost()
        let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10]))
        host.world.addEntity(entity)
        let renderer = host.renderer, node = renderer.node(for: entity)
        let fire = InputAction("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(fire, control: .key("space"))])])
        host.actionInput = input
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        host.beginInput(at: .zero)
        host.configureViewports([.init(id: "left", frame: .init(x: 0, y: 0, width: 0.5, height: 1))])
        #expect(host.inputContacts.isEmpty)
        #expect(input.state(for: fire).phase == .cancelled)
        #expect(host.renderer === renderer && host.world.observer === renderer)
        #expect(renderer.node(for: entity) === node && entity.world === host.world)
        host.configureViewports(nil)
        #expect(host.configuredViewports == nil && renderer.viewports.isEmpty)
        #expect(renderer.node(for: entity) === node)
    }

    @Test func identicalLayoutDoesNotCancelAnActiveInput() {
        let host = GameHost()
        let viewports = [GameViewport(id: "left")]
        host.configureViewports(viewports)
        let action = InputAction("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(action, control: .key("space"))])])
        host.actionInput = input
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        host.configureViewports(viewports)
        #expect(input.value(for: action).isPressed)
    }

    @Test func cancellationCallbacksCannotOverwriteANewerLayout() {
        let host = GameHost()
        let action = InputAction("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [.init(action, control: .key("space"))])])
        host.actionInput = input
        let token = input.observe { event in
            if event.phase == .cancelled { host.configureViewports([.init(id: "newest")]) }
        }
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        host.configureViewports([.init(id: "superseded")])
        #expect(host.configuredViewports?.map(\.id) == ["newest"])
        #expect(host.renderer.viewports.map(\.id) == ["newest"])
        token.cancel()
    }

    @Test func presentationRequiresBothVisibilityAndActiveApplication() {
        let host = GameHost()
        host.configureViewports([])
        #expect(host.isPresentationActive)
        host.setPresentationAppActive(false)
        #expect(!host.isPresentationActive)
        host.startPresentation()
        #expect(!host.isPresentationActive)
        host.setPresentationAppActive(true)
        #expect(host.isPresentationActive)
        host.stopPresentation()
        #expect(!host.isPresentationActive)
        host.setPresentationAppActive(false)
        host.setPresentationAppActive(true)
        #expect(!host.isPresentationActive)
        host.startPresentation()
        #expect(host.isPresentationActive)
    }
}

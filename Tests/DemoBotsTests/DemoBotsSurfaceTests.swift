@_spi(Backend) import SpriteBackend
import Foundation
import SpriteUI
import Testing
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsSurfaceTests {
    private func foldedSurface(horizontal: Bool = false) -> GameSurfaceGeometry {
        GameSurfaceGeometry(
            size: CGSize(width: 1000, height: 800), displayScale: 2,
            safeAreaInsets: .init(top: 31, left: 43, bottom: 19, right: 11),
            reservedRegions: [
                .init(id: "fold", kind: .division,
                      frame: horizontal ? CGRect(x: 0, y: 390, width: 1000, height: 24)
                                        : CGRect(x: 460, y: 0, width: 24, height: 800)),
                .init(id: "camera", kind: .occlusion, frame: CGRect(x: 680, y: 31, width: 80, height: 60)),
                .init(id: "inactive", kind: .division, frame: CGRect(x: 100, y: 0, width: 30, height: 800), isActive: false),
            ])
    }

    private func assertContained(_ rects: [CGRect], in surface: GameSurfaceGeometry) {
        for rect in rects {
            #expect(rect.width > 0 && rect.height > 0)
            #expect(surface.safeBounds.contains(rect))
            #expect(surface.usableRegions().contains { $0.contains(rect) })
            for reservation in surface.reservedRegions where reservation.isActive {
                #expect(!rect.intersects(reservation.frame))
            }
        }
    }

    @Test(arguments: [false, true])
    func hudMenusAndWholeSticksAvoidDivisionsAndOcclusions(horizontal: Bool) throws {
        let surface = foldedSurface(horizontal: horizontal)
        let layout = DemoBotsSurfaceLayout(surface: surface)
        #expect(layout == DemoBotsSurfaceLayout(surface: surface))
        #expect(layout.gameplayViewport == surface.largestUsableRegion)
        assertContained(layout.hudRects + [layout.menu, layout.inspectionHeader, layout.inspectionFooter].compactMap { $0 }, in: surface)
        let move = try #require(layout.moveStick)
        let aim = try #require(layout.aimStick)
        #expect(move.size == CGSize(width: 126, height: 146))
        #expect(aim.size == move.size)
        #expect(!move.intersects(aim))
        for (index, rect) in layout.hudRects.enumerated() {
            for other in layout.hudRects.dropFirst(index + 1) { #expect(!rect.intersects(other)) }
        }
        #expect(layout.header != nil && layout.menu != nil)
    }

    @Test func asymmetricInsetsSetActualHudAndMenuOrigins() throws {
        let surface = GameSurfaceGeometry(size: CGSize(width: 600, height: 800),
                                          safeAreaInsets: .init(top: 61, left: 47, bottom: 29, right: 13))
        let layout = DemoBotsSurfaceLayout(surface: surface)
        let header = try #require(layout.header)
        let move = try #require(layout.moveStick)
        let aim = try #require(layout.aimStick)
        #expect(header.minY == 73)
        #expect(move.minX == 59 && move.maxY == 759)
        #expect(aim.maxX == 575 && aim.maxY == 759)
        assertContained(layout.hudRects + [try #require(layout.menu)], in: surface)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 20, height: 20), CGSize(width: 140, height: 100)])
    func tinySurfacesOmitElementsThatCannotFit(size: CGSize) {
        let surface = GameSurfaceGeometry(size: size)
        let layout = DemoBotsSurfaceLayout(surface: surface)
        #expect(layout.moveStick == nil && layout.aimStick == nil)
        #expect(layout.header == nil && layout.menu == nil)
        assertContained(layout.hudRects, in: surface)
    }

    @Test func entirelyOccludedSurfaceHasNoLayoutOrFallbackControls() {
        let surface = GameSurfaceGeometry(size: CGSize(width: 600, height: 800), reservedRegions: [
            .init(id: "covered", kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 600, height: 800)),
        ])
        let layout = DemoBotsSurfaceLayout(surface: surface)
        #expect(layout.gameplayViewport.isEmpty)
        #expect(layout.hudRects.isEmpty && layout.menu == nil)
        #expect(layout.inspectionHeader == nil && layout.inspectionFooter == nil)
    }

    @Test func resizeRetainsMatchWorldPlayerCameraAndInputSession() throws {
        let game = DemoBotsSession(), world = World()
        game.attach(to: world)
        game.start()
        try #require(game.phase == .playing)
        let player = try #require(game.player), camera = try #require(game.camera)
        let playerID = player.id, cameraID = camera.id
        let entityIDs = Set(world.entities.map(\.id))
        let controls = DemoBotsInput(game: game)
        let inputPlayer = controls.player, hub = controls.hub
        let remaining = game.remainingTime
        world.timeScale = 0.5
        controls.surfaceDidChange(GameSurfaceGeometry(size: CGSize(width: 402, height: 874)))
        for surface in [foldedSurface(), foldedSurface(horizontal: true),
                        GameSurfaceGeometry(size: CGSize(width: 20, height: 20)),
                        GameSurfaceGeometry(size: CGSize(width: 402, height: 874))] {
            controls.moveStick(.zero); controls.aimStick(.zero, pressed: false)
            controls.moveStick([0.8, 0]); controls.aimStick([0, 1], pressed: true)
            #expect(game.moveInput != .zero && game.isFiring)
            controls.surfaceDidChange(surface)
            #expect(game.phase == .playing && !world.isPaused && world.timeScale == 0.5)
            #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
            #expect(game.world === world && game.player === player && game.camera === camera)
            #expect(game.player?.id == playerID && game.camera?.id == cameraID)
            #expect(Set(world.entities.map(\.id)) == entityIDs)
            #expect(controls.player === inputPlayer && controls.hub === hub)
            #expect(hub.players.count == 1 && hub.owner(of: DemoBotsInput.aimDevice) === inputPlayer)
            #expect(game.remainingTime == remaining)
            #expect(game.viewSize == surface.largestUsableRegion.size)
            #expect(camera.components[CameraComponent.self]?.zoom == game.preferredZoom)
        }
    }

    @Test func unchangedScaleOnlyAndInactiveReservationsDoNotInterruptHeldControls() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let surface = GameSurfaceGeometry(size: CGSize(width: 700, height: 500))
        controls.surfaceDidChange(surface)
        controls.moveStick([0.7, 0]); controls.aimStick([0, 1], pressed: true)
        controls.surfaceDidChange(GameSurfaceGeometry(size: surface.size, displayScale: 3))
        controls.surfaceDidChange(surface)
        controls.surfaceDidChange(GameSurfaceGeometry(size: surface.size, reservedRegions: [
            .init(id: "inactive", kind: .division, frame: CGRect(x: 300, y: 0, width: 20, height: 500), isActive: false),
        ]))
        #expect(game.phase == .playing && game.moveInput == SIMD2<Float>(0.7, 0) && game.isFiring)
        #expect(controls.surfaceInputRevision == 0)
    }

    @Test func reservationAndInsetChangesReleaseControlsUntilANewGesture() {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let initial = GameSurfaceGeometry(size: CGSize(width: 700, height: 500))
        controls.surfaceDidChange(initial)
        let surfaces = [
            GameSurfaceGeometry(size: initial.size, safeAreaInsets: .init(top: 10, left: 30, bottom: 20, right: 5)),
            GameSurfaceGeometry(size: initial.size, reservedRegions: [
                .init(id: "fold", kind: .division, frame: CGRect(x: 300, y: 0, width: 20, height: 500)),
            ]),
        ]
        for surface in surfaces {
            controls.moveStick([1, 0]); controls.aimStick([0, 1], pressed: true)
            let revision = controls.surfaceInputRevision
            controls.surfaceDidChange(surface)
            #expect(game.phase == .playing && !world.isPaused && !game.isFiring && game.moveInput == .zero)
            #expect(controls.surfaceInputRevision == revision + 1)
            // Samples from the old captured drag stay gated until it ends.
            controls.moveStick([1, 0]); controls.aimStick([0, 1], pressed: true)
            #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
            // Neutral snapshots establish a new baseline after cancellation.
            controls.moveStick(.zero); controls.aimStick(.zero, pressed: false)
            #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        }
        controls.moveStick([0.5, 0]); controls.aimStick([0, 1], pressed: true)
        #expect(game.moveInput == SIMD2<Float>(0.5, 0) && game.isFiring)
    }

    @Test(arguments: [false, true])
    func foldsRetainPausedAndInspectionPlaybackState(inspecting: Bool) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.surfaceDidChange(GameSurfaceGeometry(size: CGSize(width: 402, height: 874)))
        game.pause()
        if inspecting { game.beginInspection() }
        controls.synchronizeContext()
        world.timeScale = 0.25
        let phase = game.phase, paused = world.isPaused, remaining = game.remainingTime
        controls.surfaceDidChange(foldedSurface())
        #expect(game.phase == phase && world.isPaused == paused && world.timeScale == 0.25)
        #expect(game.isInspecting == inspecting && game.remainingTime == remaining)
    }

    @Test func tapConversionRejectsHingeInsetsOcclusionsAndOtherViewportGaps() throws {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 1000, height: 800))
        game.renderer = renderer
        renderer.viewports = DemoBotsSurfaceLayout.viewports
        let surface = foldedSurface()
        renderer.setSurfaceGeometry(surface)
        let viewport = try #require(renderer.viewportRect(id: DemoBotsSurfaceLayout.viewportID))
        #expect(viewport == surface.largestUsableRegion)
        game.sendPlayer(toView: CGPoint(x: viewport.midX + 30, y: viewport.midY))
        let destination = try #require(game.destination)
        let route = game.playerRoute
        // Include the other usable pane: it has no gameplay viewport.
        for point in [CGPoint(x: 470, y: 400), CGPoint(x: 700, y: 50),
                      CGPoint(x: 5, y: 400), CGPoint(x: 200, y: 400),
                      CGPoint(x: -1, y: 100), CGPoint(x: 1001, y: 100)] {
            #expect(renderer.viewport(at: point) == nil)
            game.sendPlayer(toView: point)
            #expect(game.destination == destination && game.playerRoute == route)
        }
    }
}

import Foundation
import SpriteUI

/// Screen-space layout shared by the host and headless adoption tests. Every
/// element fits in one usable rectangle; unavailable elements are omitted.
struct DemoBotsSurfaceLayout: Equatable {
    static let viewportID = "main"
    static var viewports: [GameViewport] { [.init(id: viewportID, region: .largestUsable)] }

    struct SurfaceState: Equatable {
        let size: CGSize
        let safeBounds: CGRect
        let regions: [CGRect]

        init(_ surface: GameSurfaceGeometry) {
            size = surface.size
            safeBounds = surface.safeBounds
            regions = surface.usableRegions()
        }
    }

    let gameplayViewport: CGRect
    let menu: CGRect?
    let header: CGRect?
    let moveStick: CGRect?
    let aimStick: CGRect?
    let beamMeter: CGRect?
    let radar: CGRect?
    let prompts: CGRect?
    let inspectionHeader: CGRect?
    let inspectionFooter: CGRect?

    init(surface: GameSurfaceGeometry) {
        gameplayViewport = surface.largestUsableRegion
        let regions = surface.usableRegions().compactMap { region -> CGRect? in
            guard region.width > 24, region.height > 24 else { return nil }
            let inset = region.insetBy(dx: 12, dy: 12)
            return inset.width > 0 && inset.height > 0 && !inset.isNull ? inset : nil
        }
        var menus = Placer(regions: regions, bounds: surface.safeBounds)
        menu = menus.place(preferred: CGSize(width: 610, height: 900),
                           minimum: CGSize(width: 200, height: 100), anchor: [0.5, 0.5])
        var inspector = Placer(regions: regions, bounds: surface.safeBounds)
        inspectionHeader = inspector.place(preferred: CGSize(width: 400, height: 60),
                                            minimum: CGSize(width: 200, height: 60), anchor: [0, 0])
        inspectionFooter = inspector.place(preferred: CGSize(width: 440, height: 70),
                                            minimum: CGSize(width: 220, height: 70), anchor: [0.5, 1])
        var hud = Placer(regions: regions, bounds: surface.safeBounds)
        header = hud.place(preferred: CGSize(width: 560, height: 78),
                           minimum: CGSize(width: 240, height: 78), anchor: [0.5, 0])
        moveStick = hud.place(CGSize(width: 126, height: 146), anchor: [0, 1])
        aimStick = hud.place(CGSize(width: 126, height: 146), anchor: [1, 1])
        beamMeter = hud.place(CGSize(width: 145, height: 52), anchor: [0.5, 1])
        radar = hud.place(CGSize(width: 103, height: 114), anchor: [1, 0])
        prompts = hud.place(CGSize(width: 150, height: 64), anchor: [0, 0])
    }

    var hudRects: [CGRect] { [header, moveStick, aimStick, beamMeter, radar, prompts].compactMap { $0 } }

    private struct Placer {
        var regions: [CGRect]
        let bounds: CGRect

        mutating func place(_ size: CGSize, anchor: SIMD2<Double>) -> CGRect? {
            place(preferred: size, minimum: size, anchor: anchor)
        }

        mutating func place(preferred: CGSize, minimum: CGSize, anchor: SIMD2<Double>) -> CGRect? {
            let target = CGPoint(x: bounds.minX + bounds.width * anchor.x,
                                 y: bounds.minY + bounds.height * anchor.y)
            let candidates = regions.filter { $0.width >= minimum.width && $0.height >= minimum.height }.map { region in
                let size = CGSize(width: min(preferred.width, region.width), height: min(preferred.height, region.height))
                return CGRect(x: region.minX + (region.width - size.width) * anchor.x,
                              y: region.minY + (region.height - size.height) * anchor.y,
                              width: size.width, height: size.height)
            }
            guard let rect = candidates.min(by: { a, b in
                let da = hypot(a.midX - target.x, a.midY - target.y)
                let db = hypot(b.midX - target.x, b.midY - target.y)
                return da == db ? a.width * a.height > b.width * b.height : da < db
            }) else { return nil }
            // Reserve a design gap too. Splitting free rectangles keeps controls
            // from overlapping even when they are assigned to the same pane.
            let occupied = rect.insetBy(dx: -8, dy: -8)
            regions = regions.flatMap { region -> [CGRect] in
                let cut = region.intersection(occupied)
                guard !cut.isNull, !cut.isEmpty else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                    CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
                    CGRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
            return rect
        }
    }
}

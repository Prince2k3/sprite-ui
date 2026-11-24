import CoreGraphics
import Foundation
import SpriteBackend
import Testing

@Suite struct GameSurfaceGeometryTests {
    private let surfaceSize = CGSize(width: 200, height: 120)

    @Test func defaultsAndRegionSelectors() {
        let geometry = GameSurfaceGeometry(size: surfaceSize)
        let bounds = CGRect(origin: .zero, size: surfaceSize)
        #expect(geometry.size == surfaceSize)
        #expect(geometry.displayScale == 1)
        #expect(geometry.safeAreaInsets == .init())
        #expect(geometry.reservedRegions.isEmpty)
        #expect(geometry.bounds == bounds)
        #expect(geometry.safeBounds == bounds)
        #expect(geometry.usableRegions() == [bounds])
        #expect(geometry.largestUsableRegion == bounds)
        #expect(geometry.rect(for: .surface) == bounds)
        #expect(geometry.rect(for: .safeArea) == bounds)
        #expect(geometry.rect(for: .largestUsable) == bounds)
        #expect(geometry.rect(for: .usable(0)) == bounds)
        #expect(geometry.rect(for: .usable(-1)) == .zero)
        #expect(geometry.rect(for: .usable(1)) == .zero)
        #expect(geometry.rect(for: .usable(.max)) == .zero)
    }

    @Test func verticalBookDivisionProducesTwoPagesWithStableTie() {
        let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [
            .init(id: "spine", kind: .division, frame: CGRect(x: 95, y: 0, width: 10, height: 120))
        ])
        let left = CGRect(x: 0, y: 0, width: 95, height: 120)
        let right = CGRect(x: 105, y: 0, width: 95, height: 120)
        #expect(geometry.usableRegions() == [left, right])
        #expect(geometry.largestUsableRegion == left)
        #expect(geometry.rect(for: .usable(1)) == right)
    }

    @Test func horizontalBookDivisionProducesTwoPages() {
        let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [
            .init(id: "fold", kind: .division, frame: CGRect(x: 0, y: 40, width: 200, height: 10))
        ])
        let top = CGRect(x: 0, y: 0, width: 200, height: 40)
        let bottom = CGRect(x: 0, y: 50, width: 200, height: 70)
        #expect(geometry.usableRegions() == [top, bottom])
        #expect(geometry.largestUsableRegion == bottom)
    }

    @Test func asymmetricInsetsAndOversizedInsetsStayInsideSurface() {
        let geometry = GameSurfaceGeometry(
            size: surfaceSize, displayScale: 3,
            safeAreaInsets: .init(top: 7, left: 11, bottom: 13, right: 17)
        )
        #expect(geometry.displayScale == 3)
        #expect(geometry.safeBounds == CGRect(x: 11, y: 7, width: 172, height: 100))
        #expect(geometry.usableRegions() == [geometry.safeBounds])
        let exhausted = GameSurfaceGeometry(
            size: surfaceSize,
            safeAreaInsets: .init(top: .greatestFiniteMagnitude, left: 30,
                                  bottom: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude)
        )
        #expect(exhausted.safeBounds == CGRect(x: 30, y: 120, width: 0, height: 0))
        #expect(exhausted.usableRegions().isEmpty)
        #expect(exhausted.largestUsableRegion == .zero)
    }

    @Test func overlappingAndOutsideRegionsAreClippedAndSubtractedOnce() {
        let geometry = GameSurfaceGeometry(size: CGSize(width: 100, height: 100), reservedRegions: [
            .init(id: "a", kind: .occlusion, frame: CGRect(x: -10, y: 20, width: 70, height: 40)),
            .init(id: "b", kind: .division, frame: CGRect(x: 40, y: 40, width: 80, height: 40)),
            .init(id: "outside", kind: .occlusion, frame: CGRect(x: 110, y: 0, width: 20, height: 20))
        ])
        #expect(geometry.reservedRegions.first { $0.id == "a" }?.frame == CGRect(x: 0, y: 20, width: 60, height: 40))
        #expect(geometry.reservedRegions.first { $0.id == "b" }?.frame == CGRect(x: 40, y: 40, width: 60, height: 40))
        #expect(geometry.reservedRegions.first { $0.id == "outside" }?.frame == .zero)
        let usable = geometry.usableRegions()
        #expect(usable == [
            CGRect(x: 0, y: 0, width: 100, height: 20),
            CGRect(x: 60, y: 20, width: 40, height: 20),
            CGRect(x: 0, y: 60, width: 40, height: 20),
            CGRect(x: 0, y: 80, width: 100, height: 20)
        ])
        #expect(usable.reduce(CGFloat.zero) { $0 + $1.width * $1.height } == 5_600)
        expectDisjoint(usable)
    }

    @Test func inactiveRegionsAreOptionalAndBothKindsReserveSpace() {
        let inactive = GameSurfaceGeometry.ReservedRegion(
            id: "overlay", kind: .occlusion,
            frame: CGRect(x: 0, y: 0, width: 200, height: 120), isActive: false
        )
        let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [inactive])
        #expect(geometry.reservedRegions == [inactive])
        #expect(geometry.usableRegions() == [geometry.bounds])
        #expect(geometry.usableRegions(includingInactive: true).isEmpty)
        #expect(geometry.placement(of: CGSize(width: 20, height: 20)) != nil)
        #expect(geometry.placement(of: CGSize(width: 20, height: 20), includingInactive: true) == nil)
        for kind in [GameSurfaceGeometry.ReservedRegion.Kind.occlusion, .division] {
            let blocked = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [
                .init(id: "block", kind: kind, frame: geometry.bounds)
            ])
            #expect(blocked.reservedRegions[0].isActive)
            #expect(blocked.usableRegions().isEmpty)
            #expect(blocked.largestUsableRegion == .zero)
        }
    }

    @Test func canonicalSubtractionIsIndependentOfDeclarationOrder() {
        let regions: [GameSurfaceGeometry.ReservedRegion] = [
            .init(id: "center", kind: .occlusion, frame: CGRect(x: 40, y: 30, width: 20, height: 40)),
            .init(id: "cross", kind: .division, frame: CGRect(x: 0, y: 45, width: 100, height: 10)),
            .init(id: "duplicate", kind: .occlusion, frame: CGRect(x: 40, y: 30, width: 20, height: 40))
        ]
        let geometry = GameSurfaceGeometry(size: CGSize(width: 100, height: 100), reservedRegions: regions)
        let reversed = GameSurfaceGeometry(size: geometry.size, reservedRegions: regions.reversed())
        let expected = [
            CGRect(x: 0, y: 0, width: 100, height: 30),
            CGRect(x: 0, y: 30, width: 40, height: 15),
            CGRect(x: 60, y: 30, width: 40, height: 15),
            CGRect(x: 0, y: 55, width: 40, height: 15),
            CGRect(x: 60, y: 55, width: 40, height: 15),
            CGRect(x: 0, y: 70, width: 100, height: 30)
        ]
        #expect(geometry.usableRegions() == expected)
        #expect(reversed.usableRegions() == expected)
        #expect(geometry.reservedRegions == reversed.reservedRegions)
        #expect(geometry == reversed)
        #expect(geometry.largestUsableRegion == expected[0])
        expectDisjoint(expected)
    }

    @Test func invalidDimensionsScaleAndInsetsBecomeFiniteValues() {
        for invalid in [CGFloat.nan, .infinity, -.infinity, -1, 0] {
            let geometry = GameSurfaceGeometry(
                size: CGSize(width: invalid, height: 120), displayScale: invalid,
                safeAreaInsets: .init(top: invalid, left: invalid, bottom: invalid, right: invalid)
            )
            #expect(geometry.size == CGSize(width: 0, height: 120))
            #expect(geometry.displayScale == 1)
            #expect(geometry.safeAreaInsets == .init())
            #expect(geometry.usableRegions().isEmpty)
            #expect(geometry.largestUsableRegion == .zero)
            #expect(geometry.placement(of: CGSize(width: 1, height: 1)) == nil)
            let invalidHeight = GameSurfaceGeometry(size: CGSize(width: 200, height: invalid))
            #expect(invalidHeight.size == CGSize(width: 200, height: 0))
            #expect(invalidHeight.usableRegions().isEmpty)
        }
        #expect(GameSurfaceGeometry(size: .zero).bounds == .zero)
    }

    @Test func storedReservationsUseIdentityKindFrameAndActivityOrder() {
        let expected: [GameSurfaceGeometry.ReservedRegion] = [
            .init(id: "a", kind: .occlusion, frame: CGRect(x: 0, y: 10, width: 5, height: 5)),
            .init(id: "a", kind: .occlusion, frame: CGRect(x: 10, y: 10, width: 5, height: 5), isActive: false),
            .init(id: "a", kind: .occlusion, frame: CGRect(x: 10, y: 10, width: 5, height: 5)),
            .init(id: "a", kind: .occlusion, frame: CGRect(x: 0, y: 20, width: 5, height: 5)),
            .init(id: "a", kind: .division, frame: CGRect(x: 0, y: 0, width: 5, height: 5)),
            .init(id: "z", kind: .occlusion, frame: .zero)
        ]
        let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: expected)
        #expect(geometry.reservedRegions == expected)
        for offset in expected.indices {
            let rotated = Array(expected[offset...]) + Array(expected[..<offset])
            let reordered = GameSurfaceGeometry(size: surfaceSize, reservedRegions: rotated.reversed())
            #expect(reordered.reservedRegions == expected)
            #expect(reordered == geometry)
        }
    }

    @Test func malformedRectanglesAreEmptyWithoutStandardizingNegativeSizes() {
        let invalidFrames: [CGRect] = [
            .null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10),
            CGRect(x: 0, y: 0, width: 10, height: CGFloat.infinity),
            CGRect(x: 10, y: 10, width: -5, height: 10),
            CGRect(x: 0, y: 0, width: 10, height: -1),
            CGRect(x: 50, y: 0, width: 0, height: 120)
        ]
        for frame in invalidFrames {
            let region = GameSurfaceGeometry.ReservedRegion(id: "invalid", kind: .occlusion, frame: frame)
            #expect(region.frame == .zero)
            let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [region])
            #expect(geometry.usableRegions() == [geometry.bounds])
            #expect(geometry == geometry)
        }
    }

    @Test func hugeFiniteCoordinatesDoNotOverflowClippingOrAreaSelection() {
        let huge = CGFloat.greatestFiniteMagnitude
        let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [
            .init(id: "overflow", kind: .occlusion, frame: CGRect(x: 10, y: 20, width: huge, height: huge)),
            .init(id: "outside", kind: .occlusion, frame: CGRect(x: huge, y: huge, width: huge, height: huge)),
            .init(id: "left", kind: .occlusion, frame: CGRect(x: -huge, y: 0, width: huge, height: 120))
        ])
        #expect(geometry.reservedRegions.first { $0.id == "overflow" }?.frame == CGRect(x: 10, y: 20, width: 190, height: 100))
        #expect(geometry.reservedRegions.first { $0.id == "outside" }?.frame == .zero)
        #expect(geometry.reservedRegions.first { $0.id == "left" }?.frame == .zero)
        #expect(geometry.usableRegions() == [
            CGRect(x: 0, y: 0, width: 200, height: 20),
            CGRect(x: 0, y: 20, width: 10, height: 100)
        ])
        let enormous = GameSurfaceGeometry(size: CGSize(width: huge, height: huge), reservedRegions: [
            .init(id: "fold", kind: .division,
                  frame: CGRect(x: 0, y: huge / 4, width: huge, height: huge / 4))
        ])
        #expect(enormous.largestUsableRegion == CGRect(x: 0, y: huge / 2, width: huge, height: huge / 2))
        let placement = enormous.placement(of: CGSize(width: huge / 8, height: huge / 8), anchor: [1, 1])
        #expect(placement?.origin.x.isFinite == true)
        #expect(placement?.origin.y.isFinite == true)
    }

    @Test func placementClampsEntireControlToSafeArea() {
        let geometry = GameSurfaceGeometry(size: surfaceSize,
                                          safeAreaInsets: .init(top: 7, left: 11, bottom: 13, right: 17))
        let control = CGSize(width: 20, height: 10)
        #expect(geometry.placement(of: control) == CGRect(x: 90, y: 55, width: 20, height: 10))
        #expect(geometry.placement(of: control, anchor: [0, 0]) == CGRect(x: 11, y: 7, width: 20, height: 10))
        #expect(geometry.placement(of: control, anchor: [1, 1]) == CGRect(x: 163, y: 97, width: 20, height: 10))
        #expect(geometry.placement(of: geometry.safeBounds.size, anchor: [1, 0]) == geometry.safeBounds)
    }

    @Test func placementUsesNearestFittingCenterAndStableTies() {
        let geometry = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [
            .init(id: "spine", kind: .division, frame: CGRect(x: 95, y: 0, width: 10, height: 120))
        ])
        let control = CGSize(width: 20, height: 10)
        #expect(geometry.placement(of: control) == CGRect(x: 75, y: 55, width: 20, height: 10))
        #expect(geometry.placement(of: control, anchor: [0.75, 0.25]) == CGRect(x: 140, y: 25, width: 20, height: 10))
        #expect(geometry.placement(of: CGSize(width: 100, height: 10)) == nil)
        let unequal = GameSurfaceGeometry(size: surfaceSize, reservedRegions: [
            .init(id: "fold", kind: .division, frame: CGRect(x: 40, y: 0, width: 10, height: 120))
        ])
        #expect(unequal.placement(of: CGSize(width: 60, height: 20), anchor: [0, 0])
                == CGRect(x: 50, y: 0, width: 60, height: 20))
        // A nearby edge beats a nearer region center for this wide right pane.
        #expect(unequal.placement(of: control, anchor: [0.3, 0.5])
                == CGRect(x: 50, y: 55, width: 20, height: 10))
    }

    @Test func placementRejectsInvalidSizesAndNormalizesAnchors() {
        let geometry = GameSurfaceGeometry(size: surfaceSize)
        for invalid in [CGFloat.nan, .infinity, -.infinity, -1, 0] {
            #expect(geometry.placement(of: CGSize(width: invalid, height: 10)) == nil)
            #expect(geometry.placement(of: CGSize(width: 10, height: invalid)) == nil)
        }
        #expect(geometry.placement(of: CGSize(width: 201, height: 10)) == nil)
        #expect(geometry.placement(of: CGSize(width: 10, height: 121)) == nil)
        let control = CGSize(width: 20, height: 10)
        #expect(geometry.placement(of: control, anchor: [-100, 100]) == CGRect(x: 0, y: 110, width: 20, height: 10))
        #expect(geometry.placement(of: control, anchor: [.nan, .infinity]) == geometry.placement(of: control))
        #expect(geometry.placement(of: control, anchor: [.nan, 0]) == CGRect(x: 90, y: 0, width: 20, height: 10))
    }

    @Test func publicValuesSupportEqualityHashingCodingAndSendability() throws {
        let insets = GameSurfaceGeometry.Insets(top: 1, left: 2, bottom: 3, right: 4)
        #expect(try JSONDecoder().decode(GameSurfaceGeometry.Insets.self,
                                        from: JSONEncoder().encode(insets)) == insets)
        #expect(Set([insets, insets]).count == 1)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let malformed = Data(#"{"top":"NaN","left":-1,"bottom":"Infinity","right":4}"#.utf8)
        #expect(try decoder.decode(GameSurfaceGeometry.Insets.self, from: malformed) == .init(right: 4))
        let selectors: [GameSurfaceRegion] = [.surface, .safeArea, .largestUsable, .usable(-1), .usable(2)]
        #expect(try JSONDecoder().decode([GameSurfaceRegion].self,
                                        from: JSONEncoder().encode(selectors)) == selectors)
        #expect(Set(selectors).count == selectors.count)
        let geometry = GameSurfaceGeometry(size: surfaceSize, safeAreaInsets: insets)
        #expect(geometry == GameSurfaceGeometry(size: surfaceSize, safeAreaInsets: insets))
        #expect(geometry != GameSurfaceGeometry(size: surfaceSize, displayScale: 2))
        requireSendable(geometry)
        requireSendable(insets)
        requireSendable(GameSurfaceGeometry.ReservedRegion(id: "a", kind: .division, frame: .zero))
        requireSendable(GameSurfaceGeometry.ReservedRegion.Kind.occlusion)
        requireSendable(GameSurfaceRegion.surface)
    }

    private func expectDisjoint(_ rectangles: [CGRect]) {
        for (index, rectangle) in rectangles.enumerated() {
            for other in rectangles.dropFirst(index + 1) {
                #expect(rectangle.intersection(other).isEmpty)
            }
        }
    }

    private func requireSendable<T: Sendable>(_ value: T) {}
}

import Foundation
@testable import GameUI
import SpriteBackend
import Testing

@Suite struct GameRenderConfigurationTests {
    @Test func defaultsAndClampedLimits() {
        let defaults = GameRenderConfiguration()
        #expect(defaults.resolutionScale == 1)
        #expect(defaults.preferredFramesPerSecond == 60)
        #expect(defaults.maximumRenderPixels == 16_777_216)
        #expect(defaults.maximumTextureDimension == 8192)
        #expect(!defaults.adaptsToSystemPressure)
        let low = GameRenderConfiguration(resolutionScale: -1, preferredFramesPerSecond: Int.min,
                                          maximumRenderPixels: Int.min, maximumTextureDimension: Int.min)
        #expect(low.resolutionScale == 0.1)
        #expect(low.preferredFramesPerSecond == 15)
        #expect(low.maximumRenderPixels == 64)
        #expect(low.maximumTextureDimension == 1)
        let high = GameRenderConfiguration(resolutionScale: 2, preferredFramesPerSecond: Int.max,
                                           maximumRenderPixels: Int.max, maximumTextureDimension: Int.max)
        #expect(high.resolutionScale == 1)
        #expect(high.preferredFramesPerSecond == 240)
        #expect(high.maximumRenderPixels == 268_435_456)
        #expect(high.maximumTextureDimension == 16_384)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonfiniteResolutionDefaultsToOne(_ scale: Double) {
        #expect(GameRenderConfiguration(resolutionScale: scale).resolutionScale == 1)
    }

    @Test(arguments: [15, 24, 30, 60, 120, 240])
    func supportedFrameCapsRemainUnchanged(_ fps: Int) {
        #expect(GameRenderConfiguration(preferredFramesPerSecond: fps).preferredFramesPerSecond == fps)
    }

    @Test func codableRoundTripsAndDecodingPreservesValidation() throws {
        let config = GameRenderConfiguration(resolutionScale: 0.6, preferredFramesPerSecond: 24,
            maximumRenderPixels: 5000, maximumTextureDimension: 400, adaptsToSystemPressure: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GameRenderConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(Set([decoded, config]).count == 1)
        let outOfRange = Data("""
        {"resolutionScale":-2,"preferredFramesPerSecond":1,"maximumRenderPixels":0,
         "maximumTextureDimension":99999,"adaptsToSystemPressure":true}
        """.utf8)
        let clamped = try JSONDecoder().decode(GameRenderConfiguration.self, from: outOfRange)
        #expect(clamped == GameRenderConfiguration(resolutionScale: 0.1, preferredFramesPerSecond: 15,
            maximumRenderPixels: 64, maximumTextureDimension: 16_384, adaptsToSystemPressure: true))
        let environment = GameRenderEnvironment(thermalState: .critical, isLowPowerModeEnabled: true)
        let environmentData = try JSONEncoder().encode(environment)
        #expect(try JSONDecoder().decode(GameRenderEnvironment.self, from: environmentData) == environment)
    }

    @Test func pressureCapsAreAbsoluteAndIdempotent() {
        let config = GameRenderConfiguration(adaptsToSystemPressure: true)
        let cases: [(GameRenderEnvironment.ThermalState, Double, Int)] = [
            (.nominal, 1, 60), (.fair, 1, 60), (.serious, 0.75, 30), (.critical, 0.5, 20)
        ]
        for (thermal, scale, fps) in cases {
            for lowPower in [false, true] {
                let environment = GameRenderEnvironment(thermalState: thermal, isLowPowerModeEnabled: lowPower)
                let resolved = config.resolved(in: environment)
                #expect(resolved.resolutionScale == scale)
                #expect(resolved.preferredFramesPerSecond == (lowPower ? min(fps, 30) : fps))
                #expect(resolved.resolved(in: environment) == resolved)
                #expect(resolved.maximumRenderPixels == config.maximumRenderPixels)
                #expect(resolved.maximumTextureDimension == config.maximumTextureDimension)
                #expect(resolved.adaptsToSystemPressure)
            }
        }
    }

    @Test func pressureNeverRaisesUserCapsOrChangesAnOptedOutConfiguration() {
        let low = GameRenderConfiguration(resolutionScale: 0.25, preferredFramesPerSecond: 15,
            maximumRenderPixels: 1000, maximumTextureDimension: 64, adaptsToSystemPressure: true)
        for thermal: GameRenderEnvironment.ThermalState in [.nominal, .fair, .serious, .critical] {
            let environment = GameRenderEnvironment(thermalState: thermal, isLowPowerModeEnabled: true)
            #expect(low.resolved(in: environment) == low)
            let optedOut = GameRenderConfiguration()
            #expect(optedOut.resolved(in: environment) == optedOut)
        }
        let critical = GameRenderConfiguration(adaptsToSystemPressure: true)
            .resolved(in: .init(thermalState: .critical))
        #expect(critical.resolved(in: .init()) == critical)
        #expect(GameRenderEnvironment() == .init(thermalState: .nominal, isLowPowerModeEnabled: false))
    }

    @Test(arguments: [15, 24, 30, 60, 120])
    func pressureRetainsLowerUserFrameCaps(_ fps: Int) {
        let config = GameRenderConfiguration(preferredFramesPerSecond: fps, adaptsToSystemPressure: true)
        #expect(config.resolved(in: .init(thermalState: .serious)).preferredFramesPerSecond == min(fps, 30))
        #expect(config.resolved(in: .init(thermalState: .critical)).preferredFramesPerSecond == min(fps, 20))
        #expect(config.resolved(in: .init(isLowPowerModeEnabled: true)).preferredFramesPerSecond == min(fps, 30))
    }

    @Test func budgetSumsCanvasAndEveryPaneIncludingOverlaps() {
        let size = CGSize(width: 100, height: 80)
        let panes = [CGRect(x: 0, y: 0, width: 60, height: 80),
                     CGRect(x: 60, y: 0, width: 40, height: 80),
                     CGRect(x: 5, y: 5, width: 10, height: 10)]
        let config = GameRenderConfiguration(resolutionScale: 0.5)
        let plan = GameRenderPlan(logicalSize: size, displayScale: 2, viewportRects: panes, configuration: config)
        #expect(plan.isValid)
        #expect(plan.drawableSize == size)
        #expect(plan.panePixelRects == panes)
        #expect(plan.totalRenderPixels == 8000 + 4800 + 3200 + 100)
        #expect(plan.effectiveResolutionScale == 0.5)
        expectWithinLimits(plan, configuration: config)
    }

    @Test func mirrorReservesThreeSelectedPaneCopies() {
        let size = CGSize(width: 100, height: 80)
        let panes = [CGRect(x: 0, y: 0, width: 25, height: 80),
                     CGRect(x: 25, y: 0, width: 75, height: 80)]
        let config = GameRenderConfiguration()
        let selected = GameRenderPlan(logicalSize: size, displayScale: 1, viewportRects: panes,
            configuration: config, presentationViewportIndex: 0, presentationCopies: 3)
        #expect(selected.totalRenderPixels == 22_000)
        let canvas = GameRenderPlan(logicalSize: size, displayScale: 1, viewportRects: panes,
            configuration: config, presentationCopies: 3)
        #expect(canvas.totalRenderPixels == 40_000)
        let capped = GameRenderPlan(logicalSize: size, displayScale: 1, viewportRects: panes,
            configuration: config, presentationViewportIndex: 0, presentationCopies: Int.max)
        #expect(capped.totalRenderPixels == selected.totalRenderPixels)
        let negative = GameRenderPlan(logicalSize: size, displayScale: 1, viewportRects: panes,
            configuration: config, presentationCopies: Int.min)
        #expect(negative.totalRenderPixels == 16_000)
    }

    @Test func mirrorCopiesParticipateInResolutionReduction() {
        let size = CGSize(width: 100, height: 100)
        let full = CGRect(origin: .zero, size: size)
        let config = GameRenderConfiguration(maximumRenderPixels: 10_000)
        let plan = GameRenderPlan(logicalSize: size, displayScale: 3, viewportRects: [full],
            configuration: config, presentationViewportIndex: 0, presentationCopies: 3)
        #expect(plan.isValid)
        #expect(plan.totalRenderPixels == 5 * Int(plan.drawableSize.width * plan.drawableSize.height))
        #expect(plan.drawableSize.width < 100)
        #expect(plan.drawableSize.width == plan.drawableSize.height)
        #expect(plan.effectiveResolutionScale < 1)
        expectWithinLimits(plan, configuration: config)
    }

    @Test func bookAndTabletopInsetsRemainInPointSpace() {
        let size = CGSize(width: 800, height: 600)
        let insets = GameSurfaceGeometry.Insets(top: 10, left: 20, bottom: 30, right: 40)
        let folds = [CGRect(x: 390, y: 0, width: 20, height: 600),
                     CGRect(x: 0, y: 290, width: 800, height: 20)]
        for fold in folds {
            let geometry = GameSurfaceGeometry(size: size, displayScale: 2, safeAreaInsets: insets,
                reservedRegions: [.init(id: "fold", kind: .division, frame: fold)])
            let original = geometry
            let panes = geometry.usableRegions()
            #expect(panes.count == 2)
            let config = GameRenderConfiguration(resolutionScale: 0.5)
            let plan = GameRenderPlan(logicalSize: geometry.size, displayScale: geometry.displayScale,
                                      viewportRects: panes, configuration: config)
            #expect(plan.isValid)
            #expect(plan.drawableSize == size)
            #expect(plan.panePixelRects == panes)
            #expect(geometry == original)
            let reducedConfig = GameRenderConfiguration(maximumRenderPixels: 1000)
            let reduced = GameRenderPlan(logicalSize: geometry.size, displayScale: geometry.displayScale,
                viewportRects: panes, configuration: reducedConfig)
            #expect(reduced.isValid)
            #expect(geometry == original)
            #expect(geometry.usableRegions() == panes)
            expectWithinLimits(reduced, configuration: reducedConfig)
        }
    }

    @Test func dimensionLimitReducesGlobalScaleAndPreservesAspect() {
        let size = CGSize(width: 800, height: 600)
        let config = GameRenderConfiguration(maximumTextureDimension: 100)
        let plan = GameRenderPlan(logicalSize: size, displayScale: 2,
            viewportRects: [CGRect(origin: .zero, size: size)], configuration: config)
        #expect(plan.isValid)
        #expect(plan.drawableSize == CGSize(width: 100, height: 75))
        #expect(plan.panePixelRects == [CGRect(x: 0, y: 0, width: 100, height: 75)])
        #expect(plan.effectiveResolutionScale == 0.0625)
        expectWithinLimits(plan, configuration: config)
    }

    @Test func existingDrawablePreservesPreallocatedTargetWithDifferentLogicalAspect() {
        // Parallax callers retain this target when their logical canvas resizes.
        let logicalSize = CGSize(width: 400, height: 180)
        let targetSize = CGSize(width: 256, height: 128)
        let panes = [CGRect(x: 0, y: 0, width: 200, height: 180),
                     CGRect(x: 200, y: 0, width: 200, height: 180)]
        let plan = GameRenderPlan(logicalSize: logicalSize, existingDrawableSize: targetSize,
                                  viewportRects: panes)
        #expect(plan.isValid)
        #expect(plan.drawableSize == targetSize)
        #expect(plan.panePixelRects == [CGRect(x: 0, y: 0, width: 128, height: 128),
                                        CGRect(x: 128, y: 0, width: 128, height: 128)])
        #expect(plan.totalRenderPixels == 65_536)
        #expect(plan.effectiveResolutionScale == 0.64)
        expectWithinLimits(plan, configuration: .init())
    }

    @Test func existingDrawableRoundsSharedHalfPixelEdgesOnBothAxesAndClipsPanes() {
        let logicalSize = CGSize(width: 400, height: 180)
        let targetSize = CGSize(width: 256, height: 128)
        // These independent logical edges land exactly at x=80.5 and y=48.5 pixels.
        let x: CGFloat = 125.78125, y: CGFloat = 68.203125
        let panes = [CGRect(x: 0, y: 0, width: x, height: y),
                     CGRect(x: x, y: 0, width: 400 - x, height: y),
                     CGRect(x: 0, y: y, width: x, height: 180 - y),
                     CGRect(x: x, y: y, width: 400 - x, height: 180 - y),
                     CGRect(x: -10, y: 170, width: 30, height: 20),
                     .zero, .null,
                     CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)]
        let expected = [CGRect(x: 0, y: 0, width: 81, height: 49),
                        CGRect(x: 81, y: 0, width: 175, height: 49),
                        CGRect(x: 0, y: 49, width: 81, height: 79),
                        CGRect(x: 81, y: 49, width: 175, height: 79),
                        CGRect(x: 0, y: 121, width: 13, height: 7),
                        .zero, .zero, .zero]
        for _ in 0..<3 {
            let plan = GameRenderPlan(logicalSize: logicalSize, existingDrawableSize: targetSize,
                                      viewportRects: panes)
            #expect(plan.isValid)
            #expect(plan.drawableSize == targetSize)
            #expect(plan.panePixelRects == expected)
            #expect(plan.panePixelRects[0].maxX == plan.panePixelRects[1].minX)
            #expect(plan.panePixelRects[0].maxY == plan.panePixelRects[2].minY)
            #expect(plan.panePixelRects[3].maxX == targetSize.width)
            #expect(plan.panePixelRects[3].maxY == targetSize.height)
            #expect(plan.totalRenderPixels == 65_536 + 91)
            expectWithinLimits(plan, configuration: .init())
        }
        let reversed = GameRenderPlan(logicalSize: logicalSize, existingDrawableSize: targetSize,
            viewportRects: Array(panes.reversed()))
        #expect(reversed.panePixelRects == Array(expected.reversed()))
        #expect(reversed.totalRenderPixels == 65_536 + 91)
    }

    @Test func existingDrawableRejectsInvalidTargetsAndAllowsNoPanes() {
        let logicalSize = CGSize(width: 400, height: 180)
        let panes = [CGRect(origin: .zero, size: logicalSize)]
        let invalidTargets = [CGSize.zero, CGSize(width: -1, height: 128),
                              CGSize(width: 256, height: 0.5),
                              CGSize(width: CGFloat.nan, height: 128),
                              CGSize(width: 256, height: CGFloat.infinity),
                              CGSize(width: 16_385, height: 128)]
        for target in invalidTargets {
            let plan = GameRenderPlan(logicalSize: logicalSize, existingDrawableSize: target,
                                      viewportRects: panes)
            expectEmpty(plan, paneCount: 1)
        }
        let invalidSource = GameRenderPlan(logicalSize: CGSize(width: 400, height: CGFloat.nan),
            existingDrawableSize: CGSize(width: 256, height: 128), viewportRects: panes)
        expectEmpty(invalidSource, paneCount: 1)
        let canvasOnly = GameRenderPlan(logicalSize: logicalSize,
            existingDrawableSize: CGSize(width: 256, height: 128), viewportRects: [])
        #expect(canvasOnly.isValid)
        #expect(canvasOnly.panePixelRects.isEmpty)
        #expect(canvasOnly.drawableSize == CGSize(width: 256, height: 128))
        #expect(canvasOnly.totalRenderPixels == 32_768)
    }

    @Test func fractionalSharedEdgesAreRoundedIdenticallyAndDeterministically() {
        let size = CGSize(width: 101.5, height: 67.25)
        let split: CGFloat = 37.125
        let panes = [CGRect(x: 0, y: 0, width: split, height: size.height),
                     CGRect(x: split, y: 0, width: size.width - split, height: size.height)]
        let config = GameRenderConfiguration(resolutionScale: 0.75)
        let first = GameRenderPlan(logicalSize: size, displayScale: 1.5,
                                   viewportRects: panes, configuration: config)
        #expect(first.drawableSize == CGSize(width: 114, height: 75))
        #expect(first.panePixelRects[0].maxX == first.panePixelRects[1].minX)
        #expect(first.panePixelRects[0].width + first.panePixelRects[1].width == first.drawableSize.width)
        for _ in 0..<10 {
            let repeated = GameRenderPlan(logicalSize: size, displayScale: 1.5,
                                          viewportRects: panes, configuration: config)
            #expect(repeated.panePixelRects == first.panePixelRects)
            #expect(repeated.totalRenderPixels == first.totalRenderPixels)
        }
        let reversed = GameRenderPlan(logicalSize: size, displayScale: 1.5,
            viewportRects: Array(panes.reversed()), configuration: config)
        #expect(reversed.panePixelRects == Array(first.panePixelRects.reversed()))
        expectWithinLimits(first, configuration: config)
    }

    @Test func clippingInvalidAndMissingPanesPreservesInputIndices() {
        let invalid: [CGRect] = [.zero, .null, .infinite,
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
            CGRect(x: 5, y: 5, width: -10, height: 10),
            CGRect(x: 200, y: 0, width: 10, height: 10)]
        let partial = CGRect(x: -10, y: 70, width: 30, height: 30)
        let panes = [partial] + invalid
        let config = GameRenderConfiguration()
        for index in [nil, -1, 0, 1, 999] as [Int?] {
            let plan = GameRenderPlan(logicalSize: CGSize(width: 100, height: 80), displayScale: 1,
                viewportRects: panes, configuration: config, presentationViewportIndex: index,
                presentationCopies: 3)
            #expect(plan.isValid)
            #expect(plan.panePixelRects.count == panes.count)
            #expect(plan.panePixelRects[0] == CGRect(x: 0, y: 70, width: 20, height: 10))
            #expect(plan.panePixelRects.dropFirst().allSatisfy { $0 == .zero })
            let copyPixels = index == nil ? 8000 : (index == 0 ? 200 : 0)
            #expect(plan.totalRenderPixels == 8200 + 3 * copyPixels)
        }
        let noPanes = GameRenderPlan(logicalSize: CGSize(width: 100, height: 80), displayScale: 1,
            viewportRects: [], configuration: config, presentationViewportIndex: 0, presentationCopies: 3)
        #expect(noPanes.isValid)
        #expect(noPanes.panePixelRects.isEmpty)
        #expect(noPanes.totalRenderPixels == 8000)
    }

    @Test func tinyClippedPanesMayRoundToZeroWithoutLosingTheirIndices() {
        let plan = GameRenderPlan(logicalSize: CGSize(width: 100, height: 100), displayScale: 1,
            viewportRects: [CGRect(x: 10, y: 20, width: 0.01, height: 0.01),
                            CGRect(x: 10, y: 20, width: 10, height: 10)],
            configuration: .init(), presentationViewportIndex: 0, presentationCopies: 3)
        #expect(plan.isValid)
        #expect(plan.panePixelRects == [.zero, CGRect(x: 10, y: 20, width: 10, height: 10)])
        #expect(plan.totalRenderPixels == 10_100)
    }

    @Test func fractionalVerticalSharedEdgesMatchAfterBudgetReduction() {
        let size = CGSize(width: 67.25, height: 101.5)
        let split: CGFloat = 37.125
        let panes = [CGRect(x: 0, y: 0, width: size.width, height: split),
                     CGRect(x: 0, y: split, width: size.width, height: size.height - split)]
        let config = GameRenderConfiguration(maximumRenderPixels: 1000)
        let plan = GameRenderPlan(logicalSize: size, displayScale: 2.75, viewportRects: panes,
            configuration: config, presentationViewportIndex: 1, presentationCopies: 3)
        #expect(plan.isValid)
        #expect(plan.panePixelRects[0].maxY == plan.panePixelRects[1].minY)
        #expect(plan.panePixelRects[1].maxY == plan.drawableSize.height)
        expectWithinLimits(plan, configuration: config)
    }

    @Test func impossibleMinimumBudgetReturnsAnEntirelyZeroPlan() {
        let panes = Array(repeating: CGRect(x: 0, y: 0, width: 100, height: 100), count: 64)
        let plan = GameRenderPlan(logicalSize: CGSize(width: 100, height: 100), displayScale: 2,
            viewportRects: panes, configuration: .init(maximumRenderPixels: 64), presentationCopies: 3)
        expectEmpty(plan, paneCount: panes.count)
        let exactlyFits = GameRenderPlan(logicalSize: CGSize(width: 1, height: 1), displayScale: 1,
            viewportRects: Array(panes.prefix(60)), configuration: .init(maximumRenderPixels: 64),
            presentationCopies: 3)
        #expect(exactlyFits.isValid)
        #expect(exactlyFits.totalRenderPixels == 64)
    }

    @Test func invalidSourceSizesAndScalesReturnZeroPlans() {
        let sizes = [CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: 20, height: 0),
                     CGSize(width: CGFloat.nan, height: 20), CGSize(width: 20, height: CGFloat.nan),
                     CGSize(width: CGFloat.infinity, height: 20), CGSize(width: 20, height: -CGFloat.infinity)]
        let pane = CGRect(x: 0, y: 0, width: 10, height: 10)
        for size in sizes {
            let plan = GameRenderPlan(logicalSize: size, displayScale: 1, viewportRects: [pane],
                                      configuration: .init(), presentationCopies: 3)
            expectEmpty(plan, paneCount: 1)
        }
        for scale: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
            let plan = GameRenderPlan(logicalSize: CGSize(width: 10, height: 10), displayScale: scale,
                                      viewportRects: [pane], configuration: .init())
            expectEmpty(plan, paneCount: 1)
        }
    }

    @Test func extremeFiniteInputsStayWithinLimitsWithoutOverflow() {
        let huge = CGFloat.greatestFiniteMagnitude
        let sizes = [CGSize(width: huge, height: huge / 2), CGSize(width: huge, height: 1),
                     CGSize(width: 1, height: huge), CGSize(width: 0.0001, height: 0.0002),
                     CGSize(width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude)]
        let config = GameRenderConfiguration(maximumRenderPixels: Int.max, maximumTextureDimension: Int.max)
        for size in sizes {
            for scale: CGFloat in [1, huge, .leastNonzeroMagnitude] {
                let plan = GameRenderPlan(logicalSize: size, displayScale: scale,
                    viewportRects: [CGRect(origin: .zero, size: size)], configuration: config,
                    presentationCopies: 3)
                #expect(plan.isValid)
                #expect(plan.effectiveResolutionScale.isFinite)
                #expect(plan.effectiveResolutionScale >= 0)
                expectWithinLimits(plan, configuration: config)
            }
        }
    }

    @Test func gridBudgetsRemainSafeAcrossFractionalScalesAndCopyCounts() {
        let size = CGSize(width: 997.5, height: 613.25)
        let panes = (0..<7).map { index in
            let left = size.width * CGFloat(index) / 7
            let right = size.width * CGFloat(index + 1) / 7
            return CGRect(x: left, y: 0, width: right - left, height: size.height)
        }
        for budget in [64, 1000, 50_000, 1_000_000] {
            for scale: CGFloat in [0.5, 1.25, 3] {
                for copies in 0...3 {
                    let config = GameRenderConfiguration(maximumRenderPixels: budget)
                    let plan = GameRenderPlan(logicalSize: size, displayScale: scale, viewportRects: panes,
                        configuration: config, presentationViewportIndex: 3, presentationCopies: copies)
                    #expect(plan.isValid)
                    expectWithinLimits(plan, configuration: config)
                    let expected = Int(plan.drawableSize.width * plan.drawableSize.height)
                        + plan.panePixelRects.reduce(0) { $0 + Int($1.width * $1.height) }
                        + copies * Int(plan.panePixelRects[3].width * plan.panePixelRects[3].height)
                    #expect(plan.totalRenderPixels == expected)
                    for index in 1..<panes.count {
                        let left = plan.panePixelRects[index - 1], right = plan.panePixelRects[index]
                        if !left.isEmpty && !right.isEmpty { #expect(left.maxX == right.minX) }
                    }
                }
            }
        }
    }

    @Test func statisticsDefaultEstimatesAndCountersCanBeOverridden() {
        let basic = statistics()
        #expect(basic.logicalSize == CGSize(width: 100, height: 80))
        #expect(basic.drawableSize == CGSize(width: 50, height: 40))
        #expect(basic.renderedViewportCount == 2)
        #expect(basic.renderPixels == 4000)
        #expect(basic.estimatedRenderTargetBytes == 16_000)
        #expect(basic.effectiveResolutionScale == 0.5)
        #expect(basic.preferredFramesPerSecond == 24)
        #expect(basic.frameNumber == 0 && basic.presentationFrameCount == 0 && basic.droppedPresentationFrames == 0)
        #expect(basic == statistics())
        let explicit = GameRenderStatistics(logicalSize: .zero, drawableSize: .zero, renderedViewportCount: 0,
            renderPixels: Int.max, estimatedRenderTargetBytes: 12, effectiveResolutionScale: 1,
            preferredFramesPerSecond: 15, frameNumber: 8, presentationFrameCount: 6, droppedPresentationFrames: 2)
        #expect(explicit.estimatedRenderTargetBytes == 12)
        #expect(explicit.frameNumber == 8 && explicit.presentationFrameCount == 6 && explicit.droppedPresentationFrames == 2)
        let overflow = GameRenderStatistics(logicalSize: .zero, drawableSize: .zero, renderedViewportCount: 0,
            renderPixels: Int.max, effectiveResolutionScale: 1, preferredFramesPerSecond: 60)
        #expect(overflow.estimatedRenderTargetBytes == Int.max)
    }

    @MainActor @Test func monitorRespectsEnabledStateAndCanClear() {
        let monitor = GameRenderMonitor()
        #expect(monitor.isEnabled && monitor.latest == nil)
        let first = statistics()
        monitor.record(first)
        #expect(monitor.latest == first)
        monitor.isEnabled = false
        monitor.record(GameRenderStatistics(logicalSize: .zero, drawableSize: .zero,
            renderedViewportCount: 0, renderPixels: 0, effectiveResolutionScale: 1, preferredFramesPerSecond: 60))
        #expect(monitor.latest == first)
        monitor.clear()
        #expect(monitor.latest == nil && !monitor.isEnabled)
        monitor.isEnabled = true
        monitor.record(first)
        #expect(monitor.latest == first)
    }

    private func statistics() -> GameRenderStatistics {
        GameRenderStatistics(logicalSize: CGSize(width: 100, height: 80), drawableSize: CGSize(width: 50, height: 40),
            renderedViewportCount: 2, renderPixels: 4000, effectiveResolutionScale: 0.5, preferredFramesPerSecond: 24)
    }

    private func expectEmpty(_ plan: GameRenderPlan, paneCount: Int) {
        #expect(!plan.isValid)
        #expect(plan.drawableSize == .zero)
        #expect(plan.panePixelRects == Array(repeating: .zero, count: paneCount))
        #expect(plan.totalRenderPixels == 0)
        #expect(plan.effectiveResolutionScale == 0)
    }

    private func expectWithinLimits(_ plan: GameRenderPlan, configuration: GameRenderConfiguration) {
        #expect(plan.isValid)
        #expect(plan.totalRenderPixels > 0 && plan.totalRenderPixels <= configuration.maximumRenderPixels)
        #expect(plan.drawableSize.width >= 1 && plan.drawableSize.height >= 1)
        #expect(plan.drawableSize.width <= CGFloat(configuration.maximumTextureDimension))
        #expect(plan.drawableSize.height <= CGFloat(configuration.maximumTextureDimension))
        #expect(plan.drawableSize.width.rounded(.down) == plan.drawableSize.width)
        #expect(plan.drawableSize.height.rounded(.down) == plan.drawableSize.height)
        for pane in plan.panePixelRects {
            #expect(pane.minX >= 0 && pane.minY >= 0)
            #expect(pane.maxX <= plan.drawableSize.width && pane.maxY <= plan.drawableSize.height)
            #expect(pane.width <= CGFloat(configuration.maximumTextureDimension))
            #expect(pane.height <= CGFloat(configuration.maximumTextureDimension))
            #expect(pane.minX.rounded() == pane.minX && pane.minY.rounded() == pane.minY)
            #expect(pane.width.rounded() == pane.width && pane.height.rounded() == pane.height)
        }
    }
}

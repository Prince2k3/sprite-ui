import Observation
import SpriteUI
import SwiftUI

/// View-owned display preferences; the host decides when to publish frames and statistics.
@MainActor @Observable
final class DemoBotsDisplaySettings {
    enum Quality: String, CaseIterable {
        case balanced, batterySaver, highRefresh

        var title: String {
            switch self {
            case .balanced: "Balanced"
            case .batterySaver: "Battery Saver"
            case .highRefresh: "High Refresh"
            }
        }
    }

    var quality: Quality = .balanced
    var showsPreview = false
    var externalEnabled = false
    var externalAvailable = false
    let monitor = GameRenderMonitor()
    let source = GamePresentationSource(viewportID: DemoBotsSurfaceLayout.viewportID)

    var configuration: GameRenderConfiguration {
        switch quality {
        case .balanced:
            GameRenderConfiguration(resolutionScale: 1, preferredFramesPerSecond: 60,
                                    maximumRenderPixels: 16_777_216, adaptsToSystemPressure: true)
        case .batterySaver:
            GameRenderConfiguration(resolutionScale: 0.75, preferredFramesPerSecond: 30,
                                    maximumRenderPixels: 8_388_608, adaptsToSystemPressure: true)
        case .highRefresh:
            GameRenderConfiguration(resolutionScale: 1, preferredFramesPerSecond: 120,
                                    maximumRenderPixels: 16_777_216, adaptsToSystemPressure: true)
        }
    }

    var presentation: GamePresentationSource? {
        (showsPreview || externalEnabled) ? source : nil
    }
}

@MainActor
struct DemoBotsDisplayPanel: View {
    @Bindable var settings: DemoBotsDisplaySettings
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Display settings").font(.title2.bold())
                    Spacer(minLength: 8)
                    Button(action: onClose) {
                        Text("Close").frame(minWidth: 44, minHeight: 44)
                    }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("display-settings-close")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Render quality").font(.headline)
                    Picker("Render quality", selection: $settings.quality) {
                        ForEach(DemoBotsDisplaySettings.Quality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Requested scale: \(settings.configuration.resolutionScale, format: .percent). Preferred presentation rate: \(settings.configuration.preferredFramesPerSecond) FPS.")
                    Text("FPS is a preference, not an achieved frame rate. System pressure may lower scale and rate without changing simulation timing.")
                        .foregroundStyle(.secondary)
                    Text("Render-target budget: \(settings.configuration.maximumRenderPixels, format: .number) pixels. Target memory estimates exclude other GPU allocations.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                Divider()
                Toggle("Local read-only preview", isOn: $settings.showsPreview).tint(.mint)
                if settings.showsPreview {
                    GamePresentationView(source: settings.source)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .background(.black, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if settings.presentation != nil {
                    DemoBotsPresentationStatus(source: settings.source)
                }
                Text("Presentation shares only the gameplay viewport. It excludes the HUD and menus and accepts no input.")
                    .font(.footnote).foregroundStyle(.secondary)
                externalControls
                Divider()
                DemoBotsRenderStatistics(monitor: settings.monitor)
            }
            .padding(24)
            .frame(maxWidth: 610, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var externalControls: some View {
#if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("External read-only display", isOn: $settings.externalEnabled).tint(.mint)
                Text(settings.externalAvailable ? "External display role: Available" : "External display role: Unavailable")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Role availability is separate from source-frame availability. Enable to present when an external role is available.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text("External display requires iOS 27 or later.")
                .font(.footnote).foregroundStyle(.secondary)
        }
#else
        Text("External display is available on iOS 27 or later, excluding Mac Catalyst.")
            .font(.footnote).foregroundStyle(.secondary)
#endif
    }
}

/// Observe frame availability here, without making the panel depend on frame updates.
@MainActor
private struct DemoBotsPresentationStatus: View {
    let source: GamePresentationSource

    var body: some View {
        Text(source.isAvailable ? "Source frame: Available" : "Source frame: Waiting for the gameplay viewport")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

/// The live monitor is read only in this leaf, away from the game host's body.
@MainActor
private struct DemoBotsRenderStatistics: View {
    let monitor: GameRenderMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live render statistics").font(.headline)
            if let stats = monitor.latest {
                Text("Drawable: \(Int(stats.drawableSize.width)) × \(Int(stats.drawableSize.height)) pixels")
                Text("Effective scale: \(stats.effectiveResolutionScale, format: .percent.precision(.fractionLength(1)))")
                Text("Preferred presentation rate: \(stats.preferredFramesPerSecond) FPS")
                Text("Rendered viewports: \(stats.renderedViewportCount)")
                Text("Render-plan reservation: \(stats.renderPixels, format: .number) pixels")
                Text("Estimated target memory: \(Double(stats.estimatedRenderTargetBytes) / 1_048_576, format: .number.precision(.fractionLength(1))) MiB")
                Text("Frame: \(stats.frameNumber) · Presentation frames: \(stats.presentationFrameCount) · Dropped: \(stats.droppedPresentationFrames)")
            } else {
                Text("Waiting for render statistics…").foregroundStyle(.secondary)
            }
        }
        .font(.footnote).monospacedDigit()
    }
}

@MainActor
struct DemoBotsExternalDisplay: ViewModifier {
    let settings: DemoBotsDisplaySettings

    @ViewBuilder func body(content: Content) -> some View {
#if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            content.gameExternalDisplay(settings.source, isEnabled: settings.externalEnabled) { available in
                settings.externalAvailable = available
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

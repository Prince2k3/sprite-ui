import ECSCore
import Foundation
import Observation
import SpriteBackend
import SwiftUI

/// Panel frames are recorded in global SwiftUI coordinates, like gesture starts.
/// Convert using the host's current frame so padding and moving hosts stay safe.
@MainActor @Observable
final class SceneDebugInputState {
    var isActive = true
    var isPicking = false
    var panelFrame: CGRect?

    func reset() { isPicking = false; panelFrame = nil }
}

extension GameHost {
    var isDebugPicking: Bool {
        debugInput.isActive && debugInput.isPicking
            && activeDebugController?.options.contains(.selection) == true
    }

    func debugPanelContains(_ point: CGPoint) -> Bool {
        guard debugInput.isActive, let controller = activeDebugController,
              !controller.options.intersection([.statistics, .inspector, .simulationControls, .selection]).isEmpty,
              let panel = debugInput.panelFrame else { return false }
        return panel.contains(CGPoint(x: point.x + viewFrame.minX, y: point.y + viewFrame.minY))
    }

    func debugBlocksInput(at point: CGPoint) -> Bool {
        isDebugPicking || debugPanelContains(point)
    }

    func setDebugPicking(_ picking: Bool) {
        let enabled = picking && debugInput.isActive
            && activeDebugController?.options.contains(.selection) == true
        guard enabled != debugInput.isPicking else { return }
        cancelInputs()
        debugInput.isPicking = enabled
    }

    func reportDebugPanel(_ frame: CGRect) {
        guard debugInput.isActive, activeDebugController != nil,
              !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return }
        debugInput.panelFrame = frame
    }

    @discardableResult
    func pickDebugEntity(atView point: CGPoint) -> Entity.ID? {
        guard isDebugPicking, attachmentStore.acceptsInput,
              CGRect(origin: .zero, size: renderer.size).contains(point),
              !debugPanelContains(point), !attachmentStore.blocksInput(at: point),
              let controller = activeDebugController else { return nil }
        return controller.select(atView: point)
    }
}

/// Opt-in controls occupy a compact corner; only explicit picking adds a full
/// scene tap layer. Attachments are hosted above this entire overlay by GameView.
@MainActor
struct SceneDebugOverlay: View {
    let controller: SceneDebugController
    let host: GameHost
    @State private var expanded = false
    @State private var showsTimings = false
    @State private var showsInspector = false
    @State private var showsHierarchy = false

    private var isBound: Bool {
        controller.isAttached && controller.scene === host.world
            && host.activeDebugController === controller
    }

    private var hasPanel: Bool {
        !controller.options.intersection([.statistics, .inspector, .simulationControls, .selection]).isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            if isBound, host.debugInput.isActive {
                ZStack(alignment: .topTrailing) {
                    if host.isDebugPicking {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                                let point = CGPoint(x: tap.location.x - host.viewFrame.minX,
                                                    y: tap.location.y - host.viewFrame.minY)
                                host.pickDebugEntity(atView: point)
                            })
                            .accessibilityLabel("Pick a scene entity")
                    }
                    if hasPanel {
                        panel(maxHeight: max(44, min(480, geometry.size.height * 0.65)))
                            .frame(width: min(340, max(0, geometry.size.width - 16)))
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                host.reportDebugPanel($0)
                            }
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .onChange(of: controller.options) { _, options in
            if !options.contains(.selection) { host.setDebugPicking(false) }
            if !hasPanel { host.debugInput.panelFrame = nil }
        }
        .onDisappear { host.debugInput.reset() }
    }

    private func panel(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                if !expanded { host.setDebugPicking(false) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "ladybug")
                    Text("Debug").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if controller.options.contains(.statistics) {
                        Text("\(controller.snapshot.framesPerSecond, specifier: "%.0f") FPS · Sim \(controller.snapshot.simulationFrameNumber)")
                            .monospacedDigit()
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .padding(12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse scene debug" : "Expand scene debug")

            if expanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.options.contains(.simulationControls) { simulationControls }
                        if controller.options.contains(.selection) { selectionControls }
                        if controller.options.contains(.inspector) { inspector }
                        if controller.options.contains(.statistics) { statistics }
                    }
                    .padding(12)
                }
                .frame(maxHeight: max(0, maxHeight - 45))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    private var simulationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(controller.isPaused ? "Resume" : "Pause",
                       systemImage: controller.isPaused ? "play.fill" : "pause.fill") {
                    controller.isPaused.toggle()
                }
                Button(controller.isStepPending ? "Step pending" : "Step", systemImage: "forward.frame") {
                    _ = controller.stepFrame()
                }
                .disabled(!controller.canStep)
            }
            .buttonStyle(.bordered)
            HStack {
                Text("Time scale")
                Slider(value: Binding(get: { controller.timeScale }, set: { controller.timeScale = $0 }),
                       in: 0...4, step: 0.25)
                    .accessibilityLabel("Simulation time scale")
                Text("\(controller.timeScale, specifier: "%.2f")×")
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    private var selectionControls: some View {
        HStack {
            Button(host.isDebugPicking ? "Done picking" : "Pick entity", systemImage: "scope") {
                host.setDebugPicking(!host.isDebugPicking)
            }
            .buttonStyle(.bordered)
            .accessibilityValue(host.isDebugPicking ? "On" : "Off")
            Button("Clear") { controller.clearSelection() }
                .disabled(controller.selectedEntityID == nil)
        }
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 5) {
            let snapshot = controller.snapshot
            Text("Render FPS \(snapshot.framesPerSecond, specifier: "%.1f") · Sim frame \(snapshot.simulationFrameNumber)")
            Text("Entities \(snapshot.activeEntityCount)/\(snapshot.entityCount) active · Nodes \(snapshot.nodeCount)")
            Text("Debug nodes \(snapshot.overlayNodeCount) · Playbacks \(snapshot.activePlaybackCount)")
            DisclosureGroup("System timings", isExpanded: $showsTimings) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(snapshot.systems.enumerated()), id: \.offset) { _, timing in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(timing.name) (\(String(describing: timing.phase)))")
                            Spacer(minLength: 4)
                            Text("\(timing.duration * 1_000, specifier: "%.3f") ms").monospacedDigit()
                        }
                    }
                    if snapshot.systems.isEmpty { Text("No system timings yet").foregroundStyle(.secondary) }
                }
                .padding(.top, 4)
            }
        }
    }

    private var inspector: some View {
        DisclosureGroup("Entity inspector", isExpanded: $showsInspector) {
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup("Hierarchy", isExpanded: $showsHierarchy) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.snapshot.entities, id: \.id) { entity in
                            Button {
                                guard let live = controller.scene?.entity(withID: entity.id),
                                      live.world === host.world else { return }
                                _ = controller.select(live)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Image(systemName: controller.selectedEntityID == entity.id ? "checkmark.circle.fill" : "circle")
                                    Text(entity.name.isEmpty ? "Entity \(entity.id)" : entity.name)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                    if !entity.isActive { Text("inactive").foregroundStyle(.secondary) }
                                }
                                .padding(.leading, CGFloat(hierarchyDepth(of: entity)) * 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 132)
                }
                if controller.snapshot.inspectionTruncated {
                    Text("Inspection limited to 500 entities").foregroundStyle(.secondary)
                }
                if let selected = controller.snapshot.entities.first(where: { $0.id == controller.selectedEntityID }) {
                    selectedDetails(selected)
                } else if controller.selectedEntityID != nil {
                    Text("Selected entity is outside the inspection limit.").foregroundStyle(.secondary)
                } else {
                    Text("Choose an entity above or enable Pick entity.").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private func hierarchyDepth(of entity: SceneDebugEntity) -> Int {
        var depth = 0
        var parentID = entity.parentID
        let entities = controller.snapshot.entities
        while let id = parentID, depth < 12,
              let parent = entities.first(where: { $0.id == id }) {
            depth += 1; parentID = parent.parentID
        }
        return depth
    }

    private func selectedDetails(_ entity: SceneDebugEntity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(entity.name.isEmpty ? "Entity" : entity.name) #\(entity.id)").fontWeight(.semibold)
            Text("Enabled: \(entity.isEnabled ? "yes" : "no") · Active: \(entity.isActive ? "yes" : "no")")
            Text("Scene position: \(entity.scenePosition.x, specifier: "%.1f"), \(entity.scenePosition.y, specifier: "%.1f")")
            Text("Local: \(entity.transform.translation.x, specifier: "%.1f"), \(entity.transform.translation.y, specifier: "%.1f") · Rotation: \(entity.transform.rotation, specifier: "%.2f")")
            Text("Presented: \(entity.presentedTransform.translation.x, specifier: "%.1f"), \(entity.presentedTransform.translation.y, specifier: "%.1f")")
            ForEach(Array(entity.components.enumerated()), id: \.offset) { _, component in
                Text("\(component.name): \(component.summary)")
            }
            ForEach(Array(entity.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label(diagnostic, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .textSelection(.enabled)
    }
}

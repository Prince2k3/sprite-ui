import SwiftUI

@main
struct SpriteUIDemoApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Animation", systemImage: "wand.and.stars") { DemoView() }
                Tab("Random", systemImage: "dice") { RandomDemoView() }
                Tab("States", systemImage: "arrow.triangle.branch") { StateMachineDemoView() }
                Tab("Paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { PathfindingDemoView() }
                Tab("Spatial", systemImage: "circle.dotted.circle") { SpatialDemoView() }
                Tab("Steering", systemImage: "bird") { SteeringDemoView() }
                Tab("Noise", systemImage: "cloud") { NoiseDemoView() }
                Tab("Decisions", systemImage: "questionmark.diamond") { DecisionDemoView() }
                Tab("Strategists", systemImage: "circle.grid.3x3.fill") { StrategistDemoView() }
            }
        }
    }
}

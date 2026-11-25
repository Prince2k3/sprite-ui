import Foundation
import DemoBotsGame
import SwiftUI

@main
struct DemoBotsApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            DemoBotsView(
                presentsGameCenterLab: ProcessInfo.processInfo.environment["DEMOBOTS_GAME_CENTER_TESTING"] == "1" || ProcessInfo.processInfo.arguments.contains("--game-center-lab"),
                usesNativeGameCenterForTesting: ProcessInfo.processInfo.environment["DEMOBOTS_GAME_CENTER_TESTING"] == "1"
            )
            #else
            DemoBotsView()
            #endif
        }
    }
}

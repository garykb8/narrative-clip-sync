import SwiftUI

@main
struct ClipSyncApp: App {
    @State private var controller = SyncController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Narrative Clip", id: "browser") {
            BrowserView(controller: controller)
        }
        .defaultSize(width: 1100, height: 720)
        // Normally opened from the menu; CLIPSYNC_OPEN_BROWSER=1 opens it at launch (for development).
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["CLIPSYNC_OPEN_BROWSER"] == nil ? .suppressed : .presented)

        Settings {
            SettingsView(controller: controller)
        }
    }
}

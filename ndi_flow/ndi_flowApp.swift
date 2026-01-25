//
//  ndi_flowApp.swift
//  ndi_flow
//
//  Entry point for the ndi_flow macOS app.
//  Wires up the shared PersistenceController's ModelContainer into the SwiftUI environment.
//
//  Target: macOS 15+, SwiftUI 6, SwiftData
//

import SwiftUI
import SwiftData

@main
struct ndi_flowApp: App {
    // Shared persistence controller that manages the ModelContainer lifecycle.
    // The PersistenceController is expected to provide a `container: ModelContainer` property.
    let persistenceController = PersistenceController.shared

    init() {
        // Perform any early app configuration here.
        // Keep lightweight to meet the launch-time goal (defer heavy work).
        // e.g. configure global appearance or logging if needed.
    }

    var body: some Scene {
        WindowGroup {
            // ContentView is the main app UI. Provide the shared ModelContainer
            // so all SwiftData model contexts are available via the environment.
            ContentView()
                .modelContainer(persistenceController.container)
        }

        // Settings window (accessible via Cmd+, or app menu)
        Settings {
            SettingsView()
                .modelContainer(persistenceController.container)
        }
    }
}

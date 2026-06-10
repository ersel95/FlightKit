//
//  FlightKitApp.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

@main
@MainActor
struct FlightKitApp: App {
    @State private var store = ProjectStore()
    /// Sparkle auto-updater — checks the GitHub appcast on launch and offers any
    /// newer notarized build (notify + confirm, never silent). See `UpdaterView`.
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup("FlightKit") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.controller.updater)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

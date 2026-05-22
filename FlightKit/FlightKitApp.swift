//
//  FlightKitApp.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

@main
struct FlightKitApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup("FlightKit") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}

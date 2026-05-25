//
//  UpdaterView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import Sparkle

/// Owns Sparkle's updater. `startingUpdater: true` begins the background update
/// scheduler immediately, which — with `SUEnableAutomaticChecks` in Info.plist —
/// checks the appcast on launch and on a daily interval. `SUAutomaticallyUpdate`
/// is false, so a found update is *offered* (notify + confirm), never silently
/// installed; Sparkle presents its standard "new version available" dialog.
@MainActor
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

/// Tracks whether a manual update check is currently allowed, so the menu item
/// can disable itself while a check is already in flight.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu item, wired to Sparkle.
@MainActor
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Güncellemeleri Denetle…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

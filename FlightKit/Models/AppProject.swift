//
//  AppProject.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// A build target variant of a project: a single Xcode build configuration paired
/// with the bundle id that configuration ships under. Switching this is how you
/// target different environments (e.g. Test / UAT / Prod) — the configuration
/// drives the active scheme settings and each one resolves to a distinct App
/// Store Connect app record via its bundle id.
struct AppEnvironment: Identifiable, Codable, Hashable {
    var name: String              // Display label, e.g. "Prod", "Test", "UAT"
    var configuration: String     // Exact xcodebuild -configuration value
    var bundleIdentifier: String  // Drives ASC app lookup + version polling

    var id: String { name }
}

/// One app FlightKit can publish. Stored in the user's Application Support catalog
/// (`ProjectStore`) — there is no bundled list, every project is user-added.
struct AppProject: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var displayName: String
    /// Absolute path to the `.xcworkspace` or `.xcodeproj` to build. The build
    /// container is selected directly so a folder with several projects is fine.
    var containerPath: String
    var schemeName: String
    /// Effective configuration + bundle id (default = first environment). `applying(_:)`
    /// overrides these per environment; the publish pipeline reads them.
    var configuration: String
    var bundleIdentifier: String
    var teamId: String
    var environments: [AppEnvironment]?
    /// Optional Microsoft Teams deep link (`https://teams.microsoft.com/l/chat/…`)
    /// of the chat/channel to notify once a publish finishes. Stored locally only
    /// (App Support catalog) — it grants the ability to post into that chat, so it
    /// is treated like a secret and never committed. Optional so existing catalogs
    /// decode unchanged.
    var teamsChatLink: String?
    /// Whether to post a release notification to `teamsChatLink` after a successful
    /// batch. Optional (defaults to off) so old projects.json decodes unchanged.
    var teamsNotifyEnabled: Bool?

    /// True only when notifications are switched on *and* a link is present.
    var teamsNotificationsActive: Bool {
        teamsNotifyEnabled == true && !(teamsChatLink?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var containerURL: URL { URL(fileURLWithPath: containerPath) }

    /// Parent directory of the container — used as the search root for the
    /// `.xcconfig` files holding MARKETING_VERSION / CURRENT_PROJECT_VERSION.
    var workspaceRoot: URL { containerURL.deletingLastPathComponent() }

    private var isWorkspace: Bool { containerURL.pathExtension.lowercased() == "xcworkspace" }

    /// Every selectable environment. When none are declared we synthesize one from
    /// the top-level fields so a single-config project still works.
    var resolvedEnvironments: [AppEnvironment] {
        if let environments, !environments.isEmpty { return environments }
        return [AppEnvironment(name: configuration, configuration: configuration, bundleIdentifier: bundleIdentifier)]
    }

    /// The `-workspace <path>` / `-project <path>` argument pair for xcodebuild.
    /// Workspaces are required when local SPM packages are wired at the workspace
    /// level — `-project` archiving can't see workspace-scoped package products.
    var xcodebuildContainerArguments: [String] {
        [isWorkspace ? "-workspace" : "-project", containerPath]
    }

    /// A copy pinned to `environment`'s configuration + bundle id. `id`, `schemeName`
    /// and `teamId` are preserved: the ASC API key is account-scoped (one key serves
    /// every app record) so keychain lookup stays keyed on the stable project id.
    func applying(_ environment: AppEnvironment) -> AppProject {
        var copy = self
        copy.configuration = environment.configuration
        copy.bundleIdentifier = environment.bundleIdentifier
        return copy
    }
}

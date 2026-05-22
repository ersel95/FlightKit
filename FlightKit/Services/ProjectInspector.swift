//
//  ProjectInspector.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// What auto-fill extracts from a selected `.xcworkspace` / `.xcodeproj`.
struct ProjectInspection {
    var displayName: String
    var schemes: [String]
    var suggestedScheme: String
    var teamId: String
    /// One environment per build configuration (name = configuration), each with
    /// the bundle id that configuration resolves to.
    var environments: [AppEnvironment]
}

/// Reads project metadata via `xcodebuild` — current version (for the detail view)
/// and full schema/configuration/bundle-id discovery (for Add App auto-fill).
enum ProjectInspector {
    /// Persistent SPM checkout cache shared with the publish pipeline so inspection
    /// doesn't re-resolve packages on every call.
    private static var spmCachePath: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "FlightKit/SourcePackages").path
    }

    private static func containerArguments(for url: URL) -> [String] {
        [url.pathExtension.lowercased() == "xcworkspace" ? "-workspace" : "-project", url.path]
    }

    static func resolveBuildVersion(for project: AppProject) async throws -> BuildVersionInfo {
        let settings = try await XcodebuildRunner.showBuildSettings(
            containerArguments: project.xcodebuildContainerArguments,
            scheme: project.schemeName,
            configuration: project.configuration,
            clonedSourcePackagesPath: spmCachePath
        )
        return BuildVersionInfo(
            marketingVersion: settings["MARKETING_VERSION"] ?? "",
            buildNumber: settings["CURRENT_PROJECT_VERSION"] ?? "",
            bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? project.bundleIdentifier,
            teamId: settings["DEVELOPMENT_TEAM"] ?? project.teamId,
            productName: settings["PRODUCT_NAME"] ?? project.schemeName
        )
    }

    /// Inspects a container for Add App auto-fill: schemes, the configurations of
    /// the chosen scheme, and the bundle id + team each configuration ships under.
    static func inspect(containerURL: URL) async throws -> ProjectInspection {
        let containerArgs = containerArguments(for: containerURL)
        let cache = spmCachePath

        let listing = try await XcodebuildRunner.list(containerArguments: containerArgs, clonedSourcePackagesPath: cache)
        guard let scheme = pickScheme(listing.schemes, container: containerURL) else {
            throw PublishError.ascAPIError(
                status: 0,
                body: "No shared scheme found in \(containerURL.lastPathComponent). In Xcode → Product → Scheme → Manage Schemes, tick 'Shared'."
            )
        }

        // Configurations: present for projects; for workspaces fall back to the
        // primary member project's list.
        var configurations = listing.configurations
        if configurations.isEmpty,
           containerURL.pathExtension.lowercased() == "xcworkspace",
           let primary = primaryProject(in: containerURL) {
            configurations = (try? await XcodebuildRunner.list(
                containerArguments: ["-project", primary.path],
                clonedSourcePackagesPath: cache
            ).configurations) ?? []
        }

        var environments: [AppEnvironment] = []
        var teamId = ""
        var displayName = containerURL.deletingPathExtension().lastPathComponent

        // nil = let xcodebuild pick the scheme's default config (when none enumerated).
        let configsToProbe: [String?] = configurations.isEmpty ? [nil] : configurations.map { $0 }
        for config in configsToProbe {
            guard let settings = try? await XcodebuildRunner.showBuildSettings(
                containerArguments: containerArgs,
                scheme: scheme,
                configuration: config,
                clonedSourcePackagesPath: cache
            ) else { continue }

            let resolvedConfig = config ?? settings["CONFIGURATION"] ?? "Release"
            let bundleId = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            guard !bundleId.isEmpty else { continue }

            environments.append(AppEnvironment(name: resolvedConfig, configuration: resolvedConfig, bundleIdentifier: bundleId))
            if teamId.isEmpty, let team = settings["DEVELOPMENT_TEAM"], !team.isEmpty { teamId = team }
            if let product = settings["PRODUCT_NAME"], !product.isEmpty { displayName = product }
        }

        return ProjectInspection(
            displayName: displayName,
            schemes: listing.schemes,
            suggestedScheme: scheme,
            teamId: teamId,
            environments: environments
        )
    }

    /// Prefer a scheme matching the container's base name (the common case), else
    /// the first shared scheme.
    private static func pickScheme(_ schemes: [String], container: URL) -> String? {
        let base = container.deletingPathExtension().lastPathComponent
        return schemes.first { $0.caseInsensitiveCompare(base) == .orderedSame } ?? schemes.first
    }

    /// The primary `.xcodeproj` referenced by a workspace, resolved from
    /// `contents.xcworkspacedata`. Used to enumerate configurations for workspaces.
    private static func primaryProject(in workspace: URL) -> URL? {
        let dataURL = workspace.appending(path: "contents.xcworkspacedata")
        guard let xml = try? String(contentsOf: dataURL, encoding: .utf8) else { return nil }
        let workspaceDir = workspace.deletingLastPathComponent()
        guard let regex = try? NSRegularExpression(pattern: #"location\s*=\s*"([^"]+)""#) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let r = Range(match.range(at: 1), in: xml) else { continue }
            let location = String(xml[r])
            guard let url = resolveWorkspaceLocation(location, workspaceDir: workspaceDir),
                  url.pathExtension.lowercased() == "xcodeproj" else { continue }
            return url
        }
        return nil
    }

    private static func resolveWorkspaceLocation(_ location: String, workspaceDir: URL) -> URL? {
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let (kind, path) = (String(parts[0]), String(parts[1]))
        switch kind {
        case "absolute": return URL(fileURLWithPath: path)
        case "group", "container": return path.isEmpty ? nil : workspaceDir.appending(path: path)
        default: return nil // "self" refers to the workspace itself, not a project
        }
    }
}

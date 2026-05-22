//
//  ProjectInspector.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// Reads the current MARKETING_VERSION / CURRENT_PROJECT_VERSION (and signing
/// metadata) for a project straight from `xcodebuild -showBuildSettings`, against
/// the same container that will be archived.
enum ProjectInspector {
    static func resolveBuildVersion(for project: AppProject) async throws -> BuildVersionInfo {
        let settings = try await XcodebuildRunner.showBuildSettings(
            containerArguments: project.xcodebuildContainerArguments,
            scheme: project.schemeName,
            configuration: project.configuration
        )
        return BuildVersionInfo(
            marketingVersion: settings["MARKETING_VERSION"] ?? "",
            buildNumber: settings["CURRENT_PROJECT_VERSION"] ?? "",
            bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? project.bundleIdentifier,
            teamId: settings["DEVELOPMENT_TEAM"] ?? project.teamId,
            productName: settings["PRODUCT_NAME"] ?? project.schemeName
        )
    }
}

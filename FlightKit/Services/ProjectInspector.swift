//
//  ProjectInspector.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation
import os

/// Accumulates a readable transcript of an auto-scan. Sequential (one task, appended
/// between `await`s) so a plain array needs no locking; `@unchecked Sendable` only so
/// it can be captured across the `async` calls.
private final class DiagnosticLog: @unchecked Sendable {
    private var lines: [String] = []
    func log(_ line: String) { lines.append(line) }
    var text: String { lines.joined(separator: "\n") }
    func emitToConsole() {
        Logger(subsystem: "com.flightkit.app", category: "inspect").log("Auto-scan transcript:\n\(self.text, privacy: .public)")
    }
}

private extension String {
    /// `self` unless empty, in which case `fallback` — keeps diagnostic lines readable.
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// What auto-fill extracts from a selected `.xcworkspace` / `.xcodeproj`.
struct ProjectInspection {
    var displayName: String
    var schemes: [String]
    var suggestedScheme: String
    var teamId: String
    /// One environment per build configuration (name = configuration), each with
    /// the bundle id that configuration resolves to.
    var environments: [AppEnvironment]
    /// Human-readable transcript of what the scan did (active developer dir, each
    /// xcodebuild invocation + exit code, per-config bundle-id resolution). Surfaced
    /// in the editor so a scan that came back empty on another machine can be
    /// diagnosed instead of failing silently.
    var diagnostics: String = ""
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
        let diag = DiagnosticLog()

        // A GUI app launched from Finder/Dock inherits launchd's minimal environment,
        // not the developer's shell. `xcrun xcodebuild` still works *if* a full Xcode
        // is selected — but on a machine with only Command Line Tools (or no Xcode),
        // it fails. This is the classic "auto-scan works on my Mac, nowhere else"
        // cause, so verify up front and throw an actionable error instead of letting
        // every later xcodebuild call quietly return nothing.
        try await verifyDeveloperTools(diag)

        let listing = try await XcodebuildRunner.list(containerArguments: containerArgs, clonedSourcePackagesPath: cache)
        diag.log("xcodebuild -list → \(listing.schemes.count) scheme(s): \(listing.schemes.joined(separator: ", ").ifEmpty("∅")); \(listing.configurations.count) configuration(s): \(listing.configurations.joined(separator: ", ").ifEmpty("∅"))")
        guard let scheme = pickScheme(listing.schemes, container: containerURL) else {
            diag.log("No scheme returned by xcodebuild -list.")
            throw PublishError.ascAPIError(
                status: 0,
                body: "No shared scheme found in \(containerURL.lastPathComponent). In Xcode → Product → Scheme → Manage Schemes, tick 'Shared'.\n\n\(diag.text)"
            )
        }
        diag.log("Using scheme: \(scheme)")

        // Configurations: present for projects; for workspaces fall back to the
        // primary member project's list.
        var configurations = listing.configurations
        if configurations.isEmpty,
           containerURL.pathExtension.lowercased() == "xcworkspace",
           let primary = primaryProject(in: containerURL) {
            diag.log("Workspace exposes no configurations; reading primary project \(primary.lastPathComponent).")
            configurations = (try? await XcodebuildRunner.list(
                containerArguments: ["-project", primary.path],
                clonedSourcePackagesPath: cache
            ).configurations) ?? []
            diag.log("Primary project configurations: \(configurations.joined(separator: ", ").ifEmpty("∅"))")
        }

        var environments: [AppEnvironment] = []
        var teamId = ""
        var displayName = containerURL.deletingPathExtension().lastPathComponent

        // nil = let xcodebuild pick the scheme's default config (when none enumerated).
        let configsToProbe: [String?] = configurations.isEmpty ? [nil] : configurations.map { $0 }
        for config in configsToProbe {
            let label = config ?? "(scheme default)"
            do {
                let settings = try await XcodebuildRunner.showBuildSettings(
                    containerArguments: containerArgs,
                    scheme: scheme,
                    configuration: config,
                    clonedSourcePackagesPath: cache
                )
                let resolvedConfig = config ?? settings["CONFIGURATION"] ?? "Release"
                let bundleId = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
                guard !bundleId.isEmpty else {
                    diag.log("\(label): no PRODUCT_BUNDLE_IDENTIFIER in build settings — skipped.")
                    continue
                }
                diag.log("\(label) → \(resolvedConfig): \(bundleId)")
                environments.append(AppEnvironment(name: resolvedConfig, configuration: resolvedConfig, bundleIdentifier: bundleId))
                if teamId.isEmpty, let team = settings["DEVELOPMENT_TEAM"], !team.isEmpty { teamId = team }
                if let product = settings["PRODUCT_NAME"], !product.isEmpty { displayName = product }
            } catch {
                diag.log("\(label): showBuildSettings failed — \(error.localizedDescription)")
            }
        }

        if environments.isEmpty {
            diag.log("No environments resolved — review the transcript above for the failing step.")
        }
        diag.emitToConsole()

        return ProjectInspection(
            displayName: displayName,
            schemes: listing.schemes,
            suggestedScheme: scheme,
            teamId: teamId,
            environments: environments,
            diagnostics: diag.text
        )
    }

    /// Confirm an Xcode can be located before scanning. Uses the same resolver the
    /// build runner uses (which injects DEVELOPER_DIR), so a misconfigured
    /// `xcode-select` doesn't block a scan as long as an Xcode exists anywhere. Throws
    /// a copy-pasteable fix only when no Xcode is found at all.
    private static func verifyDeveloperTools(_ diag: DiagnosticLog) async throws {
        let selected = try? await XcodebuildRunner.runProcess(
            executable: "/usr/bin/xcode-select", args: ["-p"], onLine: { _, _ in }
        )
        let activeDir = selected?.combinedLog.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        diag.log("xcode-select -p → \(activeDir.ifEmpty("(unset)"))")

        guard let developerDir = await XcodeLocator.shared.developerDirectory() else {
            diag.log("No Xcode could be located (xcode-select, /Applications, Spotlight all empty).")
            throw PublishError.ascAPIError(
                status: 0,
                body: """
                Bu Mac'te kullanılabilir bir Xcode bulunamadı, bu yüzden proje otomatik taranamıyor.

                Aktif geliştirici dizini: \(activeDir.ifEmpty("(yok)"))

                App Store'dan tam Xcode'u kurun (kuruluysa şunu çalıştırın):
                  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

                Uygulamayı aşağıdan elle de ekleyebilirsiniz.
                """
            )
        }
        diag.log("Using Xcode: \(developerDir)")
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

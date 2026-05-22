//
//  ProjectDetailView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import AppKit

/// What the environment picker is pointed at: a single environment, or the
/// "All" sweep that publishes every environment in declaration order.
enum EnvironmentSelection: Hashable {
    case single(AppEnvironment)
    case all
}

struct ProjectDetailView: View {
    let project: AppProject

    @State private var destination: DistributionTarget = .testFlight
    @State private var local: BuildVersionInfo?
    @State private var latestTF: ASCBuild?
    @State private var latestLive: ASCAppStoreVersion?
    @State private var credentials: ASCCredentials?
    @State private var isLoading = true

    @State private var marketingVersion: String = ""
    @State private var buildNumber: String = ""
    @State private var showCredentialsSheet = false
    @State private var pipelineBatch: PipelineBatch?
    @State private var selection: EnvironmentSelection?
    /// Latest build number seen per environment (by env name) — used in "All"
    /// mode to suggest a build number safe across every target app at once.
    @State private var allEnvLatestBuilds: [String: Int] = [:]

    private var isAllSelected: Bool { selection == .all }

    /// Environments this run will publish to, in order. `.all` → every declared
    /// environment (Test → UAT → Prod); `.single` → just that one.
    private var targetEnvironments: [AppEnvironment] {
        switch selection {
        case .all: return project.resolvedEnvironments
        case .single(let env): return [env]
        case .none: return Array(project.resolvedEnvironments.prefix(1))
        }
    }

    /// The project pinned to the environment used for the "Current state" cards
    /// and ASC lookups. In `.all` mode this is the first environment; the cards
    /// are informational only — the actual run iterates `targetEnvironments`.
    private var effectiveProject: AppProject {
        guard let env = targetEnvironments.first else { return project }
        return project.applying(env)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    versionSection
                    Divider()
                    publishSection
                }
                .padding(24)
            }
        }
        .task(id: project.id) {
            // Reset selection when navigating between projects.
            if !isSelectionValid {
                selection = project.resolvedEnvironments.first.map(EnvironmentSelection.single)
            }
            await reload()
        }
        .onChange(of: selection) {
            // Version, TestFlight build and live state all differ per bundle id.
            marketingVersion = ""
            buildNumber = ""
            Task { await reload() }
        }
        .sheet(isPresented: $showCredentialsSheet) {
            CredentialsEditor(project: project) {
                showCredentialsSheet = false
                Task { await reload() }
            }
        }
        .sheet(item: Binding(get: { pipelineBatch }, set: { pipelineBatch = $0 })) { batch in
            PipelineView(batch: batch)
                .frame(minWidth: 720, minHeight: 540)
        }
    }

    /// Whether the current `selection` still refers to something valid for this
    /// project (guards against a stale single-env selection after navigation).
    private var isSelectionValid: Bool {
        switch selection {
        case .single(let env): return project.resolvedEnvironments.contains(env)
        case .all: return project.resolvedEnvironments.count > 1
        case .none: return false
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayName).font(.largeTitle.weight(.semibold))
                Text(effectiveProject.bundleIdentifier).font(.callout).foregroundStyle(.secondary)
                Text("Team: \(project.teamId) · Scheme: \(project.schemeName) · Config: \(effectiveProject.configuration)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    showCredentialsSheet = true
                } label: {
                    Label(credentials == nil ? "Configure API key" : "Edit API key", systemImage: "key.fill")
                }
                .buttonStyle(.bordered)
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .padding(24)
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current state").font(.title3.weight(.semibold))
            HStack(spacing: 16) {
                statCard("Local xcconfig",
                         value: local.map { "\($0.marketingVersion) (\($0.buildNumber))" } ?? "—",
                         systemImage: "doc.text")
                statCard("Latest TestFlight",
                         value: latestTF.map { "\($0.preReleaseVersion) (\($0.version))" } ?? "—",
                         secondary: latestTF.map { $0.processingState.rawValue.capitalized },
                         systemImage: "airplane")
                statCard("Latest live",
                         value: latestLive?.versionString ?? "—",
                         secondary: latestLive?.appStoreState,
                         systemImage: "checkmark.seal")
            }
        }
    }

    private var publishSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New build").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination").font(.caption).foregroundStyle(.secondary)
                Picker("Destination", selection: $destination) {
                    ForEach(DistributionTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                if destination == .appStore {
                    Text("Uploads, then attaches the processed build to an editable App Store version (created if needed). Not submitted for review.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if project.resolvedEnvironments.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment").font(.caption).foregroundStyle(.secondary)
                    Picker("Environment", selection: $selection) {
                        ForEach(project.resolvedEnvironments) { env in
                            Text(env.name).tag(Optional(EnvironmentSelection.single(env)))
                        }
                        Text("All").tag(Optional(EnvironmentSelection.all))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 400, alignment: .leading)
                    if isAllSelected {
                        Text("Publishes sequentially: \(targetEnvironments.map(\.name).joined(separator: " → ")). Stops if any environment fails.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Marketing version").font(.caption).foregroundStyle(.secondary)
                    TextField("1.2.3", text: $marketingVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                VStack(alignment: .leading) {
                    Text("Build number").font(.caption).foregroundStyle(.secondary)
                    TextField("48", text: $buildNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Button("Suggest next") { suggestNext() }
                    .buttonStyle(.bordered)
            }
            HStack {
                Button {
                    startPipeline()
                } label: {
                    Label(isAllSelected ? "Upload all to \(destination.displayName)" : "Upload to \(destination.displayName)",
                          systemImage: "icloud.and.arrow.up.fill")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(credentials == nil || marketingVersion.isEmpty || buildNumber.isEmpty)
                if credentials == nil {
                    Text("Configure API key first").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func statCard(_ title: String, value: String, secondary: String? = nil, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            if let secondary {
                Text(secondary).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(minWidth: 180, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        local = try? await ProjectInspector.resolveBuildVersion(for: effectiveProject)
        credentials = try? KeychainStore.load(forProjectId: project.id)
        latestTF = nil
        latestLive = nil
        allEnvLatestBuilds = [:]
        guard let credentials else {
            suggestNext()
            return
        }
        let api = ASCAPIClient(credentials: credentials)
        if isAllSelected {
            // Sweep every target app so the suggested build number clears all of
            // them; show the last (Prod) env's TestFlight build for context.
            for env in targetEnvironments {
                guard let app = try? await api.findApp(bundleId: env.bundleIdentifier) else { continue }
                let build = try? await api.latestBuild(appId: app.id)
                latestTF = build ?? latestTF
                if let n = build.flatMap({ Int($0.preReleaseVersion) }) {
                    allEnvLatestBuilds[env.name] = n
                }
            }
        } else if let app = try? await api.findApp(bundleId: effectiveProject.bundleIdentifier) {
            latestTF = try? await api.latestBuild(appId: app.id)
            latestLive = try? await api.latestAppStoreVersion(appId: app.id)
        }
        suggestNext()
    }

    private func suggestNext() {
        if marketingVersion.isEmpty {
            marketingVersion = local?.marketingVersion ?? latestTF?.version ?? "1.0.0"
        }
        if buildNumber.isEmpty {
            // In "All" mode the next build must be higher than every target app's
            // latest, otherwise a mid-batch env hits a duplicate-build rejection.
            let ascBuilds = isAllSelected
                ? Array(allEnvLatestBuilds.values)
                : [Int(latestTF?.preReleaseVersion ?? "") ?? 0]
            let candidates = ascBuilds + [Int(local?.buildNumber ?? "0") ?? 0]
            buildNumber = String((candidates.max() ?? 0) + 1)
        }
    }

    private func startPipeline() {
        guard let credentials else { return }
        let envs = targetEnvironments
        guard !envs.isEmpty else { return }
        let states = envs.map {
            PipelineState(project: project.applying($0), destination: destination, version: marketingVersion, buildNumber: buildNumber)
        }
        let batch = PipelineBatch(states: states)
        pipelineBatch = batch
        Task { @MainActor in
            for (index, state) in batch.states.enumerated() {
                batch.activeIndex = index
                let orchestrator = PublishOrchestrator(state: state, credentials: credentials)
                await orchestrator.run()
                // Abort the sweep on the first failure — never push a later
                // environment (e.g. Prod) once an earlier one has broken.
                if state.hasFailure { break }
            }
            batch.isFinished = true
        }
    }
}

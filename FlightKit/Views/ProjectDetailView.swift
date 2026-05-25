//
//  ProjectDetailView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import AppKit

@MainActor
struct ProjectDetailView: View {
    let project: AppProject
    let store: ProjectStore

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
    /// The environments the user has ticked, by name. Any subset is allowed
    /// (e.g. Test + Prod, or Test + UAT). Persisted per project across launches.
    @State private var selectedEnvNames: Set<String> = []
    /// Latest build number seen per environment (by env name) — used when more
    /// than one environment is targeted to suggest a build number safe across
    /// every target app at once.
    @State private var allEnvLatestBuilds: [String: Int] = [:]

    /// Environments this run will publish to, in declaration order. A project
    /// with a single environment always publishes it (no picker shown); a
    /// multi-environment project publishes the ticked subset.
    private var targetEnvironments: [AppEnvironment] {
        let all = project.resolvedEnvironments
        guard all.count > 1 else { return all }
        return all.filter { selectedEnvNames.contains($0.name) }
    }

    /// True when the run sweeps more than one environment back-to-back.
    private var isMultiTarget: Bool { targetEnvironments.count > 1 }

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
            // Restore this project's remembered environment + destination picks,
            // pruned to environments that still exist.
            restoreSelection()
            await reload()
        }
        .onChange(of: selectedEnvNames) {
            persistSelection()
            // Version, TestFlight build and live state all differ per bundle id.
            marketingVersion = ""
            buildNumber = ""
            Task { await reload() }
        }
        .onChange(of: destination) {
            persistSelection()
        }
        .sheet(isPresented: $showCredentialsSheet) {
            CredentialsEditor(project: project) {
                showCredentialsSheet = false
                store.credentialsChanged() // refresh the sidebar "API key" indicator
                Task { await reload() }
            }
        }
        .sheet(item: Binding(get: { pipelineBatch }, set: { pipelineBatch = $0 })) { batch in
            PipelineView(batch: batch)
                .frame(minWidth: 720, minHeight: 540)
        }
    }

    // MARK: - Per-project remembered selection

    private var envSelectionDefaultsKey: String { "FlightKit.envSelection.\(project.id)" }
    private var destinationDefaultsKey: String { "FlightKit.destination.\(project.id)" }

    /// Loads the remembered environment subset + destination for this project,
    /// dropping any environment names that no longer exist. Falls back to the
    /// first environment when nothing valid is remembered.
    private func restoreSelection() {
        let existing = Set(project.resolvedEnvironments.map(\.name))
        let saved = (UserDefaults.standard.array(forKey: envSelectionDefaultsKey) as? [String]) ?? []
        var restored = Set(saved).intersection(existing)
        if restored.isEmpty, let first = project.resolvedEnvironments.first {
            restored = [first.name]
        }
        selectedEnvNames = restored

        if let raw = UserDefaults.standard.string(forKey: destinationDefaultsKey),
           let saved = DistributionTarget(rawValue: raw) {
            destination = saved
        }
    }

    private func persistSelection() {
        UserDefaults.standard.set(Array(selectedEnvNames), forKey: envSelectionDefaultsKey)
        UserDefaults.standard.set(destination.rawValue, forKey: destinationDefaultsKey)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Environments").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(project.resolvedEnvironments) { env in
                            environmentChip(env)
                        }
                    }
                    if targetEnvironments.isEmpty {
                        Text("En az bir ortam seçin.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if isMultiTarget {
                        Text("Sıralı yayınlanır: \(targetEnvironments.map(\.name).joined(separator: " → ")). Bir ortam başarısız olursa durur.")
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
                    Label(isMultiTarget
                          ? "Upload \(targetEnvironments.count) environments to \(destination.displayName)"
                          : "Upload to \(destination.displayName)",
                          systemImage: "icloud.and.arrow.up.fill")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(credentials == nil || marketingVersion.isEmpty || buildNumber.isEmpty || targetEnvironments.isEmpty)
                if credentials == nil {
                    Text("Configure API key first").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// A toggle chip for one environment in the multi-select picker.
    @ViewBuilder
    private func environmentChip(_ env: AppEnvironment) -> some View {
        let isOn = selectedEnvNames.contains(env.name)
        Button {
            toggleEnv(env)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(env.name)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .help(env.bundleIdentifier)
    }

    private func toggleEnv(_ env: AppEnvironment) {
        if selectedEnvNames.contains(env.name) {
            selectedEnvNames.remove(env.name)
        } else {
            selectedEnvNames.insert(env.name)
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

    private struct ASCState {
        var latestTF: ASCBuild?
        var latestLive: ASCAppStoreVersion?
        var allEnvLatestBuilds: [String: Int] = [:]
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        // Instant Keychain read first so the API-key button state is correct right away.
        credentials = try? KeychainStore.load(forProjectId: project.id)
        latestTF = nil
        latestLive = nil
        allEnvLatestBuilds = [:]

        // The local read shells out to xcodebuild (which resolves SPM packages —
        // slow on heavy projects). Run it concurrently with the ASC network calls
        // so the spinner waits for max(local, network) instead of their sum.
        async let localInfo = ProjectInspector.resolveBuildVersion(for: effectiveProject)

        if let credentials {
            let asc = await fetchASCState(credentials: credentials)
            latestTF = asc.latestTF
            latestLive = asc.latestLive
            allEnvLatestBuilds = asc.allEnvLatestBuilds
        }
        local = try? await localInfo
        suggestNext()
    }

    @MainActor
    private func fetchASCState(credentials: ASCCredentials) async -> ASCState {
        let api = ASCAPIClient(credentials: credentials)
        var state = ASCState()
        if isMultiTarget {
            // Sweep every target app so the suggested build number clears all of
            // them; show the last (Prod) env's TestFlight build for context.
            for env in targetEnvironments {
                guard let app = try? await api.findApp(bundleId: env.bundleIdentifier) else { continue }
                let build = try? await api.latestBuild(appId: app.id)
                state.latestTF = build ?? state.latestTF
                if let n = build.flatMap({ Int($0.preReleaseVersion) }) {
                    state.allEnvLatestBuilds[env.name] = n
                }
            }
        } else if let app = try? await api.findApp(bundleId: effectiveProject.bundleIdentifier) {
            state.latestTF = try? await api.latestBuild(appId: app.id)
            state.latestLive = try? await api.latestAppStoreVersion(appId: app.id)
        }
        return state
    }

    private func suggestNext() {
        if marketingVersion.isEmpty {
            marketingVersion = local?.marketingVersion ?? latestTF?.version ?? "1.0.0"
        }
        if buildNumber.isEmpty {
            // With multiple targets the next build must be higher than every target
            // app's latest, otherwise a mid-sweep env hits a duplicate-build rejection.
            let ascBuilds = isMultiTarget
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
                // Upload succeeded: watch ASC processing (and the App Store attach)
                // in the background so the next environment starts immediately
                // instead of waiting on this one's processing. The watch is
                // cancelled when the pipeline screen closes.
                let watcher = orchestrator
                batch.trackProcessingWatch(Task { @MainActor in await watcher.runProcessingWatch() })
            }
            batch.isFinished = true
        }
    }
}

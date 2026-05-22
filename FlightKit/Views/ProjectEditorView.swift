//
//  ProjectEditorView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import AppKit

/// Add or edit an app — a small wizard:
///   1. **pick** the build container (.xcworkspace / .xcodeproj) — nothing else shown
///   2. **inspecting** — auto-extract scheme, team and per-config environments
///   3. **review** — the scan result, fully editable, then confirmed to save
/// Editing an existing app jumps straight to review.
struct ProjectEditorView: View {
    @Bindable var store: ProjectStore
    let existing: AppProject?
    /// Called with the saved project (or nil if cancelled).
    let onDone: (AppProject?) -> Void

    private enum Phase { case pick, inspecting, review }

    @State private var phase: Phase
    @State private var displayName: String
    @State private var containerPath: String
    @State private var schemeName: String
    @State private var teamId: String
    @State private var environments: [AppEnvironment]
    @State private var availableSchemes: [String] = []
    @State private var scanWarning: String?
    @State private var error: String?

    init(store: ProjectStore, existing: AppProject?, onDone: @escaping (AppProject?) -> Void) {
        self.store = store
        self.existing = existing
        self.onDone = onDone
        _phase = State(initialValue: existing == nil ? .pick : .review)
        _displayName = State(initialValue: existing?.displayName ?? "")
        _containerPath = State(initialValue: existing?.containerPath ?? "")
        _schemeName = State(initialValue: existing?.schemeName ?? "")
        _teamId = State(initialValue: existing?.teamId ?? "")
        _environments = State(initialValue: existing?.environments
            ?? [AppEnvironment(name: "Prod", configuration: "Release", bundleIdentifier: "")])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch phase {
            case .pick:       pickStep
            case .inspecting: inspectingStep
            case .review:     reviewStep
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(existing == nil ? "Add app" : "Edit app").font(.title3.weight(.semibold))
            Spacer()
            Button("Cancel", role: .cancel) { onDone(nil) }.keyboardShortcut(.escape)
            if phase == .review {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(16)
    }

    // MARK: - Step 1: pick

    private var pickStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Choose the app to publish")
                .font(.title3.weight(.semibold))
            Text("Pick its .xcworkspace or .xcodeproj. FlightKit reads the scheme,\nconfigurations and bundle ids for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { pickContainer() } label: {
                Label("Choose project…", systemImage: "folder")
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Step 2: inspecting

    private var inspectingStep: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Inspecting project…").font(.headline)
            Text(URL(fileURLWithPath: containerPath).lastPathComponent)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            Text("Reading schemes, configurations and bundle ids. The first run may\nresolve Swift packages, which can take a moment.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Step 3: review

    private var reviewStep: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Project / workspace") {
                        HStack {
                            Text(URL(fileURLWithPath: containerPath).lastPathComponent)
                                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Button("Change…") { pickContainer() }.controlSize(.small)
                        }
                    }
                    TextField("Display name", text: $displayName)
                    schemeField
                    TextField("Team ID", text: $teamId)
                        .help("Apple Developer Team ID (10 chars), e.g. ABCDE12345")
                } header: {
                    Text("App")
                } footer: {
                    if let scanWarning {
                        Label(scanWarning, systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    } else {
                        Label("Auto-scanned — review and edit anything below before saving.", systemImage: "sparkles")
                            .font(.caption2)
                    }
                }
                Section {
                    ForEach($environments) { $env in
                        environmentRow($env)
                    }
                    .onDelete { environments.remove(atOffsets: $0) }
                    Button {
                        environments.append(AppEnvironment(name: "", configuration: "", bundleIdentifier: ""))
                    } label: {
                        Label("Add environment", systemImage: "plus")
                    }
                } header: {
                    Text("Environments (\(environments.count))")
                } footer: {
                    Text("Each environment is one build configuration + the bundle id it ships under. Add missing ones, fix wrong values, swipe to delete extras.")
                        .font(.caption2)
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var schemeField: some View {
        if availableSchemes.count > 1 {
            Picker("Scheme", selection: $schemeName) {
                ForEach(availableSchemes, id: \.self) { Text($0).tag($0) }
            }
        } else {
            TextField("Scheme", text: $schemeName)
        }
    }

    @ViewBuilder
    private func environmentRow(_ env: Binding<AppEnvironment>) -> some View {
        VStack(spacing: 6) {
            TextField("Name (e.g. Prod)", text: env.name)
            TextField("Configuration (e.g. Release)", text: env.configuration)
            TextField("Bundle identifier", text: env.bundleIdentifier)
                .font(.callout.monospaced())
        }
        .padding(.vertical, 4)
    }

    private var isValid: Bool {
        !displayName.trimmed.isEmpty
        && !containerPath.isEmpty
        && !schemeName.trimmed.isEmpty
        && environments.contains { !$0.name.trimmed.isEmpty && !$0.configuration.trimmed.isEmpty && !$0.bundleIdentifier.trimmed.isEmpty }
    }

    // MARK: - Actions

    private func pickContainer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // .xcworkspace / .xcodeproj are file *packages* (directories). Allowing
        // directories + not treating packages as navigable folders is what makes
        // them selectable as a single item; restricting by content type greys them
        // out because their UTI doesn't match a filename-extension-derived type.
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a .xcworkspace or .xcodeproj"
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "xcworkspace" || ext == "xcodeproj" else {
            error = "Please select a .xcworkspace or .xcodeproj (got .\(ext.isEmpty ? "folder" : ext))."
            return
        }
        error = nil
        containerPath = url.path
        phase = .inspecting
        Task { await runInspection(url) }
    }

    /// Auto-fill scheme, team and per-configuration environments by reading the
    /// project with xcodebuild, then advance to review. Best-effort: on failure we
    /// still show review (filename-based) with a warning so the user can fill in.
    @MainActor
    private func runInspection(_ url: URL) async {
        do {
            let result = try await ProjectInspector.inspect(containerURL: url)
            availableSchemes = result.schemes
            displayName = result.displayName
            schemeName = result.suggestedScheme
            teamId = result.teamId
            if !result.environments.isEmpty { environments = result.environments }
            scanWarning = result.environments.isEmpty
                ? "No build configurations were detected — add environments manually."
                : nil
            error = nil
        } catch {
            availableSchemes = []
            displayName = url.deletingPathExtension().lastPathComponent
            schemeName = url.deletingPathExtension().lastPathComponent
            scanWarning = "Couldn't auto-read the project — fill the fields manually. (\(error.localizedDescription))"
        }
        phase = .review
    }

    private func save() {
        let cleaned = environments
            .map { AppEnvironment(name: $0.name.trimmed, configuration: $0.configuration.trimmed, bundleIdentifier: $0.bundleIdentifier.trimmed) }
            .filter { !$0.name.isEmpty && !$0.configuration.isEmpty && !$0.bundleIdentifier.isEmpty }
        guard let first = cleaned.first else {
            error = "Add at least one complete environment."
            return
        }
        var project = existing ?? AppProject(
            displayName: "", containerPath: "", schemeName: "",
            configuration: "", bundleIdentifier: "", teamId: "", environments: nil
        )
        project.displayName = displayName.trimmed
        project.containerPath = containerPath
        project.schemeName = schemeName.trimmed
        project.teamId = teamId.trimmed
        project.environments = cleaned
        // Effective defaults used by the pipeline before an environment is applied.
        project.configuration = first.configuration
        project.bundleIdentifier = first.bundleIdentifier

        if existing == nil {
            store.add(project)
        } else {
            store.update(project)
        }
        onDone(project)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

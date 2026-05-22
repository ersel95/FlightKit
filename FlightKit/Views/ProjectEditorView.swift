//
//  ProjectEditorView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import AppKit

/// Add or edit an app in the catalog. Picks the build container directly
/// (.xcworkspace / .xcodeproj) and captures scheme, team and one or more
/// environments (each = a configuration + bundle id).
struct ProjectEditorView: View {
    @Bindable var store: ProjectStore
    let existing: AppProject?
    /// Called with the saved project (or nil if cancelled).
    let onDone: (AppProject?) -> Void

    @State private var displayName: String
    @State private var containerPath: String
    @State private var schemeName: String
    @State private var teamId: String
    @State private var environments: [AppEnvironment]
    @State private var error: String?
    @State private var isInspecting = false
    @State private var availableSchemes: [String] = []

    init(store: ProjectStore, existing: AppProject?, onDone: @escaping (AppProject?) -> Void) {
        self.store = store
        self.existing = existing
        self.onDone = onDone
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
            Form {
                Section {
                    TextField("Display name", text: $displayName)
                    containerPicker
                    schemeField
                    TextField("Team ID", text: $teamId)
                        .help("Apple Developer Team ID (10 chars), e.g. ABCDE12345")
                } header: {
                    Text("App")
                } footer: {
                    if isInspecting {
                        Label("Inspecting project — reading schemes, configurations and bundle ids…", systemImage: "magnifyingglass")
                            .font(.caption2)
                    } else {
                        Text("Pick a project/workspace and the fields below auto-fill.").font(.caption2)
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
                    Text("Environments")
                } footer: {
                    Text("Each environment is one build configuration + the bundle id it ships under. Add Test / UAT / Prod to publish them separately (or 'All' at once).")
                        .font(.caption2)
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(existing == nil ? "Add app" : "Edit app").font(.title3.weight(.semibold))
            Spacer()
            Button("Cancel", role: .cancel) { onDone(nil) }.keyboardShortcut(.escape)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isInspecting)
        }
        .padding(16)
    }

    private var containerPicker: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project / workspace").font(.caption).foregroundStyle(.secondary)
                Text(containerPath.isEmpty ? "Not selected" : containerPath)
                    .font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(containerPath.isEmpty ? .secondary : .primary)
            }
            Spacer()
            if isInspecting { ProgressView().controlSize(.small) }
            Button("Choose…") { pickContainer() }
                .disabled(isInspecting)
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
        Task { await runInspection(url) }
    }

    /// Auto-fill scheme, team and per-configuration environments by reading the
    /// project with xcodebuild. Best-effort: on failure we keep a filename-based
    /// default and let the user fill in the rest.
    @MainActor
    private func runInspection(_ url: URL) async {
        isInspecting = true
        defer { isInspecting = false }
        do {
            let result = try await ProjectInspector.inspect(containerURL: url)
            availableSchemes = result.schemes
            displayName = result.displayName
            schemeName = result.suggestedScheme
            if !result.teamId.isEmpty { teamId = result.teamId }
            if !result.environments.isEmpty { environments = result.environments }
            error = nil
        } catch {
            availableSchemes = []
            if displayName.trimmed.isEmpty { displayName = url.deletingPathExtension().lastPathComponent }
            if schemeName.trimmed.isEmpty { schemeName = url.deletingPathExtension().lastPathComponent }
            self.error = "Couldn't auto-read the project — fill the fields manually. (\(error.localizedDescription))"
        }
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

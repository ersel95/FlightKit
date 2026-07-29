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
    /// The shared build number, used when `buildNumberShared` is on.
    @State private var buildNumber: String = ""
    /// Per-environment build numbers (keyed by env name), used when the
    /// "her ortam için ayrı" setting is active.
    @State private var perEnvBuildNumbers: [String: String] = [:]
    /// The shared TestFlight "What to Test" note, used when `testNoteShared` is on.
    @State private var testNote: String = ""
    /// Per-environment test notes (keyed by env name), used when the test note
    /// "her ortam için ayrı" setting is active.
    @State private var perEnvTestNotes: [String: String] = [:]
    @State private var showCredentialsSheet = false
    @State private var showBuildAdmin = false

    /// Whether the build number is asked for each run (vs. auto-sending `1`).
    @AppStorage(AppSettings.buildNumberManagedKey) private var buildNumberManaged = true
    /// Whether one build number is shared across environments (vs. one each).
    @AppStorage(AppSettings.buildNumberSharedKey) private var buildNumberShared = true
    /// Whether a test note is asked for each run.
    @AppStorage(AppSettings.testNoteManagedKey) private var testNoteManaged = true
    /// Whether one test note is shared across environments (vs. one each).
    @AppStorage(AppSettings.testNoteSharedKey) private var testNoteShared = true
    /// Whether a picked branch is fetched + fast-forwarded before the archive.
    @AppStorage(AppSettings.branchPullOnCheckoutKey) private var branchPullOnCheckout = true
    @State private var pipelineBatch: PipelineBatch?
    /// The environments the user has ticked, by name. Any subset is allowed
    /// (e.g. Test + Prod, or Test + UAT). Persisted per project across launches.
    @State private var selectedEnvNames: Set<String> = []
    /// Latest build number seen per environment (by env name) — used when more
    /// than one environment is targeted to suggest a build number safe across
    /// every target app at once.
    @State private var allEnvLatestBuilds: [String: Int] = [:]
    /// TestFlight beta groups available per environment (by env name), fetched
    /// from App Store Connect during `reload`.
    @State private var allEnvBetaGroups: [String: [ASCBetaGroup]] = [:]
    /// The beta group ids the user has ticked per environment (by env name).
    /// Remembered per project across launches.
    @State private var selectedBetaGroupIds: [String: Set<String>] = [:]
    /// Whether the project's folder is a git repository — gates the branch picker.
    @State private var isGitRepo = false
    /// Branches available in that repository (local + already-fetched remotes).
    @State private var repoBranches: [GitBranch] = []
    /// The branch currently checked out, shown as the "leave as is" default.
    @State private var currentGitBranch: String?
    @State private var isLoadingBranches = false
    /// Branch picked per environment (by env name); "" / missing = don't switch.
    /// Remembered per project across launches, e.g. Test → `tst`, Prod → `liv`.
    @State private var selectedBranches: [String: String] = [:]

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
            await loadBranches()
            await reload()
        }
        .onChange(of: selectedEnvNames) {
            persistSelection()
            // Version, TestFlight build and live state all differ per bundle id.
            marketingVersion = ""
            buildNumber = ""
            perEnvBuildNumbers = [:]
            testNote = ""
            perEnvTestNotes = [:]
            Task { await reload() }
        }
        .onChange(of: destination) {
            persistSelection()
        }
        // When the Settings toggles flip, re-suggest so the now-visible fields
        // populate instead of staying blank.
        .onChange(of: buildNumberManaged) { suggestNext() }
        .onChange(of: buildNumberShared) { suggestNext() }
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
        .sheet(isPresented: $showBuildAdmin) {
            if let credentials {
                BuildAdminView(project: project, credentials: credentials) {
                    showBuildAdmin = false
                }
            }
        }
    }

    // MARK: - Per-project remembered selection

    private var envSelectionDefaultsKey: String { "FlightKit.envSelection.\(project.id)" }
    private var destinationDefaultsKey: String { "FlightKit.destination.\(project.id)" }
    private func betaGroupsDefaultsKey(env: String) -> String { "FlightKit.betaGroups.\(project.id).\(env)" }
    private func branchDefaultsKey(env: String) -> String { "FlightKit.branch.\(project.id).\(env)" }

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

        // Beta group picks are remembered per environment; pruned to groups that
        // still exist once `reload` fetches the current list.
        var restoredGroups: [String: Set<String>] = [:]
        for env in project.resolvedEnvironments {
            let saved = (UserDefaults.standard.array(forKey: betaGroupsDefaultsKey(env: env.name)) as? [String]) ?? []
            restoredGroups[env.name] = Set(saved)
        }
        selectedBetaGroupIds = restoredGroups

        // Branch picks are remembered per environment too (Test ← tst, Prod ← liv …);
        // pruned to branches that still exist once `loadBranches` returns.
        var restoredBranches: [String: String] = [:]
        for env in project.resolvedEnvironments {
            if let saved = UserDefaults.standard.string(forKey: branchDefaultsKey(env: env.name)), !saved.isEmpty {
                restoredBranches[env.name] = saved
            }
        }
        selectedBranches = restoredBranches
    }

    private func persistSelection() {
        UserDefaults.standard.set(Array(selectedEnvNames), forKey: envSelectionDefaultsKey)
        UserDefaults.standard.set(destination.rawValue, forKey: destinationDefaultsKey)
    }

    private func persistBetaGroupSelection(env: String) {
        UserDefaults.standard.set(Array(selectedBetaGroupIds[env] ?? []), forKey: betaGroupsDefaultsKey(env: env))
    }

    private func persistBranchSelection(env: String) {
        UserDefaults.standard.set(selectedBranches[env] ?? "", forKey: branchDefaultsKey(env: env))
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
                Button {
                    showBuildAdmin = true
                } label: {
                    Label("Build'ler", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .disabled(credentials == nil)
                .help(credentials == nil ? "Önce API anahtarını yapılandırın" : "Build'leri listele ve App Store Connect verilerini düzenle")
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
            branchInputs
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Marketing version").font(.caption).foregroundStyle(.secondary)
                    TextField("1.2.3", text: $marketingVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                buildNumberInputs
                if buildNumberManaged {
                    Button("Suggest next") { suggestNext() }
                        .buttonStyle(.bordered)
                }
            }
            testNoteInputs
            betaGroupsInputs
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
                .disabled(credentials == nil || !buildInputsValid)
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

    // MARK: - Git branch input

    /// Per-environment branch picker: which branch each environment is built from
    /// (e.g. Test ← `tst`, UAT ← `uat`, Prod ← `liv`). Only shown for a project that
    /// lives in a git repository. Leaving an environment on "değiştirme" keeps the
    /// old behaviour — the working copy is archived exactly as it currently is.
    @ViewBuilder
    private var branchInputs: some View {
        if isGitRepo {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Git branch (opsiyonel)").font(.caption).foregroundStyle(.secondary)
                    if isLoadingBranches {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await loadBranches(fetchFirst: true) } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Branch listesini yenile (uzaktaki yeni branch'ler için fetch eder)")
                    }
                }
                ForEach(targetEnvironments) { env in
                    HStack(spacing: 8) {
                        Text(env.name)
                            .font(.callout)
                            .frame(width: 72, alignment: .leading)
                        Picker("", selection: branchBinding(env)) {
                            Text(currentGitBranch.map { "Mevcut branch — \($0)" } ?? "Mevcut branch")
                                .tag("")
                            Divider()
                            ForEach(repoBranches) { branch in
                                Text(branch.isLocal ? branch.name : "\(branch.name) · uzak")
                                    .tag(branch.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280, alignment: .leading)
                    }
                }
                Text(branchPullOnCheckout
                     ? "Seçilen branch, o ortamın arşivi alınmadan hemen önce fetch edilip `git checkout` + `git pull --ff-only` ile güncellenir; paket uzaktaki son hâlden çıkar. Depo bu branch'te bırakılır. (Ayarlar'dan kapatılabilir.)"
                     : "Seçilen branch, o ortamın arşivi alınmadan hemen önce `git checkout` ile aktif edilir — güncelleme yapılmaz, paket lokal kopyadan çıkar. Depo bu branch'te bırakılır.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    private func branchBinding(_ env: AppEnvironment) -> Binding<String> {
        Binding(
            get: { selectedBranches[env.name] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    selectedBranches.removeValue(forKey: env.name)
                } else {
                    selectedBranches[env.name] = newValue
                }
                persistBranchSelection(env: env.name)
            }
        )
    }

    /// The branch this environment will be checked out to, or `nil` to build the
    /// working copy as-is.
    private func effectiveBranch(for env: AppEnvironment) -> String? {
        guard isGitRepo else { return nil }
        let name = selectedBranches[env.name] ?? ""
        return name.isEmpty ? nil : name
    }

    /// Reads the repository's branches and current HEAD. Failure (not a repo, no
    /// git) simply hides the picker — a project that isn't in a repository keeps
    /// publishing exactly as before. `fetchFirst` (the manual ⟳) pulls in refs for
    /// branches created elsewhere; the automatic load stays offline so opening a
    /// project never waits on the network.
    private func loadBranches(fetchFirst: Bool = false) async {
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        let repo = project.workspaceRoot
        guard await GitBranchInspector.isRepository(repo) else {
            isGitRepo = false
            repoBranches = []
            currentGitBranch = nil
            return
        }
        isGitRepo = true
        if fetchFirst { await GitBranchInspector.fetch(repoDir: repo) }
        currentGitBranch = await GitBranchInspector.currentBranch(repoDir: repo)
        let branches = (try? await GitBranchInspector.branches(repoDir: repo)) ?? []
        repoBranches = branches
        // Drop remembered picks for branches that no longer exist, so a deleted
        // branch never lingers and fails the checkout at archive time.
        if !branches.isEmpty {
            let existing = Set(branches.map(\.name))
            for (envName, branch) in selectedBranches where !existing.contains(branch) {
                selectedBranches.removeValue(forKey: envName)
                persistBranchSelection(env: envName)
            }
        }
    }

    // MARK: - Build number input (governed by Settings)

    /// The build-number entry area. Three shapes, driven by `AppSettings`:
    /// hidden (auto `1`), a single shared field, or one field per environment.
    @ViewBuilder
    private var buildNumberInputs: some View {
        if !buildNumberManaged {
            VStack(alignment: .leading) {
                Text("Build number").font(.caption).foregroundStyle(.secondary)
                Text("Otomatik: \(AppSettings.unmanagedBuildNumber)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Ayarlar'da build number yönetimi kapalı; her ortama \(AppSettings.unmanagedBuildNumber) gönderilir.")
            }
        } else if buildNumberShared {
            VStack(alignment: .leading) {
                Text("Build number").font(.caption).foregroundStyle(.secondary)
                TextField("48", text: $buildNumber)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
        } else {
            ForEach(targetEnvironments) { env in
                VStack(alignment: .leading) {
                    Text("Build · \(env.name)").font(.caption).foregroundStyle(.secondary)
                    TextField("48", text: perEnvBinding(env))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }
        }
    }

    private func perEnvBinding(_ env: AppEnvironment) -> Binding<String> {
        Binding(
            get: { perEnvBuildNumbers[env.name] ?? "" },
            set: { perEnvBuildNumbers[env.name] = $0 }
        )
    }

    /// The build number that will actually be submitted for `env`, honouring the
    /// current Settings: `1` when unmanaged, the shared value when shared, else
    /// the per-environment value.
    private func effectiveBuildNumber(for env: AppEnvironment) -> String {
        guard buildNumberManaged else { return AppSettings.unmanagedBuildNumber }
        if buildNumberShared { return buildNumber }
        return perEnvBuildNumbers[env.name] ?? AppSettings.unmanagedBuildNumber
    }

    // MARK: - Test note input (governed by Settings)

    /// The TestFlight "What to Test" entry area. Hidden when management is off,
    /// otherwise a single shared editor or one editor per environment. Always
    /// optional — a blank note simply skips the write after the build processes.
    @ViewBuilder
    private var testNoteInputs: some View {
        if testNoteManaged {
            VStack(alignment: .leading, spacing: 8) {
                if testNoteShared {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Test notu (opsiyonel)").font(.caption).foregroundStyle(.secondary)
                        testNoteEditor(text: $testNote)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(targetEnvironments) { env in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Test notu · \(env.name) (opsiyonel)").font(.caption).foregroundStyle(.secondary)
                                testNoteEditor(text: perEnvNoteBinding(env))
                            }
                        }
                    }
                }
                // Suggest from what changed since the latest existing build was uploaded.
                CommitSuggestionPanel(
                    repoURL: project.workspaceRoot,
                    since: latestTF?.uploadedDate,
                    until: nil
                ) { text in
                    appendToTestNote(text)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    /// Append commit-suggestion text into the active note field(s) — the shared note
    /// when shared, otherwise every targeted environment's per-env note.
    private func appendToTestNote(_ text: String) {
        if testNoteShared {
            testNote = TestNoteText.append(text, to: testNote)
        } else {
            for env in targetEnvironments {
                perEnvTestNotes[env.name] = TestNoteText.append(text, to: perEnvTestNotes[env.name] ?? "")
            }
        }
    }

    private func testNoteEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.callout)
            .frame(height: 72)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .frame(maxWidth: 420, alignment: .leading)
    }

    private func perEnvNoteBinding(_ env: AppEnvironment) -> Binding<String> {
        Binding(
            get: { perEnvTestNotes[env.name] ?? "" },
            set: { perEnvTestNotes[env.name] = $0 }
        )
    }

    /// The test note that will be written for `env` once its build processes:
    /// `nil` when management is off or the relevant field is blank.
    private func effectiveTestNote(for env: AppEnvironment) -> String? {
        guard testNoteManaged else { return nil }
        let raw = testNoteShared ? testNote : (perEnvTestNotes[env.name] ?? "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - TestFlight beta group input

    /// The TestFlight beta group picker. One row of toggle chips per target
    /// environment (each app has its own groups). Shown only once App Store
    /// Connect has returned at least one group for a target env. Picking nothing
    /// is fine — the build simply isn't auto-assigned to any group.
    @ViewBuilder
    private var betaGroupsInputs: some View {
        let envsWithGroups = targetEnvironments.filter { !(allEnvBetaGroups[$0.name] ?? []).isEmpty }
        if !envsWithGroups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("TestFlight grupları (opsiyonel)").font(.caption).foregroundStyle(.secondary)
                ForEach(envsWithGroups) { env in
                    VStack(alignment: .leading, spacing: 6) {
                        if isMultiTarget {
                            Text(env.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(allEnvBetaGroups[env.name] ?? []) { group in
                                    betaGroupChip(env: env, group: group)
                                }
                            }
                        }
                    }
                }
                Text("İşleme bittikten sonra build seçili gruplara otomatik atanır. Dış gruplara dağıtım, beta incelemesi tamamlandıktan sonra başlar.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// A toggle chip for one beta group within an environment.
    @ViewBuilder
    private func betaGroupChip(env: AppEnvironment, group: ASCBetaGroup) -> some View {
        let isOn = (selectedBetaGroupIds[env.name] ?? []).contains(group.id)
        Button {
            toggleBetaGroup(env: env, group: group)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(group.name)
                Image(systemName: group.isInternal ? "lock.fill" : "person.2.fill")
                    .font(.caption2)
                    .opacity(0.7)
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
        .help(group.isInternal ? "İç test grubu" : "Dış test grubu — dağıtım beta incelemesi sonrası")
    }

    // MARK: - TestFlight beta group selection

    /// Drops any remembered group ids that no longer exist on the freshly-fetched
    /// list, so a deleted group never lingers as a phantom selection.
    private func pruneBetaGroupSelection() {
        for (envName, groups) in allEnvBetaGroups {
            let existing = Set(groups.map(\.id))
            selectedBetaGroupIds[envName] = (selectedBetaGroupIds[envName] ?? []).intersection(existing)
        }
    }

    private func toggleBetaGroup(env: AppEnvironment, group: ASCBetaGroup) {
        var set = selectedBetaGroupIds[env.name] ?? []
        if set.contains(group.id) { set.remove(group.id) } else { set.insert(group.id) }
        selectedBetaGroupIds[env.name] = set
        persistBetaGroupSelection(env: env.name)
    }

    /// The beta groups that will actually be assigned for `env` once its build
    /// processes — the ticked subset of that env's available groups.
    private func effectiveBetaGroups(for env: AppEnvironment) -> [ASCBetaGroup] {
        let selected = selectedBetaGroupIds[env.name] ?? []
        return (allEnvBetaGroups[env.name] ?? []).filter { selected.contains($0.id) }
    }

    /// Whether the version/build inputs are complete enough to start a run.
    private var buildInputsValid: Bool {
        guard !marketingVersion.isEmpty, !targetEnvironments.isEmpty else { return false }
        guard buildNumberManaged else { return true }
        if buildNumberShared { return !buildNumber.isEmpty }
        return targetEnvironments.allSatisfy { !(perEnvBuildNumbers[$0.name] ?? "").isEmpty }
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
        var betaGroupsByEnv: [String: [ASCBetaGroup]] = [:]
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
        allEnvBetaGroups = [:]

        // The local read shells out to xcodebuild (which resolves SPM packages —
        // slow on heavy projects). Run it concurrently with the ASC network calls
        // so the spinner waits for max(local, network) instead of their sum.
        async let localInfo = ProjectInspector.resolveBuildVersion(for: effectiveProject)

        if let credentials {
            let asc = await fetchASCState(credentials: credentials)
            latestTF = asc.latestTF
            latestLive = asc.latestLive
            allEnvLatestBuilds = asc.allEnvLatestBuilds
            allEnvBetaGroups = asc.betaGroupsByEnv
            pruneBetaGroupSelection()
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
                // `version` is the build number (e.g. 291); `preReleaseVersion` is the
                // marketing version (e.g. "1.0.3"). The next build must clear the
                // latest *build number*, so read `version` here.
                if let n = build.flatMap({ Int($0.version) }) {
                    state.allEnvLatestBuilds[env.name] = n
                }
                state.betaGroupsByEnv[env.name] = (try? await api.betaGroups(appId: app.id)) ?? []
            }
        } else if let env = targetEnvironments.first,
                  let app = try? await api.findApp(bundleId: effectiveProject.bundleIdentifier) {
            state.latestTF = try? await api.latestBuild(appId: app.id)
            state.latestLive = try? await api.latestAppStoreVersion(appId: app.id)
            state.betaGroupsByEnv[env.name] = (try? await api.betaGroups(appId: app.id)) ?? []
        }
        return state
    }

    private func suggestNext() {
        if marketingVersion.isEmpty {
            marketingVersion = local?.marketingVersion ?? latestTF?.preReleaseVersion ?? "1.0.0"
        }
        guard buildNumberManaged else { return } // unmanaged → always 1, nothing to suggest
        if buildNumberShared {
            if buildNumber.isEmpty {
                // With multiple targets the next build must be higher than every target
                // app's latest, otherwise a mid-sweep env hits a duplicate-build rejection.
                let ascBuilds = isMultiTarget
                    ? Array(allEnvLatestBuilds.values)
                    : [Int(latestTF?.version ?? "") ?? 0]
                let candidates = ascBuilds + [Int(local?.buildNumber ?? "0") ?? 0]
                buildNumber = String((candidates.max() ?? 0) + 1)
            }
        } else {
            // Per environment: suggest each env's own next build independently.
            for env in targetEnvironments where (perEnvBuildNumbers[env.name] ?? "").isEmpty {
                perEnvBuildNumbers[env.name] = suggestedBuild(for: env)
            }
        }
    }

    /// The next safe build number for a single environment, based on that env's
    /// own latest ASC build and the local xcconfig value.
    private func suggestedBuild(for env: AppEnvironment) -> String {
        let ascLatest = isMultiTarget
            ? (allEnvLatestBuilds[env.name] ?? 0)
            : (Int(latestTF?.version ?? "") ?? 0)
        let localLatest = Int(local?.buildNumber ?? "0") ?? 0
        return String(max(ascLatest, localLatest) + 1)
    }

    private func startPipeline() {
        guard let credentials else { return }
        let envs = targetEnvironments
        guard !envs.isEmpty else { return }
        let states = envs.map {
            PipelineState(project: project.applying($0), destination: destination, version: marketingVersion, buildNumber: effectiveBuildNumber(for: $0), testNote: effectiveTestNote(for: $0), betaGroups: effectiveBetaGroups(for: $0), branch: effectiveBranch(for: $0))
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
            await notifyTeamsIfNeeded(envs: envs, states: batch.states)
        }
    }

    /// Posts a single Teams summary for the environments that uploaded successfully
    /// (once per batch, not per env, so it steals focus only once). Best-effort: a
    /// bad link or missing Accessibility permission only logs into the active state.
    private func notifyTeamsIfNeeded(envs: [AppEnvironment], states: [PipelineState]) async {
        guard project.teamsNotificationsActive, let link = project.teamsChatLink else { return }
        let uploaded = zip(envs, states).filter { $0.1.uploadedAt != nil }
        guard !uploaded.isEmpty else { return }

        var lines = ["🚀 \(project.displayName) sürümü yayınlandı"]
        for (env, state) in uploaded {
            let branch = state.targetBranch.map { " · \($0)" } ?? ""
            lines.append("• \(env.name) → \(state.destination.displayName) · \(state.targetVersion) (\(state.targetBuildNumber))\(branch)")
        }
        let message = lines.joined(separator: "\n")

        let log = { (msg: String) -> Void in states.first?.appendLog(msg, kind: .info) }
        do {
            try await TeamsNotifier.notify(chatLink: link, message: message, log: log)
        } catch {
            log("⚠︎ Teams bildirimi gönderilemedi: \(error.localizedDescription)")
        }
    }
}

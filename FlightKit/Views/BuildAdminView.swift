//
//  BuildAdminView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

/// Browse an app's builds and edit App Store Connect data *after* upload — the
/// retroactive counterpart to the publish pipeline (which only sets test note +
/// groups at upload time). Pick an environment, pick a build, then edit its export
/// compliance, "What to Test" note, beta groups, individual testers, or expire it.
/// All edits hit the environment's own ASC app record (resolved from its bundle id).
@MainActor
struct BuildAdminView: View {
    let project: AppProject
    let credentials: ASCCredentials
    let onClose: () -> Void

    @State private var selectedEnvName: String

    @State private var app: ASCApp?
    @State private var isResolving = false
    /// True while an ASC *mutation* (save/toggle/expire/assign) is in flight — shows
    /// a spinner and blocks input so the same write can't be fired twice.
    @State private var isWorking = false
    @State private var loadError: String?
    @State private var banner: String?

    @State private var builds: [ASCBuild] = []
    @State private var selectedBuildId: String?
    @State private var availableGroups: [ASCBetaGroup] = []
    @State private var buildGroupIds: Set<String> = []
    @State private var testNotes: [BetaBuildLocalization] = []
    @State private var buildTesters: [ASCBetaTester] = []
    @State private var appTesterPool: [ASCBetaTester] = []
    @State private var isLoadingBuild = false

    private let api: ASCAPIClient

    init(project: AppProject, credentials: ASCCredentials, onClose: @escaping () -> Void) {
        self.project = project
        self.credentials = credentials
        self.onClose = onClose
        self.api = ASCAPIClient(credentials: credentials)
        _selectedEnvName = State(initialValue: project.resolvedEnvironments.first?.name ?? "")
    }

    private var selectedEnv: AppEnvironment? {
        project.resolvedEnvironments.first { $0.name == selectedEnvName }
            ?? project.resolvedEnvironments.first
    }

    private var selectedBuild: ASCBuild? {
        builds.first { $0.id == selectedBuildId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let app {
                    content(app: app)
                } else {
                    placeholder
                }
            }
            .disabled(isWorking)
            .overlay {
                if isWorking {
                    ProgressView("İşleniyor…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 8)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .task(id: selectedEnvName) { await resolveApp() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build yönetimi").font(.title3.weight(.semibold))
                    Text(project.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isResolving || isWorking { ProgressView().controlSize(.small) }
                Button("Kapat", role: .cancel) { onClose() }.keyboardShortcut(.escape)
            }
            HStack(spacing: 12) {
                if project.resolvedEnvironments.count > 1 {
                    Picker("Ortam", selection: $selectedEnvName) {
                        ForEach(project.resolvedEnvironments) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 220)
                } else if let env = selectedEnv {
                    Label(env.name, systemImage: "shippingbox").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await loadBuildScope() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(app == nil)
            }
            if let env = selectedEnv {
                Text(env.bundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let banner {
                Label(banner, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Spacer()
            if isResolving {
                ProgressView()
                Text("App Store Connect kaydı çözümleniyor…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "questionmark.app.dashed").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                Text("Bu ortam için App Store Connect uygulaması bulunamadı.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(selectedEnv?.bundleIdentifier ?? "").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func content(app: ASCApp) -> some View {
        buildScope
    }

    // MARK: - Build scope

    private var buildScope: some View {
        HSplitView {
            buildList
                .frame(minWidth: 220, maxWidth: 300)
            ScrollView {
                if selectedBuild != nil {
                    buildEditor
                        .padding(16)
                } else {
                    Text("Düzenlemek için bir build seçin.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }

    /// Builds grouped by their marketing (pre-release) version, newest version
    /// first, build numbers descending within each — far easier to scan than one
    /// long flat list once an app has hundreds of builds.
    private var groupedBuilds: [(version: String, builds: [ASCBuild])] {
        var order: [String] = []
        var map: [String: [ASCBuild]] = [:]
        for build in builds {
            let key = build.preReleaseVersion.isEmpty ? build.version : build.preReleaseVersion
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(build)
        }
        return order.map { ($0, map[$0]!) }
    }

    private var buildList: some View {
        List(selection: $selectedBuildId) {
            ForEach(groupedBuilds, id: \.version) { group in
                Section("Sürüm \(group.version) (\(group.builds.count))") {
                    ForEach(group.builds) { build in
                        buildRow(build).tag(build.id)
                    }
                }
            }
        }
        .onChange(of: selectedBuildId) { Task { await loadSelectedBuild() } }
        .overlay {
            if builds.isEmpty && !isResolving {
                Text("Build yok").foregroundStyle(.secondary)
            }
        }
    }

    private func buildRow(_ build: ASCBuild) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(build.version).font(.callout.weight(.medium))
                if build.expired {
                    Text("expired").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(build.processingState.rawValue.capitalized).font(.caption2)
                    .foregroundStyle(processingColor(build.processingState))
                if build.usesNonExemptEncryption == nil {
                    Text("· Missing Compliance").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func processingColor(_ state: ASCBuild.ProcessingState) -> Color {
        switch state {
        case .valid: return .green
        case .failed, .invalid: return .red
        case .processing: return .orange
        case .unknown: return .secondary
        }
    }

    @ViewBuilder
    private var buildEditor: some View {
        if let build = selectedBuild {
            VStack(alignment: .leading, spacing: 20) {
                if isLoadingBuild { ProgressView().controlSize(.small) }

                // Export compliance
                section("Export compliance (şifreleme)") {
                    Text(complianceStatusText(build)).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Şifreleme yok / muaf") {
                            run("Export compliance") { try await api.setExportCompliance(buildId: build.id, usesNonExemptEncryption: false); await refreshBuildsKeepingSelection() }
                        }
                        Button("İhracat uyumu gerekli (non-exempt)") {
                            run("Export compliance") { try await api.setExportCompliance(buildId: build.id, usesNonExemptEncryption: true); await refreshBuildsKeepingSelection() }
                        }
                    }
                    .controlSize(.small)
                }

                // What to Test
                section("What to Test (test notu)") {
                    if testNotes.isEmpty {
                        Text("Bu build için yerelleştirme yok.").font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach($testNotes) { $note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.locale).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextEditor(text: $note.whatsNew)
                                .font(.callout).frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                    }
                    if !testNotes.isEmpty {
                        Button("Test notlarını kaydet") {
                            run("Test notu") {
                                for note in testNotes {
                                    try await api.updateTestNote(localizationId: note.id, whatsNew: note.whatsNew)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    CommitSuggestionPanel(
                        repoURL: project.workspaceRoot,
                        since: previousBuildDate(before: build),
                        until: build.uploadedDate
                    ) { text in
                        appendToTestNotes(text)
                    }
                }

                // Beta groups
                section("TestFlight grupları") {
                    let assignable = availableGroups.filter { !$0.hasAccessToAllBuilds }
                    let autoIncluded = availableGroups.filter { $0.hasAccessToAllBuilds && buildGroupIds.contains($0.id) }
                    if assignable.isEmpty {
                        Text("Atanabilir grup yok.").font(.caption).foregroundStyle(.tertiary)
                    }
                    FlowChips(assignable) { group in
                        let isOn = buildGroupIds.contains(group.id)
                        chip(group.name, systemImage: group.isInternal ? "lock.fill" : "person.2.fill", isOn: isOn) {
                            toggleGroup(build: build, group: group)
                        }
                    }
                    if !autoIncluded.isEmpty {
                        Text("Otomatik dahil (tüm build'leri alan gruplar): \(autoIncluded.map(\.name).joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                // Individual testers
                section("Bireysel test kullanıcıları") {
                    if buildTesters.isEmpty {
                        Text("Bu build'e atanmış bireysel tester yok.").font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(buildTesters) { tester in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(tester.displayName).font(.callout)
                                if !tester.email.isEmpty, tester.displayName != tester.email {
                                    Text(tester.email).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                run("Tester kaldırıldı") { try await api.removeIndividualTester(tester.id, fromBuild: build.id); await loadSelectedBuild() }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    let assignable = appTesterPool.filter { pool in !buildTesters.contains { $0.id == pool.id } }
                    if !assignable.isEmpty {
                        Menu("Tester ekle") {
                            ForEach(assignable) { tester in
                                Button(tester.displayName) {
                                    run("Tester eklendi") { try await api.assignIndividualTester(tester.id, toBuild: build.id); await loadSelectedBuild() }
                                }
                            }
                        }
                        .controlSize(.small)
                        .frame(maxWidth: 200, alignment: .leading)
                    }
                }

                // Expire
                section("Build durumu") {
                    if build.expired {
                        Text("Bu build süresi dolmuş.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Build'i expire et", role: .destructive) {
                            run("Build expire edildi") { try await api.setBuildExpired(buildId: build.id, expired: true); await refreshBuildsKeepingSelection() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func complianceStatusText(_ build: ASCBuild) -> String {
        switch build.usesNonExemptEncryption {
        case .none: return "Belirtilmemiş — App Store Connect 'Missing Compliance' gösteriyor ve TestFlight dağıtımı bloklu."
        case .some(true): return "İhracat uyumu gerekli (non-exempt encryption)."
        case .some(false): return "Şifreleme yok / muaf — dağıtıma hazır."
        }
    }

    // MARK: - Reusable building blocks

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(title)
                Image(systemName: systemImage).font(.caption2).opacity(0.7)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private func resolveApp() async {
        loadError = nil
        banner = nil
        app = nil
        builds = []
        selectedBuildId = nil
        guard let env = selectedEnv else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            guard let resolved = try await api.findApp(bundleId: env.bundleIdentifier) else {
                loadError = "ASC kaydı bulunamadı: \(env.bundleIdentifier)"
                return
            }
            app = resolved
            await loadBuildScope()
        } catch {
            loadError = describe(error)
        }
    }

    private func loadBuildScope() async {
        guard let app else { return }
        isResolving = true
        defer { isResolving = false }
        builds = (try? await api.builds(appId: app.id, limit: 200)) ?? []
        availableGroups = (try? await api.allBetaGroups(appId: app.id)) ?? []
        appTesterPool = (try? await api.internalBetaTesters(appId: app.id)) ?? []
        if selectedBuildId == nil { selectedBuildId = builds.first?.id }
        await loadSelectedBuild()
    }

    private func loadSelectedBuild() async {
        guard let build = selectedBuild else {
            testNotes = []; buildGroupIds = []; buildTesters = []
            return
        }
        isLoadingBuild = true
        defer { isLoadingBuild = false }
        testNotes = (try? await api.betaBuildLocalizationsDetailed(buildId: build.id)) ?? []
        buildGroupIds = (try? await api.betaGroupIds(forBuild: build.id)) ?? []
        buildTesters = (try? await api.individualTesters(forBuild: build.id)) ?? []
    }

    /// The upload date of the build immediately preceding `build` (the next-older one
    /// in the date-sorted list) — the start of the "what changed since last build"
    /// window for commit suggestions.
    private func previousBuildDate(before build: ASCBuild) -> Date? {
        guard let index = builds.firstIndex(where: { $0.id == build.id }) else { return nil }
        return builds[(index + 1)...].first?.uploadedDate
    }

    /// Append suggestion text into every locale's "What to Test" editor.
    private func appendToTestNotes(_ text: String) {
        for index in testNotes.indices {
            testNotes[index].whatsNew = TestNoteText.append(text, to: testNotes[index].whatsNew)
        }
    }

    /// Re-fetch the build list (e.g. after compliance/expire) while keeping the
    /// current selection so the editor stays put.
    private func refreshBuildsKeepingSelection() async {
        guard let app else { return }
        let keep = selectedBuildId
        builds = (try? await api.builds(appId: app.id, limit: 200)) ?? []
        selectedBuildId = builds.contains { $0.id == keep } ? keep : builds.first?.id
    }

    private func toggleGroup(build: ASCBuild, group: ASCBetaGroup) {
        let isOn = buildGroupIds.contains(group.id)
        run(isOn ? "Gruptan çıkarıldı" : "Gruba eklendi") {
            if isOn {
                try await api.removeBuild(build.id, fromBetaGroup: group.id)
            } else {
                try await api.addBuild(build.id, toBetaGroup: group.id)
            }
            buildGroupIds = (try? await api.betaGroupIds(forBuild: build.id)) ?? buildGroupIds
        }
    }

    // MARK: - Action runner

    /// Runs an async ASC mutation, surfacing a success banner or a readable error.
    /// Flips `isWorking` for the duration so the editor shows a spinner and blocks
    /// further input — no double-submits while a write is in flight.
    private func run(_ label: String, _ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        banner = nil
        loadError = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await action()
                banner = "\(label) kaydedildi."
            } catch {
                loadError = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if let pubError = error as? PublishError, let desc = pubError.errorDescription {
            return desc
        }
        return error.localizedDescription
    }
}

/// A wrapping row of chips. Avoids importing a flow-layout dependency: lays its
/// content out with SwiftUI's native `Layout`-free approach via a simple wrapping
/// `HStack` inside a horizontal `ScrollView` is undesirable for many groups, so we
/// use `WrapLayout`.
private struct FlowChips<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        WrapLayout(spacing: 8, lineSpacing: 8) {
            ForEach(items) { content($0) }
        }
    }
}

/// Minimal wrapping layout: places subviews left-to-right, wrapping to a new line
/// when the proposed width runs out. Used for the beta-group chip rows.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxLineWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - spacing)
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, x - spacing)
        return CGSize(width: maxWidth == .infinity ? maxLineWidth : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

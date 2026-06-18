//
//  CommitSuggestionPanel.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

/// Shared "append text to a note" rule so the build-admin and upload-time test-note
/// editors grow consistently (single trailing newline between blocks).
enum TestNoteText {
    static func append(_ addition: String, to existing: String) -> String {
        guard !existing.isEmpty else { return addition }
        return existing + (existing.hasSuffix("\n") ? "" : "\n") + addition
    }
}

/// A lazy, read-only reference panel that lists the project's git commits in a date
/// window (previous build → this build, or last build → now) with the branches each
/// landed on, so whoever writes the TestFlight "What to Test" note can see what
/// changed. Nothing runs until the user taps "getir". `onAppend` hands the host the
/// text to append into its own note binding(s).
@MainActor
struct CommitSuggestionPanel: View {
    let repoURL: URL
    let since: Date?
    let until: Date?
    let onAppend: (String) -> Void

    @State private var commits: [GitCommit] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        DisclosureGroup("Commit önerileri") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label(loaded ? "Yenile" : "Commit'leri getir", systemImage: "arrow.triangle.branch")
                    }
                    .controlSize(.small)
                    if isLoading { ProgressView().controlSize(.small) }
                    if loaded, !commits.isEmpty {
                        Button("Tümünü nota ekle") { onAppend(allSuggestionText) }
                            .controlSize(.small)
                    }
                }
                if let rangeText {
                    Text(rangeText).font(.caption2).foregroundStyle(.tertiary)
                }
                if let error {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                if loaded, commits.isEmpty, error == nil {
                    Text("Bu aralıkta commit bulunamadı.").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(commits) { commit in
                    commitRow(commit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    onAppend("- \(commit.subject)\n")
                } label: {
                    Image(systemName: "text.append")
                }
                .buttonStyle(.borderless)
                .help("Bu commit'i nota ekle")
                Text(commit.subject).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text(commit.sha).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(commit.author).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                ForEach(commit.branches, id: \.self) { branch in
                    Text(branch)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var allSuggestionText: String {
        commits.map { "- \($0.subject)" }.joined(separator: "\n") + "\n"
    }

    private var rangeText: String? {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let from = since.map { df.string(from: $0) } ?? "başlangıç"
        let to = until.map { df.string(from: $0) } ?? "şimdi"
        return "\(from) → \(to) arası (merge'ler hariç)"
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            commits = try await GitChangeInspector.commits(repoDir: repoURL, since: since, until: until)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            commits = []
        }
        loaded = true
    }
}

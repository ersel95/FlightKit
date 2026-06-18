//
//  GitChangeInspector.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// One commit surfaced as a test-note suggestion: its subject plus the branches
/// that contain it, so the note writer can see what shipped and where it came from.
struct GitCommit: Identifiable, Hashable {
    let sha: String          // short hash (display)
    let subject: String
    let author: String
    let date: Date?
    let branches: [String]   // branches that contain this commit (deduped, no origin/ prefix)
    var id: String { sha }
}

/// Lists the commits made to a project's git repository within a date window —
/// used to suggest TestFlight "What to Test" content from what actually changed
/// between the previous build and this one. Best-effort: a non-git directory or a
/// missing `git` simply yields an error the caller can show.
enum GitChangeInspector {
    enum GitError: LocalizedError {
        case notARepo(URL)
        case gitFailed(String)
        var errorDescription: String? {
            switch self {
            case .notARepo(let url): return "Bu klasör bir git deposu değil: \(url.path)"
            case .gitFailed(let msg): return "git komutu başarısız: \(msg.suffix(200))"
            }
        }
    }

    /// Commits (newest first, merges excluded) in `(since, until]`. A nil `since`
    /// falls back to the most recent `limit` commits; a nil `until` means "now".
    static func commits(repoDir: URL, since: Date?, until: Date?, limit: Int = 120) async throws -> [GitCommit] {
        let check = try await git(repoDir, ["rev-parse", "--is-inside-work-tree"])
        guard check.exitCode == 0 else { throw GitError.notARepo(repoDir) }

        let iso = ISO8601DateFormatter()
        var args = ["log", "--no-merges", "--max-count=\(limit)",
                    "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%cI"]
        if let since { args.append("--since=\(iso.string(from: since))") }
        if let until { args.append("--until=\(iso.string(from: until))") }
        let result = try await git(repoDir, args)
        guard result.exitCode == 0 else { throw GitError.gitFailed(result.combinedLog) }

        let parser = ISO8601DateFormatter()
        var commits: [GitCommit] = []
        for rawLine in result.combinedLog.split(whereSeparator: { $0.isNewline }) {
            let fields = String(rawLine).components(separatedBy: "\u{1f}")
            guard fields.count == 5 else { continue }
            let branches = (try? await branches(repoDir, fullSha: fields[0])) ?? []
            commits.append(GitCommit(
                sha: fields[1],
                subject: fields[2],
                author: fields[3],
                date: parser.date(from: fields[4]),
                branches: branches
            ))
        }
        return commits
    }

    /// Branches (local + remote) that contain `fullSha`, cleaned to unique short
    /// names: `origin/` stripped, HEAD/symbolic entries dropped.
    private static func branches(_ repoDir: URL, fullSha: String) async throws -> [String] {
        let result = try await git(repoDir, ["branch", "-a", "--contains", fullSha, "--format=%(refname:short)"])
        guard result.exitCode == 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for rawLine in result.combinedLog.split(whereSeparator: { $0.isNewline }) {
            var name = String(rawLine).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.contains("HEAD") || name.contains("->") { continue }
            if name.hasPrefix("origin/") { name = String(name.dropFirst("origin/".count)) }
            if seen.insert(name).inserted { out.append(name) }
        }
        return out.sorted()
    }

    private static func git(_ repoDir: URL, _ args: [String]) async throws -> XcodebuildResult {
        try await XcodebuildRunner.runProcess(
            executable: "/usr/bin/git",
            args: ["-C", repoDir.path] + args,
            onLine: { _, _ in }
        )
    }
}

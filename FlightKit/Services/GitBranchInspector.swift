//
//  GitBranchInspector.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// One selectable branch of the project's repository. `isLocal` distinguishes a
/// checked-out-able local branch from a remote-only one (`origin/…`), which git
/// still resolves on checkout by creating a tracking branch — as long as exactly
/// one remote carries that name.
struct GitBranch: Identifiable, Hashable, Sendable {
    let name: String
    let isLocal: Bool
    var id: String { name }
}

/// What a checkout actually did, so the caller (the pipeline) can log it. Returned
/// instead of taking a log closure: this type crosses actor boundaries, a
/// `@MainActor` logging closure would not.
struct GitCheckoutOutcome: Sendable {
    let branch: String
    /// Branch HEAD pointed at before the checkout (`nil` when detached).
    let previousBranch: String?
    /// `<short sha> <subject>` of the new HEAD — what this build is actually made of.
    let headDescription: String
    /// Paths with uncommitted changes at checkout time (empty on a clean tree).
    /// Git carries compatible modifications across the switch, so this is a warning,
    /// not a failure — the build may not be a pristine copy of the branch.
    let dirtyPaths: [String]
    /// What the update pass did (fetch/pull), ready to log. Empty when updating is
    /// switched off in Settings.
    let updateNotes: [String]
}

/// Reads and switches the branch of a project's git repository, so a publish can
/// be pinned to the branch that environment ships from (e.g. Test ← `tst`,
/// UAT ← `uat`, Prod ← `liv`). Best-effort by design: a non-git directory simply
/// yields "not a repo" and the branch UI stays hidden.
enum GitBranchInspector {
    enum BranchError: LocalizedError {
        case notARepo(URL)
        case checkoutFailed(branch: String, log: String)
        case pullFailed(branch: String, log: String)
        var errorDescription: String? {
            switch self {
            case .notARepo(let url):
                return "Bu klasör bir git deposu değil: \(url.path)"
            case .checkoutFailed(let branch, let log):
                return "'\(branch)' branch'ine geçilemedi.\n\(log.suffix(600))"
            case .pullFailed(let branch, let log):
                return """
                '\(branch)' branch'i güncellenemedi (git pull --ff-only).
                Lokal branch uzaktan ıraksamış olabilir ya da ağ/kimlik doğrulama sorunu vardır. \
                Elle çözün veya Ayarlar'dan "Branch'i yayından önce güncelle" seçeneğini kapatın.
                \(log.suffix(600))
                """
            }
        }
    }

    static func isRepository(_ repoDir: URL) async -> Bool {
        let result = try? await git(repoDir, ["rev-parse", "--is-inside-work-tree"])
        return result?.exitCode == 0
    }

    /// The currently checked-out branch, or `nil` when HEAD is detached (or the
    /// directory isn't a repository).
    static func currentBranch(repoDir: URL) async -> String? {
        guard let result = try? await git(repoDir, ["rev-parse", "--abbrev-ref", "HEAD"]),
              result.exitCode == 0 else { return nil }
        let name = result.combinedLog.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "HEAD") ? nil : name
    }

    /// `git fetch --prune`, so a branch created elsewhere becomes pickable. Returns
    /// whether it succeeded — the caller only refreshes a list, so being offline is
    /// not worth an error.
    @discardableResult
    static func fetch(repoDir: URL) async -> Bool {
        let result = try? await git(repoDir, ["fetch", "--prune"])
        return result?.exitCode == 0
    }

    /// Every branch the user can pick: local branches plus already-fetched remote
    /// branches, deduped on the short name (a local branch shadows its remote twin)
    /// and sorted. No network access — remote branches come from the existing refs,
    /// so a branch created elsewhere shows up only after the user fetches/pulls.
    static func branches(repoDir: URL) async throws -> [GitBranch] {
        guard await isRepository(repoDir) else { throw BranchError.notARepo(repoDir) }
        let result = try await git(repoDir, [
            "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes",
        ])
        guard result.exitCode == 0 else { return [] }

        var locals: [String] = []
        var remotes: [String] = []
        for rawLine in result.combinedLog.split(whereSeparator: { $0.isNewline }) {
            let ref = String(rawLine).trimmingCharacters(in: .whitespaces)
            if let name = ref.dropPrefix("refs/heads/") {
                locals.append(name)
            } else if let remoteRef = ref.dropPrefix("refs/remotes/") {
                // `origin/feature/x` → `feature/x`; skip the symbolic `origin/HEAD`.
                let parts = remoteRef.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[1] != "HEAD" else { continue }
                remotes.append(String(parts[1]))
            }
        }

        let localSet = Set(locals)
        var seen = Set<String>()
        var out = locals.filter { seen.insert($0).inserted }.map { GitBranch(name: $0, isLocal: true) }
        for name in remotes where !localSet.contains(name) && seen.insert(name).inserted {
            out.append(GitBranch(name: name, isLocal: false))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Switches the working copy to `branch`, optionally bringing it up to date
    /// first. Already being on it is a no-op that still reports HEAD. A dirty tree
    /// is *not* pre-blocked: git carries harmless modifications across and refuses
    /// only when the switch would overwrite them — in which case git's own message
    /// is surfaced verbatim, which is the actionable one ("commit or stash …").
    ///
    /// With `pull` on (the Settings default) the sequence is `fetch --prune` →
    /// `checkout` → `pull --ff-only`. Fast-forward only, so a diverged local branch
    /// fails the step instead of being merged or rebased behind the user's back; a
    /// branch with no upstream simply skips the pull. A failed fetch is only a
    /// warning — the pull that follows reports the real problem.
    static func checkout(_ branch: String, repoDir: URL, pull: Bool = false) async throws -> GitCheckoutOutcome {
        guard await isRepository(repoDir) else { throw BranchError.notARepo(repoDir) }
        let previous = await currentBranch(repoDir: repoDir)
        let dirty = await dirtyPaths(repoDir: repoDir)
        var notes: [String] = []

        // Fetch before checking out: a branch that only exists on the remote can
        // then be resolved, and the local ref is fresh for the pull below.
        if pull {
            let fetch = try await git(repoDir, ["fetch", "--prune"])
            notes.append(fetch.exitCode == 0
                         ? "git fetch --prune tamam"
                         : "⚠︎ git fetch başarısız (exit \(fetch.exitCode)) — lokal ref'lerle devam ediliyor")
        }

        if previous != branch {
            let result = try await git(repoDir, ["checkout", branch])
            guard result.exitCode == 0 else {
                throw BranchError.checkoutFailed(branch: branch, log: result.combinedLog)
            }
        }

        if pull {
            if await hasUpstream(repoDir: repoDir) {
                let result = try await git(repoDir, ["pull", "--ff-only"])
                guard result.exitCode == 0 else {
                    throw BranchError.pullFailed(branch: branch, log: result.combinedLog)
                }
                let summary = result.combinedLog
                    .split(whereSeparator: { $0.isNewline })
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .last(where: { !$0.isEmpty }) ?? "tamam"
                notes.append("git pull --ff-only: \(summary)")
            } else {
                notes.append("'\(branch)' için upstream yok — pull atlandı")
            }
        }

        let head = try? await git(repoDir, ["log", "-1", "--pretty=%h %s"])
        return GitCheckoutOutcome(
            branch: branch,
            previousBranch: previous,
            headDescription: (head?.combinedLog ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            dirtyPaths: dirty,
            updateNotes: notes
        )
    }

    /// Whether the checked-out branch tracks a remote branch — pulling a purely
    /// local branch has nothing to pull from and would fail.
    private static func hasUpstream(repoDir: URL) async -> Bool {
        let result = try? await git(repoDir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        return result?.exitCode == 0
    }

    /// Paths with uncommitted changes (tracked or untracked), capped for logging.
    private static func dirtyPaths(repoDir: URL, limit: Int = 12) async -> [String] {
        guard let result = try? await git(repoDir, ["status", "--porcelain"]), result.exitCode == 0 else { return [] }
        return result.combinedLog
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0) }
    }

    private static func git(_ repoDir: URL, _ args: [String]) async throws -> XcodebuildResult {
        try await XcodebuildRunner.runProcess(
            executable: "/usr/bin/git",
            args: ["-C", repoDir.path] + args,
            onLine: { _, _ in }
        )
    }
}

private extension String {
    /// The remainder after `prefix`, or `nil` when the string doesn't start with it.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

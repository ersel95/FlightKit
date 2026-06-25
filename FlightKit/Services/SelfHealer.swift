//
//  SelfHealer.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct SelfHealer {
    let rules: [HealRule]

    static func defaultRules() -> [HealRule] {
        [
            HealRule(
                id: "missing-export-options",
                trigger: .stageAndPattern(stage: PublishStep.exportIPA.rawValue, regex: "exportOptionsPlist .* (missing|not found)"),
                humanDescription: "Regenerating exportOptions.plist (was missing/invalid)",
                fix: { ctx in
                    try ExportOptionsBuilder.write(to: ctx.exportOptionsURL, teamId: ctx.project.teamId)
                    ctx.appendLog("✓ Wrote new exportOptions.plist at \(ctx.exportOptionsURL.path)")
                }
            ),
            HealRule(
                id: "manual-signing-mismatch",
                trigger: .stageAndPattern(stage: PublishStep.exportIPA.rawValue, regex: "(No profiles for|provisioning profile .* doesn't include|No signing certificate)"),
                humanDescription: "Falling back to automatic signing in exportOptions.plist",
                fix: { ctx in
                    try ExportOptionsBuilder.write(to: ctx.exportOptionsURL, teamId: ctx.project.teamId, signingStyle: .automatic)
                    ctx.appendLog("✓ Switched exportOptions.plist to automatic signing")
                }
            ),
            HealRule(
                id: "spm-resolve-failure",
                trigger: .stageAndPattern(stage: PublishStep.archive.rawValue, regex: "(Could not resolve package dependencies|Cannot resolve a Swift package|xcodebuild: error: Could not resolve)"),
                humanDescription: "Cleaning DerivedData and re-resolving Swift packages",
                fix: { ctx in
                    try? FileManager.default.removeItem(at: ctx.derivedDataDir)
                    try? FileManager.default.createDirectory(at: ctx.derivedDataDir, withIntermediateDirectories: true)
                    ctx.appendLog("✓ Removed DerivedData at \(ctx.derivedDataDir.path)")
                }
            ),
            HealRule(
                id: "spm-incomplete-checkout",
                // A package checked out into the shared cache can be left incomplete
                // (interrupted resolve, killed app, network drop) — clang then can't
                // find a header that lives *inside* that same checkout, e.g.
                // "'AppCheckCore/Sources/Core/APIService/GACAppCheckAPIService.h' file
                // not found". The shared cache is never re-validated, so it stays broken
                // forever. Repair surgically: delete only the offending checkout(s) and
                // let the retry's archive re-resolve them — never wipe the whole cache.
                trigger: .stageAndPattern(stage: PublishStep.archive.rawValue, regex: #"SourcePackages/checkouts/[^/]+/[^\n]*(file not found|No such file or directory)"#),
                humanDescription: "Re-fetching incomplete Swift package checkout(s)",
                fix: { ctx in
                    let names = SelfHealer.corruptedCheckoutNames(in: ctx.log)
                    guard !names.isEmpty else {
                        // Couldn't pin the package from the log — bail rather than
                        // nuke unrelated checkouts.
                        ctx.appendLog("⚠︎ Could not identify the broken package from the log; skipping cache repair")
                        return
                    }
                    let fm = FileManager.default
                    let checkoutsDir = ctx.sharedSPMCacheDir.appending(path: "checkouts")
                    for name in names {
                        let dir = checkoutsDir.appending(path: name)
                        try? fm.removeItem(at: dir)
                        ctx.appendLog("✓ Removed incomplete checkout '\(name)' — xcodebuild will re-resolve it on retry")
                    }
                }
            ),
            HealRule(
                id: "spm-missing-binary-artifact",
                // A binary (xcframework) SPM target's artifact can be left INCOMPLETE in the
                // shared cache — an interrupted/partial extraction drops the real `.xcframework`
                // (e.g. only `SealObjc.xcframework` lands, not `Seal.xcframework`; or the dir holds
                // just a LICENSE) while `workspace-state.json` still records the package as
                // resolved. SPM trusts that recorded state and never re-validates the files on
                // disk, so the archive fails *forever* with "There is no XCFramework found at
                // …/SourcePackages/artifacts/<pkg>/<name>/<name>.xcframework". Wiping DerivedData
                // cannot fix it — the artifacts live in the symlinked shared cache, untouched.
                // Repair surgically: delete the broken artifact dir(s) AND drop their entries from
                // workspace-state, so the retry's resolve re-extracts them (the zip is already in
                // SPM's global download cache, so this is fast and needs no network).
                trigger: .stageAndPattern(stage: PublishStep.archive.rawValue, regex: #"There is no XCFramework found at '[^']*/SourcePackages/artifacts/"#),
                humanDescription: "Re-extracting incomplete Swift binary artifact(s) (xcframework)",
                fix: { ctx in
                    let names = SelfHealer.missingArtifactPackageNames(in: ctx.log)
                    guard !names.isEmpty else {
                        ctx.appendLog("⚠︎ Could not identify the broken binary artifact from the log; skipping cache repair")
                        return
                    }
                    let fm = FileManager.default
                    let artifactsDir = ctx.sharedSPMCacheDir.appending(path: "artifacts")
                    for name in names {
                        try? fm.removeItem(at: artifactsDir.appending(path: name))
                        // Also clear the matching extraction-staging dir so a leftover partial
                        // extract can't shadow the fresh one.
                        try? fm.removeItem(at: artifactsDir.appending(path: "extract").appending(path: name))
                        ctx.appendLog("✓ Removed incomplete artifact '\(name)'")
                    }
                    SelfHealer.dropArtifactsFromWorkspaceState(named: names, in: ctx.sharedSPMCacheDir, appendLog: ctx.appendLog)
                    ctx.appendLog("✓ xcodebuild will re-extract the artifact(s) on retry")
                }
            ),
            HealRule(
                id: "stale-archive",
                trigger: .stageAndPattern(stage: PublishStep.exportIPA.rawValue, regex: "(unable to read archive|archive .* not found|No such file or directory.* xcarchive)"),
                humanDescription: "Removing stale .xcarchive and re-archiving",
                fix: { ctx in
                    try? FileManager.default.removeItem(at: ctx.archiveURL)
                    ctx.appendLog("✓ Removed stale archive at \(ctx.archiveURL.path)")
                }
            ),
            HealRule(
                id: "altool-auth-expired",
                trigger: .stageAndPattern(stage: PublishStep.upload.rawValue, regex: "(Authentication failed|Could not authenticate|Unable to authenticate|401 Unauthorized)"),
                humanDescription: "JWT token may be expired — will retry with a fresh one on next attempt",
                fix: { ctx in
                    ctx.appendLog("→ Will refresh JWT on retry (cached token discarded)")
                }
            ),
            HealRule(
                id: "altool-network",
                trigger: .stageAndPattern(stage: PublishStep.upload.rawValue, regex: "(Connection .* (timed out|reset|refused)|Network is unreachable|Could not connect)"),
                humanDescription: "Network blip — waiting 15s before retry",
                fix: { _ in
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                }
            ),
            HealRule(
                id: "build-locked",
                trigger: .stageAndPattern(stage: PublishStep.archive.rawValue, regex: "(Resource is busy|Could not lock|database is locked)"),
                humanDescription: "Another xcodebuild process holds the lock — waiting 10s",
                fix: { _ in
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                }
            ),
        ]
    }

    /// Parses a build log for SPM checkout paths that reported a missing file, and
    /// returns the distinct package directory names (the `<name>` in
    /// `SourcePackages/checkouts/<name>/…`). The compiler prints the broken source's
    /// absolute path — which includes the checkout dir — on the same line as the
    /// "file not found" / "No such file" diagnostic, so we scan line by line.
    static func corruptedCheckoutNames(in log: String) -> [String] {
        var names: [String] = []
        for line in log.split(separator: "\n") {
            guard line.contains("file not found") || line.contains("No such file") else { continue }
            guard let range = line.range(of: #"checkouts/[^/]+/"#, options: .regularExpression) else { continue }
            // range covers "checkouts/<name>/" — strip the fixed prefix and trailing slash.
            let name = line[range].dropFirst("checkouts/".count).dropLast()
            if !name.isEmpty, !names.contains(String(name)) {
                names.append(String(name))
            }
        }
        return names
    }

    /// Parses a build log for `There is no XCFramework found at
    /// '<…>/SourcePackages/artifacts/<pkg>/<name>/<name>.xcframework'` archive failures and
    /// returns the distinct package-identity dir names (`<pkg>`). A binary artifact extracted
    /// incompletely into the shared cache leaves the package recorded as resolved in
    /// workspace-state but missing its `.xcframework` on disk; this pins which artifact dir(s)
    /// to purge so the retry re-extracts them.
    static func missingArtifactPackageNames(in log: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"SourcePackages/artifacts/([^/]+)/"#) else { return [] }
        var names: [String] = []
        for line in log.split(separator: "\n") {
            guard line.contains("There is no XCFramework found at") else { continue }
            let s = String(line)
            guard let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let range = Range(match.range(at: 1), in: s) else { continue }
            let name = String(s[range])
            // `extract` is the staging dir, not a package — never treat it as one.
            if !name.isEmpty, name != "extract", !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Removes the named packages' binary-artifact entries from the shared cache's
    /// `workspace-state.json`. SPM records resolved binary artifacts there and will NOT
    /// re-validate their on-disk presence — so an incomplete extraction stays broken until the
    /// stale entry is dropped, after which the next resolve re-fetches/extracts it. Best-effort:
    /// a malformed/absent state file just means the retry re-resolves more than strictly needed.
    static func dropArtifactsFromWorkspaceState(named names: [String], in sharedSPMCacheDir: URL, appendLog: (String) -> Void) {
        let stateURL = sharedSPMCacheDir.appending(path: "workspace-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var object = root["object"] as? [String: Any],
              let artifacts = object["artifacts"] as? [[String: Any]] else {
            appendLog("⚠︎ Could not read workspace-state.json; retry will re-resolve from scratch instead")
            return
        }
        let wanted = Set(names)
        let kept = artifacts.filter { entry in
            let identity = (entry["packageRef"] as? [String: Any])?["identity"] as? String
            return identity.map { !wanted.contains($0) } ?? true
        }
        guard kept.count != artifacts.count else { return }
        object["artifacts"] = kept
        root["object"] = object
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: stateURL)
        appendLog("✓ Dropped \(artifacts.count - kept.count) stale artifact entr\(artifacts.count - kept.count == 1 ? "y" : "ies") from workspace-state.json")
    }

    func attemptFix(stage: String, log: String, context: HealContext) async -> HealRule? {
        for rule in rules {
            if rule.matches(stage: stage, log: log) {
                do {
                    try await rule.fix(context)
                    return rule
                } catch {
                    context.appendLog("✗ Heal rule '\(rule.id)' failed: \(error.localizedDescription)")
                    return nil
                }
            }
        }
        return nil
    }
}

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
                id: "archive-missing-resource-bundle",
                // After the package graph changes (e.g. a checkout was just re-resolved
                // by `spm-incomplete-checkout`), the per-run DerivedData — which is
                // reused across publish runs — goes stale: the incremental build thinks
                // SPM resource bundles are up-to-date while the files are actually gone,
                // and archive dies with e.g.
                // "lstat(.../Prod-iphoneos/nanopb_nanopb.bundle): No such file or directory".
                // Cleaning DerivedData forces a fresh build that rebuilds the bundles. The
                // shared SPM cache is only symlinked into DerivedData (recreated on the
                // next archive), so wiping DerivedData never touches the resolved packages.
                trigger: .stageAndPattern(stage: PublishStep.archive.rawValue, regex: #"lstat\([^)]*\.bundle\): No such file or directory"#),
                humanDescription: "Cleaning stale DerivedData and re-archiving (missing resource bundle)",
                fix: { ctx in
                    try? FileManager.default.removeItem(at: ctx.derivedDataDir)
                    try? FileManager.default.createDirectory(at: ctx.derivedDataDir, withIntermediateDirectories: true)
                    ctx.appendLog("✓ Removed stale DerivedData at \(ctx.derivedDataDir.path) — archive will rebuild resource bundles on retry")
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

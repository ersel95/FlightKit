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

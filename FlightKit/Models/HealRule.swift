//
//  HealRule.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct HealRule: Identifiable, Sendable {
    enum Trigger: Sendable {
        case stageAndPattern(stage: String, regex: String)
    }

    let id: String
    let trigger: Trigger
    let humanDescription: String
    let fix: @Sendable (HealContext) async throws -> Void

    func matches(stage: String, log: String) -> Bool {
        switch trigger {
        case .stageAndPattern(let s, let pattern):
            guard s == stage else { return false }
            return log.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

struct HealContext: Sendable {
    let project: AppProject
    let workspaceRoot: URL
    let derivedDataDir: URL
    let exportOptionsURL: URL
    let archiveURL: URL
    /// Persistent shared SPM checkout cache (`<derivedData>/SourcePackages` is a
    /// symlink to this). Heal rules use it to repair individual package checkouts.
    let sharedSPMCacheDir: URL
    /// The failing step's recent log, so a fix can parse it (e.g. to find which
    /// package checkout is broken) instead of nuking unrelated state.
    let log: String
    let appendLog: @Sendable (String) -> Void
}

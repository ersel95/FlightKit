//
//  HealRule.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct HealRule: Identifiable {
    enum Trigger {
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

struct HealContext {
    let project: AppProject
    let workspaceRoot: URL
    let derivedDataDir: URL
    let exportOptionsURL: URL
    let archiveURL: URL
    let appendLog: @Sendable (String) -> Void
}

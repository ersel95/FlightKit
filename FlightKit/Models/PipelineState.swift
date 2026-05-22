//
//  PipelineState.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

@MainActor
@Observable
final class PipelineState {
    let project: AppProject
    let destination: DistributionTarget
    let targetVersion: String
    let targetBuildNumber: String
    var stepStatuses: [PublishStep: PublishStepStatus]
    var currentStep: PublishStep?
    var logLines: [LogLine] = []
    var isFinished: Bool = false
    var finalIPAPath: URL?
    var uploadedBuildId: String?
    /// When altool reported the upload as accepted — used to ignore stale builds
    /// while polling (only builds uploaded at/after this are "ours").
    var uploadedAt: Date?
    /// What App Store Connect actually recorded for the accepted build. May differ
    /// from `targetVersion`/`targetBuildNumber` if the store renumbered the build.
    var publishedMarketingVersion: String?
    var publishedBuildNumber: String?
    var processingStateText: String?

    /// True once ASC reports a build number different from the one we submitted.
    var buildNumberWasRenumbered: Bool {
        guard let publishedBuildNumber else { return false }
        return publishedBuildNumber != targetBuildNumber
    }

    /// The ordered steps for this run — depends on the destination (App Store
    /// adds the attach step).
    var steps: [PublishStep] { PublishStep.steps(for: destination) }

    init(project: AppProject, destination: DistributionTarget, version: String, buildNumber: String) {
        self.project = project
        self.destination = destination
        self.targetVersion = version
        self.targetBuildNumber = buildNumber
        var initial: [PublishStep: PublishStepStatus] = [:]
        for step in PublishStep.steps(for: destination) {
            initial[step] = .pending
        }
        self.stepStatuses = initial
    }

    /// True once any step has terminally failed. Drives the batch runner's
    /// decision to abort remaining environments (don't ship PROD if TEST broke).
    var hasFailure: Bool {
        stepStatuses.values.contains { if case .failed = $0 { return true } else { return false } }
    }

    func setStep(_ step: PublishStep, status: PublishStepStatus) {
        stepStatuses[step] = status
        if case .running = status { currentStep = step }
        if case .retrying = status { currentStep = step }
    }

    func appendLog(_ line: String, kind: LogLine.Kind = .stdout) {
        logLines.append(LogLine(message: line, kind: kind, timestamp: Date()))
    }
}

/// An ordered run of one or more `PipelineState`s executed back-to-back.
/// A single-environment publish is just a batch of one; the "All" selection
/// produces Test → UAT → Prod in that order. The runner advances `activeIndex`
/// and the pipeline view follows it.
@MainActor
@Observable
final class PipelineBatch: Identifiable {
    let id = UUID()
    let states: [PipelineState]
    var activeIndex: Int = 0
    var isFinished: Bool = false

    init(states: [PipelineState]) {
        self.states = states
    }
}

struct LogLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case stdout
        case stderr
        case info
        case fix
        case error
    }
    let id = UUID()
    let message: String
    let kind: Kind
    let timestamp: Date
}

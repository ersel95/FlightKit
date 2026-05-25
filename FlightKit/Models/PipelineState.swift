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
    /// The raw ASC processing state ("PROCESSING", "VALID", …) from the last poll.
    var processingStateText: String?
    /// High-level lifecycle of the post-upload, non-blocking processing watch.
    /// The blocking pipeline ends at `upload`; this tracks what happens afterwards
    /// (ASC processing and, for App Store, the automatic version attach) while the
    /// pipeline screen stays open.
    var processingPhase: ProcessingPhase = .idle

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
    /// True once every environment's *blocking* pipeline (through upload) has run.
    /// Processing watches may still be polling in the background after this flips.
    var isFinished: Bool = false

    /// Background processing watches, one per uploaded environment. They run
    /// independently (so no environment waits on another's processing) and are
    /// cancelled when the pipeline screen closes.
    private var processingTasks: [Task<Void, Never>] = []

    init(states: [PipelineState]) {
        self.states = states
    }

    func trackProcessingWatch(_ task: Task<Void, Never>) {
        processingTasks.append(task)
    }

    /// Stops all in-flight processing watches — called when the screen closes,
    /// since the watch only runs "while the screen stays open".
    func cancelProcessingWatches() {
        for task in processingTasks { task.cancel() }
        processingTasks.removeAll()
    }
}

/// Lifecycle of the background processing watch that runs after `upload`.
enum ProcessingPhase: Equatable {
    /// Upload not yet reached / watch not started.
    case idle
    /// Polling App Store Connect for the build to finish processing.
    case waiting
    /// Build processed successfully (TestFlight-ready). Terminal for TestFlight.
    case valid
    /// App Store only: attaching the processed build to an App Store version.
    case attaching
    /// App Store only: build attached to the named version (not submitted).
    case attached(version: String)
    /// Processing or attach failed / timed out.
    case failed(reason: String)
    /// Watch was stopped before completing (pipeline screen closed).
    case stopped

    /// No further work will happen on its own — `valid`/`attached`/`failed`.
    var isTerminal: Bool {
        switch self {
        case .valid, .attached, .failed: return true
        case .idle, .waiting, .attaching, .stopped: return false
        }
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

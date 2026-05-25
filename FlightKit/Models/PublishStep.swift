//
//  PublishStep.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

enum PublishStep: String, CaseIterable, Identifiable, Hashable {
    case validate = "Validate"
    case writeXcconfig = "Write version to xcconfig"
    case generateExportOptions = "Generate exportOptions.plist"
    case archive = "Archive"
    case exportIPA = "Export IPA"
    case upload = "Upload to App Store Connect"
    case waitProcessing = "Wait for processing"
    case attachVersion = "Attach to App Store version"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// The ordered *blocking* steps for a given destination. The pipeline ends at
    /// `upload`; what comes after — ASC processing and (App Store only) the version
    /// attach — runs as a non-blocking background watch so environments in an "All"
    /// sweep never wait on each other's processing. `waitProcessing`/`attachVersion`
    /// therefore no longer appear as pipeline steps (see `ProcessingPhase`).
    static func steps(for destination: DistributionTarget) -> [PublishStep] {
        [
            .validate, .writeXcconfig, .generateExportOptions,
            .archive, .exportIPA, .upload,
        ]
    }

    var systemImage: String {
        switch self {
        case .validate: return "checkmark.shield"
        case .writeXcconfig: return "doc.text"
        case .generateExportOptions: return "list.bullet.rectangle"
        case .archive: return "archivebox"
        case .exportIPA: return "shippingbox"
        case .upload: return "icloud.and.arrow.up"
        case .waitProcessing: return "clock.arrow.circlepath"
        case .attachVersion: return "app.badge.checkmark"
        }
    }
}

enum PublishStepStatus: Hashable {
    case pending
    case running
    case retrying(reason: String)
    case succeeded
    case failed(message: String)

    var isActive: Bool {
        switch self {
        case .running, .retrying: return true
        default: return false
        }
    }
}

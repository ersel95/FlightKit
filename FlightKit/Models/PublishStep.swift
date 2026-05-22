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

    /// The ordered steps for a given destination. `attachVersion` only runs for
    /// App Store (TestFlight needs nothing past processing).
    static func steps(for destination: DistributionTarget) -> [PublishStep] {
        var steps: [PublishStep] = [
            .validate, .writeXcconfig, .generateExportOptions,
            .archive, .exportIPA, .upload, .waitProcessing,
        ]
        if destination == .appStore { steps.append(.attachVersion) }
        return steps
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

//
//  ASCBuild.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct ASCBuild: Identifiable, Hashable {
    let id: String
    let version: String
    let preReleaseVersion: String
    let processingState: ProcessingState
    let uploadedDate: Date?
    let expired: Bool
    /// Export-compliance answer recorded on the build. `nil` = not yet answered
    /// (App Store Connect shows "Missing Compliance" and blocks TestFlight until
    /// it's set). `true`/`false` map to "uses non-exempt encryption".
    var usesNonExemptEncryption: Bool? = nil

    enum ProcessingState: String, Hashable {
        case processing = "PROCESSING"
        case failed = "FAILED"
        case invalid = "INVALID"
        case valid = "VALID"
        case unknown = "UNKNOWN"

        init(raw: String?) {
            self = ProcessingState(rawValue: raw ?? "") ?? .unknown
        }

        var isTerminal: Bool {
            switch self {
            case .valid, .failed, .invalid: return true
            case .processing, .unknown: return false
            }
        }
    }
}

struct ASCAppStoreVersion: Hashable {
    let id: String
    let versionString: String
    let appStoreState: String
    var copyright: String = ""
}

struct ASCApp: Hashable {
    let id: String
    let name: String
    let bundleId: String
}

/// A TestFlight beta group (internal or external) on an app record. The user
/// picks a subset at launch; the processed build is assigned to them once it
/// reaches VALID. External groups only distribute after the build clears beta
/// review.
struct ASCBetaGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let isInternal: Bool
    /// "Default" groups that automatically receive *every* build. Assigning a build
    /// to one is a no-op, so the publish picker hides them — but the build admin
    /// screen still surfaces them read-only so its membership matches ASC.
    var hasAccessToAllBuilds: Bool = false
}

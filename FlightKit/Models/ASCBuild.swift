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
}

struct ASCApp: Hashable {
    let id: String
    let name: String
    let bundleId: String
}

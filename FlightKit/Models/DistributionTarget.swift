//
//  DistributionTarget.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// Where a build should land. The upload itself is identical for both — the
/// difference is what happens afterwards.
enum DistributionTarget: String, CaseIterable, Identifiable, Codable, Hashable {
    /// Upload only; the build becomes available to TestFlight testers.
    case testFlight
    /// Upload, then attach the processed build to an editable App Store version
    /// (created if needed). It is **not** submitted for review — you finish that
    /// in App Store Connect.
    case appStore

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .testFlight: return "TestFlight"
        case .appStore: return "App Store"
        }
    }
}

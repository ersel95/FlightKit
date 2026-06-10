//
//  AppSettings.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// App-wide preferences that govern how the publish pipeline collects a build
/// number. Stored in `UserDefaults` (the Settings window binds them via
/// `@AppStorage`); both default to `true` so the out-of-the-box behaviour is
/// unchanged: ask for one shared build number per run.
enum AppSettings {
    /// When `true`, the build number is asked for on every run (the editable
    /// field is shown). When `false`, the field is hidden and the pipeline
    /// silently submits `1` for every environment.
    static let buildNumberManagedKey = "FlightKit.settings.buildNumberManaged"

    /// Only meaningful when `buildNumberManaged` is `true`. When `true`, a
    /// single build number is shared across every selected environment (today's
    /// behaviour). When `false`, each environment gets its own build-number
    /// field and value.
    static let buildNumberSharedKey = "FlightKit.settings.buildNumberShared"

    /// The build number sent in the background when management is disabled.
    static let unmanagedBuildNumber = "1"

    static var buildNumberManaged: Bool {
        UserDefaults.standard.object(forKey: buildNumberManagedKey) as? Bool ?? true
    }

    static var buildNumberShared: Bool {
        UserDefaults.standard.object(forKey: buildNumberSharedKey) as? Bool ?? true
    }
}

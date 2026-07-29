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

    /// When `true`, a TestFlight "What to Test" note is asked for on every run
    /// (the editable field is shown). When `false`, the field is hidden and no
    /// note is written. The note itself is always optional — leaving it blank
    /// simply skips the write.
    static let testNoteManagedKey = "FlightKit.settings.testNoteManaged"

    /// Only meaningful when `testNoteManaged` is `true`. When `true`, one note is
    /// shared across every selected environment; when `false`, each environment
    /// gets its own note field.
    static let testNoteSharedKey = "FlightKit.settings.testNoteShared"

    static var testNoteManaged: Bool {
        UserDefaults.standard.object(forKey: testNoteManagedKey) as? Bool ?? true
    }

    static var testNoteShared: Bool {
        UserDefaults.standard.object(forKey: testNoteSharedKey) as? Bool ?? true
    }

    /// When `true` (the default), a run that pinned a git branch updates it before
    /// archiving: `git fetch --prune`, then `git pull --ff-only` once the branch is
    /// checked out — so the package is built from what the remote actually has.
    /// Turn it off to build the local copy as it stands (offline, or to ship a
    /// deliberately older commit).
    static let branchPullOnCheckoutKey = "FlightKit.settings.branchPullOnCheckout"

    static var branchPullOnCheckout: Bool {
        UserDefaults.standard.object(forKey: branchPullOnCheckoutKey) as? Bool ?? true
    }
}

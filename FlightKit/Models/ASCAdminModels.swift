//
//  ASCAdminModels.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// A TestFlight beta tester on an app record. Used by the build admin screen to
/// assign/remove individual testers (those invited directly to a build, separate
/// from group membership).
struct ASCBetaTester: Identifiable, Hashable {
    let id: String
    let email: String
    let firstName: String
    let lastName: String

    /// "First Last" when names exist, else the email — for display in chips/lists.
    var displayName: String {
        let full = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? email : full
    }
}

/// One locale's TestFlight "What to Test" note on a build. Unlike the upload-time
/// flow (which only writes), the admin screen reads the existing text so it can be
/// edited per locale.
struct BetaBuildLocalization: Identifiable, Hashable {
    let id: String
    let locale: String
    var whatsNew: String
}

/// One locale's tester-facing TestFlight "app" metadata (App Store Connect →
/// TestFlight → Test Information). App-scoped, not build-scoped.
struct BetaAppLocalization: Identifiable, Hashable {
    let id: String
    let locale: String
    var description: String
    var feedbackEmail: String
    var marketingUrl: String
    var privacyPolicyUrl: String
}

/// The single external-beta-review contact + demo-account record for an app. Apple
/// requires it before an external build can clear beta review.
struct BetaAppReviewDetail: Identifiable, Hashable {
    let id: String
    var contactEmail: String
    var contactFirstName: String
    var contactLastName: String
    var contactPhone: String
    var demoAccountName: String
    var demoAccountPassword: String
    var demoAccountRequired: Bool
    var notes: String
}

/// One locale's editable App Store version text (App Store destination). Maps to a
/// single `appStoreVersionLocalizations` record.
struct AppStoreVersionLocalization: Identifiable, Hashable {
    let id: String
    let locale: String
    var description: String
    var keywords: String
    var whatsNew: String
    var promotionalText: String
    var marketingUrl: String
    var supportUrl: String
}

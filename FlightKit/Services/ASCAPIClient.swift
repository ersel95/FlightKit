//
//  ASCAPIClient.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

actor ASCAPIClient {
    private let credentials: ASCCredentials
    private var cachedToken: (token: String, expiry: Date)?

    init(credentials: ASCCredentials) {
        self.credentials = credentials
    }

    private func token() throws -> String {
        if let cached = cachedToken, cached.expiry.timeIntervalSinceNow > 60 {
            return cached.token
        }
        let validity: TimeInterval = 1200
        let token = try JWTGenerator.make(credentials: credentials, validity: validity)
        cachedToken = (token, Date().addingTimeInterval(validity))
        return token
    }

    func findApp(bundleId: String) async throws -> ASCApp? {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps")!
            .appending(queryItems: [URLQueryItem(name: "filter[bundleId]", value: bundleId)])
        let (data, response) = try await get(url)
        try ensureOK(response, data: data)

        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let name: String
                    let bundleId: String
                }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        // ASC's filter[bundleId] is a *prefix/substring* match, not exact: querying
        // "com.acme.app" also returns "com.acme.app.test", "com.acme.app.uat", etc.
        // (the order is not significant). Taking `.first` would resolve a sibling
        // app — uploading/version-checking against the wrong record — whenever
        // environments share a bundle-id prefix (the usual Test/UAT/Prod layout).
        // Always pin the exact match.
        guard let item = env.data.first(where: { $0.attributes.bundleId == bundleId }) else { return nil }
        return ASCApp(id: item.id, name: item.attributes.name, bundleId: item.attributes.bundleId)
    }

    func latestBuild(appId: String) async throws -> ASCBuild? {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/builds")!
        components.queryItems = [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include", value: "preReleaseVersion"),
        ]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        return decodeFirstBuild(from: data)
    }

    func build(byVersion version: String, appId: String) async throws -> ASCBuild? {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/builds")!
        components.queryItems = [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "filter[version]", value: version),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include", value: "preReleaseVersion"),
        ]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        return decodeFirstBuild(from: data)
    }

    func latestAppStoreVersion(appId: String) async throws -> ASCAppStoreVersion? {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/apps/\(appId)/appStoreVersions")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "1"),
        ]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)

        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let versionString: String
                    let appStoreState: String?
                    let copyright: String?
                }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let item = env.data.first else { return nil }
        return ASCAppStoreVersion(
            id: item.id,
            versionString: item.attributes.versionString,
            appStoreState: item.attributes.appStoreState ?? "UNKNOWN",
            copyright: item.attributes.copyright ?? ""
        )
    }

    private func decodeFirstBuild(from data: Data) -> ASCBuild? {
        decodeBuilds(from: data).first
    }

    private func decodeBuilds(from data: Data) -> [ASCBuild] {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                let relationships: Relationships?
                struct Attrs: Decodable {
                    let version: String?
                    let processingState: String?
                    let uploadedDate: Date?
                    let expired: Bool?
                    let usesNonExemptEncryption: Bool?
                }
                struct Relationships: Decodable {
                    let preReleaseVersion: PRV?
                    struct PRV: Decodable {
                        let data: PRVData?
                        struct PRVData: Decodable { let id: String }
                    }
                }
            }
            struct Included: Decodable {
                let id: String
                let type: String
                let attributes: Attrs
                struct Attrs: Decodable { let version: String? }
            }
            let data: [Item]
            let included: [Included]?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let env = try? decoder.decode(Envelope.self, from: data) else { return [] }
        return env.data.map { item in
            let prvId = item.relationships?.preReleaseVersion?.data?.id
            let prvVersion = env.included?.first(where: { $0.id == prvId && $0.type == "preReleaseVersions" })?.attributes.version ?? ""
            return ASCBuild(
                id: item.id,
                version: item.attributes.version ?? "",
                preReleaseVersion: prvVersion,
                processingState: ASCBuild.ProcessingState(raw: item.attributes.processingState),
                uploadedDate: item.attributes.uploadedDate,
                expired: item.attributes.expired ?? false,
                usesNonExemptEncryption: item.attributes.usesNonExemptEncryption
            )
        }
    }

    // MARK: - App Store version (for the App Store destination)

    /// An editable App Store version this build can attach to. Returns the first
    /// version matching `versionString` on iOS, or nil if none exists yet.
    func appStoreVersion(appId: String, versionString: String) async throws -> ASCAppStoreVersion? {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/apps/\(appId)/appStoreVersions")!
        components.queryItems = [
            URLQueryItem(name: "filter[versionString]", value: versionString),
            URLQueryItem(name: "filter[platform]", value: "IOS"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        return decodeFirstVersion(from: data)
    }

    /// Creates a new editable iOS App Store version with `versionString`.
    func createAppStoreVersion(appId: String, versionString: String) async throws -> ASCAppStoreVersion {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/appStoreVersions")!
        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersions",
                "attributes": ["platform": "IOS", "versionString": versionString],
                "relationships": ["app": ["data": ["type": "apps", "id": appId]]],
            ],
        ]
        let (data, response) = try await send("POST", url: url, jsonBody: body)
        try ensureOK(response, data: data)
        guard let version = decodeFirstVersion(from: wrapSingle(data)) else {
            throw PublishError.ascAPIError(status: 0, body: "Could not decode created appStoreVersion")
        }
        return version
    }

    /// Attaches `buildId` to the App Store version's `build` relationship. Does not
    /// submit for review — the version stays editable in App Store Connect.
    func attachBuild(versionId: String, buildId: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/appStoreVersions/\(versionId)/relationships/build")!
        let body: [String: Any] = ["data": ["type": "builds", "id": buildId]]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - TestFlight "What to Test" (betaBuildLocalizations)

    /// The build's existing "What to Test" localizations, one per locale. App
    /// Store Connect seeds these automatically for a build's locales; we write the
    /// note into each (or create one for `en-US` if none exist yet).
    func betaBuildLocalizations(buildId: String) async throws -> [(id: String, locale: String)] {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)/betaBuildLocalizations")!
        let (data, response) = try await get(url)
        try ensureOK(response, data: data)

        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable { let locale: String? }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.data.map { (id: $0.id, locale: $0.attributes.locale ?? "") }
    }

    /// Updates an existing localization's `whatsNew` (the TestFlight test note).
    func updateTestNote(localizationId: String, whatsNew: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/\(localizationId)")!
        let body: [String: Any] = [
            "data": [
                "type": "betaBuildLocalizations",
                "id": localizationId,
                "attributes": ["whatsNew": whatsNew],
            ],
        ]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    /// Creates a new localization carrying the test note for `locale` (used when
    /// the build has no betaBuildLocalizations yet).
    func createTestNote(buildId: String, locale: String, whatsNew: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations")!
        let body: [String: Any] = [
            "data": [
                "type": "betaBuildLocalizations",
                "attributes": ["locale": locale, "whatsNew": whatsNew],
                "relationships": ["build": ["data": ["type": "builds", "id": buildId]]],
            ],
        ]
        let (data, response) = try await send("POST", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - TestFlight beta groups

    /// The *assignable* beta groups on the app record — those a build must be added
    /// to explicitly. Groups with `hasAccessToAllBuilds` (the "default" groups that
    /// automatically receive every build) are filtered out: assigning to them is a
    /// no-op, so they'd only clutter the picker.
    func betaGroups(appId: String) async throws -> [ASCBetaGroup] {
        try await allBetaGroups(appId: appId).filter { !$0.hasAccessToAllBuilds }
    }

    /// Every beta group on the app record, including the `hasAccessToAllBuilds`
    /// "default" groups (which `betaGroups` hides). The build admin screen needs the
    /// full set to display membership that matches App Store Connect.
    func allBetaGroups(appId: String) async throws -> [ASCBetaGroup] {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/apps/\(appId)/betaGroups")!
        components.queryItems = [URLQueryItem(name: "limit", value: "200")]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)

        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let name: String?
                    let isInternalGroup: Bool?
                    let hasAccessToAllBuilds: Bool?
                }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.data.map {
            ASCBetaGroup(
                id: $0.id,
                name: $0.attributes.name ?? "—",
                isInternal: $0.attributes.isInternalGroup ?? false,
                hasAccessToAllBuilds: $0.attributes.hasAccessToAllBuilds ?? false
            )
        }
    }

    /// Adds `buildId` to a beta group's build list — the build becomes available to
    /// that group's testers (external groups distribute only after beta review).
    func addBuild(_ buildId: String, toBetaGroup groupId: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaGroups/\(groupId)/relationships/builds")!
        let body: [String: Any] = ["data": [["type": "builds", "id": buildId]]]
        let (data, response) = try await send("POST", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - Build admin: listing & build attributes

    /// Recent builds for an app, newest first — for the build admin browser. Each
    /// carries its TestFlight version, processing state, expiry and export-compliance
    /// answer.
    func builds(appId: String, limit: Int = 25) async throws -> [ASCBuild] {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/builds")!
        components.queryItems = [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "include", value: "preReleaseVersion"),
        ]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        return decodeBuilds(from: data)
    }

    /// Records the export-compliance (encryption) answer on a build — this is what
    /// clears App Store Connect's "Missing Compliance" status so the build becomes
    /// testable.
    func setExportCompliance(buildId: String, usesNonExemptEncryption: Bool) async throws {
        try await patchBuild(buildId, attributes: ["usesNonExemptEncryption": usesNonExemptEncryption])
    }

    /// Expires a build so testers can no longer install it. (Apple only honours
    /// setting this to `true`.)
    func setBuildExpired(buildId: String, expired: Bool) async throws {
        try await patchBuild(buildId, attributes: ["expired": expired])
    }

    private func patchBuild(_ buildId: String, attributes: [String: Any]) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)")!
        let body: [String: Any] = ["data": ["type": "builds", "id": buildId, "attributes": attributes]]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - Build admin: beta group membership

    /// The ids of the beta groups a build is currently assigned to — so the admin
    /// picker can show existing membership, not just add to it.
    ///
    /// Note: the `/builds/{id}/betaGroups` and `/builds/{id}/relationships/betaGroups`
    /// endpoints both return **403 FORBIDDEN** ("the given operation is not allowed")
    /// for an API-key token. Reading the linkage off the build resource itself via
    /// `?include=betaGroups` is the path that's actually permitted.
    func betaGroupIds(forBuild buildId: String) async throws -> Set<String> {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)")!
        components.queryItems = [URLQueryItem(name: "include", value: "betaGroups")]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        struct Envelope: Decodable {
            struct Item: Decodable {
                struct Relationships: Decodable {
                    struct BetaGroups: Decodable {
                        struct Ref: Decodable { let id: String }
                        let data: [Ref]?
                    }
                    let betaGroups: BetaGroups?
                }
                let relationships: Relationships?
            }
            let data: Item
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return Set((env.data.relationships?.betaGroups?.data ?? []).map(\.id))
    }

    /// Removes a build from a beta group's build list (the inverse of `addBuild`).
    func removeBuild(_ buildId: String, fromBetaGroup groupId: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaGroups/\(groupId)/relationships/builds")!
        let body: [String: Any] = ["data": [["type": "builds", "id": buildId]]]
        let (data, response) = try await send("DELETE", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - Build admin: "What to Test" (read for editing)

    /// The build's existing test-note localizations *with* their current text, so the
    /// admin screen can edit them in place. (The publish flow's variant returns only
    /// id+locale because it overwrites.)
    func betaBuildLocalizationsDetailed(buildId: String) async throws -> [BetaBuildLocalization] {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)/betaBuildLocalizations")!
        let (data, response) = try await get(url)
        try ensureOK(response, data: data)
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable { let locale: String?; let whatsNew: String? }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.data.map {
            BetaBuildLocalization(id: $0.id, locale: $0.attributes.locale ?? "", whatsNew: $0.attributes.whatsNew ?? "")
        }
    }

    // MARK: - Build admin: individual testers

    /// Testers invited to this build directly (the build's `individualTesters`),
    /// independent of group membership.
    func individualTesters(forBuild buildId: String) async throws -> [ASCBetaTester] {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)/individualTesters")!
        components.queryItems = [URLQueryItem(name: "limit", value: "200")]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        return decodeBetaTesters(from: data)
    }

    /// The app's **internal** beta testers — members of its internal beta groups.
    /// This is the pool the admin screen offers for individual build assignment:
    /// `PUBLIC_LINK` (external/"Anonymous") and other external testers are excluded,
    /// since a build can't meaningfully be opened to them individually here.
    /// Filtering by the internal group ids returns only those testers in one query.
    func internalBetaTesters(appId: String) async throws -> [ASCBetaTester] {
        let internalGroupIds = try await allBetaGroups(appId: appId).filter(\.isInternal).map(\.id)
        guard !internalGroupIds.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/betaTesters")!
        components.queryItems = [
            URLQueryItem(name: "filter[betaGroups]", value: internalGroupIds.joined(separator: ",")),
            URLQueryItem(name: "limit", value: "200"),
        ]
        let (data, response) = try await get(components.url!)
        try ensureOK(response, data: data)
        return decodeBetaTesters(from: data)
    }

    func assignIndividualTester(_ testerId: String, toBuild buildId: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)/relationships/individualTesters")!
        let body: [String: Any] = ["data": [["type": "betaTesters", "id": testerId]]]
        let (data, response) = try await send("POST", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    func removeIndividualTester(_ testerId: String, fromBuild buildId: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/builds/\(buildId)/relationships/individualTesters")!
        let body: [String: Any] = ["data": [["type": "betaTesters", "id": testerId]]]
        let (data, response) = try await send("DELETE", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    private func decodeBetaTesters(from data: Data) -> [ASCBetaTester] {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable { let email: String?; let firstName: String?; let lastName: String? }
            }
            let data: [Item]
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return env.data.map {
            ASCBetaTester(id: $0.id, email: $0.attributes.email ?? "", firstName: $0.attributes.firstName ?? "", lastName: $0.attributes.lastName ?? "")
        }
    }

    // MARK: - App admin: TestFlight "Test Information" (betaAppLocalizations)

    /// The tester-facing TestFlight metadata for an app, one record per locale.
    func betaAppLocalizations(appId: String) async throws -> [BetaAppLocalization] {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps/\(appId)/betaAppLocalizations")!
        let (data, response) = try await get(url)
        try ensureOK(response, data: data)
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let locale: String?
                    let description: String?
                    let feedbackEmail: String?
                    let marketingUrl: String?
                    let privacyPolicyUrl: String?
                }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.data.map {
            BetaAppLocalization(
                id: $0.id,
                locale: $0.attributes.locale ?? "",
                description: $0.attributes.description ?? "",
                feedbackEmail: $0.attributes.feedbackEmail ?? "",
                marketingUrl: $0.attributes.marketingUrl ?? "",
                privacyPolicyUrl: $0.attributes.privacyPolicyUrl ?? ""
            )
        }
    }

    func updateBetaAppLocalization(_ loc: BetaAppLocalization) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaAppLocalizations/\(loc.id)")!
        let body: [String: Any] = [
            "data": [
                "type": "betaAppLocalizations",
                "id": loc.id,
                "attributes": [
                    "description": orNull(loc.description),
                    "feedbackEmail": orNull(loc.feedbackEmail),
                    "marketingUrl": orNull(loc.marketingUrl),
                    "privacyPolicyUrl": orNull(loc.privacyPolicyUrl),
                ],
            ],
        ]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - App admin: external beta review detail (betaAppReviewDetails)

    /// The single beta-review contact + demo-account record for an app (Apple needs
    /// it before an external build clears beta review). Returns `nil` if the app
    /// has none yet.
    func betaAppReviewDetail(appId: String) async throws -> BetaAppReviewDetail? {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps/\(appId)/betaAppReviewDetail")!
        let (data, response) = try await get(url)
        try ensureOK(response, data: data)
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let contactEmail: String?
                    let contactFirstName: String?
                    let contactLastName: String?
                    let contactPhone: String?
                    let demoAccountName: String?
                    let demoAccountPassword: String?
                    let demoAccountRequired: Bool?
                    let notes: String?
                }
            }
            let data: Item
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let a = env.data.attributes
        return BetaAppReviewDetail(
            id: env.data.id,
            contactEmail: a.contactEmail ?? "",
            contactFirstName: a.contactFirstName ?? "",
            contactLastName: a.contactLastName ?? "",
            contactPhone: a.contactPhone ?? "",
            demoAccountName: a.demoAccountName ?? "",
            demoAccountPassword: a.demoAccountPassword ?? "",
            demoAccountRequired: a.demoAccountRequired ?? false,
            notes: a.notes ?? ""
        )
    }

    func updateBetaAppReviewDetail(_ detail: BetaAppReviewDetail) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaAppReviewDetails/\(detail.id)")!
        let body: [String: Any] = [
            "data": [
                "type": "betaAppReviewDetails",
                "id": detail.id,
                "attributes": [
                    "contactEmail": orNull(detail.contactEmail),
                    "contactFirstName": orNull(detail.contactFirstName),
                    "contactLastName": orNull(detail.contactLastName),
                    "contactPhone": orNull(detail.contactPhone),
                    "demoAccountName": orNull(detail.demoAccountName),
                    "demoAccountPassword": orNull(detail.demoAccountPassword),
                    "demoAccountRequired": detail.demoAccountRequired,
                    "notes": orNull(detail.notes),
                ],
            ],
        ]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    // MARK: - App Store version admin (App Store destination)

    func appStoreVersionLocalizations(versionId: String) async throws -> [AppStoreVersionLocalization] {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations")!
        let (data, response) = try await get(url)
        try ensureOK(response, data: data)
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let locale: String?
                    let description: String?
                    let keywords: String?
                    let whatsNew: String?
                    let promotionalText: String?
                    let marketingUrl: String?
                    let supportUrl: String?
                }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.data.map {
            AppStoreVersionLocalization(
                id: $0.id,
                locale: $0.attributes.locale ?? "",
                description: $0.attributes.description ?? "",
                keywords: $0.attributes.keywords ?? "",
                whatsNew: $0.attributes.whatsNew ?? "",
                promotionalText: $0.attributes.promotionalText ?? "",
                marketingUrl: $0.attributes.marketingUrl ?? "",
                supportUrl: $0.attributes.supportUrl ?? ""
            )
        }
    }

    func updateAppStoreVersionLocalization(_ loc: AppStoreVersionLocalization) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/\(loc.id)")!
        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersionLocalizations",
                "id": loc.id,
                "attributes": [
                    "description": orNull(loc.description),
                    "keywords": orNull(loc.keywords),
                    "whatsNew": orNull(loc.whatsNew),
                    "promotionalText": orNull(loc.promotionalText),
                    "marketingUrl": orNull(loc.marketingUrl),
                    "supportUrl": orNull(loc.supportUrl),
                ],
            ],
        ]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    /// Updates the version-level `copyright` and/or `versionString` on an editable
    /// App Store version.
    func updateAppStoreVersion(versionId: String, copyright: String?, versionString: String?) async throws {
        var attributes: [String: Any] = [:]
        if let copyright { attributes["copyright"] = orNull(copyright) }
        if let versionString, !versionString.isEmpty { attributes["versionString"] = versionString }
        guard !attributes.isEmpty else { return }
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/appStoreVersions/\(versionId)")!
        let body: [String: Any] = ["data": ["type": "appStoreVersions", "id": versionId, "attributes": attributes]]
        let (data, response) = try await send("PATCH", url: url, jsonBody: body)
        try ensureOK(response, data: data)
    }

    /// Empty string → JSON `null` so PATCH clears the field instead of sending an
    /// invalid empty value (App Store Connect rejects `""` for URL-typed fields).
    private nonisolated func orNull(_ value: String) -> Any {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : value
    }

    private func decodeFirstVersion(from data: Data) -> ASCAppStoreVersion? {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let versionString: String
                    let appStoreState: String?
                    let copyright: String?
                }
            }
            let data: [Item]
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let item = env.data.first else { return nil }
        return ASCAppStoreVersion(
            id: item.id,
            versionString: item.attributes.versionString,
            appStoreState: item.attributes.appStoreState ?? "UNKNOWN",
            copyright: item.attributes.copyright ?? ""
        )
    }

    /// POST/PATCH responses return a single `data` object; wrap it as `{ "data": [obj] }`
    /// so the array-based `decodeFirstVersion` can read it.
    private func wrapSingle(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let single = object["data"] else { return data }
        return (try? JSONSerialization.data(withJSONObject: ["data": [single]])) ?? data
    }

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: req)
    }

    private func send(_ method: String, url: URL, jsonBody: [String: Any]) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await URLSession.shared.data(for: req)
    }

    private func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PublishError.ascAPIError(status: http.statusCode, body: body)
        }
    }
}

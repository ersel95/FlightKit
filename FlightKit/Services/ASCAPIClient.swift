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
        guard let item = env.data.first else { return nil }
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
                }
            }
            let data: [Item]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let item = env.data.first else { return nil }
        return ASCAppStoreVersion(
            id: item.id,
            versionString: item.attributes.versionString,
            appStoreState: item.attributes.appStoreState ?? "UNKNOWN"
        )
    }

    private func decodeFirstBuild(from data: Data) -> ASCBuild? {
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
        guard let env = try? decoder.decode(Envelope.self, from: data),
              let item = env.data.first else { return nil }
        let prvId = item.relationships?.preReleaseVersion?.data?.id
        let prvVersion = env.included?.first(where: { $0.id == prvId && $0.type == "preReleaseVersions" })?.attributes.version ?? ""
        return ASCBuild(
            id: item.id,
            version: item.attributes.version ?? "",
            preReleaseVersion: prvVersion,
            processingState: ASCBuild.ProcessingState(raw: item.attributes.processingState),
            uploadedDate: item.attributes.uploadedDate,
            expired: item.attributes.expired ?? false
        )
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

    private func decodeFirstVersion(from data: Data) -> ASCAppStoreVersion? {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let attributes: Attrs
                struct Attrs: Decodable {
                    let versionString: String
                    let appStoreState: String?
                }
            }
            let data: [Item]
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let item = env.data.first else { return nil }
        return ASCAppStoreVersion(
            id: item.id,
            versionString: item.attributes.versionString,
            appStoreState: item.attributes.appStoreState ?? "UNKNOWN"
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

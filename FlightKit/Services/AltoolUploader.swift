//
//  AltoolUploader.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

enum AltoolUploader {
    /// Upload an .ipa to App Store Connect using xcrun altool with API key.
    /// Writes the .p8 key to a temp directory and points API_PRIVATE_KEYS_DIR there.
    static func upload(
        ipaURL: URL,
        credentials: ASCCredentials,
        onLine: @Sendable @escaping (String, Bool) -> Void
    ) async throws {
        let keyDir = FileManager.default.temporaryDirectory
            .appending(path: "flightkit-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let keyURL = keyDir.appending(path: "AuthKey_\(credentials.keyId).p8")
        try credentials.privateKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)

        let result = try await XcodebuildRunner.runProcess(
            executable: "/usr/bin/xcrun",
            args: [
                "altool",
                "--upload-app",
                "--type", "ios",
                "--file", ipaURL.path,
                "--apiKey", credentials.keyId,
                "--apiIssuer", credentials.issuerId,
                "--output-format", "normal",
            ],
            environment: ["API_PRIVATE_KEYS_DIR": keyDir.path],
            onLine: onLine
        )
        guard result.exitCode == 0 else {
            throw PublishError.altoolFailed(exitCode: result.exitCode, log: result.combinedLog)
        }
    }
}

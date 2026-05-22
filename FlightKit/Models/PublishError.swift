//
//  PublishError.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

enum PublishError: LocalizedError {
    case missingCredentials
    case invalidVersionFormat(String)
    case projectNotFound(URL)
    case xcconfigVersionFieldNotFound(field: String)
    case xcodebuildFailed(stage: String, exitCode: Int32, log: String)
    case altoolFailed(exitCode: Int32, log: String)
    case ascAPIError(status: Int, body: String)
    case jwtSigningFailed(String)
    case keychainError(OSStatus)
    case unfixableAfterRetry(stage: String, lastError: String)
    case timeout(stage: String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "App Store Connect API key not configured for this project."
        case .invalidVersionFormat(let v):
            return "Invalid version format: \(v). Use semantic versioning like 1.2.3."
        case .projectNotFound(let url):
            return "Xcode project not found at: \(url.path())"
        case .xcconfigVersionFieldNotFound(let field):
            return "Could not locate \(field) in any xcconfig file for this configuration."
        case .xcodebuildFailed(let stage, let code, let log):
            return "xcodebuild \(stage) failed (exit \(code)).\n\(log.suffix(800))"
        case .altoolFailed(let code, let log):
            return "altool upload failed (exit \(code)).\n\(log.suffix(800))"
        case .ascAPIError(let status, let body):
            return "App Store Connect API error \(status).\n\(body.prefix(400))"
        case .jwtSigningFailed(let reason):
            return "Failed to sign JWT: \(reason)"
        case .keychainError(let status):
            return "Keychain error (OSStatus \(status))."
        case .unfixableAfterRetry(let stage, let last):
            return "Auto-fix failed at \(stage). Last error: \(last.suffix(400))"
        case .timeout(let stage):
            return "Stage timed out: \(stage)"
        }
    }
}

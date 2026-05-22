//
//  JWTGenerator.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation
import CryptoKit

enum JWTGenerator {
    static func make(credentials: ASCCredentials, validity: TimeInterval = 1200) throws -> String {
        let now = Date()
        let exp = now.addingTimeInterval(validity)

        let header: [String: Any] = [
            "alg": "ES256",
            "kid": credentials.keyId,
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "iss": credentials.issuerId,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(exp.timeIntervalSince1970),
            "aud": "appstoreconnect-v1",
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = "\(headerData.base64URLEncoded()).\(payloadData.base64URLEncoded())"

        let signingKey = try loadSigningKey(from: credentials.privateKeyPEM)

        guard let signingData = signingInput.data(using: .utf8) else {
            throw PublishError.jwtSigningFailed("UTF-8 encoding failed")
        }
        let signature = try signingKey.signature(for: signingData)
        let signatureBase64URL = signature.rawRepresentation.base64URLEncoded()
        return "\(signingInput).\(signatureBase64URL)"
    }

    /// Loads the ES256 (P-256) signing key from an App Store Connect `.p8`.
    /// CryptoKit parses the PKCS#8 PEM (`BEGIN PRIVATE KEY`, Apple's format)
    /// directly, so we try that first; the DER / raw fallbacks cover keys stored
    /// without armor or as bare key bytes. The previous decode→re-wrap→parse
    /// round-trip was the source of `CryptoKitASN1Error 7`.
    private static func loadSigningKey(from pem: String) throws -> P256.Signing.PrivateKey {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return key
        }
        if let der = try? parsePEMtoDER(pem) {
            if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return key }
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: der) { return key }
        }
        throw PublishError.jwtSigningFailed("Unable to parse EC P-256 private key from .p8")
    }

    private static func parsePEMtoDER(_ pem: String) throws -> Data {
        let lines = pem
            .components(separatedBy: .newlines)
            .filter { !$0.contains("BEGIN") && !$0.contains("END") && !$0.isEmpty }
        let base64 = lines.joined()
        guard let data = Data(base64Encoded: base64) else {
            throw PublishError.jwtSigningFailed("Invalid PEM body")
        }
        return data
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

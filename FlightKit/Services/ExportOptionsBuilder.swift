//
//  ExportOptionsBuilder.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

enum ExportOptionsBuilder {
    /// Build a minimal `app-store-connect` export options plist.
    static func build(teamId: String, signingStyle: SigningStyle = .automatic) -> Data {
        let plist: [String: Any] = [
            "method": "app-store-connect",
            "teamID": teamId,
            "signingStyle": signingStyle.rawValue,
            "stripSwiftSymbols": true,
            "uploadBitcode": false,
            "uploadSymbols": true,
            "destination": "export",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    static func write(to url: URL, teamId: String, signingStyle: SigningStyle = .automatic) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try build(teamId: teamId, signingStyle: signingStyle).write(to: url)
    }

    enum SigningStyle: String { case automatic, manual }
}

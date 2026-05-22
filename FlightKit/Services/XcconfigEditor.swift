//
//  XcconfigEditor.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

enum XcconfigEditor {
    /// Locate the xcconfig file most likely to own a given build setting field.
    /// Searches all `.xcconfig` files under `searchRoot`, prefers files whose
    /// name matches the build configuration (e.g. `Prod.xcconfig`), then
    /// `Common`/`Config`/base files.
    static func findFile(field: String, searchRoot: URL, configurationName: String) throws -> URL {
        let xcconfigs = enumerateXcconfigs(under: searchRoot)
        let pattern = try NSRegularExpression(
            pattern: "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: field))\\s*=",
            options: []
        )
        let candidates: [URL] = xcconfigs.filter { url in
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return pattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
        }
        guard !candidates.isEmpty else {
            throw PublishError.xcconfigVersionFieldNotFound(field: field)
        }
        let configMatch = candidates.first { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(configurationName) == .orderedSame }
        if let configMatch { return configMatch }
        let commonMatch = candidates.first { ["Common", "Config", "Base"].contains($0.deletingPathExtension().lastPathComponent) }
        if let commonMatch { return commonMatch }
        return candidates[0]
    }

    /// Replace `field = value` in-place, preserving the rest of the file.
    static func setValue(_ value: String, forField field: String, in fileURL: URL) throws {
        let body = try String(contentsOf: fileURL, encoding: .utf8)
        let pattern = "(?m)^(\\s*\(NSRegularExpression.escapedPattern(for: field))\\s*=).*$"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsBody = body as NSString
        let range = NSRange(location: 0, length: nsBody.length)
        guard regex.firstMatch(in: body, range: range) != nil else {
            throw PublishError.xcconfigVersionFieldNotFound(field: field)
        }
        let updated = regex.stringByReplacingMatches(
            in: body,
            options: [],
            range: range,
            withTemplate: "$1\(value.replacingOccurrences(of: "$", with: "\\$"))"
        )
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func readValue(forField field: String, in fileURL: URL) throws -> String? {
        let body = try String(contentsOf: fileURL, encoding: .utf8)
        let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: field))\\s*=\\s*(.*?)\\s*$"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsBody = body as NSString
        guard let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)),
              match.numberOfRanges >= 2 else { return nil }
        return nsBody.substring(with: match.range(at: 1))
    }

    private static func enumerateXcconfigs(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "xcconfig" { result.append(url) }
        }
        return result
    }
}

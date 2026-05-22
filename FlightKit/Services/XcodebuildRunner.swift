//
//  XcodebuildRunner.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct XcodebuildResult {
    let exitCode: Int32
    let combinedLog: String
}

enum XcodebuildRunner {
    /// Run xcodebuild with given args, streaming each stdout/stderr line via `onLine`.
    /// Returns combined log + exit code.
    static func run(
        args: [String],
        environment: [String: String]? = nil,
        onLine: @Sendable @escaping (String, Bool) -> Void
    ) async throws -> XcodebuildResult {
        try await runProcess(executable: "/usr/bin/xcrun", args: ["xcodebuild"] + args, environment: environment, onLine: onLine)
    }

    static func runProcess(
        executable: String,
        args: [String],
        environment: [String: String]? = nil,
        onLine: @Sendable @escaping (String, Bool) -> Void
    ) async throws -> XcodebuildResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let environment {
                var combined = ProcessInfo.processInfo.environment
                for (k, v) in environment { combined[k] = v }
                process.environment = combined
            }
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let combinedBuffer = LogBuffer()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let text = String(data: data, encoding: .utf8) {
                    combinedBuffer.append(text)
                    for line in text.split(whereSeparator: { $0.isNewline }) {
                        onLine(String(line), false)
                    }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let text = String(data: data, encoding: .utf8) {
                    combinedBuffer.append(text)
                    for line in text.split(whereSeparator: { $0.isNewline }) {
                        onLine(String(line), true)
                    }
                }
            }
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: XcodebuildResult(
                    exitCode: proc.terminationStatus,
                    combinedLog: combinedBuffer.snapshot()
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run `xcodebuild -showBuildSettings -json` and return parsed dictionary.
    /// `containerArguments` is the `-workspace`/`-project` pair so build settings
    /// are read from the same container that will be archived.
    static func showBuildSettings(containerArguments: [String], scheme: String, configuration: String) async throws -> [String: String] {
        let result = try await run(
            args: containerArguments + [
                "-scheme", scheme,
                "-configuration", configuration,
                "-showBuildSettings",
                "-json",
            ],
            onLine: { _, _ in }
        )
        guard result.exitCode == 0 else {
            throw PublishError.xcodebuildFailed(stage: "showBuildSettings", exitCode: result.exitCode, log: result.combinedLog)
        }
        let jsonStart = result.combinedLog.firstIndex(of: "[") ?? result.combinedLog.startIndex
        let jsonText = String(result.combinedLog[jsonStart...])
        guard let data = jsonText.data(using: .utf8) else {
            throw PublishError.xcodebuildFailed(stage: "showBuildSettings", exitCode: 0, log: "Failed to encode showBuildSettings output")
        }
        struct Entry: Decodable {
            let buildSettings: [String: String]
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.first?.buildSettings ?? [:]
    }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return storage }
}

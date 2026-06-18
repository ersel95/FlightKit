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
        // A Finder-launched app inherits launchd's environment, not the shell — so a
        // shell-set DEVELOPER_DIR is absent and xcode-select may point at Command Line
        // Tools (no xcodebuild) even on an active dev's Mac. Resolve a concrete Xcode
        // and pass DEVELOPER_DIR explicitly so xcrun finds xcodebuild regardless.
        var env = environment ?? [:]
        if env["DEVELOPER_DIR"] == nil, let dev = await XcodeLocator.shared.developerDirectory() {
            env["DEVELOPER_DIR"] = dev
        }
        return try await runProcess(executable: "/usr/bin/xcrun", args: ["xcodebuild"] + args, environment: env, onLine: onLine)
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

    /// Verifies an Xcode can be located so `xcrun xcodebuild` resolves (via the
    /// auto-injected DEVELOPER_DIR). Throws an actionable error only when *no* Xcode
    /// exists anywhere — not merely when xcode-select points at Command Line Tools.
    /// The publish pipeline calls this up front so a missing toolchain fails fast
    /// instead of dying deep in the archive with a cryptic xcrun exit 72.
    static func ensureXcodebuildAvailable() async throws {
        guard await XcodeLocator.shared.developerDirectory() != nil else {
            let active = (try? await runProcess(executable: "/usr/bin/xcode-select", args: ["-p"], onLine: { _, _ in }))?
                .combinedLog.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PublishError.toolingUnavailable(activeDir: (active?.isEmpty == false ? active! : "(seçili değil)"))
        }
    }

    /// Run `xcodebuild -showBuildSettings -json` and return parsed dictionary.
    /// `containerArguments` is the `-workspace`/`-project` pair so build settings
    /// are read from the same container that will be archived. A nil `configuration`
    /// lets xcodebuild use the scheme's default. `clonedSourcePackagesPath` reuses a
    /// shared SPM checkout cache so resolution isn't repeated per call.
    static func showBuildSettings(
        containerArguments: [String],
        scheme: String,
        configuration: String?,
        clonedSourcePackagesPath: String? = nil
    ) async throws -> [String: String] {
        var args = containerArguments + ["-scheme", scheme]
        if let configuration { args += ["-configuration", configuration] }
        if let clonedSourcePackagesPath { args += ["-clonedSourcePackagesDirPath", clonedSourcePackagesPath] }
        args += ["-showBuildSettings", "-json"]
        let result = try await run(args: args, onLine: { _, _ in })
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

    struct ProjectListing {
        let schemes: [String]
        let configurations: [String]
    }

    /// Run `xcodebuild -list -json`. Schemes are reported for both projects and
    /// workspaces; build configurations only for projects (a workspace's configs
    /// live in its member projects).
    static func list(containerArguments: [String], clonedSourcePackagesPath: String? = nil) async throws -> ProjectListing {
        var args = containerArguments + ["-list", "-json"]
        if let clonedSourcePackagesPath { args += ["-clonedSourcePackagesDirPath", clonedSourcePackagesPath] }
        let result = try await run(args: args, onLine: { _, _ in })
        guard result.exitCode == 0 else {
            throw PublishError.xcodebuildFailed(stage: "list", exitCode: result.exitCode, log: result.combinedLog)
        }
        let jsonStart = result.combinedLog.firstIndex(of: "{") ?? result.combinedLog.startIndex
        guard let data = String(result.combinedLog[jsonStart...]).data(using: .utf8) else {
            throw PublishError.xcodebuildFailed(stage: "list", exitCode: 0, log: "Failed to encode -list output")
        }
        struct Envelope: Decodable {
            struct Container: Decodable {
                let schemes: [String]?
                let configurations: [String]?
            }
            let project: Container?
            let workspace: Container?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let container = env.project ?? env.workspace
        return ProjectListing(
            schemes: container?.schemes ?? [],
            configurations: container?.configurations ?? []
        )
    }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Locates a usable Xcode `Developer` directory for command-line builds, caching the
/// result for the session. A Finder-launched GUI app doesn't inherit the shell's
/// `DEVELOPER_DIR`, and `xcode-select` may point at Command Line Tools (which lack
/// xcodebuild) even on an active developer's Mac — so FlightKit resolves a concrete
/// Xcode itself and passes it as `DEVELOPER_DIR`, rather than trusting the inherited
/// environment. Returns nil only when no Xcode exists anywhere.
actor XcodeLocator {
    static let shared = XcodeLocator()
    private var resolved = false
    private var developerDir: String?

    func developerDirectory() async -> String? {
        if resolved { return developerDir }
        developerDir = await Self.locate()
        resolved = true
        return developerDir
    }

    private static func locate() async -> String? {
        // 1. Whatever the current toolchain already resolves (a correct xcode-select
        //    or an inherited DEVELOPER_DIR) wins — that's the developer's explicit
        //    choice. Derive the Developer dir from the resolved xcodebuild path.
        if let found = try? await XcodebuildRunner.runProcess(
            executable: "/usr/bin/xcrun", args: ["--find", "xcodebuild"], onLine: { _, _ in }
        ), found.exitCode == 0 {
            let path = found.combinedLog.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                // .../Developer/usr/bin/xcodebuild → .../Developer
                return URL(fileURLWithPath: path)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
            }
        }
        // 2. No usable toolchain selected (xcode-select on Command Line Tools, etc.).
        //    Gather every Xcode we can find and pick the NEWEST — picking an old Xcode
        //    is a common cause of dependencies (e.g. Firebase) failing to compile.
        var candidates = Set<String>()
        let standard = "/Applications/Xcode.app/Contents/Developer"
        if FileManager.default.fileExists(atPath: standard + "/usr/bin/xcodebuild") { candidates.insert(standard) }
        if let hits = try? await XcodebuildRunner.runProcess(
            executable: "/usr/bin/mdfind",
            args: ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"], onLine: { _, _ in }
        ), hits.exitCode == 0 {
            for line in hits.combinedLog.split(whereSeparator: { $0.isNewline }) {
                let dir = String(line).trimmingCharacters(in: .whitespaces) + "/Contents/Developer"
                if FileManager.default.fileExists(atPath: dir + "/usr/bin/xcodebuild") { candidates.insert(dir) }
            }
        }
        var best: (dir: String, version: [Int])?
        for dir in candidates {
            let version = await xcodeVersion(developerDir: dir)
            if let current = best {
                if current.version.lexicographicallyPrecedes(version) { best = (dir, version) }
            } else {
                best = (dir, version)
            }
        }
        return best?.dir ?? candidates.first
    }

    /// `[major, minor]` of the Xcode at `developerDir`, or `[0]` if unreadable —
    /// used to pick the newest among several installed Xcodes.
    private static func xcodeVersion(developerDir: String) async -> [Int] {
        guard let result = try? await XcodebuildRunner.runProcess(
            executable: developerDir + "/usr/bin/xcodebuild", args: ["-version"], onLine: { _, _ in }
        ), result.exitCode == 0 else { return [0] }
        // First line looks like "Xcode 16.2".
        let first = result.combinedLog.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let digits = first.replacingOccurrences(of: "Xcode", with: "").trimmingCharacters(in: .whitespaces)
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? [0] : parts
    }
}

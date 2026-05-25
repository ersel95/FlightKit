//
//  PublishOrchestrator.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

@MainActor
final class PublishOrchestrator {
    let state: PipelineState
    let project: AppProject
    let credentials: ASCCredentials
    let workspaceRoot: URL
    let healer = SelfHealer(rules: SelfHealer.defaultRules())

    private let workDir: URL
    private let derivedDataDir: URL
    private let archiveURL: URL
    private let exportDir: URL
    private let exportOptionsURL: URL
    private let sharedSPMCacheDir: URL
    private var ipaURL: URL?

    private let maxRetriesPerStep = 2

    init(state: PipelineState, credentials: ASCCredentials) {
        self.state = state
        self.project = state.project
        self.credentials = credentials
        // The container's parent dir holds the .xcconfig files we bump.
        self.workspaceRoot = state.project.workspaceRoot
        // Namespace by configuration too: in an "All" batch the runs share one
        // project.id, so without this they'd clobber each other's archive/IPA.
        let work = FileManager.default.temporaryDirectory.appending(path: "flightkit/\(project.id)-\(project.configuration)")
        self.workDir = work
        self.derivedDataDir = work.appending(path: "DerivedData")
        self.archiveURL = work.appending(path: "\(project.id).xcarchive")
        self.exportDir = work.appending(path: "Export")
        self.exportOptionsURL = work.appending(path: "exportOptions.plist")
        // Persistent, cross-run, cross-project SPM checkout cache. The per-run
        // DerivedData lives in /tmp (cleaned by macOS), so without this every
        // archive re-clones multiple GB of dependencies (Firebase/gRPC/abseil).
        // SPM keys checkouts by repo URL, so sharing across projects is safe and
        // maximises reuse.
        self.sharedSPMCacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "FlightKit/SourcePackages")
    }

    func run() async {
        do {
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await execute(.validate, body: { try await self.validate() })
            try await execute(.writeXcconfig, body: { try await self.writeXcconfig() })
            try await execute(.generateExportOptions, body: { try await self.writeExportOptions() })
            try await execute(.archive, body: { try await self.archive() })
            try await execute(.exportIPA, body: { try await self.exportIPA() })
            try await execute(.upload, body: { try await self.upload() })
            state.isFinished = true
            // Processing (and the App Store version attach) is intentionally NOT a
            // blocking step — it runs afterwards via `runProcessingWatch()`, started
            // by the batch runner, so an "All" sweep moves to the next environment
            // immediately instead of waiting up to 30 min per env.
            state.appendLog("✓ Upload tamamlandı — App Store Connect işlemesi arka planda izlenecek", kind: .info)
        } catch {
            state.appendLog("✗ Pipeline failed: \(error.localizedDescription)", kind: .error)
            state.isFinished = true
        }
    }

    private func execute(_ step: PublishStep, body: @escaping () async throws -> Void) async throws {
        var attempt = 0
        var lastError: Error?
        while attempt < maxRetriesPerStep {
            attempt += 1
            state.setStep(step, status: .running)
            state.appendLog("▶ Step \(step.rawValue) (attempt \(attempt))", kind: .info)
            do {
                try await body()
                state.setStep(step, status: .succeeded)
                state.appendLog("✓ \(step.rawValue) completed", kind: .info)
                return
            } catch {
                lastError = error
                let logSnapshot = state.logLines.suffix(80).map(\.message).joined(separator: "\n")
                let context = HealContext(
                    project: project,
                    workspaceRoot: workspaceRoot,
                    derivedDataDir: derivedDataDir,
                    exportOptionsURL: exportOptionsURL,
                    archiveURL: archiveURL,
                    appendLog: { [state] msg in
                        Task { @MainActor in state.appendLog(msg, kind: .fix) }
                    }
                )
                if let healed = await healer.attemptFix(stage: step.rawValue, log: logSnapshot, context: context),
                   attempt < maxRetriesPerStep {
                    state.setStep(step, status: .retrying(reason: healed.humanDescription))
                    state.appendLog("⚙︎ Self-heal: \(healed.humanDescription)", kind: .fix)
                    continue
                }
                state.setStep(step, status: .failed(message: error.localizedDescription))
                state.appendLog("✗ \(step.rawValue) failed: \(error.localizedDescription)", kind: .error)
                throw PublishError.unfixableAfterRetry(stage: step.rawValue, lastError: error.localizedDescription)
            }
        }
        if let lastError {
            throw PublishError.unfixableAfterRetry(stage: step.rawValue, lastError: lastError.localizedDescription)
        }
    }

    // MARK: - Steps

    private func validate() async throws {
        let versionRegex = try NSRegularExpression(pattern: #"^\d+\.\d+(?:\.\d+)?$"#)
        let v = state.targetVersion
        guard versionRegex.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil else {
            throw PublishError.invalidVersionFormat(v)
        }
        guard Int(state.targetBuildNumber) != nil else {
            throw PublishError.invalidVersionFormat("build=\(state.targetBuildNumber)")
        }
        let containerURL = project.containerURL
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw PublishError.projectNotFound(containerURL)
        }
        state.appendLog("Container: \(containerURL.path)", kind: .info)
        state.appendLog("Destination: \(state.destination.displayName)", kind: .info)
        state.appendLog("Scheme: \(project.schemeName)  Config: \(project.configuration)", kind: .info)
        state.appendLog("Target version: \(state.targetVersion) (\(state.targetBuildNumber))", kind: .info)
    }

    /// Best-effort: persist the version bump into the project's `.xcconfig` files.
    /// Many projects keep MARKETING_VERSION / CURRENT_PROJECT_VERSION in the target
    /// build settings (pbxproj) instead, where there is no field to edit — that's
    /// fine: the archive step injects both as command-line build-setting overrides,
    /// so the build always carries the right version regardless of this step.
    private func writeXcconfig() async throws {
        bumpXcconfig(field: "MARKETING_VERSION", to: state.targetVersion)
        bumpXcconfig(field: "CURRENT_PROJECT_VERSION", to: state.targetBuildNumber)
    }

    private func bumpXcconfig(field: String, to value: String) {
        do {
            let file = try XcconfigEditor.findFile(field: field, searchRoot: workspaceRoot, configurationName: project.configuration)
            try XcconfigEditor.setValue(value, forField: field, in: file)
            state.appendLog("\(field) → \(file.lastPathComponent)", kind: .info)
        } catch {
            state.appendLog("\(field): no .xcconfig field found — applied via build-setting override at archive instead.", kind: .info)
        }
    }

    private func writeExportOptions() async throws {
        try ExportOptionsBuilder.write(to: exportOptionsURL, teamId: project.teamId)
        state.appendLog("Wrote \(exportOptionsURL.lastPathComponent)", kind: .info)
    }

    private func archive() async throws {
        try? FileManager.default.createDirectory(at: sharedSPMCacheDir, withIntermediateDirectories: true)
        let logState = state
        let result = try await XcodebuildRunner.run(
            args: project.xcodebuildContainerArguments + [
                "-scheme", project.schemeName,
                "-configuration", project.configuration,
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", derivedDataDir.path,
                "-clonedSourcePackagesDirPath", sharedSPMCacheDir.path,
                "-archivePath", archiveURL.path,
                "MARKETING_VERSION=\(state.targetVersion)",
                "CURRENT_PROJECT_VERSION=\(state.targetBuildNumber)",
                "archive",
            ],
            onLine: { line, isStderr in
                Task { @MainActor in logState.appendLog(line, kind: isStderr ? .stderr : .stdout) }
            }
        )
        guard result.exitCode == 0 else {
            throw PublishError.xcodebuildFailed(stage: "archive", exitCode: result.exitCode, log: result.combinedLog)
        }
    }

    /// Materialises the ASC API key (.p8) into the work dir and returns the
    /// xcodebuild authentication arguments. Together with `-allowProvisioningUpdates`
    /// this lets xcodebuild create/download cloud-managed distribution certificates
    /// and provisioning profiles via App Store Connect — no interactive Apple ID
    /// session required (the local Xcode account may be broken/absent on this Mac).
    private func apiKeySigningArguments() throws -> [String] {
        let keyURL = workDir.appending(path: "AuthKey_\(credentials.keyId).p8")
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            try credentials.privateKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }
        return [
            "-allowProvisioningUpdates",
            "-authenticationKeyPath", keyURL.path,
            "-authenticationKeyID", credentials.keyId,
            "-authenticationKeyIssuerID", credentials.issuerId,
        ]
    }

    private func exportIPA() async throws {
        try? FileManager.default.removeItem(at: exportDir)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let logState = state
        let result = try await XcodebuildRunner.run(
            args: [
                "-exportArchive",
                "-archivePath", archiveURL.path,
                "-exportPath", exportDir.path,
                "-exportOptionsPlist", exportOptionsURL.path,
            ] + (try apiKeySigningArguments()),
            onLine: { line, isStderr in
                Task { @MainActor in logState.appendLog(line, kind: isStderr ? .stderr : .stdout) }
            }
        )
        guard result.exitCode == 0 else {
            throw PublishError.xcodebuildFailed(stage: "exportArchive", exitCode: result.exitCode, log: result.combinedLog)
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)) ?? []
        guard let ipa = candidates.first(where: { $0.pathExtension.lowercased() == "ipa" }) else {
            throw PublishError.xcodebuildFailed(stage: "exportArchive", exitCode: 0, log: "No .ipa found in export directory")
        }
        ipaURL = ipa
        state.finalIPAPath = ipa
        state.appendLog("IPA: \(ipa.lastPathComponent)", kind: .info)
    }

    private func upload() async throws {
        guard let ipaURL else { throw PublishError.xcodebuildFailed(stage: "upload", exitCode: 0, log: "No IPA path") }
        let logState = state
        try await AltoolUploader.upload(
            ipaURL: ipaURL,
            credentials: credentials,
            onLine: { line, isStderr in
                Task { @MainActor in logState.appendLog(line, kind: isStderr ? .stderr : .stdout) }
            }
        )
        state.uploadedAt = Date()
    }

    /// Non-blocking, post-upload watch: polls App Store Connect until the build
    /// finishes processing, then — for App Store — attaches it to a version. Runs
    /// independently per environment and is cancellable (the pipeline screen owns
    /// its lifetime), so it never blocks an "All" sweep and never throws into the
    /// pipeline; outcomes are recorded on `state.processingPhase`.
    func runProcessingWatch() async {
        state.processingPhase = .waiting
        do {
            let api = ASCAPIClient(credentials: credentials)
            guard let app = try await api.findApp(bundleId: project.bundleIdentifier) else {
                throw PublishError.ascAPIError(status: 404, body: "App with bundle id \(project.bundleIdentifier) not found")
            }
            let deadline = Date().addingTimeInterval(60 * 30) // 30 min
            // Only accept builds uploaded at/after our upload (minus skew tolerance) —
            // guards against locking onto a stale earlier build, especially when we
            // fall back to "latest" because the store renumbered ours.
            let cutoff = (state.uploadedAt ?? Date()).addingTimeInterval(-300)
            var pollCount = 0
            while Date() < deadline {
                if Task.isCancelled {
                    state.processingPhase = .stopped
                    state.appendLog("⏸ İşleme izleme durduruldu (ekran kapatıldı)", kind: .info)
                    return
                }
                pollCount += 1
                if let build = try await resolveOurBuild(api: api, appId: app.id, cutoff: cutoff) {
                    state.appendLog("Build \(build.preReleaseVersion) (\(build.version)) — state: \(build.processingState.rawValue) [poll #\(pollCount)]", kind: .info)
                    state.uploadedBuildId = build.id
                    state.publishedMarketingVersion = build.preReleaseVersion
                    state.publishedBuildNumber = build.version
                    state.processingStateText = build.processingState.rawValue
                    if build.version != state.targetBuildNumber {
                        state.appendLog("⚠︎ App Store Connect build numarasını \(state.targetBuildNumber) → \(build.version) olarak değiştirdi", kind: .fix)
                    }
                    if build.processingState.isTerminal {
                        if build.processingState == .valid {
                            state.processingPhase = .valid
                            state.appendLog("✓ İşleme tamamlandı (VALID)", kind: .info)
                            if state.destination == .appStore {
                                try await attachProcessedBuild(api: api, appId: app.id)
                            }
                        } else {
                            state.processingPhase = .failed(reason: "İşleme \(build.processingState.rawValue) ile sonuçlandı")
                            state.appendLog("✗ İşleme \(build.processingState.rawValue) ile sonuçlandı", kind: .error)
                        }
                        return
                    }
                } else {
                    state.appendLog("Build ASC'de henüz görünmüyor [poll #\(pollCount)]", kind: .info)
                }
                try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            }
            state.processingPhase = .failed(reason: "Build 30 dk içinde işlenmedi")
            state.appendLog("✗ İşleme 30 dk içinde tamamlanmadı", kind: .error)
        } catch is CancellationError {
            state.processingPhase = .stopped
            state.appendLog("⏸ İşleme izleme durduruldu (ekran kapatıldı)", kind: .info)
        } catch {
            state.processingPhase = .failed(reason: error.localizedDescription)
            state.appendLog("✗ İşleme izleme hatası: \(error.localizedDescription)", kind: .error)
        }
    }

    /// Resolves the build we just uploaded. Prefers an exact build-number match;
    /// if the store renumbered it (our number already existed) the match is nil,
    /// so we fall back to the latest build — accepted only if it was uploaded
    /// after our upload, so a pre-existing build is never mistaken for ours.
    private func resolveOurBuild(api: ASCAPIClient, appId: String, cutoff: Date) async throws -> ASCBuild? {
        if let exact = try await api.build(byVersion: state.targetBuildNumber, appId: appId),
           exact.uploadedDate.map({ $0 >= cutoff }) ?? true {
            return exact
        }
        if let latest = try await api.latestBuild(appId: appId),
           latest.uploadedDate.map({ $0 >= cutoff }) ?? false {
            return latest
        }
        return nil
    }

    /// App Store destination only: attach the just-processed build to an editable
    /// App Store version (created if missing). Does NOT submit for review. Called
    /// from `runProcessingWatch` once the build is VALID, reusing its API client.
    private func attachProcessedBuild(api: ASCAPIClient, appId: String) async throws {
        guard let buildId = state.uploadedBuildId else {
            throw PublishError.ascAPIError(status: 0, body: "No processed build id to attach")
        }
        state.processingPhase = .attaching
        let versionString = state.publishedMarketingVersion ?? state.targetVersion

        let version: ASCAppStoreVersion
        if let existing = try await api.appStoreVersion(appId: appId, versionString: versionString) {
            version = existing
            state.appendLog("Mevcut App Store sürümü kullanılıyor \(existing.versionString) [\(existing.appStoreState)]", kind: .info)
        } else {
            version = try await api.createAppStoreVersion(appId: appId, versionString: versionString)
            state.appendLog("App Store sürümü oluşturuldu \(version.versionString)", kind: .info)
        }

        try await api.attachBuild(versionId: version.id, buildId: buildId)
        state.appendLog("Build, App Store sürümüne bağlandı \(version.versionString) — incelemeye gönderilmedi", kind: .info)
        state.processingPhase = .attached(version: version.versionString)
    }
}

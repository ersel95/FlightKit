//
//  ProjectStore.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation
import Observation

/// The user's catalog of apps to publish, persisted as JSON under
/// `~/Library/Application Support/FlightKit/projects.json`. Nothing is bundled —
/// every project is added by the user, so FlightKit ships with no app-specific data.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [AppProject] = []
    /// Bumped whenever a project's API key is saved/deleted. Views that show a
    /// credential indicator (the sidebar) read this so they re-check the Keychain.
    private(set) var credentialsRevision = 0

    private let fileURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FlightKit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appending(path: "projects.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AppProject].self, from: data) else {
            projects = []
            return
        }
        projects = decoded
    }

    /// Call after saving/deleting an API key so credential indicators refresh.
    func credentialsChanged() {
        credentialsRevision += 1
    }

    func add(_ project: AppProject) {
        projects.append(project)
        persist()
    }

    func update(_ project: AppProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        persist()
    }

    func delete(_ project: AppProject) {
        projects.removeAll { $0.id == project.id }
        // The ASC API key is keyed on the project id; drop it with the project.
        try? KeychainStore.delete(forProjectId: project.id)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

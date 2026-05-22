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
    // No default value: a nonisolated init can *initialize* this isolated property
    // exactly once, but reassigning a defaulted value counts as a mutation (which
    // a nonisolated init isn't allowed to do on a @MainActor property).
    private(set) var projects: [AppProject]
    /// Bumped whenever a project's API key is saved/deleted. Views that show a
    /// credential indicator (the sidebar) read this so they re-check the Keychain.
    private(set) var credentialsRevision = 0

    private let fileURL: URL

    /// `nonisolated` so SwiftUI can build it in a property initializer
    /// (`@State private var store = ProjectStore()`) regardless of the App's
    /// isolation. The disk read is inlined since the MainActor `load()` can't be
    /// called from here; setting the isolated stored properties during init is allowed.
    nonisolated init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FlightKit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appending(path: "projects.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AppProject].self, from: data) {
            self.projects = decoded
        } else {
            self.projects = []
        }
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

//
//  ProjectListView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

/// Sidebar list of the user's apps. Add / edit / delete are surfaced here; the
/// catalog itself lives in `ProjectStore` (Application Support).
@MainActor
struct ProjectListView: View {
    @Bindable var store: ProjectStore
    @Binding var selectionID: String?
    let onAdd: () -> Void
    let onEdit: (AppProject) -> Void

    var body: some View {
        List(selection: $selectionID) {
            ForEach(store.projects) { project in
                ProjectRow(project: project, store: store)
                    .tag(project.id)
                    .contextMenu {
                        Button("Edit…") { onEdit(project) }
                        Button("Delete", role: .destructive) { store.delete(project) }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("FlightKit")
        .overlay {
            if store.projects.isEmpty {
                ContentUnavailableView("No apps", systemImage: "tray", description: Text("Add your first app to publish."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) { Image(systemName: "plus") }
                    .help("Add an app")
            }
        }
    }
}

@MainActor
private struct ProjectRow: View {
    let project: AppProject
    let store: ProjectStore

    /// Read synchronously each render. Reading `store.credentialsRevision` below
    /// registers a dependency so saving/deleting an API key refreshes this row.
    private var hasCredentials: Bool {
        (try? KeychainStore.load(forProjectId: project.id)) != nil
    }

    var body: some View {
        _ = store.credentialsRevision // observe: re-evaluate when credentials change
        return VStack(alignment: .leading, spacing: 4) {
            Text(project.displayName).font(.headline)
            Text(project.bundleIdentifier)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text(project.containerURL.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if !hasCredentials {
                Label("API key not set", systemImage: "key.slash")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

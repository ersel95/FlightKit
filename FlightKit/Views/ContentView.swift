//
//  ContentView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: ProjectStore
    @State private var selectionID: String?
    @State private var editorTarget: ProjectEditorTarget?

    private var selectedProject: AppProject? {
        store.projects.first { $0.id == selectionID }
    }

    var body: some View {
        NavigationSplitView {
            ProjectListView(
                store: store,
                selectionID: $selectionID,
                onAdd: { editorTarget = ProjectEditorTarget(project: nil) },
                onEdit: { editorTarget = ProjectEditorTarget(project: $0) }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let project = selectedProject {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                emptyDetail
            }
        }
        .sheet(item: $editorTarget) { target in
            ProjectEditorView(store: store, existing: target.project) { saved in
                if let saved { selectionID = saved.id }
                editorTarget = nil
            }
            .frame(minWidth: 560, minHeight: 520)
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            Label(store.projects.isEmpty ? "No apps yet" : "Select an app", systemImage: "airplane.departure")
        } description: {
            Text(store.projects.isEmpty
                 ? "Add an app to publish — pick its .xcworkspace or .xcodeproj, then upload to TestFlight or the App Store."
                 : "Pick an app on the left to view its versions and publish.")
        } actions: {
            if store.projects.isEmpty {
                Button("Add app…") { editorTarget = ProjectEditorTarget(project: nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Identifiable wrapper so the editor sheet can present either a new project
/// (`project == nil`) or an existing one for editing.
struct ProjectEditorTarget: Identifiable {
    let id = UUID()
    let project: AppProject?
}

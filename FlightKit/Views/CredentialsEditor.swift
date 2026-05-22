//
//  CredentialsEditor.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import AppKit

struct CredentialsEditor: View {
    let project: AppProject
    let onClose: () -> Void

    @State private var keyId: String = ""
    @State private var issuerId: String = ""
    @State private var pemText: String = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("App Store Connect API key").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.escape)
            }
            Text("For: \(project.displayName)  ·  Team \(project.teamId)")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Key ID")
                TextField("e.g. ABCD1234XY", text: $keyId)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Issuer ID")
                TextField("e.g. 69a6de70-…", text: $issuerId)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Private key (.p8)")
                    Spacer()
                    Button("Choose .p8 file…") { pickFile() }
                }
                TextEditor(text: $pemText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if (try? KeychainStore.load(forProjectId: project.id)) != nil {
                    Button(role: .destructive) {
                        try? KeychainStore.delete(forProjectId: project.id)
                        onClose()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || keyId.isEmpty || issuerId.isEmpty || pemText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.prompt = "Select .p8 file"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                pemText = try String(contentsOf: url, encoding: .utf8)
                if keyId.isEmpty {
                    let name = url.deletingPathExtension().lastPathComponent
                    if let r = name.range(of: "AuthKey_") {
                        keyId = String(name[r.upperBound...])
                    }
                }
            } catch {
                self.error = "Could not read .p8: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        isSaving = true
        defer { isSaving = false }
        let creds = ASCCredentials(keyId: keyId.trimmingCharacters(in: .whitespaces),
                                    issuerId: issuerId.trimmingCharacters(in: .whitespaces),
                                    privateKeyPEM: pemText)
        do {
            try KeychainStore.save(creds, forProjectId: project.id)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

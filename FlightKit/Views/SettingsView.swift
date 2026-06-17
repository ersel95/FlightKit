//
//  SettingsView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

/// The app's preferences window (⌘,). Currently governs how the publish
/// pipeline collects a build number — see `AppSettings`.
@MainActor
struct SettingsView: View {
    @AppStorage(AppSettings.buildNumberManagedKey) private var buildNumberManaged = true
    @AppStorage(AppSettings.buildNumberSharedKey) private var buildNumberShared = true
    @AppStorage(AppSettings.testNoteManagedKey) private var testNoteManaged = true
    @AppStorage(AppSettings.testNoteSharedKey) private var testNoteShared = true

    var body: some View {
        Form {
            Section("Build number") {
                Toggle("Build number'ı her yayında sor", isOn: $buildNumberManaged)
                Text(buildNumberManaged
                     ? "Her yayında build number alanı gösterilir ve elle girilir."
                     : "Build number alanı gizlenir; her ortama arka planda otomatik olarak \(AppSettings.unmanagedBuildNumber) gönderilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Çoklu ortamda build number", selection: $buildNumberShared) {
                    Text("Tüm ortamlar için ortak").tag(true)
                    Text("Her ortam için ayrı").tag(false)
                }
                .pickerStyle(.radioGroup)
                .disabled(!buildNumberManaged)

                Text(buildNumberShared
                     ? "Seçili tüm ortamlar aynı build number ile yayınlanır."
                     : "Her seçili ortam için ayrı bir build number girilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test notu (TestFlight)") {
                Toggle("Test notunu her yayında sor", isOn: $testNoteManaged)
                Text(testNoteManaged
                     ? "Her yayında test notu alanı gösterilir. Alan opsiyoneldir; boş bırakılırsa not yazılmaz."
                     : "Test notu alanı gizlenir; hiçbir sürüme test notu yazılmaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Çoklu ortamda test notu", selection: $testNoteShared) {
                    Text("Tüm ortamlar için ortak").tag(true)
                    Text("Her ortam için ayrı").tag(false)
                }
                .pickerStyle(.radioGroup)
                .disabled(!testNoteManaged)

                Text(testNoteShared
                     ? "Seçili tüm ortamlara aynı test notu yazılır."
                     : "Her seçili ortam için ayrı bir test notu girilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

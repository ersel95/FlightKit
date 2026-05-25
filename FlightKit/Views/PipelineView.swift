//
//  PipelineView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI
import AppKit

@MainActor
struct PipelineView: View {
    @Bindable var batch: PipelineBatch
    @State private var shownIndex: Int = 0
    /// Whether the log view auto-scrolls to the tail. Turns off when the user
    /// scrolls up; the "Takip et" button (and scrolling back to the bottom) re-arms it.
    @State private var isFollowingLog = true
    @State private var showReport = false
    @Environment(\.dismiss) private var dismiss

    /// The pipeline currently displayed. Clamped so it stays valid even if the
    /// batch shrinks (it never does today, but keeps the index access safe).
    private var state: PipelineState {
        batch.states[min(shownIndex, batch.states.count - 1)]
    }

    private var isBatch: Bool { batch.states.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isBatch {
                environmentSwitcher
            }
            Divider()
            HSplitView {
                stepsPanel
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                logPanel
            }
        }
        .background(.background)
        .onChange(of: batch.activeIndex) { _, newValue in
            // Follow the running environment unless the user is finished sweeping.
            if !batch.isFinished { shownIndex = newValue }
        }
        .onChange(of: shownIndex) { _, _ in
            // Re-arm tail following when switching to another environment's log.
            isFollowingLog = true
        }
        .onChange(of: batch.isFinished) { _, finished in
            if finished { showReport = true }
        }
        .onDisappear {
            // The processing watch only runs "while the screen stays open" — stop
            // polling once the pipeline window is dismissed.
            batch.cancelProcessingWatches()
        }
        .sheet(isPresented: $showReport) {
            PipelineReportView(batch: batch) { showReport = false }
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Publishing \(state.project.displayName)").font(.title3.weight(.semibold))
                Text("\(state.targetVersion) (\(state.targetBuildNumber)) · \(state.project.bundleIdentifier)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copyLog()
            } label: {
                Label("Copy log", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy the full log of the shown environment to the clipboard")
            if batch.isFinished {
                Button {
                    showReport = true
                } label: {
                    Label("Rapor", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
    }

    private func copyLog() {
        let text = state.logLines.map(\.message).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var environmentSwitcher: some View {
        Picker("", selection: $shownIndex) {
            ForEach(Array(batch.states.enumerated()), id: \.offset) { index, st in
                Label(st.project.configuration, systemImage: glyph(for: st, at: index))
                    .tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// SF Symbol summarising an environment's state within the batch.
    private func glyph(for st: PipelineState, at index: Int) -> String {
        if st.hasFailure { return "xmark.circle.fill" }
        if st.isFinished { return "checkmark.circle.fill" }
        if index == batch.activeIndex && !batch.isFinished { return "arrow.triangle.2.circlepath" }
        return "circle"
    }

    private var stepsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.steps) { step in
                    StepRow(step: step, status: state.stepStatuses[step] ?? .pending, isCurrent: state.currentStep == step)
                }
                if let ipa = state.finalIPAPath {
                    Divider().padding(.vertical, 6)
                    Label(ipa.lastPathComponent, systemImage: "shippingbox.fill")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if state.isFinished || state.processingPhase != .idle {
                    Divider().padding(.vertical, 6)
                    ProcessingStatusRow(state: state)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logPanel: some View {
        // Native NSTextView: a drag selection spans the entire log (separate
        // SwiftUI Text views can't be selected across — selection stopped at each
        // line). Also gives ⌘F find and incremental appends that don't disturb an
        // in-progress selection.
        SelectableLogView(lines: state.logLines, isFollowing: $isFollowingLog)
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingLog {
                    Button {
                        isFollowingLog = true
                    } label: {
                        Label("Takip et", systemImage: "arrow.down.to.line")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.secondary.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .shadow(radius: 4, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isFollowingLog)
    }
}

/// Read-only, monospaced, colourised log console backed by `NSTextView`.
/// Appends incrementally. When `isFollowing` is on it pins to the tail on every
/// update; user scrolling (detected via live-scroll, not content growth) toggles
/// `isFollowing` to match whether they're at the bottom — so the parent can show
/// a "follow" button when they've scrolled up.
private struct SelectableLogView: NSViewRepresentable {
    let lines: [LogLine]
    @Binding var isFollowing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.black.withAlphaComponent(0.85)

        // A programmatically-built scrollable NSTextView needs the full resizable
        // setup (frame + min/max size + vertical resizing + width autoresizing +
        // a width-tracking container). Without it the text view stays zero-sized
        // and lays its text out into nothing — the panel shows only the scroll
        // view's background and the log looks "empty" regardless of appearance.
        let contentSize = scroll.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll

        // Live-scroll fires only for user-driven scrolling (trackpad/mouse/scroller),
        // never for our programmatic scrollToEnd or content-height growth — so it's
        // a clean signal of intent without the false positives a bounds observer hits.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.userDidLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scroll
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard let textView = coord.textView, let storage = textView.textStorage else { return }

        // Reset if the log was cleared / replaced (count shrank).
        if lines.count < coord.renderedCount {
            storage.setAttributedString(NSAttributedString())
            coord.renderedCount = 0
        }

        if lines.count > coord.renderedCount {
            let appended = NSMutableAttributedString()
            for line in lines[coord.renderedCount..<lines.count] {
                if storage.length > 0 || appended.length > 0 {
                    appended.append(NSAttributedString(string: "\n"))
                }
                appended.append(NSAttributedString(string: line.message, attributes: [
                    .foregroundColor: Self.color(for: line.kind),
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                ]))
            }
            storage.append(appended)
            coord.renderedCount = lines.count
        }

        // Pin to the tail whenever following is armed — covers both new content
        // and the user re-arming via the "Takip et" button.
        if isFollowing { textView.scrollToEndOfDocument(nil) }
    }

    static func isScrolledToBottom(_ scroll: NSScrollView) -> Bool {
        let clip = scroll.contentView
        guard let docHeight = scroll.documentView?.bounds.height else { return true }
        let visibleMaxY = clip.bounds.origin.y + clip.bounds.height
        return visibleMaxY >= docHeight - 24 // within ~one line of the bottom
    }

    private static func color(for kind: LogLine.Kind) -> NSColor {
        switch kind {
        case .stdout: return NSColor.systemGreen.withAlphaComponent(0.85)
        case .stderr: return NSColor.systemYellow.withAlphaComponent(0.9)
        case .info:   return NSColor.systemCyan
        case .fix:    return NSColor.systemOrange
        case .error:  return NSColor.systemRed
        }
    }

    @MainActor
    final class Coordinator {
        var parent: SelectableLogView
        var textView: NSTextView?
        weak var scrollView: NSScrollView?

        var renderedCount = 0

        init(_ parent: SelectableLogView) { self.parent = parent }

        // AppKit delivers live-scroll notifications on the main thread, so the
        // @MainActor selector touches the (MainActor) binding safely.
        @objc func userDidLiveScroll() {
            guard let scroll = scrollView else { return }
            let atBottom = SelectableLogView.isScrolledToBottom(scroll)
            // Scrolling up disarms following; scrolling back to the bottom re-arms it.
            if parent.isFollowing != atBottom {
                parent.isFollowing = atBottom
            }
        }
    }
}

private struct StepRow: View {
    let step: PublishStep
    let status: PublishStepStatus
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(step.displayName).font(.body.weight(.medium))
                if case .retrying(let reason) = status {
                    Text("retrying — \(reason)").font(.caption2).foregroundStyle(.orange)
                }
                if case .failed(let msg) = status {
                    Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isCurrent
            ? AnyShapeStyle(.tint.opacity(0.10))
            : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary).frame(width: 18, height: 18)
        case .running:
            ProgressView().controlSize(.small).frame(width: 18, height: 18)
        case .retrying:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).frame(width: 18, height: 18)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 18, height: 18)
        }
    }
}

/// Live, non-blocking status of the post-upload App Store Connect processing
/// (and, for App Store, the automatic version attach). Mirrors `ProcessingPhase`.
@MainActor
private struct ProcessingStatusRow: View {
    let state: PipelineState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text("App Store Connect işlemesi").font(.body.weight(.medium))
                Text(ProcessingPresentation.detail(for: state))
                    .font(.caption2)
                    .foregroundStyle(ProcessingPresentation.isError(state.processingPhase) ? .red : .secondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.processingPhase {
        case .idle:
            Image(systemName: "clock").foregroundStyle(.tertiary).frame(width: 18, height: 18)
        case .waiting, .attaching:
            ProgressView().controlSize(.small).frame(width: 18, height: 18)
        case .valid, .attached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 18, height: 18)
        case .stopped:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange).frame(width: 18, height: 18)
        }
    }
}

/// Shared human-readable text for a `PipelineState`'s processing phase, used by
/// both the live pipeline view and the post-run report.
@MainActor
enum ProcessingPresentation {
    static func isError(_ phase: ProcessingPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    static func detail(for state: PipelineState) -> String {
        switch state.processingPhase {
        case .idle:
            return "Upload sonrası başlayacak"
        case .waiting:
            let raw = state.processingStateText.map { " (\($0))" } ?? ""
            return "İşleniyor…\(raw)"
        case .valid:
            return state.destination == .appStore
                ? "İşleme tamamlandı — sürüme bağlanıyor"
                : "İşleme tamamlandı — TestFlight'ta hazır"
        case .attaching:
            return "App Store sürümüne bağlanıyor…"
        case .attached(let version):
            return "Sürüm \(version)'e bağlandı — incelemeye gönderilmedi"
        case .failed(let reason):
            return reason
        case .stopped:
            return "İzleme durduruldu — ekranı açık tutarak devam ettirin"
        }
    }
}

// MARK: - Report

/// Post-run summary: per environment, what we submitted vs what App Store Connect
/// actually recorded. Surfaces the store renumbering the build (the number we sent
/// already existed) so "1.0.0 (1)" landing as "1.0.0 (2)" is never a silent surprise.
@MainActor
struct PipelineReportView: View {
    let batch: PipelineBatch
    let onClose: () -> Void

    private var allSucceeded: Bool { batch.states.allSatisfy { !$0.hasFailure } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(Array(batch.states.enumerated()), id: \.offset) { _, state in
                    Section {
                        rows(for: state)
                    } header: {
                        sectionHeader(for: state)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: allSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(allSucceeded ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Yayın Raporu").font(.title3.weight(.semibold))
                Text(allSucceeded
                     ? "Tüm hedefler tamamlandı"
                     : "Bazı hedefler başarısız oldu")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Kapat") { onClose() }.buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    @ViewBuilder
    private func sectionHeader(for state: PipelineState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.hasFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(state.hasFailure ? .red : .green)
            Text(state.project.displayName).font(.headline)
            Text(state.project.configuration)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
            Spacer()
            Text(state.project.bundleIdentifier)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func rows(for state: PipelineState) -> some View {
        LabeledContent("Gönderilen", value: "\(state.targetVersion) (\(state.targetBuildNumber))")

        LabeledContent("App Store Connect") {
            if let build = state.publishedBuildNumber {
                Text("\(state.publishedMarketingVersion ?? state.targetVersion) (\(build))")
                    .foregroundStyle(state.buildNumberWasRenumbered ? .orange : .secondary)
            } else {
                Text("Doğrulanamadı").foregroundStyle(.secondary)
            }
        }

        if state.buildNumberWasRenumbered {
            Label {
                Text("App Store Connect build numarasını **\(state.targetBuildNumber) → \(state.publishedBuildNumber ?? "?")** olarak değiştirdi — gönderdiğiniz numara zaten mevcuttu.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }

        LabeledContent("İşleme durumu") {
            HStack(spacing: 6) {
                if !state.processingPhase.isTerminal && state.processingPhase != .idle {
                    ProgressView().controlSize(.small)
                }
                Text(ProcessingPresentation.detail(for: state))
                    .foregroundStyle(ProcessingPresentation.isError(state.processingPhase) ? .red : .secondary)
                    .multilineTextAlignment(.trailing)
            }
        }

        if let failure = failure(for: state) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failure.step.displayName) başarısız").font(.caption.weight(.semibold))
                    Text(failure.message).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    private func failure(for state: PipelineState) -> (step: PublishStep, message: String)? {
        for step in state.steps {
            if case .failed(let message) = state.stepStatuses[step] ?? .pending {
                return (step, message)
            }
        }
        return nil
    }
}

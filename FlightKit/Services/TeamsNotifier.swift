//
//  TeamsNotifier.swift
//  FlightKit
//
//  Created by Mr. t.
//

import AppKit
import ApplicationServices
import CoreGraphics

/// Posts a release notification into a Microsoft Teams chat by driving the local
/// Teams desktop app — used when the org has locked down Incoming Webhooks and the
/// Power Automate portal, so there is no server-side path to a channel.
///
/// The flow is deliberately UI-level and best-effort: it opens the chat via a Teams
/// deep link (which focuses the compose box), puts the message on the clipboard, then
/// synthesises `⌘V` + `Return` via `CGEvent`. That requires the app to be trusted for
/// Accessibility (System Settings → Privacy & Security → Accessibility). FlightKit is
/// not sandboxed, so once granted this works. It is inherently fragile — a Teams UI/
/// shortcut change can break it — and never throws into the pipeline.
@MainActor
enum TeamsNotifier {
    /// macOS virtual key codes (ANSI layout) for the keys we synthesise.
    private enum Key {
        static let v: CGKeyCode = 0x09
        static let `return`: CGKeyCode = 0x24
    }

    /// Seconds to wait after opening the deep link before typing — Teams must come
    /// to the front, navigate to the chat, and focus its compose box first. A cold
    /// launch needs the higher end; this is the conservative default.
    private static let focusDelay: Duration = .milliseconds(2500)

    /// Whether the app is currently trusted to post synthetic events.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the user to grant Accessibility access (opens the System Settings
    /// pane the first time). Returns the current trust state.
    @discardableResult
    static func requestAccess() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a global `var` (not concurrency-safe under
        // Swift 6); its value is this stable string, so reference the key literally.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    enum NotifyError: LocalizedError {
        case notTrusted
        case badLink(String)

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Erişilebilirlik izni yok. System Settings → Privacy & Security → Accessibility'den FlightKit'e izin verin."
            case .badLink(let link):
                return "Geçersiz Teams bağlantısı: \(link)"
            }
        }
    }

    /// Opens the chat and sends `message` into it. Throws `NotifyError` on a bad link
    /// or missing permission; the caller logs and continues (never fatal).
    static func notify(chatLink: String, message: String, log: (String) -> Void = { _ in }) async throws {
        let trimmed = chatLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true || url.scheme == "msteams" else {
            throw NotifyError.badLink(chatLink)
        }
        guard isTrusted else {
            requestAccess()
            throw NotifyError.notTrusted
        }

        // Preserve whatever the user had on the clipboard — we borrow it for the paste.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)

        log("Teams sohbeti açılıyor…")
        NSWorkspace.shared.open(url)

        try? await Task.sleep(for: focusDelay)

        // The deep link should have activated Teams, but focus can drift — pull it
        // back to the front explicitly before typing.
        activateTeams()
        try? await Task.sleep(for: .milliseconds(300))

        paste()
        try? await Task.sleep(for: .milliseconds(300))
        pressReturn()
        log("Teams'e bildirim gönderildi")

        // Restore the user's clipboard once Teams has had time to read the paste.
        try? await Task.sleep(for: .milliseconds(500))
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    // MARK: - Helpers

    /// Brings the running Teams app (new "Teams" or classic) to the foreground.
    private static func activateTeams() {
        let bundleIds = ["com.microsoft.teams2", "com.microsoft.teams"]
        let teams = NSWorkspace.shared.runningApplications.first { app in
            guard let id = app.bundleIdentifier else { return false }
            return bundleIds.contains(id)
        }
        teams?.activate(options: [.activateAllWindows])
    }

    private static func paste() {
        postKey(Key.v, flags: .maskCommand)
    }

    private static func pressReturn() {
        postKey(Key.return, flags: [])
    }

    /// Synthesises a key press (down + up) on the HID event tap, so the frontmost
    /// app (Teams) receives it as real input.
    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

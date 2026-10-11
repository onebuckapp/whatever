// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import AppKit

/// Two-press ⌘Q quit confirmation, Chrome-style.
///
/// The first ⌘Q does not quit: it arms, shows a brief floating prompt, and
/// starts a short timer. A second ⌘Q before the timer expires quits; expiry
/// dismisses the prompt and the next ⌘Q starts over. Only the keyboard
/// shortcut warns — the menu item clicked with the mouse, the Dock menu, and
/// shutdown quit at once, as does everything when the settings toggle is
/// off. The second press terminates through `NSApp`, so the existing
/// `applicationShouldTerminate` session/settings save runs unchanged.
@MainActor
final class QuitConfirmation {
    static let shared = QuitConfirmation()

    /// How long the second press stays valid. Seconds.
    static let confirmationWindow: TimeInterval = 2.0

    /// The prompt copy. Native ⌘ symbol, never "Cmd".
    static let promptText = "Press ⌘Q again to quit"

    /// Where the quit request came from. The WhateverApp action maps
    /// `NSApp.currentEvent`: a keyDown is the shortcut, anything else is a
    /// menu click.
    enum RequestSource {
        case keyboard
        case menu
    }

    /// Runs the real quit. A seam so tests can watch without terminating.
    var terminateHandler: () -> Void = { NSApp.terminate(nil) }

    /// Reads the settings toggle. A seam so tests need not touch the shared
    /// store.
    var confirmationEnabled: () -> Bool = {
        SettingsStore.shared.settings.general.warnBeforeQuitting
    }

    /// Whether a first press is outstanding. Tests pin the transitions
    /// through this rather than the timer.
    private(set) var isArmed = false

    private var expiry: Task<Void, Never>?
    private let panel: QuitPromptPanel
    private var resignObserver: NSObjectProtocol?

    init(panel: QuitPromptPanel = QuitPromptPanel()) {
        self.panel = panel
        // A topmost prompt must not linger over other apps: switching away
        // dismisses and resets, so coming back starts over.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Resign-active posts on the main thread and `queue: nil`
            // delivers synchronously, so the handoff stays synchronous and
            // deterministic instead of racing the next keypress.
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    /// Whether the prompt is currently presented, for tests.
    var isPromptVisible: Bool { panel.isShowing }

    func handleQuitRequest(source: RequestSource) {
        guard confirmationEnabled(), source == .keyboard else {
            terminateHandler()
            return
        }
        if isArmed {
            disarm()
            terminateHandler()
            return
        }
        isArmed = true
        panel.show()
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.confirmationWindow * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    /// Fires the timer early. The timer's target and the tests' hook: expiry
    /// dismisses and resets without quitting.
    func expire() {
        disarm()
    }

    private func disarm() {
        expiry?.cancel()
        expiry = nil
        isArmed = false
        panel.hide()
    }
}

/// The "Press ⌘Q again to quit" prompt.
///
/// A borderless floating pill: no title bar, no border, just the message on
/// a translucent dark background. Deliberately not a true modal — it never
/// activates, cannot become key or main, and ignores the mouse entirely, so
/// typing into the page and the second ⌘Q keep working while it is up. A
/// blocking modal would swallow both for the whole confirmation window. One
/// instance lives on `QuitConfirmation.shared`; show/hide are idempotent.
final class QuitPromptPanel: NSPanel {
    /// The pill background opacity. Translucent enough to read as a
    /// transient, solid enough to lift the message off any page behind it.
    static let backgroundOpacity: CGFloat = 0.7

    private let container = NSView()
    private let label: NSTextField

    /// Whether the prompt is currently presented. Tests pin the transitions
    /// through this rather than the fade animation.
    private(set) var isShowing = false

    init(text: String = QuitConfirmation.promptText) {
        label = NSTextField(labelWithString: text)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        // Above everything in the app: floating sits below modal panels and
        // popup-level windows, either of which could otherwise cover the
        // prompt. `.fullScreenAuxiliary` joins fullscreen Spaces instead of
        // vanishing when the browser is fullscreen.
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: Self.backgroundOpacity).cgColor
        container.layer?.cornerRadius = 12

        label.font = .systemFont(ofSize: 14)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        contentView = container
        // Dialog-like padding around the message. The fixed string always
        // fits; the inequality constraints above only guard future copy.
        let textSize = label.intrinsicContentSize
        setContentSize(NSSize(width: textSize.width + 48, height: textSize.height + 36))

        // Announced, not focused: VoiceOver reads the prompt while keyboard
        // input stays where it was.
        label.setAccessibilityLabel(text)

        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// The message as laid out, for tests.
    var messageText: String { label.stringValue }

    /// The message's VoiceOver label, for tests.
    var messageAccessibilityLabel: String? { label.accessibilityLabel() }

    /// Whether the message laid out to a real frame, for tests.
    var isMessageLaidOut: Bool { !label.frame.isEmpty }

    func show() {
        guard !isShowing else { return }
        isShowing = true
        let size = contentView?.frame.size ?? frame.size
        if let anchor = NSApp.keyWindow ?? NSApp.mainWindow {
            setFrameOrigin(NSPoint(
                x: anchor.frame.midX - size.width / 2,
                y: anchor.frame.midY - size.height / 2
            ))
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
        }
        orderFrontRegardless()
        animator().alphaValue = 1
        NSAccessibility.post(
            element: label,
            notification: .announcementRequested,
            userInfo: [.announcement: label.stringValue]
        )
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        animator().alphaValue = 0
        // The fade-out leaves a transparent panel behind; order out on the
        // next pass. Delayed to outlive the animation rather than snapping it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.orderOut(nil)
        }
    }
}

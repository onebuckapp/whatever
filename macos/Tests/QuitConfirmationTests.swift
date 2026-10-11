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
import Foundation
import Testing
@testable import Whatever

/// Two-press ⌘Q quit confirmation: the first press arms and shows the
/// prompt without quitting, the second quits, and expiry resets — while the
/// menu click and a disabled toggle quit at once.
@MainActor
struct QuitConfirmationTests {
    /// A confirmation that records quits instead of terminating, with the
    /// settings toggle injected so the shared store stays untouched.
    private func confirmation(enabled: Bool = true) -> (QuitConfirmation, () -> Bool) {
        var terminated = false
        let subject = QuitConfirmation()
        subject.terminateHandler = { terminated = true }
        subject.confirmationEnabled = { enabled }
        return (subject, { terminated })
    }

    @Test("the second press stays valid for two seconds")
    func windowIsTwoSeconds() {
        #expect(QuitConfirmation.confirmationWindow == 2.0)
    }

    @Test("the prompt uses the native ⌘ symbol")
    func promptCopy() {
        #expect(QuitConfirmation.promptText == "Press ⌘Q again to quit")
        #expect(QuitConfirmation.promptText.contains("⌘"))
        #expect(!QuitConfirmation.promptText.contains("Cmd"))
    }

    @Test("the first press arms and shows without quitting")
    func firstPressArms() {
        let (subject, terminated) = confirmation()
        subject.handleQuitRequest(source: .keyboard)
        #expect(subject.isArmed)
        #expect(subject.isPromptVisible)
        #expect(!terminated())
    }

    @Test("the second press quits and resets")
    func secondPressQuits() {
        let (subject, terminated) = confirmation()
        subject.handleQuitRequest(source: .keyboard)
        subject.handleQuitRequest(source: .keyboard)
        #expect(terminated())
        #expect(!subject.isArmed)
        #expect(!subject.isPromptVisible)
    }

    @Test("expiry dismisses and resets without quitting")
    func expiryResets() {
        let (subject, terminated) = confirmation()
        subject.handleQuitRequest(source: .keyboard)
        subject.expire()
        #expect(!subject.isArmed)
        #expect(!subject.isPromptVisible)
        #expect(!terminated())
        // The next ⌘Q starts over: it arms again instead of quitting.
        subject.handleQuitRequest(source: .keyboard)
        #expect(subject.isArmed)
        #expect(!terminated())
    }

    @Test("a disabled toggle quits at once with no prompt")
    func toggleOffQuitsAtOnce() {
        let (subject, terminated) = confirmation(enabled: false)
        subject.handleQuitRequest(source: .keyboard)
        #expect(terminated())
        #expect(!subject.isArmed)
        #expect(!subject.isPromptVisible)
    }

    @Test("a menu click quits at once with no prompt")
    func menuClickQuitsAtOnce() {
        let (subject, terminated) = confirmation()
        subject.handleQuitRequest(source: .menu)
        #expect(terminated())
        #expect(!subject.isArmed)
        #expect(!subject.isPromptVisible)
    }

    @Test("the panel floats, ignores input, and stays unfocusable")
    func panelManners() {
        let panel = QuitPromptPanel()
        #expect(panel.styleMask == .borderless)
        #expect(panel.level == .popUpMenu)
        #expect(panel.level.rawValue > NSWindow.Level.modalPanel.rawValue)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.isExcludedFromWindowsMenu)
    }

    @Test("the pill background sits at 70%")
    func backgroundOpacity() {
        #expect(QuitPromptPanel.backgroundOpacity == 0.7)
        let panel = QuitPromptPanel()
        #expect(abs((panel.contentView?.layer?.backgroundColor?.alpha ?? 1) - 0.7) < 0.01)
    }

    @Test("the pill carries its message")
    func dialogCopy() {
        let panel = QuitPromptPanel()
        #expect(panel.messageText == QuitConfirmation.promptText)
        panel.show()
        panel.layoutIfNeeded()
        #expect(panel.isMessageLaidOut)
        panel.hide()
    }

    @Test("the panel is announced to assistive technology")
    func panelAccessibility() {
        let panel = QuitPromptPanel()
        panel.show()
        #expect(panel.isShowing)
        #expect(panel.messageAccessibilityLabel == QuitConfirmation.promptText)
        panel.hide()
        #expect(!panel.isShowing)
    }

    @Test("switching apps dismisses and resets without quitting")
    func resignActiveResets() {
        let (subject, terminated) = confirmation()
        subject.handleQuitRequest(source: .keyboard)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!subject.isArmed)
        #expect(!subject.isPromptVisible)
        #expect(!terminated())
    }

    @Test("a legacy document without the toggle keeps its general settings")
    func legacyDecodeKeepsGeneral() throws {
        let legacy = #"{"restoreSession":false,"recordsHistory":true,"historyCollapseWindow":10}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.GeneralSettings.self, from: legacy)
        #expect(decoded.restoreSession == false)
        #expect(decoded.recordsHistory == true)
        #expect(decoded.historyCollapseWindow == 10)
        #expect(decoded.warnBeforeQuitting == true)
    }

    @Test("the toggle defaults on and round-trips")
    func toggleRoundTrip() throws {
        #expect(AppSettings.GeneralSettings().warnBeforeQuitting == true)
        var settings = AppSettings.GeneralSettings()
        settings.warnBeforeQuitting = false
        let roundTripped = try JSONDecoder().decode(
            AppSettings.GeneralSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(roundTripped == settings)
    }
}

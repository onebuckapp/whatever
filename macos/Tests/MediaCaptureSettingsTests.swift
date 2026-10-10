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

import Foundation
import Testing
@testable import Whatever

/// Capture permission memory: per-site verdicts, tolerant decoding, and the
/// verdict-not-session state the tab carries. Pure values throughout.
@MainActor
struct MediaCaptureSettingsTests {
    @Test("nothing stored means asking")
    func defaultsToAsk() {
        let settings = AppSettings.MediaCaptureSettings()
        #expect(settings.decision(for: "example.com", kind: .microphone) == .ask)
        #expect(settings.decision(for: "example.com", kind: .camera) == .ask)
    }

    @Test("verdicts store per host and kind, case-insensitively")
    func storesPerHostAndKind() {
        var settings = AppSettings.MediaCaptureSettings()
        settings.setDecision(.allow, for: "Example.COM", kind: .microphone)
        #expect(settings.decision(for: "example.com", kind: .microphone) == .allow)
        #expect(settings.decision(for: "EXAMPLE.com", kind: .microphone) == .allow)
        // Other kinds and hosts keep asking.
        #expect(settings.decision(for: "example.com", kind: .camera) == .ask)
        #expect(settings.decision(for: "other.com", kind: .microphone) == .ask)
    }

    @Test("storing ask clears the verdict and drops empty hosts")
    func askClears() {
        var settings = AppSettings.MediaCaptureSettings()
        settings.setDecision(.block, for: "example.com", kind: .camera)
        settings.setDecision(.ask, for: "example.com", kind: .camera)
        #expect(settings.decision(for: "example.com", kind: .camera) == .ask)
        #expect(settings.decisions["example.com"] == nil)
    }

    @Test("later verdicts overwrite")
    func overwrites() {
        var settings = AppSettings.MediaCaptureSettings()
        settings.setDecision(.allow, for: "example.com", kind: .camera)
        settings.setDecision(.block, for: "example.com", kind: .camera)
        #expect(settings.decision(for: "example.com", kind: .camera) == .block)
    }

    @Test("verdicts round-trip through the settings document")
    func roundTrips() throws {
        var settings = AppSettings.MediaCaptureSettings()
        settings.setDecision(.allow, for: "example.com", kind: .microphone)
        settings.setDecision(.block, for: "example.com", kind: .camera)
        let decoded = try JSONDecoder().decode(
            AppSettings.MediaCaptureSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }

    @Test("documents written before capture settings existed decode to asking")
    func legacyDecodes() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.MediaCaptureSettings.self,
            from: Data("{}".utf8)
        )
        #expect(decoded.decision(for: "example.com", kind: .microphone) == .ask)
    }

    @Test("the whole settings document carries the new group")
    func documentCarriesGroup() throws {
        var document = AppSettings()
        document.mediaCapture.setDecision(.allow, for: "example.com", kind: .camera)
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(document)
        )
        #expect(decoded.mediaCapture == document.mediaCapture)
    }

    @Test("requests and grants drive the toolbar button")
    func activity() {
        var state = MediaCaptureState()
        #expect(state.hasActivity == false)
        state.noteRequest(.microphone)
        #expect(state.hasActivity == true)
        state.noteGranted(.microphone)
        #expect(state.requests.isEmpty)
        #expect(state.grants == [.microphone])
        #expect(state.hasActivity == true)
        state.noteDenied(.camera)
        #expect(state.hasActivity == true)
        state.clear()
        #expect(state.hasActivity == false)
    }

    @Test("same-host walks keep grants but never pending requests")
    func carriedAcrossNavigation() {
        var state = MediaCaptureState()
        state.noteGranted(.camera)
        state.noteRequest(.microphone)
        let same = MediaCaptureState.carried(from: "example.com", to: "example.com", state: state)
        #expect(same.grants == [.camera])
        #expect(same.requests.isEmpty)
        // A new host, a lost host, or a first host all start clean.
        #expect(MediaCaptureState.carried(from: "example.com", to: "other.com", state: state) == MediaCaptureState())
        #expect(MediaCaptureState.carried(from: "example.com", to: nil, state: state) == MediaCaptureState())
        #expect(MediaCaptureState.carried(from: nil, to: "example.com", state: state) == MediaCaptureState())
    }
}

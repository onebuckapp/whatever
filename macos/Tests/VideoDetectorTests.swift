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
import WebKit
@testable import Whatever

/// The video detector: which video enters PiP, and what the page script
/// looks like.
///
/// The selection rule is pure inputs, so the matrix below runs without
/// WebKit; the script shape is pinned by string, and the factory install
/// by a real page like the hover reporter's.
struct VideoDetectorTests {
    private func candidate(
        index: Int = 0,
        isPlaying: Bool = true,
        area: Double = 100_000,
        audible: Bool = true,
        duration: Double = -1,
        hasAudio: Bool = true,
        disabled: Bool = false,
        focused: Bool = false
    ) -> VideoCandidate {
        var raw: [String: Any] = [
            "index": index,
            "playing": isPlaying,
            "area": area,
            "audible": audible,
            "src": "https://example.com/v.mp4",
        ]
        raw["duration"] = duration
        raw["hasAudio"] = hasAudio
        raw["disabled"] = disabled
        raw["focused"] = focused
        return VideoCandidate(raw: raw)!
    }

    @Test("no candidates means no PiP")
    func emptyMeansNil() {
        #expect(VideoDetector.pickBestVideo(from: []) == nil)
    }

    @Test("a paused page offers nothing")
    func pausedMeansNil() {
        let candidates = [
            candidate(index: 0, isPlaying: false),
            candidate(index: 1, isPlaying: false),
        ]
        #expect(VideoDetector.pickBestVideo(from: candidates) == nil)
    }

    @Test("the playing video wins over paused ones")
    func playingBeatsPaused() {
        let candidates = [
            candidate(index: 0, isPlaying: false, area: 1_000_000),
            candidate(index: 1, isPlaying: true, area: 10_000),
        ]
        #expect(VideoDetector.pickBestVideo(from: candidates)?.index == 1)
    }

    @Test("the largest playing video wins")
    func largestPlayingWins() {
        let candidates = [
            candidate(index: 0, area: 50_000),
            candidate(index: 1, area: 400_000),
            candidate(index: 2, area: 200_000),
        ]
        #expect(VideoDetector.pickBestVideo(from: candidates)?.index == 1)
    }

    @Test("audible breaks area ties, then document order")
    func tiesBreakAudibleThenOrder() {
        let loud = candidate(index: 1, area: 100_000, audible: true)
        let quiet = candidate(index: 0, area: 100_000, audible: false)
        #expect(VideoDetector.pickBestVideo(from: [quiet, loud])?.index == 1)
        let first = candidate(index: 0, area: 100_000, audible: false)
        let second = candidate(index: 1, area: 100_000, audible: false)
        #expect(VideoDetector.pickBestVideo(from: [second, first])?.index == 0)
    }

    @Test("sizeless videos never win")
    func sizelessNeverWins() {
        #expect(VideoDetector.pickBestVideo(from: [candidate(area: 0)]) == nil)
        #expect(VideoDetector.pickBestVideo(from: [candidate(area: -4)]) == nil)
    }

    @Test("a focused video jumps the queue")
    func focusedBeatsLarger() {
        let big = candidate(index: 0, area: 1_000_000)
        let small = candidate(index: 1, area: 10_000, focused: true)
        #expect(VideoDetector.pickBestVideo(from: [big, small])?.index == 1)
    }

    @Test("a live stream outranks a clip of equal size")
    func liveBeatsClip() {
        let clip = candidate(index: 0, duration: 30)
        let live = candidate(index: 1, duration: -1)
        #expect(VideoDetector.pickBestVideo(from: [clip, live])?.index == 1)
        let longer = candidate(index: 0, duration: 3_600)
        let shorter = candidate(index: 1, duration: 60)
        #expect(VideoDetector.pickBestVideo(from: [shorter, longer])?.index == 0)
    }

    @Test("a PiP-disabled video loses ties but still plays")
    func disabledLosesTies() {
        let blocked = candidate(index: 0, disabled: true)
        let free = candidate(index: 1, disabled: false)
        #expect(VideoDetector.pickBestVideo(from: [blocked, free])?.index == 1)
        #expect(VideoDetector.pickBestVideo(from: [blocked])?.index == 0)
    }

    @Test("new candidate facts default neutrally")
    func candidateDefaults() {
        let bare = VideoCandidate(
            raw: ["index": 0, "playing": true, "area": 10.0, "audible": true]
        )!
        #expect(bare.duration == -1)
        #expect(bare.rankDuration == .infinity)
        #expect(bare.hasAudio)
        #expect(!bare.disabled)
        #expect(!bare.focused)
        #expect(candidate(duration: 30).rankDuration == 30)
    }

    @Test("malformed reports parse to nothing")
    func malformedParsesNil() {
        #expect(VideoCandidate(raw: [:]) == nil)
        #expect(VideoCandidate(raw: ["index": 0, "playing": true]) == nil)
        #expect(VideoCandidate(raw: ["index": "0", "playing": true, "area": 1.0, "audible": true]) == nil)
    }

    @Test("report parsing keeps candidates and the PiP flag")
    func reportParsing() {
        let body: [String: Any] = [
            "videos": [["index": 2, "playing": true, "area": 50_000.0, "audible": false]],
            "pip": true,
        ]
        let report = VideoReport.parse(body)
        #expect(report.candidates.map(\.index) == [2])
        #expect(report.pipActive)
        #expect(!report.floating)
    }

    @Test("report parsing carries the floating flag and new facts")
    func reportParsingFloating() {
        let body: [String: Any] = [
            "videos": [[
                "index": 0, "playing": true, "area": 50_000.0, "audible": true,
                "duration": -1.0, "hasAudio": true, "disabled": false, "focused": true,
            ]],
            "pip": false,
            "floating": true,
        ]
        let report = VideoReport.parse(body)
        #expect(report.floating)
        #expect(!report.pipActive)
        let only = report.candidates.first
        #expect(only?.duration == -1)
        #expect(only?.hasAudio == true)
        #expect(only?.focused == true)
    }

    @Test("report parsing tolerates malformed bodies")
    func reportParsingToleratesGarbage() {
        #expect(VideoReport.parse(nil) == VideoReport())
        #expect(VideoReport.parse("nope") == VideoReport())
        #expect(VideoReport.parse(["videos": [["index": 0]]]) == VideoReport())
        let missingFlag = VideoReport.parse(["videos": []])
        #expect(missingFlag == VideoReport())
    }

    @Test("script watches media events, PiP events, and DOM churn on every frame")
    func scriptShape() {
        let source = VideoDetector.source
        #expect(source.contains("playing"))
        #expect(source.contains("pause"))
        #expect(source.contains("enterpictureinpicture"))
        #expect(source.contains("leavepictureinpicture"))
        #expect(source.contains("MutationObserver"))
        #expect(source.contains(VideoDetector.handlerName))
        #expect(source.contains("postMessage"))
        #expect(source.contains("__whateverVideo"))
        #expect(source.contains("pictureInPictureElement"))
    }

    @Test("script installs at document start on every frame")
    @MainActor
    func installsEarlyEverywhere() {
        let script = VideoDetector.script
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly == false)
    }

    @Test("script exposes a per-frame enter/exit API and pierces shadow roots")
    func frameAPIShape() {
        let source = VideoDetector.source
        #expect(source.contains("enterBest"))
        #expect(source.contains("shadowRoot"))
        #expect(source.contains("removeAttribute(\"disablepictureinpicture\")"))
        #expect(source.contains("webkitSetPresentationMode"))
        #expect(source.contains("readyState"))
        #expect(source.contains("activeElement"))
        #expect(source.contains("webkitAudioDecodedByteCount"))
    }

    @Test("script reports Safari PiP state and the floating box")
    func activeAndFloatingShape() {
        let source = VideoDetector.source
        #expect(source.contains("webkitPresentationMode"))
        #expect(source.contains("__whateverFloat"))
        #expect(source.contains("floatBest"))
        #expect(source.contains("unfloat"))
        #expect(source.contains("adoptFloat"))
    }

    @Test("float sources mirror the enter/exit traversal")
    func floatSourcesShape() {
        let float = VideoDetector.floatPictureInPictureSource()
        #expect(float.contains("floatBest"))
        #expect(float.contains("postMessage"))
        #expect(float.contains("\"broadcast\""))
        let unfloat = VideoDetector.unfloatPictureInPictureSource
        #expect(unfloat.contains("unfloat"))
        #expect(unfloat.contains("postMessage"))
        #expect(unfloat.contains("\"idle\""))
    }

    @Test("script obeys top-frame enter/exit broadcasts")
    func broadcastShape() {
        let source = VideoDetector.source
        #expect(source.contains("__whateverVideoCommand"))
        #expect(source.contains("postMessage"))
        #expect(source.contains("window.top"))
    }

    @Test("enter-PiP asks the top frame, then broadcasts to the rest")
    func enterPiPShape() {
        let source = VideoDetector.enterPictureInPictureSource()
        #expect(source.contains("enterBest"))
        #expect(source.contains("postMessage"))
        #expect(source.contains("\"ok\""))
        #expect(source.contains("\"broadcast\""))
    }

    @Test("exit-PiP exits locally, then tells every frame to exit")
    func exitPiPShape() {
        let source = VideoDetector.exitPictureInPictureSource
        #expect(source.contains("postMessage"))
        #expect(source.contains("\"idle\""))
    }

    @Test("failure verdicts name the reason, success stays silent")
    func pipFailureText() {
        #expect(BrowserToolbarController.pipFailureText("ok") == nil)
        #expect(BrowserToolbarController.pipFailureText("pending") == nil)
        #expect(
            BrowserToolbarController.pipFailureText("NotAllowedError|rs4|p0|d0")
                == "Couldn't open Picture in Picture (NotAllowedError)"
        )
        #expect(
            BrowserToolbarController.pipFailureText("broadcast")
                == "Couldn't open Picture in Picture (broadcast)"
        )
    }

    @Test("factory pages run the video detector")
    @MainActor
    func installs() async throws {
        let view = WebViewFactory.makeWebView(mode: .regular, dataStore: .default())
        view.loadHTMLString("<video></video>", baseURL: nil)
        var installed = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let hit = try await view.evaluateJavaScriptSafely(
                "typeof window.__whateverVideo?.enterBest === 'function'"
            )
            if (hit as? Bool) == true {
                installed = true
                break
            }
        }
        #expect(installed)
    }
}

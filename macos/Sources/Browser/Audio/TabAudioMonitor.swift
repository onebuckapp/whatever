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
import WebKit

/// Watches one tab's page for sound, and silences it on request.
///
/// Poll-only, because WebKit's `_isPlayingAudio` is a plain getter rather than a
/// property: there is nothing to observe, so the only way to know is to ask. A
/// call measures about 0.4µs, so the poll is cheap enough to run at a rate a
/// person would read as immediate.
///
/// The poll speeds up only for tabs that have something to report. A quiet tab is
/// polled twice a second rather than four times a second so that a window full of
/// idle tabs does not sit on a timer and keep the process out of deep sleep.
///
/// Main-thread only, and not isolated as such: `BrowserTabController`, which owns
/// one of these, is not `@MainActor` either because its KVO callbacks arrive on
/// WebKit's threads. Everything here is reached from main-thread code and runs
/// there, since the timer is on the main run loop.
final class TabAudioMonitor {
    /// Whether the page is making sound right now.
    private(set) var isProducingAudio = false

    /// Whether the user asked this tab to be silent.
    ///
    /// Held here rather than on the view, because a cross-site navigation
    /// discards the view and a tab that remembers being muted is the behaviour
    /// every browser has.
    private(set) var isMuted: Bool

    /// Called on the main actor whenever either value changes.
    var onChange: ((Bool, Bool) -> Void)?

    private weak var webView: WKWebView?
    private var timer: Timer?

    init(isMuted: Bool = false) {
        self.isMuted = isMuted
    }

    /// Starts watching a page, re-asserting the mute onto it.
    ///
    /// Every view starts unmuted, and whether WebKit carries a page's mute across
    /// a navigation inside one view is its own business, so the mute is applied
    /// here rather than assumed to have survived.
    func attach(to webView: WKWebView) {
        detach()
        self.webView = webView
        PageAudioBridge.setMuted(isMuted, on: webView)
        poll()
    }

    /// Stops watching. The mute state stays, since the tab keeps it.
    func detach() {
        timer?.invalidate()
        timer = nil
        webView = nil
        setProducingAudio(false)
    }

    /// Muting deliberately does not change what a tab reports. A silenced tab is
    /// still a tab with something playing, and that is what keeps its indicator on
    /// and reversible, so nothing here recomputes the playing flag on a mute.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if let webView {
            PageAudioBridge.setMuted(muted, on: webView)
        }
        onChange?(isProducingAudio, isMuted)
        rescheduleIfNeeded()
    }

    private func poll() {
        guard let webView else { return }
        // Mute is applied per page, so it is reconciled against what WebKit
        // actually has muted rather than assumed. This is what puts a replacement
        // view, or a page that muted itself since, back into the muted state.
        if isMuted, PageAudioBridge.mutedState(of: webView) & PageAudioMuteState.audio == 0 {
            PageAudioBridge.setMuted(true, on: webView)
        }
        setProducingAudio(PageAudioBridge.isProducingAudio(webView))
        rescheduleIfNeeded()
    }

    private func setProducingAudio(_ producing: Bool) {
        guard producing != isProducingAudio else { return }
        isProducingAudio = producing
        onChange?(isProducingAudio, isMuted)
    }

    /// Runs only while the tab has a view: a tab that has not been realized has
    /// no page to make noise, so there is nothing to ask. The rate is four
    /// checks a second either way, since a check is about half a microsecond;
    /// what changes is that macOS coalesces an idle repeating timer, so a quiet
    /// window full of tabs still gets to sleep.
    private func rescheduleIfNeeded() {
        guard webView != nil else { return }
        let wanted: TimeInterval = (isProducingAudio || isMuted) ? 0.25 : 0.5
        if let timer, abs(timer.timeInterval - wanted) < 0.001 { return }
        timer?.invalidate()
        let next = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // `.common` so a tab that starts playing during a drag or a menu track
        // still updates.
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
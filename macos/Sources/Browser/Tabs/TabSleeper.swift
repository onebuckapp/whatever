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

/// Discards hidden tabs' pages after they sit unused, freeing their WebKit
/// processes.
///
/// Each navigation already builds its view on a fresh process pool, so
/// dropping the view is what actually releases the memory: cookies and site
/// data live in the tab's data store, which survives, and the tab's own
/// history is in-memory, so waking a slept tab reloads its address anew
/// through the normal pane path. Scroll position, form state, and the
/// back/forward cache do not survive the sleep.
///
/// Never sleeps a tab that is displayed (both split panes count), pinned,
/// making sound, or still loading: those are either visible, explicitly
/// kept, or doing work. Everything else with a view past the setting's
/// idle threshold goes. Off disables sweeping entirely; slept tabs stay
/// viewless until shown again rather than being rebuilt eagerly.
@MainActor
final class TabSleeper {
    static let shared = TabSleeper()

    /// How often idle tabs are reaped. Short enough that turning the setting
    /// on bites promptly; the sweep itself is a date comparison per tab.
    private static let sweepInterval: TimeInterval = 60

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            // Hops instead of assuming: the callback carries no actor
            // context, and assuming the main actor from a bare runloop
            // source traps where the executor is not the main one (notably
            // the test host, which launches the app delegate and so starts
            // this timer, then fires it mid-suite).
            Task { @MainActor in
                self?.sweep()
            }
        }
        // `.common` so a sweep is not held up by a menu track or a drag.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Drops one page per qualifying tab. Called by the timer and whenever
    /// the web settings change, so enabling sleeping takes effect at once.
    func sweep() {
        guard let minutes = SettingsStore.shared.settings.web.sleepInactiveTabs.minutes else { return }
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        for window in BrowserCoordinator.shared.windows {
            let displayed = Set(window.displayedTabs.map(\.id))
            for tab in window.tabs {
                guard Self.shouldSleep(
                    hasView: tab.webView != nil,
                    lastActiveAt: tab.lastActiveAt,
                    isDisplayed: displayed.contains(tab.id),
                    isPinned: tab.presentation.isPinned,
                    isProducingAudio: tab.tabController.isProducingAudio,
                    isLoading: tab.tabController.isLoading,
                    cutoff: cutoff
                ) else { continue }
                tab.discardWebView()
            }
        }
    }

    /// The sleep decision as pure inputs, so it is unit-testable without WebKit.
    /// Non-isolated on purpose: it touches no actor state.
    nonisolated static func shouldSleep(
        hasView: Bool,
        lastActiveAt: Date,
        isDisplayed: Bool,
        isPinned: Bool,
        isProducingAudio: Bool,
        isLoading: Bool,
        cutoff: Date
    ) -> Bool {
        guard hasView else { return false }
        guard lastActiveAt < cutoff else { return false }
        guard !isDisplayed, !isPinned, !isProducingAudio, !isLoading else { return false }
        return true
    }
}

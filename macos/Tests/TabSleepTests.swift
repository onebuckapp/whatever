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

/// Sleeping-tab policy: the option mapping and the sleep decision.
///
/// The decision is pure inputs by design, so the matrix below runs without
/// WebKit; the timer, selection stamping, and pane wake path are AppKit and
/// stay out of the suite.
struct TabSleepTests {
    private func decision(
        hasView: Bool = true,
        idleMinutes: Double = 60,
        thresholdMinutes: Double = 5,
        isDisplayed: Bool = false,
        isPinned: Bool = false,
        isProducingAudio: Bool = false,
        isLoading: Bool = false
    ) -> Bool {
        TabSleeper.shouldSleep(
            hasView: hasView,
            lastActiveAt: Date().addingTimeInterval(-idleMinutes * 60),
            isDisplayed: isDisplayed,
            isPinned: isPinned,
            isProducingAudio: isProducingAudio,
            isLoading: isLoading,
            cutoff: Date().addingTimeInterval(-thresholdMinutes * 60)
        )
    }

    @Test("sleeping is off by default")
    func offByDefault() {
        #expect(AppSettings.WebSettings().sleepInactiveTabs == .off)
        #expect(AppSettings.InactiveTabSleep.off.minutes == nil)
    }

    @Test("each option maps to its idle minutes")
    func minutesMapping() {
        #expect(AppSettings.InactiveTabSleep.after5Minutes.minutes == 5)
        #expect(AppSettings.InactiveTabSleep.after15Minutes.minutes == 15)
        #expect(AppSettings.InactiveTabSleep.after30Minutes.minutes == 30)
        #expect(AppSettings.InactiveTabSleep.after1Hour.minutes == 60)
    }

    @Test("the option round-trips and old documents decode to off")
    func persistence() throws {
        var web = AppSettings.WebSettings()
        web.sleepInactiveTabs = .after15Minutes
        let stored = try JSONEncoder().encode(web)
        #expect(try JSONDecoder().decode(AppSettings.WebSettings.self, from: stored) == web)

        let legacy = try JSONDecoder().decode(
            AppSettings.WebSettings.self,
            from: Data("{}".utf8)
        )
        #expect(legacy.sleepInactiveTabs == .off)
    }

    @Test("a long-idle hidden tab sleeps")
    func sleepsWhenIdle() {
        #expect(decision(idleMinutes: 60))
    }

    @Test("a recently used tab stays")
    func staysWhenFresh() {
        #expect(!decision(idleMinutes: 1))
    }

    @Test("a tab without a page has nothing to free")
    func staysWithoutView() {
        #expect(!decision(hasView: false, idleMinutes: 600))
    }

    @Test("displayed, pinned, sounding, and loading tabs never sleep")
    func exemptions() {
        #expect(!decision(idleMinutes: 600, isDisplayed: true))
        #expect(!decision(idleMinutes: 600, isPinned: true))
        #expect(!decision(idleMinutes: 600, isProducingAudio: true))
        #expect(!decision(idleMinutes: 600, isLoading: true))
    }
}

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

/// Resetting the Appearance pane: every group the pane shows returns to its
/// built-in default, and nothing else moves.
///
/// Whole-struct equality is off the table: default gradient stops mint a
/// fresh `UUID` on every init, so two default documents are never `==`.
/// The comparisons below pin values against fresh defaults instead, ignoring
/// stop identity.
struct AppearanceResetTests {
    private func customized() -> AppSettings {
        var document = AppSettings()
        document.appearance.tabCornerRadius = 2
        document.appearance.tabShape = .pills
        document.appearance.crawlCornerRadius = 12
        document.appearance.pageCornerRadius = 0
        document.appearance.linkHoverOpacity = 0.5
        document.appearance.noise.opacity = 0.5
        document.appearance.noise.isEnabled = false
        document.appearance.background.kind = .gradient
        document.appearance.tabTheme.foreground = BackgroundColor(red: 1, green: 0, blue: 0, alpha: 1)
        document.appearance.activeTabTheme.foreground = BackgroundColor(red: 0, green: 1, blue: 0, alpha: 1)
        document.addressBar.fillsWidth = false
        document.addressBar.cornerRadius = 0
        document.addressBar.fieldHeight = 40
        return document
    }

    /// Gradient stops without their identity: colour and position, which is
    /// what "back to the built-in gradient" means.
    private func stopSignature(_ stops: [BackgroundMediaConfiguration.Gradient.Stop]) -> [(BackgroundColor, Double)] {
        stops.map { ($0.color, $0.location) }
    }

    @Test("reset restores the appearance and address bar groups")
    func restoresDefaults() {
        var document = customized()
        document.resetAppearance()
        let fresh = AppSettings()

        #expect(document.appearance.noise == fresh.appearance.noise)
        #expect(document.appearance.background.kind == .none)
        #expect(
            stopSignature(document.appearance.background.gradient.stops).map { "\($0.0.hexString)@\($0.1)" }
                == stopSignature(fresh.appearance.background.gradient.stops).map { "\($0.0.hexString)@\($0.1)" }
        )
        #expect(document.appearance.tabTheme.foreground == nil)
        #expect(document.appearance.activeTabTheme.foreground == nil)
        #expect(document.appearance.tabCornerRadius == fresh.appearance.tabCornerRadius)
        #expect(document.appearance.tabShape == fresh.appearance.tabShape)
        #expect(document.appearance.crawlCornerRadius == fresh.appearance.crawlCornerRadius)
        #expect(document.appearance.pageCornerRadius == fresh.appearance.pageCornerRadius)
        #expect(document.appearance.linkHoverOpacity == fresh.appearance.linkHoverOpacity)
        #expect(document.addressBar == AddressBarSettings())
    }

    @Test("reset leaves every other group alone")
    func preservesOtherGroups() {
        var document = customized()
        document.web.allowsJavaScript = false
        document.general.restoreSession = false
        document.search.cleanResultLinks = true
        document.resetAppearance()
        #expect(document.web.allowsJavaScript == false)
        #expect(document.general.restoreSession == false)
        #expect(document.search.cleanResultLinks == true)
    }

    @Test("resetting an already-default document changes no value")
    func idempotent() {
        var document = AppSettings()
        let fresh = AppSettings()
        document.resetAppearance()
        #expect(document.appearance.noise == fresh.appearance.noise)
        #expect(document.appearance.tabCornerRadius == fresh.appearance.tabCornerRadius)
        #expect(document.appearance.tabShape == fresh.appearance.tabShape)
        #expect(document.addressBar == AddressBarSettings())
        #expect(document.web == fresh.web)
        #expect(document.general == fresh.general)
    }
}

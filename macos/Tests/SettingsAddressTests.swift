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

/// The `w://settings` address-bar command: recognized or not.
struct SettingsAddressTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("the settings address is recognized")
    func settings() {
        #expect(BrowserWindowController.isSettingsAddress(url("w://settings")))
    }

    @Test("a trailing slash still counts")
    func trailingSlash() {
        #expect(BrowserWindowController.isSettingsAddress(url("w://settings/")))
    }

    @Test("the retired scheme alias counts too")
    func retiredScheme() {
        #expect(BrowserWindowController.isSettingsAddress(url("whtvr://settings")))
    }

    @Test("other w addresses are plain navigations")
    func otherWAddresses() {
        #expect(!BrowserWindowController.isSettingsAddress(url("w://about")))
        #expect(!BrowserWindowController.isSettingsAddress(url("w://homepage/whatever_logo.svg")))
    }

    @Test("web addresses are not settings")
    func web() {
        #expect(!BrowserWindowController.isSettingsAddress(url("https://example.com/settings")))
        #expect(!BrowserWindowController.isSettingsAddress(url("https://settings.example.com")))
    }
}

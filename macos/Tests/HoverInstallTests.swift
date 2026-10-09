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

/// Probes whether factory-built pages actually run the hover reporter.
/// The bubble never appears when the install marker is missing, whatever
/// the opacity slider says.
struct HoverInstallTests {
    @Test("factory pages run the hover reporter")
    @MainActor
    func installs() async throws {
        let view = WebViewFactory.makeWebView(mode: .regular, dataStore: .default())
        view.loadHTMLString("<a href='https://example.com/'>x</a>", baseURL: nil)
        var installed = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let hit = try await view.evaluateJavaScript("window.__whateverLinkHover === true")
            if (hit as? Bool) == true {
                installed = true
                break
            }
        }
        #expect(installed)

        // The install marker only proves the script ran. Dispatch a real
        // mouseover and require the message to reach the view: a reporting
        // break anywhere in script, relay, or handler shows up here.
        var seen: URL?
        view.onLinkHover = { seen = $0 }
        try await view.evaluateJavaScript(
            "document.querySelector('a').dispatchEvent(new MouseEvent('mouseover', {bubbles: true}))"
        )
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if seen != nil { break }
        }
        #expect(seen?.absoluteString == "https://example.com/")
    }
}

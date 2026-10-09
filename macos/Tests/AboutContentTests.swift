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
import Testing
@testable import Whatever

/// About panel credits: tagline, copyright line, and both links.
struct AboutContentTests {
    @Test("credits carry the tagline, copyright, and makers lines")
    func text() {
        let text = AboutContent.credits().string
        #expect(text.contains("Browsing the dead internet"))
        #expect(text.contains("(c) 2026 George Lemon | GPLv3 License"))
        #expect(text.contains("Made by Humans from OpenPeeps for OneBuck.app"))
    }

    @Test("credits link both names")
    func links() {
        let credits = AboutContent.credits()
        let text = credits.string as NSString
        for (name, url) in [
            ("OpenPeeps", AboutContent.openPeepsURL),
            ("OneBuck.app", AboutContent.oneBuckURL),
        ] {
            let range = text.range(of: name)
            #expect(range.location != NSNotFound)
            var found: URL?
            credits.enumerateAttribute(.link, in: range) { value, _, _ in
                found = value as? URL ?? (value as? String).flatMap(URL.init(string:))
            }
            #expect(found == url)
        }
    }
}

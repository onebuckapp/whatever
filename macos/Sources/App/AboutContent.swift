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

/// Content for the standard About panel (`About Whatever`).
///
/// The panel itself stays Apple's: name and version come from the bundle,
/// and this supplies the credits — the tagline plus the copyright line with
/// clickable links. Kept separate from `AppDelegate` so the text and its
/// links are unit-testable without opening the panel.
enum AboutContent {
    static let tagline = "Browsing the dead internet"

    static let openPeepsURL = URL(string: "https://github.com/openpeeps")!
    static let oneBuckURL = URL(string: "https://onebuck.app")!

    /// Tagline, copyright line, then the makers line with links on the two
    /// names. Small system font and label color, so it reads as panel
    /// furniture rather than app text.
    static func credits() -> NSAttributedString {
        let full = "\(tagline)\n\n(c) 2026 George Lemon | GPLv3 License\nMade by Humans from OpenPeeps for OneBuck.app"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSMutableAttributedString(
            string: full,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        for (name, url) in [("OpenPeeps", openPeepsURL), ("OneBuck.app", oneBuckURL)] {
            let range = (full as NSString).range(of: name)
            guard range.location != NSNotFound else { continue }
            string.addAttribute(.link, value: url, range: range)
        }
        return string
    }
}

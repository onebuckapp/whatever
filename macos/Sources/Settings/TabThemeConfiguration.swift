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

/// Per-state tab chrome: what fills the cell behind its content, and what
/// colour its text and glyphs take.
///
/// The background reuses `BackgroundMediaConfiguration`, so tabs accept the
/// same solid colours, images, and videos as the window background — stored
/// the same way, with no migration step. The settings UI offers none, solid,
/// image, and video; the cell renderer additionally honours a hand-set
/// gradient rather than dropping it.
///
/// `foreground` is nil for the system look (label/secondary, exactly as
/// before this existed) and a stored colour otherwise.
struct TabThemeConfiguration: Codable, Equatable {
    var background = BackgroundMediaConfiguration()
    var foreground: BackgroundColor?
}

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

/// The Software Update icon renders 32pt from a pre-rasterized image with
/// explicit 1x/2x/3x bitmap representations. Regenerating the `.icns`
/// without enough pixels would silently bring the blur back, so pin the
/// 2x representation here.
@MainActor
struct AppIconViewTests {
    @Test("icon carries 2x pixels for its 32pt frame")
    func retinaPixels() {
        let image = AppIconView.iconImage
        #expect(image.size == NSSize(width: 32, height: 32))
        #expect(image.representations.contains { $0.pixelsWide >= 64 && $0.pixelsHigh >= 64 })
    }
}

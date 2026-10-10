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

/// Tab image placement: fit sizing plus top/center/bottom anchoring, in the
/// background view's y-up coordinates. Pure geometry, no views needed.
@MainActor
struct TabImagePlacementTests {
    // A 170x32 cell with a 1600x900 picture, like a wide wallpaper behind
    // a tab.
    private let cell = CGRect(x: 0, y: 0, width: 170, height: 32)
    private let photo = CGSize(width: 1600, height: 900)

    private func frame(
        fit: BackgroundMediaConfiguration.Fit,
        scale: Double = 100,
        position: BackgroundMediaConfiguration.Position = .center
    ) -> CGRect {
        TabThemeMedia.imageFrame(
            imageSize: photo,
            in: cell,
            fit: fit,
            scalePercent: scale,
            position: position
        )
    }

    private func expectClose(_ actual: CGRect, _ expected: CGRect, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(abs(actual.minX - expected.minX) < 0.01, sourceLocation: sourceLocation)
        #expect(abs(actual.minY - expected.minY) < 0.01, sourceLocation: sourceLocation)
        #expect(abs(actual.width - expected.width) < 0.01, sourceLocation: sourceLocation)
        #expect(abs(actual.height - expected.height) < 0.01, sourceLocation: sourceLocation)
    }

    @Test("fill covers the cell and anchors the crop")
    func fillAnchors() {
        // Scale 0.10625: 170 wide, 95.625 tall, overflowing vertically.
        expectClose(
            frame(fit: .fill, position: .topCenter),
            CGRect(x: 0, y: 32 - 95.625, width: 170, height: 95.625)
        )
        expectClose(
            frame(fit: .fill, position: .center),
            CGRect(x: 0, y: (32 - 95.625) / 2, width: 170, height: 95.625)
        )
        expectClose(
            frame(fit: .fill, position: .bottomCenter),
            CGRect(x: 0, y: 0, width: 170, height: 95.625)
        )
    }

    @Test("fit letterboxes the whole picture")
    func fitLetterboxes() {
        // Scale 0.0355…: 56.89 wide, exactly 32 tall, pillarboxed.
        let fitted = frame(fit: .contain, position: .center)
        #expect(abs(fitted.height - 32) < 0.01)
        #expect(abs(fitted.width - 56.89) < 0.01)
        #expect(abs(fitted.minX - (170 - fitted.width) / 2) < 0.01)
        #expect(abs(fitted.minY) < 0.01)
    }

    @Test("custom scale sizes from the original and still anchors")
    func customScaleAnchors() {
        expectClose(
            frame(fit: .custom, scale: 50, position: .topCenter),
            CGRect(x: (170 - 800) / 2, y: 32 - 450, width: 800, height: 450)
        )
        expectClose(
            frame(fit: .custom, scale: 50, position: .bottomCenter),
            CGRect(x: (170 - 800) / 2, y: 0, width: 800, height: 450)
        )
    }

    @Test("original draws pixel-sized and centered")
    func originalCenters() {
        let drawn = frame(fit: .original, position: .center)
        expectClose(drawn, CGRect(x: (170 - 1600) / 2, y: (32 - 900) / 2, width: 1600, height: 900))
    }

    @Test("stretch fills the cell exactly")
    func stretchFills() {
        expectClose(frame(fit: .stretch), cell)
    }

    @Test("degenerate sizes fall back to the cell")
    func degenerateFallsBack() {
        #expect(TabThemeMedia.imageFrame(
            imageSize: .zero, in: cell, fit: .fill, scalePercent: 100, position: .center
        ) == cell)
        #expect(TabThemeMedia.imageFrame(
            imageSize: photo, in: .zero, fit: .fill, scalePercent: 100, position: .center
        ) == .zero)
    }

    @Test("anchor choices round-trip through the shared position")
    func anchorMapping() {
        #expect(TabImageVerticalAnchor.top.position == .topCenter)
        #expect(TabImageVerticalAnchor.center.position == .center)
        #expect(TabImageVerticalAnchor.bottom.position == .bottomCenter)
        #expect(TabImageVerticalAnchor.from(.topLeft) == .top)
        #expect(TabImageVerticalAnchor.from(.center) == .center)
        #expect(TabImageVerticalAnchor.from(.bottomRight) == .bottom)
        #expect(TabImageVerticalAnchor.from(.custom) == .center)
    }

    @Test("image fit and position round-trip in the theme document")
    func imageSettingsRoundTrip() throws {
        var theme = TabThemeConfiguration()
        theme.background.kind = .image
        theme.background.fit = .custom
        theme.background.fitScale = 150
        theme.background.position = .bottomCenter
        let decoded = try JSONDecoder().decode(
            TabThemeConfiguration.self,
            from: JSONEncoder().encode(theme)
        )
        #expect(decoded == theme)
        #expect(decoded.background.fit == .custom)
        #expect(decoded.background.fitScale == 150)
        #expect(decoded.background.position == .bottomCenter)
    }
}

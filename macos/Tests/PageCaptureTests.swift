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
import Foundation
import Testing
@testable import Whatever

/// Full-screen capture: the save name and the PNG encoding. The render
/// itself needs a live page, so it stays out of unit tests.
struct PageCaptureTests {
    private func date(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 10, day: 10,
            hour: hour, minute: minute, second: second
        ))!
    }

    @Test("the save name follows the macOS screenshot format")
    func screenshotName() {
        #expect(PageCapture.suggestedFilename(now: date(16, 1, 23)) == "Screenshot 2026-10-10 at 4.01.23 PM.png")
        #expect(PageCapture.suggestedFilename(now: date(9, 5, 7)) == "Screenshot 2026-10-10 at 9.05.07 AM.png")
        #expect(PageCapture.suggestedFilename(now: date(0, 0, 0)) == "Screenshot 2026-10-10 at 12.00.00 AM.png")
    }

    @Test("a capture encodes as PNG data")
    func pngEncoding() throws {
        let context = CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 4, height: 4))
        let data = try #require(PageCapture.pngData(for: image))
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A.
        #expect(data.prefix(8).map { $0 } == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

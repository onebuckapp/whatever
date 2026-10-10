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
import PDFKit
import Testing
@testable import Whatever

/// Print sidebar settings: paper, orientation, copies, and the save-panel
/// filename. Pure values, no window or web view needed.
@MainActor
struct PrintSettingsTests {
    @Test("defaults print a single portrait A4 fit to the page")
    func defaults() {
        let settings = PrintSettings()
        let info = NSPrintInfo()
        settings.apply(to: info)
        // `NSPrintInfo` normalizes the size to whole points on the way in.
        #expect(abs(info.paperSize.width - 595) < 1)
        #expect(abs(info.paperSize.height - 842) < 1)
        #expect(info.orientation == .portrait)
        #expect(settings.scale.pdfScalingMode == .pageScaleToFit)
        #expect(settings.clampedCopies == 1)
    }

    @Test("letter landscape applies paper and rotation")
    func letterLandscape() {
        var settings = PrintSettings()
        settings.paperSize = .letter
        settings.orientation = .landscape
        let info = NSPrintInfo()
        settings.apply(to: info)
        // Normalized and rotated: width and height swap for landscape.
        #expect(abs(info.paperSize.width - 792) < 1)
        #expect(abs(info.paperSize.height - 612) < 1)
        #expect(info.orientation == .landscape)
    }

    @Test("actual size prints without scaling")
    func actualSize() {
        var settings = PrintSettings()
        settings.scale = .actual
        #expect(settings.scale.pdfScalingMode == .pageScaleNone)
    }

    @Test("copies clamp to the stepper range")
    func copiesClamp() {
        var settings = PrintSettings()
        settings.copies = 0
        #expect(settings.clampedCopies == 1)
        settings.copies = 250
        #expect(settings.clampedCopies == 99)
        settings.copies = 3
        #expect(settings.clampedCopies == 3)
    }

    @Test("copies reach the print system through the settings dictionary")
    func copiesApply() {
        var settings = PrintSettings()
        settings.copies = 3
        let info = NSPrintInfo()
        settings.apply(to: info)
        let copies = info.printSettings[NSPrintInfo.AttributeKey(rawValue: "NSPrintCopies")] as? NSNumber
        #expect(copies?.intValue == 3)
    }

    @Test("the print stylesheet is on by default and round-trips")
    func printStylesheetDefault() {
        #expect(PrintSettings().printStylesheet)
        var settings = PrintSettings()
        settings.printStylesheet = false
        #expect(settings != PrintSettings())
        #expect(!settings.printStylesheet)
    }

    @Test("filenames sanitize titles and fall back when empty")
    func filenames() {
        #expect(PrintSettings.sanitizedFilename(title: "Example Page") == "Example Page.pdf")
        #expect(PrintSettings.sanitizedFilename(title: "a/b") == "a:b.pdf")
        #expect(PrintSettings.sanitizedFilename(title: "  ") == "Untitled.pdf")
        #expect(PrintSettings.sanitizedFilename(title: nil) == "Untitled.pdf")
    }
}

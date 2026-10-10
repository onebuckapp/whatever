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
import PDFKit

/// The print preview sidebar, as data. Pure value: the card edits it, the
/// print button applies it to an `NSPrintInfo`, and the backgrounds flag
/// regenerates the PDF. Testable without a window, web view, or panel.
struct PrintSettings: Equatable {
    enum PaperSize: String, CaseIterable, Identifiable {
        case a4
        case letter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .a4: return "A4"
            case .letter: return "Letter"
            }
        }

        /// Points, portrait. The orientation applies the rotation.
        var size: NSSize {
            switch self {
            case .a4: return NSSize(width: 595.28, height: 841.89)
            case .letter: return NSSize(width: 612, height: 792)
            }
        }
    }

    enum Orientation: String, CaseIterable, Identifiable {
        case portrait
        case landscape

        var id: String { rawValue }

        var title: String {
            switch self {
            case .portrait: return "Portrait"
            case .landscape: return "Landscape"
            }
        }

        var printOrientation: NSPrintInfo.PaperOrientation {
            switch self {
            case .portrait: return .portrait
            case .landscape: return .landscape
            }
        }
    }

    enum Scale: String, CaseIterable, Identifiable {
        case fit
        case actual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fit: return "Fit to page"
            case .actual: return "Actual size"
            }
        }

        var pdfScalingMode: PDFPrintScalingMode {
            switch self {
            case .fit: return .pageScaleToFit
            case .actual: return .pageScaleNone
            }
        }
    }

    var copies: Int = 1
    var paperSize: PaperSize = .a4
    var orientation: Orientation = .portrait
    var scale: Scale = .fit
    var backgrounds: Bool = true
    /// Renders with the page's print stylesheet (`@media print`) instead of
    /// the screen styles, like a real printout. Implemented by flipping the
    /// web view's media type for the duration of the render.
    var printStylesheet: Bool = true

    /// Copies clamped to the stepper's range, so a stray value cannot reach
    /// the print system.
    var clampedCopies: Int {
        min(max(copies, 1), 99)
    }

    /// Copies apply through the print settings dictionary: `NSPrintInfo`
    /// has no copies property of its own. `NSPrintCopies` is the
    /// `PMPrintSettings` key the print system reads.
    func apply(to printInfo: NSPrintInfo) {
        printInfo.paperSize = paperSize.size
        printInfo.orientation = orientation.printOrientation
        printInfo.printSettings[NSPrintInfo.AttributeKey(rawValue: "NSPrintCopies")] =
            NSNumber(value: clampedCopies)
    }

    /// A save-panel filename for a page title: the same sanitizing as
    /// downloads use (slashes cannot appear in a filename), without forcing
    /// the downloads folder — the panel owns the location. Static and pure
    /// so the rule is testable without a panel.
    static func sanitizedFilename(title: String?) -> String {
        let cleaned = (title ?? "")
            .replacingOccurrences(of: "/", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled.pdf" : "\(cleaned).pdf"
    }
}

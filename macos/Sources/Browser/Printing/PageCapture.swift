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
import UniformTypeIdentifiers
import WebKit

/// Full-screen capture: renders the whole page to PNG through the print
/// pipeline (`createPDF`), so the capture matches what "Save as PDF" would
/// produce — screen media, backgrounds on — then stitches the pages into
/// one tall image and asks where to save it.
///
/// The render never touches the live page's layout (no resize tricks), so
/// nothing flickers; a fixed-position header simply repeats on every page,
/// exactly as on paper.
///
/// Must run on the main thread: menu actions always do. The render
/// completion hops back explicitly, since WebKit does not promise which
/// thread it answers on.
enum PageCapture {
    /// macOS screenshot name: `Screenshot 2026-10-10 at 4.01.23 PM.png`.
    /// The locale is fixed, not translated: Finder sorts these names
    /// chronologically, and a localized month or day-period would break
    /// that. Static and pure so the format is testable without a panel.
    static func suggestedFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'Screenshot' yyyy-MM-dd 'at' h.mm.ss a"
        return formatter.string(from: now) + ".png"
    }

    /// Stacks every PDF page vertically at `scale`, falling back to 1x when
    /// a very long page would blow past the pixel budget. Nil when the
    /// document has no renderable pages.
    static func stitchedImage(pdf: PDFDocument, scale: CGFloat) -> NSImage? {
        let clamped = min(max(scale, 1), 2)
        return stitch(pdf: pdf, scale: clamped, pixelBudget: 150_000_000)
            ?? stitch(pdf: pdf, scale: 1, pixelBudget: .greatestFiniteMagnitude)
    }

    /// Encodes an image as PNG data. Nil when the image has no raster form.
    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// Renders the page, then panels for a destination. Beeps when there is
    /// no page to capture or the render fails; the panel's cancel is silent.
    static func captureAndSave(webView: WKWebView?, window: NSWindow?) {
        guard let webView else {
            SystemBeep.play()
            return
        }
        let scale = webView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        var configuration = WKPDFConfiguration()
        configuration.allowTransparentBackground = false
        webView.createPDF(configuration: configuration) { result in
            Task { @MainActor in
                guard case .success(let data) = result,
                      let pdf = PDFDocument(data: data),
                      let image = Self.stitchedImage(pdf: pdf, scale: scale),
                      let png = Self.pngData(for: image)
                else {
                    SystemBeep.play()
                    return
                }
                Self.presentSavePanel(png: png, window: window)
            }
        }
    }

    /// Asks where to save, defaulting to the screenshot name. Sheet on the
    /// given window, falling back to app-modal — the same shape as the
    /// print preview's PDF save.
    private static func presentSavePanel(png: Data, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let window else {
            if panel.runModal() == .OK, let url = panel.url {
                try? png.write(to: url)
            }
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    /// One stitching pass at an exact scale. Nil when a page is missing,
    /// nothing renders, or the canvas would exceed `pixelBudget`.
    private static func stitch(pdf: PDFDocument, scale: CGFloat, pixelBudget: CGFloat) -> NSImage? {
        guard pdf.pageCount > 0 else { return nil }
        var rendered: [(image: NSImage, size: NSSize)] = []
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for index in 0 ..< pdf.pageCount {
            guard let page = pdf.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let target = NSSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
            let image = page.thumbnail(of: target, for: .mediaBox)
            guard image.size.width > 0, image.size.height > 0 else { continue }
            rendered.append((image, image.size))
            totalHeight += image.size.height
            maxWidth = max(maxWidth, image.size.width)
        }
        guard !rendered.isEmpty, totalHeight > 0, maxWidth > 0,
              maxWidth * totalHeight <= pixelBudget
        else {
            return nil
        }
        let canvas = NSImage(size: NSSize(width: maxWidth, height: totalHeight))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        var y = totalHeight
        for page in rendered {
            y -= page.size.height
            page.image.draw(
                at: NSPoint(x: 0, y: y),
                from: NSRect(origin: .zero, size: page.size),
                operation: .copy,
                fraction: 1.0
            )
        }
        canvas.unlockFocus()
        return canvas
    }
}

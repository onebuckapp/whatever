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
import SwiftUI

/// Who and what Whatever is built from, for the Credits window.
///
/// Names and roles are data so the list is testable without opening the
/// window; links only where the URL is certain (the About panel's two plus
/// the popup package from `project.yml`), plain names everywhere else.
enum CreditsContent {
    struct Entry: Hashable {
        let name: String
        let detail: String
        let url: URL?
    }

    struct Section: Hashable {
        let title: String
        let entries: [Entry]
    }

    static let madeBy = Section(
        title: "Made by",
        entries: [
            Entry(
                name: "George Lemon",
                detail: "Design and development · © 2026 · GPLv3",
                url: nil
            ),
        ]
    )

    static let builtWith = Section(
        title: "Built with",
        entries: [
            Entry(
                name: "OpenPeeps",
                detail: "Tooling and infrastructure",
                url: URL(string: "https://github.com/openpeeps")
            ),
            Entry(
                name: "OneBuck.app",
                detail: "Home of Whatever",
                url: URL(string: "https://onebuck.app")
            ),
        ]
    )

    static let interface = Section(
        title: "Interface",
        entries: [
            Entry(
                name: "Tabler Icons",
                detail: "Toolbar and chrome glyphs",
                url: URL(string: "https://tabler.io")
            ),
            Entry(
                name: "Mijick Popups",
                detail: "In-window card presentations",
                url: URL(string: "https://github.com/Mijick/Popups")
            ),
        ]
    )

    static let core = Section(
        title: "Storage core",
        entries: [
            Entry(name: "openparser", detail: "Fuzzy matching (Nim)", url: nil),
            Entry(name: "boogie", detail: "Embedded store (Nim)", url: nil),
            Entry(name: "nimcypher", detail: "Cryptography (Nim)", url: nil),
            Entry(name: "blackpaper", detail: "Utilities (Nim)", url: nil),
        ]
    )

    static let sections = [madeBy, builtWith, interface, core]

    /// Short version string for the header, from the bundle.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

/// Fixed backdrop for the Credits window.
///
/// Renders the bundled `CreditsBackground` image cover-bleed when it
/// exists, a neutral window fill until then — so adding the art later is
/// dropping a `CreditsBackground` imageset into `Assets.xcassets` with no
/// code change. Sibling of the content, never its parent, so scrolling
/// cannot move it.
final class CreditsBackgroundView: NSView {
    static let imageName = "CreditsBackground"

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = NSImage(named: Self.imageName) else {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        let drawing = Self.imageDrawRect(for: image.size, in: bounds)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: drawing,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
    }

    /// Cover-bleed rect for `size` in `bounds`: scaled to fill, centered,
    /// overflowing where aspects differ. Static so the geometry is testable
    /// without a window.
    static func imageDrawRect(for size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(
            x: bounds.minX + (bounds.width - width) / 2,
            y: bounds.minY + (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }
}

/// The Credits window's scrollable content: app header, then one group per
/// section. Plain scrolling list over the background sibling.
struct CreditsContentView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                ForEach(CreditsContent.sections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(section.entries, id: \.self) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView(points: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Whatever \(CreditsContent.appVersion)")
                    .font(.system(size: 17, weight: .semibold))
                Text(AboutContent.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func entryRow(_ entry: CreditsContent.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let url = entry.url {
                Link(entry.name, destination: url)
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(entry.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

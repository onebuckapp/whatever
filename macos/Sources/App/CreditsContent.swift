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
        /// License tag shown after the name, when the artifact has one.
        /// People and organizations carry none.
        let license: String?
        let detail: String
        let url: URL?

        /// Title line: just text, never a link — `Name | License`, or the
        /// bare name when there is no license to show.
        var titleLine: String {
            license.map { "\(name) | \($0)" } ?? name
        }
    }

    struct Section: Hashable {
        let title: String
        let entries: [Entry]
    }

    /// Section data as computed properties (not stored lets) so a language
    /// switch re-resolves every title and detail: names, licenses, and URLs
    /// stay literal, prose goes through `tr()`.
    static var madeBy: Section {
        Section(
            title: tr("Made by", ctx: "Credits"),
            entries: [
                Entry(
                    name: "George Lemon",
                    license: "GPLv3",
                    detail: tr("Design and development · © 2026", ctx: "Credits"),
                    url: nil
                ),
            ]
        )
    }

    static var writtenIn: Section {
        Section(
            title: tr("Written in", ctx: "Credits"),
            entries: [
                Entry(
                    name: "Swift",
                    license: nil,
                    detail: tr("App and interface language", ctx: "Credits"),
                    url: URL(string: "https://swift.org")
                ),
                Entry(
                    name: "Nim",
                    license: nil,
                    detail: tr("A statically typed compiled systems programming language", ctx: "Credits"),
                    url: URL(string: "https://nim-lang.org")
                ),
            ]
        )
    }

    static var builtWith: Section {
        Section(
            title: tr("Built with", ctx: "Credits"),
            entries: [
                Entry(
                    name: "OpenPeeps",
                    license: nil,
                    detail: tr("Tooling and infrastructure", ctx: "Credits"),
                    url: URL(string: "https://github.com/openpeeps")
                ),
                Entry(
                    name: "OneBuck.app",
                    license: nil,
                    detail: tr("Home of Whatever", ctx: "Credits"),
                    url: URL(string: "https://onebuck.app")
                ),
            ]
        )
    }

    static var interface: Section {
        Section(
            title: tr("Interface", ctx: "Credits"),
            entries: [
                Entry(
                    name: "Tabler Icons",
                    license: "MIT-licensed",
                    detail: tr("Built and maintained by Paweł Kuna", ctx: "Credits"),
                    url: URL(string: "https://tabler.io")
                ),
                Entry(
                    name: "Mijick Popups",
                    license: "Apache-2.0 license",
                    detail: tr("Author Tomasz Kurylik", ctx: "Credits"),
                    url: URL(string: "https://github.com/Mijick/Popups")
                ),
            ]
        )
    }

    static var core: Section {
        Section(
            title: tr("Storage core", ctx: "Credits"),
            entries: [
                Entry(name: "openparser", license: "MIT-licensed", detail: tr("Collection of tiny parsers and dumpers", ctx: "Credits"), url: URL(string: "https://github.com/openpeeps/openparser")),
                Entry(name: "boogie", license: "MIT-licensed", detail: tr("A suite of WAL-based embedded data stores", ctx: "Credits"), url: URL(string: "https://github.com/openpeeps/boogie")),
                Entry(name: "nimcypher", license: "BSD-2-Clause", detail: tr("Pure-Nim cryptographic library", ctx: "Credits"), url: URL(string: "https://github.com/nimbase/nimcypher")),
                Entry(name: "blackpaper", license: "MIT-licensed", detail: tr("Password strength estimator (Nim)", ctx: "Credits"), url: URL(string: "https://github.com/openpeeps/blackpaper")),
            ]
        )
    }

    static var sections: [Section] {
        [madeBy, writtenIn, builtWith, interface, core]
    }

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
    // Observed for `revision`: the static data above re-resolves on every
    // access, so a language switch re-renders the list in place.
    @ObservedObject private var localization = Localization.shared

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
            Text(entry.titleLine)
                .font(.system(size: 12, weight: .medium))
            Text(entry.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // The raw address, directly: link text is the URL itself, the
            // title line above stays plain text.
            if let url = entry.url {
                Link(url.absoluteString, destination: url)
                    .font(.system(size: 11))
            }
        }
    }
}

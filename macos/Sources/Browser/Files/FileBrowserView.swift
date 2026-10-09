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
import UniformTypeIdentifiers

/// The file browser card: breadcrumbs, one directory listing, nothing else.
///
/// Read-only: rows open deeper or leave to the tab; there is no rename,
/// delete, or new-folder affordance. A row opens on double-click or Enter
/// when selected; single click only selects. Visual language follows the
/// feed reader cards — 13pt names, 11pt secondary details, 8pt control
/// radii — rather than inventing a file-manager theme.
struct FileBrowserView: View {
    @ObservedObject var store: FileBrowserStore
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks to measured bounds; the shadow needs room, kept
        // symmetric so the card stays centered. Same 88 as every other card.
        .padding(.vertical, 88)
        .onTapGesture {}
        .task {
            store.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                store.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!store.canGoUp)
            .help("Go to parent folder")
            .accessibilityLabel("Parent folder")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.breadcrumbs.indices, id: \.self) { index in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        let isCurrent = index == store.breadcrumbs.count - 1
                        Button(store.breadcrumbs[index]) {
                            store.navigate(to: store.path(forBreadcrumb: index))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .disabled(isCurrent)
                        .help(store.path(forBreadcrumb: index))
                    }
                }
            }

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("Hidden", isOn: $store.showHidden)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Show hidden files")

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    store.refresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        } else if store.entries.isEmpty, !store.isLoading {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List(store.entries, id: \.path, selection: $selection) { entry in
                FileRow(entry: entry)
                    .tag(entry.path)
                    // The whole row is the hit area. Opening takes a
                    // double-click (or Enter): a single click only selects,
                    // so exploring never navigates away by accident.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Guarded: a first double-click may already have
                        // navigated away, leaving this row stale.
                        if store.entries.contains(where: { $0.path == entry.path }) {
                            store.open(entry)
                        }
                    }
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: entry.path)]
                            )
                        }
                        Button("Copy Path") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(entry.path, forType: .string)
                        }
                    }
            }
            .listStyle(.plain)
            .onKeyPress(.return) {
                if let path = selection,
                   let entry = store.entries.first(where: { $0.path == path })
                {
                    store.open(entry)
                    return .handled
                }
                return .ignored
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Text(itemCount)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if store.hasMore {
                Text("showing first \(store.entries.count) of \(store.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var itemCount: String {
        var text = store.total == 1 ? "1 item" : "\(store.total) items"
        if store.skipped > 0 {
            text += store.skipped == 1 ? ", 1 unavailable" : ", \(store.skipped) unavailable"
        }
        return text
    }
}

/// One listing row: icon, name, and a details line.
///
/// Directories carry a chevron so they read as navigable without
/// double-clicking to find out; files show size and modification date.
private struct FileRow: View {
    let entry: FileSystemEnumerator.RawEntry
    @State private var isHovering = false
    @State private var cursorPushed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FileIcon.symbol(for: entry))
                .font(.system(size: 15))
                .foregroundStyle(entry.isDir ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if entry.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityLabel(entry.name)
        // Subtle fill plus a pointing hand, so rows read as clickable
        // without competing with the selection highlight. The cursor is
        // reference-counted here because a row can disappear mid-hover when
        // a double-click navigates away, which would otherwise strand it.
        .listRowBackground(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
            if hovering, !cursorPushed {
                NSCursor.pointingHand.push()
                cursorPushed = true
            } else if !hovering, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    private var details: String {
        if entry.isDir {
            return "Folder"
        }
        return "\(FileSize.string(from: entry.size)) · \(FileDate.string(from: entry.mtime))"
    }
}

/// SF Symbol for a listing entry, by kind then by extension.
///
/// Extension-first would mislabel extensionless READMEs and overrule the
/// directory check; kind comes first, then a small table of common types,
/// then the system type as a fallback, then the generic document glyph.
private enum FileIcon {
    static func symbol(for entry: FileSystemEnumerator.RawEntry) -> String {
        if entry.isDir {
            return "folder"
        }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "svg", "heic", "ico":
            return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "film"
        case "mp3", "wav", "flac", "m4a", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "markdown", "rst":
            return "doc.text"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg":
            return "archivebox"
        case "html", "htm", "css", "js", "ts", "json", "xml", "yml", "yaml", "toml":
            return "chevron.left.forwardslash.chevron.right"
        case "swift", "c", "h", "cpp", "hpp", "m", "mm", "py", "rb", "go", "rs", "java", "kt", "sh", "nim", "nims":
            return "curlybraces"
        default:
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
                return "doc"
            }
            if type.conforms(to: .image) {
                return "photo"
            }
            if type.conforms(to: .audiovisualContent) {
                return "film"
            }
            if type.conforms(to: .audio) {
                return "music.note"
            }
            if type.conforms(to: .text) {
                return "doc.text"
            }
            return "doc"
        }
    }
}

/// Cached formatters, so every row is not building its own.
private enum FileSize {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(from bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

private enum FileDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

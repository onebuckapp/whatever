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

import SwiftUI

/// The panes of the settings modal.
///
/// Order is sidebar order. The identifiers are stored nowhere, so reordering or
/// renaming a case only moves a row in the list.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case web
    case contentBlocker
    case bookmarks
    case rssFeeds
    case history
    case search
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .web: "Web"
        case .contentBlocker: "Content Blocker"
        case .bookmarks: "Bookmarks"
        case .rssFeeds: "RSS & Feeds"
        case .history: "History"
        case .search: "Search"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .web: "globe"
        case .contentBlocker: "shield"
        case .bookmarks: "bookmark"
        case .rssFeeds: "rss"
        case .history: "clock"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// Heading for a group of related rows inside a detail pane.
struct SettingsGroupLabel: View {
    let title: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled on/off row.
///
/// Laid out as one row rather than a `Form`, because the detail pane scrolls
/// inside a fixed-width card and `Form` brings its own inset and grouping chrome
/// that fights the card's edges.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

/// A labelled slider with its value shown alongside.
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.05
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(format(value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

/// A labelled segmented picker.
struct SettingsPickerRow<Label: Hashable & Identifiable>: View {
    let title: String
    let options: [Label]
    @Binding var selection: Label
    /// Segmented reads better than a menu for a short, fixed set of options.
    var isSegmented = false
    let label: (Label) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
            Spacer(minLength: 12)
            Group {
                if isSegmented {
                    picker.pickerStyle(.segmented)
                } else {
                    picker
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                Text(label(option)).tag(option)
            }
        }
        .labelsHidden()
    }
}

/// One row of a single-choice list.
///
/// Built by hand rather than from `Picker` with a `.radio` style, which SwiftUI
/// does not have: the stock styles are menu and segmented, and a segmented control
/// for a list this long would not fit a 720pt card. The whole row is the target, so
/// the click area is the row rather than the glyph.
struct SettingsRadioRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .padding(.vertical, 3)
    }
}

extension SettingsRadioRow where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            onSelect: onSelect,
            accessory: { EmptyView() }
        )
    }
}

/// A Bootstrap-style surface for one section of a detail pane.
///
/// Bootstrap's card, in the plain sense: its own background, a hairline border,
/// rounded corners and internal padding, so a group of rows reads as one object
/// instead of loose controls floating on the pane.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

/// A row that ends in a control it does not own, such as a button.
///
/// Matches the label column of `SettingsToggleRow` and `SettingsSliderRow` so a
/// pane can mix them without the text jumping between row types.
struct SettingsButtonRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 3)
    }
}

/// A labelled short-text field, for marks and names that fit a few glyphs.
///
/// Clamps live to `maxCharacters` grapheme clusters, so an emoji or composed
/// character counts as one and pasting a sentence cannot overflow the bound.
/// Empty input stays empty while typing; readers normalize it back to their
/// default, so clearing the field previews as the default mark.
struct SettingsTextRow: View {
    let title: String
    var subtitle: String?
    @Binding var text: String
    var maxCharacters: Int = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12))
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: text) { _, new in
                    if new.count > maxCharacters {
                        text = String(new.prefix(maxCharacters))
                    }
                }
        }
        .padding(.vertical, 3)
    }
}

/// Filler for a section that has nothing to show yet.
///
/// Says what is missing rather than rendering an empty pane, so an unimplemented
/// section never looks like a bug.
///
/// This centers itself in whatever space it is given, which means a pane that
/// puts a header above it lands the placeholder lower than a pane that does not.
/// Panes that use this are expected to show it on its own, as the whole body,
/// rather than below their own chrome.
struct SettingsPlaceholder: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Padding before the flexible frame, not after: a trailing padding is
        // applied outside the frame, so the view finished 24pt taller than the
        // space it was given and made its pane scrollable.
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Word-based section matching for settings filter fields.
///
/// Every query word must appear somewhere in the haystack; an empty query
/// matches everything, so panes open unfiltered. Case-insensitive, so
/// "grain", "Grain", and "GRAIN" all find the Grain section.
enum SettingsFilter {
    static func matches(query: String, haystack: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let target = haystack.lowercased()
        return words.allSatisfy { target.range(of: $0) != nil }
    }
}

/// Vertical rhythm shared by every detail pane.
///
/// Owns its own scroll view. The card hands this a bounded height so that a pane
/// can center itself in it, which it could not do inside a scroll view of the
/// card's own: the scroll view that can scroll is the one that would have to pass
/// the height down.
///
/// Lazy, so a pane's first paint builds only the visible rows: switching
/// sections used to construct every group up front, including the ones below
/// the fold, which is what made the first visit to a heavy pane feel stuck.
struct SettingsDetailStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }
}

/// One section of a detail pane: a heading and its description above a card of
/// controls.
///
/// The heading sits *outside* the card. Bootstrap folds a card's title into a
/// header strip inside the surface, but the descriptions here are sentences
/// explaining when a change takes effect, which read as page copy above the card
/// rather than as part of it.
///
/// Every pane is built from this, so the heading, description, card surface and row
/// spacing stay identical from one section to the next.
struct SettingsGroup<Content: View>: View {
    var title: String
    var footnote: String?
    /// Dims the controls without removing them, so a pane does not change shape when
    /// the thing being configured is switched off.
    var isEnabled: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroupLabel(title: title, footnote: footnote)
            SettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
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

import Combine
import Foundation

/// Synchronous lookup into the cached active catalog, e.g.
/// `tr("Restore last session", ctx: "Settings.General")`. Fail-open by
/// design — a missing
/// entry reads back its English msgid, so an untranslated build is simply
/// an English one.
///
/// Callable from any thread: the table sits behind a lock, while refreshes
/// (which replace the whole table at once) stay on the main actor.
///
/// The cache fills once at launch (and on every language change) from one
/// `bc_locale_table` call, so rendering never waits on the store service.
/// Anything plural or `{name}`-formatted resolves core-side: `batch(_:)`
/// for one-offs, the dynamic table below for strings needed synchronously.
func tr(_ msgid: String, ctx: String = "") -> String {
    Localization.table.get(Localization.key(msgid: msgid, ctx: ctx)) ?? msgid
}

/// `tr` with `{name}` values filled in: `tr("Hello {name}", args: ["name": user])`.
///
/// Pure substitution, so it stays synchronous: translators freely reorder
/// or drop placeholders, and replacing an opaque value commutes with
/// translation (no locale shapes the replacement itself). Anything where
/// the VALUE shapes the wording — plural form selection by `n` — must go
/// through `batch(_:)` instead, which evaluates core-side.
func tr(_ msgid: String, ctx: String = "", args: [String: String]) -> String {
    var text = tr(msgid, ctx: ctx)
    for (key, value) in args {
        text = text.replacingOccurrences(of: "{\(key)}", with: value)
    }
    return text
}

extension Notification.Name {
    /// Posted on the main thread when the active language changes (not on
    /// every refresh). AppKit-owned UI that SwiftUI does not rebuild — the
    /// File > Close retitle — observes this to re-apply translated titles.
    static let localizationDidChange = Notification.Name("com.onebuckapp.whatever.localizationDidChange")
}

/// Lock-guarded string table. `tr()` reads from any thread — a picker
/// switch, a notification, a view-model — while refreshes replace the
/// table wholesale, so a lock (not an actor hop) keeps lookup synchronous.
final class LocalizationStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return strings[key]
    }

    func set(_ strings: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.strings = strings
    }
}

/// App-side translation cache and language resolution.
///
/// Translation itself lives in the Nim core (`bc_locale_*`): this type only
/// holds the active table, resolves which language is active, and refreshes
/// the cache. `revision` ticks on every refresh so migrated views
/// re-render in the new language; unmigrated screens stay hardcoded
/// English until they gain `tr()` calls, whatever the setting says.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    /// Ticks on every cache refresh. Migrated views observe it (directly or
    /// through `shared` as an `ObservedObject`) so a language switch
    /// re-renders them without a relaunch.
    @Published private(set) var revision = 0
    /// The active language tag (`ro`, or `en` in English mode).
    @Published private(set) var lang = "en"

    /// The shared table every `tr()` reads. Replaced wholesale on refresh.
    static let table = LocalizationStrings()

    /// The cache key for one entry, mirroring the core's table: plain
    /// msgid, or `msgctxt + U+0004 + msgid`. A concatenation, not
    /// translation logic — hence safe to call from anywhere.
    nonisolated static func key(msgid: String, ctx: String) -> String {
        ctx.isEmpty ? msgid : ctx + "\u{04}" + msgid
    }

    func lookup(msgid: String, ctx: String) -> String {
        Self.table.get(Self.key(msgid: msgid, ctx: ctx)) ?? msgid
    }

    /// Test seam: loads a table without touching the store service.
    func load(table: LocaleTable) {
        Self.table.set(table.strings)
        lang = table.lang
        revision += 1
    }

    /// Resolves the language (settings override or system locale), points
    /// the core at the bundled locale directory, activates the catalog, and
    /// caches its table. Fail-open throughout: any failure keeps the
    /// previous table (English on first launch).
    func refresh() async {
        let tag = Self.resolveTag()
        guard let moDir = Self.bundledLocaleDir else { return }
        do {
            try await BrowserCore.localeInit(moDir: moDir.path)
            try await BrowserCore.setLocale(tag)
            let table = try await BrowserCore.localeTable()
            let active = try await BrowserCore.localeTag()
            Self.table.set(table.strings)
            let previous = lang
            lang = active
            revision += 1
            if active != previous {
                NotificationCenter.default.post(name: .localizationDidChange, object: nil)
            }
        } catch {
            // The previous tables stand: a store hiccup must never blank
            // the interface.
        }
    }

    /// The effective BCP-47 tag: the settings override, or the system
    /// locale when it says `"system"`. The core normalizes (`ro-RO` tries
    /// `ro_RO` then `ro`), so no canonicalization here.
    static func resolveTag() -> String {
        let override = SettingsStore.shared.settings.general.language
        if override == "system" || override.isEmpty {
            return Locale.current.identifier
        }
        return override
    }

    /// The bundled `<lang>/LC_MESSAGES/whatever.mo` tree, copied into
    /// Resources by the `macos` Makefile step.
    static var bundledLocaleDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("locale", isDirectory: true)
    }

    /// Tags the core ships catalogs for, sorted, including English. Empty
    /// (not failing) when the service is unreachable: the picker then
    /// offers System alone.
    static func shippedTags() async -> [String] {
        (try? await BrowserCore.localeLanguages()) ?? []
    }

    /// Picker label for a tag: its native language name (`Română` for
    /// `ro`), falling back to the tag itself.
    static func displayName(for tag: String) -> String {
        let code = tag.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? tag
        if let name = Locale(identifier: tag).localizedString(forLanguageCode: code),
           !name.isEmpty
        {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return tag
    }

    /// Translates batch items in order through the core: plurals and
    /// `{name}` formatting resolve there, keeping one implementation on
    /// every platform. Fail-open: a store failure returns each item's
    /// template (singular, or plural when `n` is not 1) with `{name}`
    /// placeholders filled from the item's own args, so counts still read
    /// as digits offline.
    static func batch(_ items: [LocaleItem]) async -> [String] {
        do {
            return try await BrowserCore.localeBatch(items)
        } catch {
            return items.map { item in
                let template: String
                if let n = item.n, n != 1, let plural = item.plural {
                    template = plural
                } else {
                    template = item.msgid
                }
                guard let args = item.args else { return template }
                var text = template
                for (key, value) in args {
                    text = text.replacingOccurrences(of: "{\(key)}", with: value)
                }
                return text
            }
        }
    }
}

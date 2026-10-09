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

import Foundation
import WebKit

/// Owns the compiled content-blocker lists: compiling the core's JSON with
/// WebKit, caching the result across launches, and handing it out.
///
/// Split from the core on purpose. The core parses filter text and emits
/// rule JSON — pure string work it can test. Compiling that JSON with
/// `WKContentRuleListStore` and attaching the result to web views are
/// WebKit calls that only exist in the app process; a compiled list cannot
/// cross the XPC boundary, only its JSON source can.
///
/// Fail-open throughout: any failure here leaves `lists` empty and records
/// `lastError`, so pages load unblocked rather than not at all.
@MainActor
final class ContentBlockerStore: ObservableObject {
    static let shared = ContentBlockerStore()

    /// Rules per compiled list. WebKit's hard limit is 50k; the margin
    /// keeps a chunk safely below it.
    private static let rulesPerList = 40_000

    private static let identifierPrefix = "com.onebuckapp.whatever.blocker"

    private static let snapshotResources = ["adaway-hosts", "whatever-extra"]
    private static let snapshotVersionResource = "snapshot-version"

    /// Compiled lists ready to attach. Empty when disabled or uncompiled.
    @Published private(set) var lists: [WKContentRuleList] = []
    /// Last compile failure, for the settings UI. Nil when healthy.
    @Published private(set) var lastError: String?
    /// Counts and fingerprint of the current filter text, for the settings
    /// UI. Refreshed on every compile check, including lookup hits, so the
    /// stats survive a relaunch without recompiling.
    @Published private(set) var lastMeta: FilterMeta?

    /// Last applied state per tab, so a change reloads only tabs whose
    /// blocking actually moved. Reloading every tab on every exception edit
    /// would throw away form state across the whole window.
    private var appliedSignatures: [UUID: String] = [:]

    private init() {}

    /// Compiles the bundled snapshot plus user rules unless the fingerprint
    /// matches the last compile, in which case the persisted lists are
    /// looked up instead. Called at launch before the first tab and again
    /// whenever the filter text changes.
    ///
    /// Does not touch open pages itself: on a recompile it records the new
    /// fingerprint through `SettingsStore`, whose `onChange` fan-out pushes
    /// the lists onto open pages exactly once.
    func refreshIfNeeded() async {
        let adblock = SettingsStore.shared.settings.adblock
        guard adblock.enabled else {
            lists = []
            lastError = nil
            return
        }
        guard let snapshot = Self.bundledSnapshotText() else {
            lastError = "The bundled filter snapshot is missing."
            lists = []
            return
        }
        let version = Self.bundledSnapshotVersion() ?? "unknown"
        let text = snapshot + "\n" + adblock.userRules
        do {
            let meta = try await BrowserCore.filterMeta(text, version: version)
            lastMeta = meta
            if meta.inputHashHex == adblock.lastCompiledHash, adblock.compiledChunks > 0 {
                let found = await lookUp(count: adblock.compiledChunks)
                if found.count == adblock.compiledChunks {
                    lists = found
                    lastError = nil
                    return
                }
                // A persisted list went missing (store evicted it); fall
                // through and recompile rather than running half-blocked.
            }
            let data = try await BrowserCore.compiledFilters(text)
            let compiled = try await compile(chunks: Self.chunk(data))
            await removeStaleIdentifiers(keeping: compiled.count, previous: adblock.compiledChunks)
            lists = compiled
            lastError = nil
            SettingsStore.shared.update {
                $0.adblock.lastCompiledHash = meta.inputHashHex
                $0.adblock.compiledChunks = compiled.count
                $0.adblock.snapshotVersion = version
            }
        } catch {
            lastError = error.localizedDescription
            lists = []
        }
    }

    // MARK: - WebKit compilation

    private static func chunk(_ data: Data) throws -> [String] {
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return try stride(from: 0, to: array.count, by: rulesPerList).map { start -> String in
            let slice = Array(array[start ..< min(start + rulesPerList, array.count)])
            let chunk = try JSONSerialization.data(withJSONObject: slice)
            return String(decoding: chunk, as: UTF8.self)
        }
    }

    private func compile(chunks: [String]) async throws -> [WKContentRuleList] {
        var compiled: [WKContentRuleList] = []
        for (index, json) in chunks.enumerated() {
            compiled.append(
                try await compile(json: json, identifier: "\(Self.identifierPrefix).\(index)")
            )
        }
        return compiled
    }

    private func compile(json: String, identifier: String) async throws -> WKContentRuleList {
        // The default store is optional in the SDK and nil means compiling
        // is not possible in this process, which fails the compile.
        guard let store = WKContentRuleListStore.default() else {
            throw ContentBlockerError.noStore
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: ContentBlockerError.noListCompiled)
                }
            }
        }
    }

    private func lookUp(count: Int) async -> [WKContentRuleList] {
        // Nil store, or any identifier missing, means recompile rather than
        // running half-blocked.
        guard let store = WKContentRuleListStore.default() else { return [] }
        var found: [WKContentRuleList] = []
        for index in 0 ..< count {
            let list: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(
                    forIdentifier: "\(Self.identifierPrefix).\(index)"
                ) { list, _ in
                    continuation.resume(returning: list)
                }
            }
            guard let list else { return [] }
            found.append(list)
        }
        return found
    }

    /// Removes identifiers left over from a shrunken list. Best effort: a
    /// stale list that survives just sits unused until the next shrink.
    private func removeStaleIdentifiers(keeping count: Int, previous: Int) async {
        guard previous > count,
              let store = WKContentRuleListStore.default()
        else {
            return
        }
        for index in count ..< previous {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(
                    forIdentifier: "\(Self.identifierPrefix).\(index)"
                ) { _ in
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Per-page enforcement

    /// Syncs one controller's rule lists with the exception list for `url`.
    ///
    /// Idempotent: safe on every main-frame decision before allowing it, and
    /// on every live push. Stripped stays stripped until a non-excepted page
    /// re-adds; the lists are the store's current compile, so a recompile
    /// between navigations is picked up here too. Returns whether lists are
    /// attached afterwards.
    @discardableResult
    func applyException(for url: URL?, to controller: WKUserContentController) -> Bool {
        let adblock = SettingsStore.shared.settings.adblock
        controller.removeAllContentRuleLists()
        guard adblock.enabled else { return false }
        guard let host = url?.host, !Self.isExcepted(host: host, in: adblock.exceptions) else {
            return false
        }
        for list in lists {
            controller.add(list)
        }
        return !lists.isEmpty
    }

    /// Whether `host` or one of its parents is excepted. Both sides are
    /// lowercased and trailing dots trimmed, so `Example.COM.` matches an
    /// `example.com` entry.
    static func isExcepted(host: String, in exceptions: Set<String>) -> Bool {
        let needle = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !needle.isEmpty else { return false }
        return exceptions.contains { entry in
            let candidate = entry.lowercased()
            return needle == candidate || needle.hasSuffix("." + candidate)
        }
    }

    /// Records a tab's applied state, reporting whether it moved. The
    /// coordinator reloads only moved tabs; the controller sync above runs
    /// unconditionally because it is cheap and idempotent.
    func noteApplied(tab id: UUID, attached: Bool) -> Bool {
        let signature = "\(attached)-\(lists.count)-\(SettingsStore.shared.settings.adblock.lastCompiledHash ?? "")"
        guard appliedSignatures[id] != signature else { return false }
        appliedSignatures[id] = signature
        return true
    }

    /// Drops signatures for tabs that no longer exist, so the map stays
    /// proportional to the session rather than its history.
    func forgetTabs(notIn liveIDs: Set<UUID>) {
        appliedSignatures = appliedSignatures.filter { liveIDs.contains($0.key) }
    }

    // MARK: - Bundled snapshot

    private static func bundledSnapshotText() -> String? {
        // All or nothing: a missing file fails the snapshot (and the pages
        // load unblocked) rather than silently under-blocking with half a
        // list.
        let parts = snapshotResources.compactMap { bundledText(resource: $0) }
        guard parts.count == snapshotResources.count else { return nil }
        return parts.joined(separator: "\n")
    }

    private static func bundledSnapshotVersion() -> String? {
        bundledText(resource: snapshotVersionResource)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bundledText(resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

enum ContentBlockerError: Error, LocalizedError {
    case noListCompiled
    case noStore

    var errorDescription: String? {
        switch self {
        case .noListCompiled:
            "WebKit returned no rule list."
        case .noStore:
            "WebKit has no content rule store in this process."
        }
    }
}

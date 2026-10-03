import Foundation

/// One row of browsing history, as the store returns it.
///
/// The store owns the shape: `id` is its primary key and the timestamps are Unix
/// seconds. `visitCount` and `lastVisited` come from collapsing repeat visits, so
/// a row is a page rather than a single visit — the same URL opened twice in a
/// row is one row with a higher count.
struct HistoryEntry: Identifiable, Decodable, Hashable {
    let id: String
    let url: String
    let title: String
    let host: String
    let firstVisited: Date
    let lastVisited: Date
    let visitCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, url, title, host, firstVisited, lastVisited, visitCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        // A row with no title is normal: the store records whatever the page had
        // at commit time, and some pages never set one.
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        host = (try? container.decode(String.self, forKey: .host)) ?? ""
        firstVisited = Date(timeIntervalSince1970: TimeInterval(try container.decode(Int64.self, forKey: .firstVisited)))
        lastVisited = Date(timeIntervalSince1970: TimeInterval(try container.decode(Int64.self, forKey: .lastVisited)))
        visitCount = (try? container.decode(Int.self, forKey: .visitCount)) ?? 1
    }

    /// Decodes a listing, dropping rows that are not usable objects.
    ///
    /// One malformed row should cost that row, not the whole list.
    static func decodeList(_ data: Data) -> [HistoryEntry] {
        guard let rows = try? JSONDecoder().decode([FailableEntry].self, from: data) else {
            return []
        }
        return rows.compactMap(\.entry)
    }

    private struct FailableEntry: Decodable {
        let entry: HistoryEntry?

        init(from decoder: Decoder) throws {
            entry = try? HistoryEntry(from: decoder)
        }
    }
}

/// Seam for persistent history, so the tab layer does not know where visits go.
///
/// Recording is fire-and-forget: a visit that cannot be written is not worth
/// interrupting the user over, and the store is in another process anyway.
protocol HistoryRecording: AnyObject {
    func record(url: URL, title: String?)
}

/// Writes visits through the `WhateverStore` service.
///
/// The app links no Nim code, so this is an async XPC call rather than a
/// synchronous one. Calls are made from the main actor and hop straight into a
/// `Task`: the recorder deliberately holds no queue of its own, because a visit
/// that lands late is still a visit, and queueing would only mean holding URLs
/// in memory for no benefit.
@MainActor
final class StoreHistoryRecorder: HistoryRecording {
    /// Whether visits are recorded at all, from General settings.
    ///
    /// Read per visit rather than captured, so turning recording off takes effect
    /// on the next page without anything having to be reconfigured.
    var isEnabled: Bool {
        SettingsStore.shared.settings.general.recordsHistory
    }

    /// Why the last visit did not reach the store.
    ///
    /// Surfaced rather than logged: a page load must not be interrupted by
    /// history, but history failing silently is its own kind of bug, and this is
    /// where to look when a page is missing from the list.
    private(set) var lastError: String?

    func record(url: URL, title: String?) {
        guard isEnabled else { return }
        let visitedAt = Int64(Date().timeIntervalSince1970)
        let pageTitle = title ?? url.absoluteString
        Task {
            do {
                try await StoreClient.shared.recordVisit(
                    url: url.absoluteString,
                    title: pageTitle,
                    at: Date(timeIntervalSince1970: TimeInterval(visitedAt)),
                    collapseWindow: SettingsStore.shared.settings.general.historyCollapseWindow
                )
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
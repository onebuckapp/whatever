import Foundation

/// A tab's back/forward URL list and position, as pure value semantics.
///
/// Every mutation goes through here so the rules live in one place and are
/// unit-testable:
///
/// - A new address always appends and drops forward entries. Nothing here
///   collapses repeats: each access is logged, and fluent prev/next
///   navigation is a direct consequence of the list being complete.
/// - Movement only shifts the index; the list itself never changes.
/// - `noteCommitted` reconciles addresses the page committed to without going
///   through `navigate(to:)` (scripted, form, and redirect navigations), so
///   the list cannot disagree with what is on screen.
struct TabHistory: Equatable {
    private(set) var urls: [URL] = []
    private(set) var index: Int = -1

    init(urls: [URL] = [], index: Int = -1) {
        self.urls = urls
        // Clamp like a restore does: an index past the end settles on the
        // last entry rather than pointing at nothing.
        self.index = urls.isEmpty ? -1 : min(max(0, index), urls.count - 1)
    }

    /// The address the tab is on, or nil when the list is empty.
    var currentURL: URL? {
        guard urls.indices.contains(index) else { return nil }
        return urls[index]
    }

    var canGoBack: Bool {
        index > 0
    }

    var canGoForward: Bool {
        index >= 0 && index < urls.count - 1
    }

    /// Records a new address, dropping any forward entries.
    mutating func navigate(to url: URL) {
        if index < urls.count - 1 {
            urls.removeSubrange((index + 1)..<urls.count)
        }
        urls.append(url)
        index = urls.count - 1
    }

    /// Steps back, returning the address now current, or nil at the start.
    mutating func moveBack() -> URL? {
        guard index > 0 else { return nil }
        index -= 1
        return urls[index]
    }

    /// Steps forward, returning the address now current, or nil at the end.
    mutating func moveForward() -> URL? {
        guard index >= 0, index < urls.count - 1 else { return nil }
        index += 1
        return urls[index]
    }

    /// Logs a committed address that bypassed `navigate(to:)`.
    ///
    /// Returns whether anything was appended. A match against the current
    /// address (see `URL.hasSameAddress`) is a no-op, so reloads and
    /// back/forward loads — which move the index before loading — never
    /// duplicate.
    @discardableResult
    mutating func noteCommitted(_ url: URL) -> Bool {
        if let current = currentURL, url.hasSameAddress(as: current) {
            return false
        }
        if index < urls.count - 1 {
            urls.removeSubrange((index + 1)..<urls.count)
        }
        urls.append(url)
        index = urls.count - 1
        return true
    }
}

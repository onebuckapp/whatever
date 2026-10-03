import Foundation

/// Value snapshot of a browser tab. Independent from `WKWebView`,
/// which is owned by the tab's `BrowserWindowController`.
struct BrowserTabState: Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var estimatedProgress: Double

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        url: URL? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        estimatedProgress: Double = 0
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.estimatedProgress = estimatedProgress
    }
}

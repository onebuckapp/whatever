import Foundation

/// Privacy mode of a tab. Decided once when the tab's `WKWebView` is
/// created; a web view is never switched between modes afterwards.
enum BrowserPrivacyMode {
    case regular
    case privateBrowsing
}

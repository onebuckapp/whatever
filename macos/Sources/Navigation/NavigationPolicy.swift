import AppKit
import WebKit

/// Decides whether a navigation may proceed inside the web view.
/// Web schemes load in place; anything else (mailto:, tel:, …) is
/// handed to the OS and cancelled in the tab.
enum NavigationPolicy {
    static func decision(for request: URLRequest) -> WKNavigationActionPolicy {
        guard let url = request.url, let scheme = url.scheme?.lowercased() else {
            return .cancel
        }
        switch scheme {
        case "http", "https", "file", "about", "data", "blob", "whtvr":
            return .allow
        default:
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}

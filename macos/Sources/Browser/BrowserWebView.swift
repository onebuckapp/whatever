import AppKit
import WebKit

/// Application web view.
///
/// WebKit owns the page context menu, so replacing `NSView.menu` is not
/// enough. Overriding `willOpenMenu` lets the app inject its own item into
/// the menu WebKit actually displays.
final class BrowserWebView: WKWebView {
    static let generateQRCodeItemID = NSUserInterfaceItemIdentifier(
        rawValue: "com.onebuckapps.whatever.generateQRCode"
    )

    /// Called when the injected page-menu item is chosen.
    var onGenerateQRCode: (() -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // WebKit can reuse a menu object, so do not stack duplicate items.
        guard !menu.items.contains(where: { $0.identifier == Self.generateQRCodeItemID }) else {
            return
        }

        let item = NSMenuItem(
            title: "Generate QR Code",
            action: #selector(handleGenerateQRCode(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.generateQRCodeItemID
        item.target = self
        item.isEnabled = true
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func handleGenerateQRCode(_ sender: NSMenuItem?) {
        onGenerateQRCode?()
    }
}

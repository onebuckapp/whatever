import AppKit
import SwiftUI
import WebKit
import MijickPopups

/// Centered QR popup rendered by Mijick/Popups.
///
/// The symbol comes from the Nim backend as openparser's standalone SVG
/// document and is rendered as SVG — no dot-by-dot drawing on our side.
/// Presentation, dismissal, and styling stay here.
struct QRCodePopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let text: String
    let svg: String

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.black.opacity(0.38))
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            QRPopupCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            QRCodeSVGView(svg: svg)
                .frame(width: 280, height: 254)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 280)
        }
        .frame(width: 320, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks the whole popup (content included) to its measured
        // bounds, so the shadow needs transparent room to live in. The
        // padding is symmetric, so the card itself stays centered.
        .padding(.vertical, 88)
        .onTapGesture {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
        .onExitCommand {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
    }
}

/// Renders the backend's SVG document.
///
/// AppKit has no general SVG image support, so a lightweight non-interactive
/// web view does the rendering — fitting for a browser. The document is
/// inlined into a transparent page that scales it to the view bounds.
struct QRCodeSVGView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = webpagePreferences
        // Own pool like every other view: it dies with the popup.
        configuration.processPool = WKProcessPool()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(page(for: svg), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The document is fixed for the life of this view.
    }

    private func page(for svg: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>html,body{margin:0;padding:0;background:transparent}\
        svg{display:block;width:100vw;height:100vh}</style></head>\
        <body>\(svg)</body></html>
        """
    }
}

/// Resolves dynamic AppKit colors to static CSS hex strings, so the SVG the
/// backend renders matches the current appearance when the popup opens.
enum QRCodeSVGColors {
    static var darkHex: String {
        hex(NSColor.labelColor, fallback: "#000000")
    }

    static let lightHex = "none"

    private static func hex(_ color: NSColor, fallback: String) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return fallback }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}

/// Root view hosted inside the active page area.
///
/// It fills the page container so Mijick centers the popup on the webpage,
/// then presents the popup once the registered stack is on screen.
struct QRPopupRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let text: String
    let svg: String

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.black.opacity(0.38))
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await QRCodePopup(stackID: stackID, popupID: popupID, text: text, svg: svg)
                    .present(popupStackID: stackID)
            }
    }
}

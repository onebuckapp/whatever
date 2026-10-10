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

import AppKit
import Foundation
import MijickPopups
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The print preview card: a PDF preview with its scrollbar on the left and
/// a print-settings sidebar on the right, presented by Mijick/Popups.
///
/// The card renders a PDF of the live page once, then prints or saves that
/// document. Print settings (paper, orientation, scale, copies) apply to the
/// print operation; only the backgrounds toggle regenerates the PDF.
struct PrintPreviewPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            PrintPreviewCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        PrintPreviewCard()
            .frame(width: 800, height: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
            .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
            // Mijick masks the popup to its measured bounds, so the shadows
            // need transparent room; the padding is symmetric, so the card
            // stays centered.
            .padding(.vertical, 88)
            // Consume taps on the card itself so a click on empty card space
            // cannot reach the tap-outside layer.
            .onTapGesture {}
            .onExitCommand {
                Task {
                    await PopupStack.dismissPopup(popupID, popupStackID: stackID)
                }
            }
    }
}

/// The card itself: preview states on the left, settings on the right. An
/// ordinary view holding a per-open model; the popup struct above stays
/// `Sendable` with lets only.
private struct PrintPreviewCard: View {
    @StateObject private var model = PrintPreviewModel(
        webView: PrintPreviewCoordinator.shared.pendingWebView,
        title: PrintPreviewCoordinator.shared.pendingTitle ?? "Untitled"
    )

    private static let sidebarWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            sidebar
                .frame(width: Self.sidebarWidth)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .task {
            model.generate()
        }
        .onChange(of: model.settings.backgrounds) {
            model.generate()
        }
        .onChange(of: model.settings.printStylesheet) {
            model.generate()
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        switch model.phase {
        case .generating:
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Preparing preview…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            PDFPreviewView(document: model.document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 12) {
                Text("Could not render this page.")
                    .font(.system(size: 13, weight: .semibold))
                Text("Only loaded web pages can be printed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 4)
            if let count = model.pageCount, count > 0 {
                Text(count == 1 ? "1 page" : "\(count) pages")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
                .padding(.vertical, 8)

            Group {
                Stepper("Copies: \(model.settings.clampedCopies)", value: $model.settings.copies, in: 1...99)
                Picker("Paper", selection: $model.settings.paperSize) {
                    ForEach(PrintSettings.PaperSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("Orientation", selection: $model.settings.orientation) {
                    ForEach(PrintSettings.Orientation.allCases) { orientation in
                        Text(orientation.title).tag(orientation)
                    }
                }
                Picker("Scale", selection: $model.settings.scale) {
                    ForEach(PrintSettings.Scale.allCases) { scale in
                        Text(scale.title).tag(scale)
                    }
                }
                Toggle("Backgrounds", isOn: $model.settings.backgrounds)
                Toggle("Print stylesheet", isOn: $model.settings.printStylesheet)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .disabled(!model.isReady)

            Spacer(minLength: 8)
            Divider()
                .padding(.vertical, 8)
            Button {
                model.printDocument()
            } label: {
                Label("Print…", systemImage: "printer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .disabled(!model.isReady)
            Button {
                model.saveDocument()
            } label: {
                Label("Save as PDF…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .disabled(!model.isReady)
        }
    }
}

/// `PDFView` in SwiftUI: continuous scrolling with its own scrollbar, scaled
/// to fit the pane. The document swaps only when generation produces a new
/// one, so zoom and scroll position survive settings changes.
private struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }
    }
}

/// Per-open preview state: generates the PDF, holds the document, and runs
/// the print and save actions. Owned by the card, so two windows preview
/// independently.
@MainActor
final class PrintPreviewModel: ObservableObject {
    enum Phase {
        case generating
        case ready
        case failed
    }

    @Published var settings = PrintSettings()
    @Published private(set) var phase = Phase.generating

    private(set) var document: PDFDocument?
    private(set) var pdfData: Data?
    let title: String

    private weak var webView: WKWebView?
    /// Guards late completions: a backgrounds toggle starts a new
    /// generation, and only the latest may publish.
    private var generation = 0

    init(webView: WKWebView?, title: String) {
        self.webView = webView
        self.title = title
    }

    var isReady: Bool {
        phase == .ready && document != nil && pdfData != nil
    }

    var pageCount: Int? {
        document?.pageCount
    }

    /// Renders the page to PDF. Only the latest generation publishes: an
    /// earlier completion that arrives late is dropped, never shown.
    ///
    /// The web view's media type flips for the render when the print
    /// stylesheet is on, then always flips back — even for a superseded
    /// generation — so the live page never keeps print styles. The popup
    /// covers the page meanwhile, so the flip is not visible.
    func generate() {
        generation += 1
        let current = generation
        phase = .generating
        document = nil
        pdfData = nil
        guard let webView else {
            phase = .failed
            return
        }
        var configuration = WKPDFConfiguration()
        configuration.allowTransparentBackground = !settings.backgrounds
        let previousMediaType = webView.mediaType
        if settings.printStylesheet {
            webView.mediaType = "print"
        }
        webView.createPDF(configuration: configuration) { [weak self, weak webView] result in
            webView?.mediaType = previousMediaType
            guard let self, self.generation == current else { return }
            switch result {
            case .success(let data):
                guard let document = PDFDocument(data: data) else {
                    self.phase = .failed
                    return
                }
                self.pdfData = data
                self.document = document
                self.phase = .ready
            case .failure:
                self.phase = .failed
            }
        }
    }

    /// Runs the print operation with the sidebar's settings. The panel is
    /// app-modal; the preview stays open behind it.
    func printDocument() {
        guard let document, phase == .ready else { return }
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        settings.apply(to: printInfo)
        guard let operation = document.printOperation(
            for: printInfo,
            scalingMode: settings.scale.pdfScalingMode,
            autoRotate: true
        ) else {
            return
        }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.run()
    }

    /// Asks where to save, defaulting to the page title. Sheet on the key
    /// window — the preview's own — falling back to app-modal.
    func saveDocument() {
        guard let data = pdfData, phase == .ready else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = PrintSettings.sanitizedFilename(title: title)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let window = NSApp.keyWindow else {
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}

/// Root view hosted in the window content.
struct PrintPreviewRootView: View {
    let stackID: PopupStackID
    let popupID: String

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.clear)
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await PrintPreviewPopup(stackID: stackID, popupID: popupID)
                    .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick's dismissal callback back to the presenter that owns the
/// hosting view, and carries the page across: popup structs must stay
/// `Sendable`, so they cannot hold the web view directly.
@MainActor
final class PrintPreviewCoordinator {
    static let shared = PrintPreviewCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]

    /// The page being previewed, set just before presenting. Cleared on
    /// present so a stale page can never leak into a later card.
    var pendingWebView: WKWebView?
    var pendingTitle: String?

    func register(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
    }
}

/// Bridges the window to Mijick/Popups for the print preview.
///
/// One presenter per window, owned by the content controller next to the
/// feed-reader presenter. The window owns the card's lifetime, so tab
/// switches do not dismiss it; Escape and tap-outside do. No backdrop-drag
/// guard: the card holds no text fields, so every press on the backdrop is
/// a real dismiss.
@MainActor
final class PrintPreviewPresenter {
    private weak var container: NSView?
    private var hostingView: NSHostingView<PrintPreviewRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?

    init(container: NSView, onDidDismiss: (() -> Void)? = nil) {
        self.container = container
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Shows the preview for one page's web view, reopening when already
    /// open: the new page belongs to this press, not to the previous card.
    func present(webView: WKWebView?, title: String) {
        guard let container, container.window != nil else { return }
        resetForReuse()
        PrintPreviewCoordinator.shared.pendingWebView = webView
        PrintPreviewCoordinator.shared.pendingTitle = title

        let stackID = PopupStackID(rawValue: "print-preview-\(UUID().uuidString)")
        let popupID = "print-preview"
        let root = PrintPreviewRootView(stackID: stackID, popupID: popupID)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.hostingView = hostingView
        self.stackID = stackID
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
                return nil
            }
            return event
        }
        PrintPreviewCoordinator.shared.register(id: popupID) { [weak self] in
            self?.tearDown()
        }
        // Not cleared here: the card initializes after this returns and
        // reads the page then. Overwritten by every present; the weak web
        // view nils itself when its tab goes away.
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }

    private func resetForReuse() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        hostingView?.removeFromSuperview()
        hostingView = nil
        stackID = nil
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}

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
import PDFKit

/// The tab's native PDF page: a `PDFView` with the app's own floating
/// toolbar.
///
/// WebKit never renders a PDF in this app (see `PDFSupport`): its built-in
/// viewer — the zoom/duplicate/download bar this replaces — never appears,
/// so this toolbar is the only one on screen. Zoom answers ⌘+ / ⌘− through
/// the window controller like web pages do; save writes the fetched bytes
/// and print runs PDFKit's own operation.
final class PDFViewerController: NSViewController {
    /// What the viewer is showing. Mirrors the tab's PDF state; pushed by
    /// the hosting pane.
    enum Content {
        case loading(URL)
        case ready(document: PDFDocument, data: Data, filename: String)
        case failed(url: URL, message: String)
    }

    /// Called by the retry button in the error state. Set by the hosting
    /// pane, which owns the tab.
    var onRetry: (() -> Void)?

    /// The view keyboard focus moves into when this viewer is shown.
    var focusView: NSView {
        pdfView
    }

    private let pdfView = PDFView()
    private let toolbar = NSVisualEffectView()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let fitButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let pageLabel = NSTextField(labelWithString: "")
    private let printButton = NSButton()
    private let saveButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    private let errorStack = NSStackView()

    private var content = Content.loading(URL(string: "about:blank")!)
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installToolbar()
        installStatusViews()
        observers = [
            NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: pdfView, queue: .main
            ) { [weak self] _ in self?.updatePageLabel() },
            NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: pdfView, queue: .main
            ) { [weak self] _ in self?.updateZoomLabel() },
            NotificationCenter.default.addObserver(
                forName: .PDFViewDocumentChanged, object: pdfView, queue: .main
            ) { [weak self] _ in self?.updatePageLabel() },
        ]
        render(content)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Shows `content`, swapping the document only when it is a new one so
    /// zoom and scroll position survive re-renders of the same file.
    func render(_ content: Content) {
        self.content = content
        guard isViewLoaded else { return }
        switch content {
        case .loading:
            pdfView.document = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
            errorStack.isHidden = true
            setToolbarEnabled(false)
        case .ready(let document, _, _):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            errorStack.isHidden = true
            if pdfView.document !== document {
                pdfView.document = document
                pdfView.autoScales = true
            }
            setToolbarEnabled(true)
            updatePageLabel()
            updateZoomLabel()
        case .failed(_, let message):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            errorLabel.stringValue = message
            errorStack.isHidden = false
            setToolbarEnabled(false)
        }
    }

    // MARK: - Zoom

    /// Current magnification, for the window controller's stop checks.
    var zoomLevel: Double {
        Double(pdfView.scaleFactor)
    }

    func zoomIn() {
        setManualZoom(ZoomSupport.stepped(zoomLevel, direction: 1))
    }

    func zoomOut() {
        setManualZoom(ZoomSupport.stepped(zoomLevel, direction: -1))
    }

    /// Actual size: a 1:1 scale, not a fit. The toolbar's fit button is the
    /// one that scales to the window.
    func resetZoom() {
        setManualZoom(1.0)
    }

    func fitToWindow() {
        pdfView.autoScales = true
        updateZoomLabel()
    }

    private func setManualZoom(_ scale: Double) {
        pdfView.autoScales = false
        pdfView.scaleFactor = CGFloat(scale)
        updateZoomLabel()
    }

    // MARK: - Toolbar actions

    @objc private func didTapZoomOut() { zoomOut() }
    @objc private func didTapZoomIn() { zoomIn() }
    @objc private func didTapFit() { fitToWindow() }
    @objc private func didTapPrevious() { pdfView.goToPreviousPage(nil) }
    @objc private func didTapNext() { pdfView.goToNextPage(nil) }
    @objc private func didTapRetry() { onRetry?() }

    @objc private func didTapPrint() {
        guard case .ready(let document, _, let filename) = content else { return }
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        guard let operation = document.printOperation(
            for: printInfo,
            scalingMode: .pageScaleNone,
            autoRotate: true
        ) else {
            return
        }
        operation.jobTitle = filename
        operation.showsPrintPanel = true
        operation.run()
    }

    @objc private func didTapSave() {
        guard case .ready(_, let data, let filename) = content else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let window = view.window else {
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

    // MARK: - Layout

    private func installToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 14
        view.addSubview(toolbar)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])

        style(zoomOutButton, symbol: "minus.magnifyingglass",
              tip: tr("Zoom Out", ctx: "PDF"), action: #selector(didTapZoomOut))
        style(zoomInButton, symbol: "plus.magnifyingglass",
              tip: tr("Zoom In", ctx: "PDF"), action: #selector(didTapZoomIn))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        style(fitButton, symbol: "arrow.up.left.and.arrow.down.right",
              tip: tr("Fit to Window", ctx: "PDF"), action: #selector(didTapFit))
        style(previousButton, symbol: "chevron.left",
              tip: tr("Previous Page", ctx: "PDF"), action: #selector(didTapPrevious))
        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        style(nextButton, symbol: "chevron.right",
              tip: tr("Next Page", ctx: "PDF"), action: #selector(didTapNext))
        style(printButton, symbol: "printer",
              tip: tr("Print", ctx: "PDF"), action: #selector(didTapPrint))
        style(saveButton, symbol: "square.and.arrow.down",
              tip: tr("Save…", ctx: "PDF"), action: #selector(didTapSave))

        stack.addArrangedSubview(zoomOutButton)
        stack.addArrangedSubview(zoomInButton)
        stack.addArrangedSubview(zoomLabel)
        stack.addArrangedSubview(Self.separator())
        stack.addArrangedSubview(fitButton)
        stack.addArrangedSubview(Self.separator())
        stack.addArrangedSubview(previousButton)
        stack.addArrangedSubview(pageLabel)
        stack.addArrangedSubview(nextButton)
        stack.addArrangedSubview(Self.separator())
        stack.addArrangedSubview(printButton)
        stack.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
    }

    private func installStatusViews() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .large
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        retryButton.title = tr("Retry", ctx: "PDF")
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(didTapRetry)
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        errorStack.orientation = .vertical
        errorStack.alignment = .centerX
        errorStack.spacing = 12
        errorStack.addArrangedSubview(errorLabel)
        errorStack.addArrangedSubview(retryButton)
        errorStack.isHidden = true
        view.addSubview(errorStack)
        NSLayoutConstraint.activate([
            errorStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])
    }

    /// A borderless symbol button for the floating bar.
    private func style(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.target = self
        button.action = action
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: 18),
        ])
        return box
    }

    private func setToolbarEnabled(_ enabled: Bool) {
        for button in [zoomOutButton, zoomInButton, fitButton, previousButton, nextButton, printButton, saveButton] {
            button.isEnabled = enabled
        }
    }

    private func updatePageLabel() {
        guard let document = pdfView.document,
              let page = pdfView.currentPage
        else {
            pageLabel.stringValue = ""
            return
        }
        let index = document.index(for: page)
        guard index != NSNotFound else {
            pageLabel.stringValue = ""
            return
        }
        pageLabel.stringValue = tr(
            "Page {current} of {total}",
            ctx: "PDF",
            args: ["current": "\(index + 1)", "total": "\(document.pageCount)"]
        )
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int(round(Double(pdfView.scaleFactor) * 100)))%"
    }
}

import AppKit

/// Where a dragged tab would land if released over the page area.
enum SplitDropZone: Equatable {
    case leading
    case trailing
    case center

    /// Left/right thirds decide the pane order; the middle third is a
    /// deliberate no-op so an accidental release cannot split.
    static func zone(for point: NSPoint, in bounds: NSRect) -> SplitDropZone {
        guard bounds.width > 0 else { return .center }
        let normalizedX = (point.x - bounds.minX) / bounds.width
        if normalizedX < 0.35 {
            return .leading
        } else if normalizedX > 0.65 {
            return .trailing
        }
        return .center
    }
}

/// Translucent overlay drawn above the page area while a tab is dragged
/// over the window, showing which pane would receive it. Purely visual:
/// the layout is untouched until the drag ends.
final class SplitDropPreviewView: NSView {
    var zone: SplitDropZone = .trailing {
        didSet {
            if oldValue != zone {
                needsDisplay = true
            }
        }
    }

    private let inset: CGFloat = 12

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        // Never intercept the drag: the tab strip keeps event capture.
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func present(zone: SplitDropZone, animated: Bool) {
        self.zone = zone
        if isHidden {
            isHidden = false
            alphaValue = animated ? 0 : 1
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    self.animator().alphaValue = 1
                }
            }
        }
        needsDisplay = true
    }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.isHidden = true
            self.alphaValue = 1
        }
    }

    /// Rect the preview occupies inside the view for the current zone.
    func previewRect() -> NSRect {
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard area.width > 0, area.height > 0 else { return area }
        switch zone {
        case .leading:
            return NSRect(
                x: area.minX,
                y: area.minY,
                width: (area.width / 2) - 4,
                height: area.height
            )
        case .trailing:
            return NSRect(
                x: area.midX + 4,
                y: area.minY,
                width: (area.width / 2) - 4,
                height: area.height
            )
        case .center:
            return area
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = previewRect()
        guard rect.width > 1, rect.height > 1 else { return }

        let fill = NSColor.controlAccentColor.withAlphaComponent(zone == .center ? 0.08 : 0.18)
        fill.setFill()

        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.fill()

        let stroke = NSColor.controlAccentColor.withAlphaComponent(0.85)
        stroke.setStroke()
        path.lineWidth = 2
        if zone == .center {
            let dashes: [CGFloat] = [6, 4]
            path.setLineDash(dashes, count: dashes.count, phase: 0)
        }
        path.stroke()
    }
}

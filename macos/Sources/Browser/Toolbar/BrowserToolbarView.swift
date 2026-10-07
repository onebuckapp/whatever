import AppKit

/// The window's top strip: navigation on the leading side, the address field in
/// the middle, bookmarks / downloads / settings on the trailing side.
///
/// Hand-rolled rather than an `NSToolbar`, and visually the same thing in the same
/// place. The reason is positioning and reach: AppKit draws an `NSToolbar` in its
/// own layer *above* the content view, so nothing in this app could be laid out
/// relative to it or drawn across it. Owning the strip is what makes the top zone
/// somewhere a dropdown can eventually hang from.
///
/// The strip is 52pt, which is exactly the safe-area inset the native toolbar used
/// to contribute to the content view, so the tab bar below it does not move. That
/// inset is now contributed by this view instead, pinned explicitly.
@MainActor
final class BrowserToolbarView: NSView {
    /// The height the native toolbar used to contribute as a safe-area inset.
    static let height: CGFloat = 52

    /// Room for the three window buttons at the leading edge.
    ///
    /// Measured rather than guessed: the close button's frame is x 19 to 33 with
    /// the other two at roughly 20pt intervals, so the last one ends near x 79.
    /// 92 leaves a margin. The buttons are drawn by AppKit over the content view
    /// because of `fullSizeContentView`, so nothing reserves space for them.
    private static let windowButtonInset: CGFloat = 92

    /// Breathing room at the trailing edge.
    ///
    /// The buttons used to be laid out by `NSToolbar`, which kept them off the
    /// window edge on its own; a hand-placed cluster butts straight against it.
    private static let trailingInset: CGFloat = 10

    private let leadingCluster = NSStackView()
    private let trailingCluster = NSStackView()
    private let center: NSView

    /// Breathing room between the field and each button cluster in stretch
    /// mode, so the field never touches a glyph.
    private static let stretchGap: CGFloat = 8

    /// Centring constraint for the default fixed-width field. Kept to swap
    /// against the stretch pins below.
    private var centerXConstraint: NSLayoutConstraint?
    /// Pins the field across the space between the clusters. Built once,
    /// toggled with the centring constraint; Auto Layout re-resolves them
    /// on every resize, which is what makes the mode responsive.
    private var stretchConstraints: [NSLayoutConstraint] = []
    private var isStretched = false

    init(leading: [NSView], center: NSView, trailing: [NSView]) {
        self.center = center
        super.init(frame: .zero)

        // The window buttons are drawn over this strip, so it must not draw
        // anything of its own behind them.
        wantsLayer = true

        configure(cluster: leadingCluster, buttons: leading)
        configure(cluster: trailingCluster, buttons: trailing)

        for view in [leadingCluster, center, trailingCluster] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // Centred on the strip rather than floated between the two clusters by
        // flexible spaces. The clusters happen to be the same width today, so
        // this looks identical to what `NSToolbar` did, but it stays centred
        // when they are not.
        let centerX = center.centerXAnchor.constraint(equalTo: centerXAnchor)
        centerXConstraint = centerX
        stretchConstraints = [
            center.leadingAnchor.constraint(
                equalTo: leadingCluster.trailingAnchor,
                constant: Self.stretchGap
            ),
            center.trailingAnchor.constraint(
                equalTo: trailingCluster.leadingAnchor,
                constant: -Self.stretchGap
            ),
        ]
        NSLayoutConstraint.activate([
            leadingCluster.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.windowButtonInset
            ),
            leadingCluster.centerYAnchor.constraint(equalTo: centerYAnchor),

            centerX,
            center.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailingCluster.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.trailingInset
            ),
            trailingCluster.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // The clusters give way before the address field does, so a narrow window
        // loses the outer buttons rather than breaking the layout outright.
        for cluster in [leadingCluster, trailingCluster] {
            cluster.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cluster.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        center.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    /// Switches the field between a centred fixed width and filling the space
    /// between the button clusters. Idempotent: repeated calls with the same
    /// value touch nothing, so settings ticks that change other fields do not
    /// rebuild constraints.
    func setFullWidth(_ fillsWidth: Bool) {
        guard fillsWidth != isStretched else { return }
        isStretched = fillsWidth
        centerXConstraint?.isActive = !fillsWidth
        for constraint in stretchConstraints {
            constraint.isActive = fillsWidth
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(cluster: NSStackView, buttons: [NSView]) {
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 2
        // AppKit's own toolbar item spacing, so the buttons sit where they did.
        for button in buttons {
            cluster.addArrangedSubview(button)
        }
    }

    // MARK: - Moving the window

    /// The strip stands in for the titlebar, because a full-size content view sits
    /// above the titlebar and receives the click first. Without this the window
    /// could only be moved by its edges.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            performTitlebarDoubleClick()
            return
        }
        window?.performDrag(with: event)
    }

    /// Driven from `mouseDown` instead: returning true here would hand the drag to
    /// AppKit's own titlebar handling, which this view is standing in for.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// Honours the system preference rather than always zooming, because that is
    /// what the titlebar this replaces would have done.
    private func performTitlebarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.miniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }
}
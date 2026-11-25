import AppKit

/// Non-modal notice at the bottom of the viewer window, e.g. "Peekaboo 20261126 is ready  [Restart to Update]
/// [Later]". Created only when there is an update to act on (never during launch); frames are set by hand, so
/// the window keeps its constraint-free layout. It takes no keys: the viewer's key monitor keeps every binding.
final class UpdateBanner: NSView {
    private var actions: [() -> Void] = []
    private static let margin: CGFloat = 18

    init(text: String, buttons: [(title: String, action: () -> Void)]) {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
        layer?.cornerRadius = 9
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        var views: [NSView] = [label]
        for (index, button) in buttons.enumerated() {
            let control = NSButton(title: button.title, target: self, action: #selector(pressed(_:)))
            control.tag = index
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            control.refusesFirstResponder = true
            // The first button is the action; accent-coloured like a default button, without taking Return.
            if index == 0 { control.bezelColor = .controlAccentColor }
            control.sizeToFit()
            views.append(control)
            actions.append(button.action)
        }
        let height = (views.map(\.frame.height).max() ?? 20) + 12
        var x: CGFloat = 14
        for (index, view) in views.enumerated() {
            view.frame.origin = CGPoint(x: x, y: ((height - view.frame.height) / 2).rounded())
            addSubview(view)
            x += view.frame.width + (index == 0 ? 14 : 6)
        }
        frame.size = CGSize(width: x + 8 - 6, height: height)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { false }

    /// Add to `container` (the window's flipped content view), centred at the bottom; it stays there on resize.
    func show(in container: NSView) {
        let bounds = container.bounds
        frame.origin = CGPoint(x: ((bounds.width - frame.width) / 2).rounded(),
                               y: container.isFlipped ? bounds.height - frame.height - Self.margin : Self.margin)
        autoresizingMask = [.minXMargin, .maxXMargin, container.isFlipped ? .minYMargin : .maxYMargin]
        container.addSubview(self)
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

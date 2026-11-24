import AppKit
import CoreText
import PeekabooCore
import QuartzCore

/// What the info overlay shows for the current image.
struct HUDContent: Equatable {
    /// `name · index/count · dims · zoom % · rating/label`
    var line = ""
    /// Full-mode rows (label, value).
    var details: [Row] = []
    struct Row: Equatable { var label: String; var value: String }
}

/// Removes implicit animations from a layer (the HUD changes in one frame, never fades in).
private let noActions: [String: CAAction] = [
    "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(), "hidden": NSNull(),
    "opacity": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "backgroundColor": NSNull(),
    "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "contentsScale": NSNull(),
]

/// A rounded, translucent black box holding one `CATextLayer`.
private final class TextBox {
    let box = CALayer()
    let text = CATextLayer()
    var padding = CGSize(width: 9, height: 5)

    init(cornerRadius: CGFloat = 6, alpha: CGFloat = 0.55) {
        box.backgroundColor = CGColor(gray: 0, alpha: alpha)
        box.cornerRadius = cornerRadius
        box.actions = noActions
        text.actions = noActions
        text.isWrapped = true
        text.truncationMode = .end
        text.alignmentMode = .left
        // Rasterise the text off the main thread at commit time.
        text.drawsAsynchronously = true
        box.addSublayer(text)
        box.isHidden = true
    }

    /// Set the text and size the box to fit (at most `maxWidth` wide). Returns the box size.
    @discardableResult
    func set(_ string: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let limit = max(maxWidth - 2 * padding.width, 40)
        let measured: CGSize
        let singleLine = !string.string.contains("\n")
        if singleLine {
            // One CTLine is ~10x cheaper than a TextKit bounding rect (HUD updates on every navigation).
            let line = CTLineCreateWithAttributedString(string)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            measured = CGSize(width: width, height: ascent + descent + leading)
        } else {
            measured = string.boundingRect(with: CGSize(width: limit, height: 10_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        }
        let size = CGSize(width: min(ceil(measured.width) + 2, limit), height: ceil(measured.height) + 1)
        text.isWrapped = !singleLine
        text.string = string
        text.frame = CGRect(x: padding.width, y: padding.height, width: size.width, height: size.height)
        box.bounds = CGRect(x: 0, y: 0, width: size.width + 2 * padding.width, height: size.height + 2 * padding.height)
        return box.bounds.size
    }

    func setScale(_ scale: CGFloat) {
        box.contentsScale = scale
        text.contentsScale = scale
    }
}

/// HUD, toasts, progress line, centred message and help overlay: Core Animation layers above
/// the Metal layer, updated only when their content changes, always with actions disabled.
final class HUD {
    private let root = CALayer()
    private let info = TextBox()
    private let details = TextBox()
    private let toast = TextBox(cornerRadius: 8, alpha: 0.7)
    private let message = TextBox(cornerRadius: 10, alpha: 0.0)
    private let help = CALayer()
    private var helpColumns: [CATextLayer] = []
    private let progress = CALayer()
    private let progressBar = CALayer()

    private var size = CGSize(width: 100, height: 100)
    private var topInset: CGFloat = 0
    /// 0 until the first layout, so the text layers always receive the real backing scale.
    private var scale: CGFloat = 0
    private var content = HUDContent()
    private var toastGeneration = 0
    private var messageText: String?
    private var helpSections: [(title: String, lines: [(keys: String, title: String)])]?

    var mode: AppConfig.HUDMode = .minimal { didSet { if mode != oldValue { refreshInfo() } } }
    /// `view.hud_hide`: hide every overlay (the toast still confirms actions).
    var hidesAll = false { didSet { if hidesAll != oldValue { refreshInfo() } } }
    var isHelpVisible: Bool { helpSections != nil }

    private static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let detailLabelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let toastFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 15, weight: .medium)

    init(parent: CALayer) {
        root.actions = noActions
        root.isGeometryFlipped = false
        parent.addSublayer(root)
        for layer in [details.box, info.box, toast.box, message.box, help, progress] { root.addSublayer(layer) }
        help.backgroundColor = CGColor(gray: 0, alpha: 0.78)
        help.cornerRadius = 12
        help.actions = noActions
        help.isHidden = true
        progress.actions = noActions
        progress.isHidden = true
        progress.masksToBounds = true
        progressBar.backgroundColor = CGColor(gray: 1, alpha: 0.75)
        progressBar.actions = noActions
        progress.addSublayer(progressBar)
        message.padding = CGSize(width: 16, height: 10)
    }

    // MARK: Geometry

    func layout(size: CGSize, topInset: CGFloat, scale: CGFloat) {
        let scaleChanged = scale != self.scale
        let widthChanged = abs(size.width - self.size.width) >= 1
        self.size = size
        self.topInset = topInset
        self.scale = scale
        transaction {
            root.frame = CGRect(origin: .zero, size: size)
            if scaleChanged {
                for box in [info, details, toast, message] { box.setScale(scale) }
                for column in helpColumns { column.contentsScale = scale }
            }
            progress.frame = CGRect(x: 0, y: size.height - 2, width: size.width, height: 2)
            progressBar.frame = CGRect(x: 0, y: 0, width: max(size.width * 0.22, 60), height: 2)
            layoutInfo()
            layoutMessage()
            layoutToast()
        }
        // Re-measure so the info line truncates to the new width (and re-rasterises at a new scale).
        if widthChanged || scaleChanged { refreshInfo() }
        if helpSections != nil { renderHelp() }
    }

    private func layoutInfo() {
        let margin: CGFloat = 12
        let infoSize = info.box.bounds.size
        info.box.frame.origin = CGPoint(x: margin, y: size.height - margin - infoSize.height)
        let detailSize = details.box.bounds.size
        details.box.frame.origin = CGPoint(x: margin, y: info.box.frame.minY - 6 - detailSize.height)
    }

    private func layoutMessage() {
        let s = message.box.bounds.size
        message.box.frame.origin = CGPoint(x: ((size.width - s.width) / 2).rounded(), y: ((size.height - s.height) / 2).rounded())
    }

    private func layoutToast() {
        let s = toast.box.bounds.size
        toast.box.frame.origin = CGPoint(x: ((size.width - s.width) / 2).rounded(), y: max(topInset, 0) + 40)
    }

    // MARK: Info

    func setContent(_ new: HUDContent) {
        guard new != content else { return }
        content = new
        Trace.log("hud: \(new.line)\(new.details.isEmpty ? "" : " | " + new.details.map { "\($0.label)=\($0.value)" }.joined(separator: "; "))")
        refreshInfo()
    }

    private func refreshInfo() {
        transaction {
            let showLine = !hidesAll && mode != .off && !content.line.isEmpty
            info.box.isHidden = !showLine
            if showLine {
                info.set(NSAttributedString(string: content.line, attributes: [
                    .font: Self.lineFont, .foregroundColor: NSColor.white,
                ]), maxWidth: size.width - 24)
            }
            let showDetails = showLine && mode == .full && !content.details.isEmpty
            details.box.isHidden = !showDetails
            if showDetails {
                let width = content.details.map(\.label.count).max() ?? 0
                let text = NSMutableAttributedString()
                for (i, row) in content.details.enumerated() {
                    let label = row.label.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                    text.append(NSAttributedString(string: label, attributes: [
                        .font: Self.detailLabelFont, .foregroundColor: NSColor(white: 1, alpha: 0.62),
                    ]))
                    text.append(NSAttributedString(string: row.value + (i + 1 < content.details.count ? "\n" : ""), attributes: [
                        .font: Self.detailFont, .foregroundColor: NSColor.white,
                    ]))
                }
                details.set(text, maxWidth: min(size.width - 24, 560))
            }
            layoutInfo()
        }
    }

    // MARK: Toast

    /// Show `text` for 1.2 s at the same spot (replaces the previous toast).
    func showToast(_ text: String) {
        toastGeneration += 1
        let generation = toastGeneration
        transaction {
            toast.box.removeAllAnimations()
            toast.box.opacity = 1
            toast.box.isHidden = false
            toast.set(NSAttributedString(string: text, attributes: [
                .font: Self.toastFont, .foregroundColor: NSColor.white,
            ]), maxWidth: size.width - 40)
            layoutToast()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.18
            self.transaction {
                self.toast.box.opacity = 0
                self.toast.box.add(fade, forKey: "fade")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.toastGeneration == generation else { return }
                self.transaction { self.toast.box.isHidden = true }
            }
        }
    }

    // MARK: Progress line

    /// 2-px indeterminate line along the bottom edge (shown when the target has no pixels after 150 ms).
    func setLoading(_ loading: Bool) {
        guard loading == progress.isHidden else { return }
        transaction {
            progress.isHidden = !loading
            if loading {
                let sweep = CABasicAnimation(keyPath: "position.x")
                let w = progressBar.bounds.width
                sweep.fromValue = -w / 2
                sweep.toValue = size.width + w / 2
                sweep.duration = 0.9
                sweep.repeatCount = .infinity
                progressBar.add(sweep, forKey: "sweep")
            } else {
                progressBar.removeAllAnimations()
            }
        }
    }

    // MARK: Centred message

    /// Centred hint or error (empty folder, nothing open, cannot decode). nil hides it.
    func setMessage(_ text: String?) {
        guard text != messageText else { return }
        messageText = text
        transaction {
            message.box.isHidden = text == nil
            if let text {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineSpacing = 3
                message.text.alignmentMode = .center
                message.set(NSAttributedString(string: text, attributes: [
                    .font: Self.messageFont, .foregroundColor: NSColor(white: 1, alpha: 0.72), .paragraphStyle: paragraph,
                ]), maxWidth: min(size.width - 40, 520))
                layoutMessage()
            }
        }
    }

    // MARK: Help

    func setHelp(_ sections: [(title: String, lines: [(keys: String, title: String)])]?) {
        helpSections = sections
        if sections == nil {
            transaction { help.isHidden = true }
        } else {
            renderHelp()
        }
    }

    private func renderHelp() {
        guard let sections = helpSections else { return }
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        let lineHeight: CGFloat = 17
        let available = max(size.height - 80, 200)
        let maxLines = max(Int(available / lineHeight), 8)
        // Greedy column fill; sections are not split unless one is taller than a column.
        var columns: [[(String, Bool, String)]] = [[]]
        for section in sections {
            let needed = section.lines.count + 2
            if !columns[columns.count - 1].isEmpty, columns[columns.count - 1].count + needed > maxLines { columns.append([]) }
            columns[columns.count - 1].append((section.title, true, ""))
            for line in section.lines {
                if columns[columns.count - 1].count >= maxLines { columns.append([]) }
                columns[columns.count - 1].append((line.keys, false, line.title))
            }
            columns[columns.count - 1].append(("", false, ""))
        }
        let keyWidth = min(sections.flatMap { $0.lines.map(\.keys.count) }.max() ?? 8, 22)
        transaction {
            for column in helpColumns { column.removeFromSuperlayer() }
            helpColumns.removeAll()
            var x: CGFloat = 20
            var height: CGFloat = 0
            for column in columns where !column.isEmpty {
                let text = NSMutableAttributedString()
                for (keys, isHead, title) in column {
                    if isHead {
                        text.append(NSAttributedString(string: keys + "\n", attributes: [.font: headFont, .foregroundColor: NSColor.white]))
                    } else if keys.isEmpty && title.isEmpty {
                        text.append(NSAttributedString(string: "\n", attributes: [.font: titleFont]))
                    } else {
                        let padded = keys.count > keyWidth ? String(keys.prefix(keyWidth - 1)) + "…" : keys.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
                        text.append(NSAttributedString(string: padded + "  ", attributes: [
                            .font: keyFont, .foregroundColor: NSColor(calibratedRed: 1, green: 0.84, blue: 0.45, alpha: 1),
                        ]))
                        text.append(NSAttributedString(string: title + "\n", attributes: [.font: titleFont, .foregroundColor: NSColor.white]))
                    }
                }
                let rect = text.boundingRect(with: CGSize(width: 520, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
                let layer = CATextLayer()
                layer.actions = noActions
                layer.contentsScale = scale
                layer.isWrapped = false
                layer.string = text
                layer.frame = CGRect(x: x, y: 18, width: ceil(rect.width) + 4, height: ceil(rect.height) + 2)
                help.addSublayer(layer)
                helpColumns.append(layer)
                x += ceil(rect.width) + 28
                height = max(height, ceil(rect.height) + 2)
            }
            let width = min(x - 8, size.width - 20)
            let h = min(height + 36, size.height - 20)
            help.frame = CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: width, height: h)
            help.isHidden = false
        }
    }

    // MARK: Helpers

    private func transaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

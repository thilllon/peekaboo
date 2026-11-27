import AppKit
import PeekabooCore

/// The image list (`view.image_list`): every image of the browsing set at the right edge of the window, each with its
/// thumbnail and name, picks flagged. The image on screen is the selected row and stays in view; a click shows another.
///
/// Speed first:
/// - Built the first time it opens, never at launch: when it was open at the last quit, the viewer keeps its width for
///   the first frame and builds it once the image on screen is sharp. Closed, it costs nothing.
/// - A view-based table with a fixed row height: only the rows on screen exist and they are reused, at 50 or 50,000
///   images alike. A change of image selects one row and scrolls it into view; a new browsing set (an open, a file
///   operation, a rescan, the picks-only view) reloads the rows on screen. The set is the pipeline's array, shared:
///   telling a new one from the one shown compares two pointers.
/// - Rows are layers (thumbnail, name, flag): no controls and no view drawing; text is rasterised off the main thread.
/// - Thumbnails come from `ThumbnailLoader`: rows on screen only, off the main thread, paused while the viewer decodes
///   the image on screen.
/// - It never takes the keyboard focus: every key stays the viewer's.
final class ImageListPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 240
    static let rowHeight: CGFloat = 48
    /// Thumbnails are made at twice the row height in pixels: sharp on a Retina screen.
    static let thumbnailPixels = Int(2 * rowHeight)
    static let background = NSColor(white: 0.07, alpha: 1)

    let table = ImageListTable()
    let scrollView = NSScrollView()
    let thumbnails: ThumbnailLoader
    /// Shows `files[row]`: a click on a row (main thread).
    var onSelect: ((Int) -> Void)?
    /// Whether `file` is a pick (the viewer's picks).
    var isPick: (ImageFile) -> Bool = { _ in false }
    /// The browsing set the rows show: the pipeline's array, shared.
    private(set) var files: [ImageFile] = []
    /// The row of the image on screen (-1: none).
    private(set) var selectedRow = -1
    private let separator = CALayer()
    private var observers: [NSObjectProtocol] = []

    init(thumbnails: ThumbnailLoader) {
        self.thumbnails = thumbnails
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        separator.backgroundColor = CGColor(gray: 1, alpha: 0.1)
        separator.actions = ImageListCell.noActions
        layer?.addSublayer(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("image"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] row in self?.clicked(row) }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        // The panel's layer is the background: nothing behind the rows is drawn on the CPU.
        scrollView.drawsBackground = false
        // Below the title bar in a window, from the top in full screen; rows scroll on under the bar.
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.frame = NSRect(x: 1, y: 0, width: bounds.width - 1, height: bounds.height)
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        table.sizeLastColumnToFit()

        thumbnails.onLoaded = { [weak self] file, entry in self?.loaded(file, entry) }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: nil) { [weak self] _ in
            self?.requestThumbnailsOnScreen()
        })
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    override func layout() {
        super.layout()
        layoutSeparator()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutSeparator()
    }

    private func layoutSeparator() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
    }

    // MARK: Following the viewer

    /// Follow the viewer: the browsing set `newFiles` (the pipeline's), the image on screen at `index`, and whether the
    /// viewer is decoding that image (no thumbnail starts meanwhile). Another set reloads the rows on screen; the same one
    /// only checks their picks. Another `index` selects its row and scrolls it into view.
    func update(files newFiles: [ImageFile], index: Int, viewerBusy: Bool) {
        thumbnails.isPaused = viewerBusy
        if !Self.sameStorage(newFiles, files) {
            files = newFiles
            selectedRow = -1
            table.reloadData()
        } else {
            refreshPicks()
        }
        select(newFiles.indices.contains(index) ? index : -1)
    }

    /// The list opens again: rows on screen whose thumbnail was cancelled when it closed ask for it again.
    func opened() { requestThumbnailsOnScreen() }

    /// The list closed: nothing more is made for it.
    func closed() { thumbnails.cancelAll() }

    /// `a` and `b` share their storage: the same browsing set, unchanged. A new set is another array, and the panel keeps
    /// the one it shows, so that storage cannot be reused for another one. O(1), where comparing the files would hash
    /// every URL.
    static func sameStorage(_ a: [ImageFile], _ b: [ImageFile]) -> Bool {
        guard a.count == b.count else { return false }
        guard !a.isEmpty else { return true }
        return a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress } }
    }

    private func select(_ row: Int) {
        guard row != selectedRow else { return }
        selectedRow = row
        guard row >= 0 else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// The rows on screen (their range in `files`).
    private var rowsOnScreen: Range<Int> {
        let rows = table.rows(in: table.visibleRect)
        let lower = max(rows.location, 0), upper = min(rows.location + rows.length, files.count)
        return lower < upper ? lower..<upper : 0..<0
    }

    private func cell(at row: Int) -> ImageListCell? {
        table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ImageListCell
    }

    /// Picks change without another set (P, X, U, an undo, a tag read): the rows on screen show them.
    private func refreshPicks() {
        for row in rowsOnScreen { cell(at: row)?.setPick(isPick(files[row])) }
    }

    private func clicked(_ row: Int) {
        guard files.indices.contains(row), row != selectedRow else { return }
        onSelect?(row)
    }

    // MARK: Thumbnails

    private func isOnScreen(_ row: Int) -> Bool { table.visibleRect.intersects(table.rect(ofRow: row)) }

    /// Rows that came on screen (scrolling, a reload, the list opening) ask for their thumbnails.
    private func requestThumbnailsOnScreen() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        for row in rowsOnScreen {
            guard let cell = cell(at: row), cell.needsThumbnail, let file = cell.file, let key = cell.key else { continue }
            thumbnails.request(file, key: key)
        }
    }

    private func loaded(_ file: ImageFile, _ entry: ThumbnailLoader.Entry) {
        let key = ThumbnailLoader.key(file)
        table.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? ImageListCell, cell.key == key else { return }
            cell.setThumbnail(entry)
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ImageListRowView.identifier, owner: nil) as? ImageListRowView ?? ImageListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard files.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: ImageListCell.identifier, owner: nil) as? ImageListCell ?? ImageListCell()
        let file = files[row]
        let key = ThumbnailLoader.key(file)
        let entry = thumbnails.cached(key)
        cell.configure(file, key: key, pick: isPick(file), thumbnail: entry)
        // Rows the table prepares beyond the visible ones ask once they come on screen.
        if entry == nil, isOnScreen(row) { thumbnails.request(file, key: key) }
        return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? ImageListCell, cell.needsThumbnail, let key = cell.key else { return }
        thumbnails.cancel(key)
    }
}

/// The image list's table. It never takes the keyboard focus (every key stays the viewer's, and type-select would move
/// the selection), and a click shows the clicked image at once: there is no selection tracking, the selection follows
/// the viewer.
final class ImageListTable: NSTableView {
    var onClick: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The table draws nothing itself (no background, grid or drop feedback here): the panel's layer shows through, and
    /// a change of selection redraws no part of the table on the CPU.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func mouseDown(with event: NSEvent) {
        // The strip under the title bar moves the window, as it does over the image.
        if let window, window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
           event.locationInWindow.y > window.contentLayoutRect.maxY {
            window.performDrag(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick?(row) }
    }
}

/// A row of the image list: the selection is a layer (no drawing on the CPU when it moves).
final class ImageListRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("imageRow")
    private let highlight = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: ImageListPanel.width, height: ImageListPanel.rowHeight))
        identifier = Self.identifier
        wantsLayer = true
        highlight.actions = ImageListCell.noActions
        highlight.cornerRadius = 5
        highlight.isHidden = true
        layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var wantsUpdateLayer: Bool { true }

    /// Resolves the accent colour for the (dark) appearance; set only when it changes (a selection change asks again).
    override func updateLayer() {
        let colour = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        if highlight.backgroundColor != colour { highlight.backgroundColor = colour }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            highlight.isHidden = !isSelected
        }
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 4, dy: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// The contents of a row, all layers: the thumbnail (a placeholder until it is made), the name (truncated in the middle)
/// and the Pick flag.
final class ImageListCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("imageCell")
    /// Layers change in the frame they are set, never animated.
    static let noActions: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "string": NSNull(), "backgroundColor": NSNull(), "contentsScale": NSNull(), "onOrderIn": NSNull(),
        "onOrderOut": NSNull(), "sublayers": NSNull(),
    ]
    private static let thumbnailSide: CGFloat = 40
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let placeholder = CGColor(gray: 1, alpha: 0.08)

    private(set) var file: ImageFile?
    /// `ThumbnailLoader.key(file)`.
    private(set) var key: NSString?
    /// No thumbnail yet: it was asked for, or is once the row is on screen.
    private(set) var needsThumbnail = true
    private(set) var isPick = false
    private let thumbnail = CALayer()
    private let name = CATextLayer()
    private let flag = CATextLayer()
    /// Width over height of the thumbnail shown (nil: the placeholder).
    private var aspect: CGFloat?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: ImageListPanel.width, height: ImageListPanel.rowHeight))
        identifier = Self.identifier
        wantsLayer = true
        for sublayer in [thumbnail, name, flag] {
            sublayer.actions = Self.noActions
            layer?.addSublayer(sublayer)
        }
        // Text is rasterised off the main thread when the layer tree is committed (as the HUD's).
        name.drawsAsynchronously = true
        flag.drawsAsynchronously = true
        thumbnail.contentsGravity = .resize
        thumbnail.cornerRadius = 3
        thumbnail.masksToBounds = true
        thumbnail.backgroundColor = Self.placeholder
        name.font = Self.font
        name.fontSize = Self.font.pointSize
        name.foregroundColor = CGColor(gray: 1, alpha: 0.88)
        name.truncationMode = .middle
        name.isWrapped = false
        name.alignmentMode = .left
        flag.string = "⚑"
        flag.font = Self.font
        flag.fontSize = 13
        flag.foregroundColor = CGColor(red: 1, green: 0.84, blue: 0.45, alpha: 1)
        flag.alignmentMode = .center
        flag.isHidden = true
        updateScale()
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func configure(_ file: ImageFile, key: NSString, pick: Bool, thumbnail entry: ThumbnailLoader.Entry?) {
        self.file = file
        self.key = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        name.string = file.name
        applyPick(pick)
        applyThumbnail(entry)
        CATransaction.commit()
        setAccessibilityLabel(file.name)
    }

    func setThumbnail(_ entry: ThumbnailLoader.Entry?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyThumbnail(entry)
        CATransaction.commit()
    }

    func setPick(_ pick: Bool) {
        guard pick != isPick else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPick(pick)
        CATransaction.commit()
    }

    private func applyPick(_ pick: Bool) {
        isPick = pick
        flag.isHidden = !pick
        setAccessibilityValue(pick ? "Pick" : nil)
    }

    private func applyThumbnail(_ entry: ThumbnailLoader.Entry?) {
        needsThumbnail = entry == nil
        let image = entry?.image
        thumbnail.contents = image
        thumbnail.backgroundColor = image == nil ? Self.placeholder : nil
        aspect = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
        layoutLayers()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    /// Everything is centred vertically, so the same frames hold whether the layer tree is flipped or not.
    private func layoutLayers() {
        let side = Self.thumbnailSide
        let box = CGRect(x: 10, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        if let aspect {
            let width = aspect >= 1 ? side : (side * aspect).rounded()
            let height = aspect >= 1 ? (side / aspect).rounded() : side
            thumbnail.frame = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        } else {
            thumbnail.frame = box
        }
        let line = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let flagWidth: CGFloat = 20
        let textX = box.maxX + 10
        name.frame = CGRect(x: textX, y: ((bounds.height - line) / 2).rounded(),
                            width: max(bounds.width - textX - flagWidth - 8, 10), height: line)
        flag.frame = CGRect(x: bounds.width - flagWidth - 6, y: ((bounds.height - line - 2) / 2).rounded(),
                            width: flagWidth, height: line + 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for sublayer in [thumbnail, name, flag] where sublayer.contentsScale != scale { sublayer.contentsScale = scale }
    }
}

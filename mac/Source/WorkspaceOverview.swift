import AppKit

extension BoardStore {
    var showsWorkspaceOverview: Bool {
        workspaceOverviewsEnabled && board.parentID == nil && board.cards.isEmpty
    }
}

final class PagePreviewButton: NSButton {
    var subtitle: String?
    var page: Board
    unowned let store: BoardStore
    init(page: Board, store: BoardStore, target: AnyObject, action: Selector) {
        self.page = page
        self.store = store
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        identifier = .init(page.id.uuidString)
        setAccessibilityLabel("Open page \(page.name), \(page.cards.count) items")
        toolTip = "Open \(page.name) · Right-click to rename or delete"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.pasteboardSurface.setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        shape.fill()
        NSColor.pasteboardBorder.setStroke()
        shape.stroke()
        let preview = CGRect(x: 16, y: 16, width: bounds.width - 32, height: bounds.height - 84)
        NSColor.pasteboardCanvas.setFill()
        NSBezierPath(roundedRect: preview, xRadius: 6, yRadius: 6).fill()
        if let first = page.cards.first {
            let box = page.cards.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            let scale = min(
                (preview.width - 16) / max(1, box.width), (preview.height - 16) / max(1, box.height))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: preview).addClip()
            for card in page.cards.prefix(150) {
                let rect = CGRect(
                    x: preview.midX + (card.x - box.midX) * scale,
                    y: preview.midY + (card.y - box.midY) * scale, width: card.width * scale,
                    height: card.height * scale)
                if let asset = card.asset,
                    let image = store.preview(asset, pixelSize: 512, crop: card.imageCrop)
                {
                    NSImage(cgImage: image, size: .zero).draw(
                        in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                        hints: nil)
                } else {
                    let colour =
                        card.hex.flatMap(SwatchColor.init).flatMap { NSColor(cgColor: $0.color) }
                        ?? (card.text == nil
                            ? .pasteboardBorder : NSColor.pasteboardAccent.withAlphaComponent(0.12))
                    colour.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                    if let text = card.text, rect.width > 25, rect.height > 15 {
                        (String(text.prefix(90)) as NSString).draw(
                            in: rect.insetBy(dx: 4, dy: 4),
                            withAttributes: [
                                .font: NSFont.systemFont(ofSize: max(5, min(11, 18 * scale))),
                                .foregroundColor: NSColor.pasteboardInk,
                            ])
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
            image.draw(in: CGRect(x: preview.midX - 15, y: preview.midY - 18, width: 30, height: 36))
        }
        let truncation = NSMutableParagraphStyle()
        truncation.lineBreakMode = .byTruncatingTail
        (page.name as NSString).draw(
            in: CGRect(x: 18, y: bounds.height - 56, width: bounds.width - 36, height: 23),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.pasteboardInk, .paragraphStyle: truncation,
            ])
        ((subtitle ?? "\(page.cards.count) \(page.cards.count == 1 ? "item" : "items")") as NSString).draw(
            in: CGRect(x: 18, y: bounds.height - 30, width: bounds.width - 36, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.pasteboardMuted,
                .paragraphStyle: truncation,
            ])
        if window?.firstResponder === self {
            NSColor.pasteboardAccent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}

final class WorkspaceOverview: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView()
    private let document = Document()
    private let heading = NSTextField(labelWithString: "Your pages")
    private let detail = NSTextField(labelWithString: "Keep different ideas together in one workspace.")
    private let create = NSButton(title: "New Page", target: nil, action: nil)
    private let empty = NSTextField(
        wrappingLabelWithString: "A little room for your ideas.\nCreate a page, or paste to start one.")
    private let readyHeading = NSTextField(labelWithString: "Ready to post")
    private let readyDetail = NSTextField(
        labelWithString: "Images and frames you’ve marked across this workspace.")
    private let readyEmpty = NSTextField(
        wrappingLabelWithString: "Select an image or frame on a page, then right-click → Mark Ready to Post.")
    private var readyTiles: [PagePreviewButton] = []
    private var readySnapshot: [SocialPost] = []
    var openPost: ((UUID, UUID) -> Void)?
    private var tiles: [PagePreviewButton] = []
    private var pageSnapshot: [Board] = []
    private var rootID: UUID?
    private var global = false
    var openPage: ((UUID) -> Void)?
    var newPage: (() -> Void)?
    var renamePage: ((UUID) -> Void)?
    var deletePage: ((UUID) -> Void)?
    var pasteItems: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        addSubview(scroll)
        heading.font = .systemFont(ofSize: 26, weight: .semibold)
        heading.textColor = .pasteboardInk
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .pasteboardMuted
        create.target = self
        create.action = #selector(addPage(_:))
        create.bezelStyle = .rounded
        create.setAccessibilityLabel("Create a page in this workspace")
        empty.font = .systemFont(ofSize: 18)
        empty.textColor = .pasteboardMuted
        empty.alignment = .center
        readyHeading.font = .systemFont(ofSize: 26, weight: .semibold)
        readyHeading.textColor = .pasteboardInk
        readyDetail.font = .systemFont(ofSize: 14)
        readyDetail.textColor = .pasteboardMuted
        readyEmpty.font = .systemFont(ofSize: 14)
        readyEmpty.textColor = .pasteboardMuted
        for view in [heading, detail, create, empty, readyHeading, readyDetail, readyEmpty] {
            document.addSubview(view)
        }
        setAccessibilityLabel("Workspace page overview")
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(pages: [Board], store: BoardStore, globally: Bool = false) {
        let posts = globally ? store.allReadyPosts : store.readyPosts(in: store.board.id)
        guard
            global != globally || rootID != store.board.id || pageSnapshot != pages || readySnapshot != posts
        else { return }
        global = globally
        readyDetail.stringValue =
            globally
            ? "Every ready image and frame, across all your workspaces."
            : "Images and frames you’ve marked across this workspace."
        readyEmpty.stringValue =
            globally
            ? "Nothing marked yet. Select an image or frame in any workspace, then right-click → Mark Ready to Post."
            : "Select an image or frame on a page, then right-click → Mark Ready to Post."
        heading.isHidden = globally
        detail.isHidden = globally
        create.isHidden = globally
        readySnapshot = posts
        for tile in readyTiles { tile.removeFromSuperview() }
        readyTiles = []
        for (index, post) in posts.enumerated() {
            let preview = Board(name: post.title, cards: post.cards)
            let tile = PagePreviewButton(
                page: preview, store: store, target: self, action: #selector(openReady(_:)))
            tile.tag = index
            tile.subtitle =
                post.isComplete
                ? (globally
                    ? (store.workspace.boards.first { $0.id == post.boardID }.map {
                        store.workspace.path(for: $0)
                    } ?? post.pageName) : post.pageName) + " · " + post.draft.platform.title
                : "Frame needs review"
            tile.setAccessibilityLabel("Preview ready post, \(post.pageName), \(post.title)")
            tile.toolTip =
                (store.workspace.boards.first { $0.id == post.boardID }.map { store.workspace.path(for: $0) }
                    ?? post.pageName) + " · Preview post and edit caption"
            readyTiles.append(tile)
            document.addSubview(tile)
        }
        readyHeading.stringValue = posts.isEmpty ? "Ready to post" : "Ready to post · \(posts.count)"
        readyEmpty.isHidden = !posts.isEmpty
        rootID = store.board.id
        pageSnapshot = pages
        for tile in tiles { tile.removeFromSuperview() }
        tiles = []
        for page in pages {
            let tile = PagePreviewButton(page: page, store: store, target: self, action: #selector(open(_:)))
            let menu = NSMenu()
            for (title, action) in [
                ("Rename Page…", #selector(rename(_:))), ("Delete Page…", #selector(remove(_:))),
            ] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = page.id
            }
            tile.menu = menu
            tiles.append(tile)
            document.addSubview(tile)
        }
        empty.isHidden = globally || !pages.isEmpty
        needsLayout = true
    }
    func refreshImages() { for tile in tiles + readyTiles { tile.needsDisplay = true } }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = max(1, scroll.contentSize.width)
        let columns = max(1, Int((width - 48) / 270))
        let gap: CGFloat = 20
        let margin: CGFloat = 28
        let tileWidth = max(180, (width - margin * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns))
        readyHeading.frame = CGRect(x: margin, y: 28, width: width - margin * 2, height: 35)
        readyDetail.frame = CGRect(x: margin, y: 70, width: width - margin * 2, height: 22)
        readyEmpty.frame = CGRect(x: margin, y: 110, width: width - margin * 2, height: 50)
        for (index, tile) in readyTiles.enumerated() {
            tile.frame = CGRect(
                x: margin + CGFloat(index % columns) * (tileWidth + gap),
                y: 115 + CGFloat(index / columns) * 240, width: tileWidth, height: 220)
        }
        let readyRows = (readyTiles.count + columns - 1) / columns
        let pageTop: CGFloat = readyTiles.isEmpty ? 190 : 140 + CGFloat(readyRows) * 240
        heading.frame = CGRect(x: margin, y: pageTop, width: max(180, width - 210), height: 35)
        detail.frame = CGRect(x: margin, y: pageTop + 42, width: max(1, width - margin * 2), height: 22)
        create.frame = CGRect(x: width - 138, y: pageTop, width: 110, height: 32)
        for (index, tile) in tiles.enumerated() {
            tile.frame = CGRect(
                x: margin + CGFloat(index % columns) * (tileWidth + gap),
                y: pageTop + 92 + CGFloat(index / columns) * 240, width: tileWidth, height: 220)
        }
        let rows = (tiles.count + columns - 1) / columns
        let height =
            global
            ? max(bounds.height, 140 + CGFloat(max(1, readyRows)) * 240)
            : max(bounds.height, pageTop + 160 + CGFloat(rows) * 240)
        document.frame = CGRect(x: 0, y: 0, width: width, height: height)
        empty.frame = CGRect(x: margin, y: pageTop + 120, width: width - margin * 2, height: 100)
    }
    @objc private func openReady(_ sender: NSButton) {
        guard readySnapshot.indices.contains(sender.tag) else { return }
        let post = readySnapshot[sender.tag]
        openPost?(post.boardID, post.anchorID)
    }
    @objc private func addPage(_ sender: Any?) { newPage?() }
    @objc private func open(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) { openPage?(id) }
    }
    @objc private func rename(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { renamePage?(id) }
    }
    @objc private func remove(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { deletePage?(id) }
    }
    @objc func paste(_ sender: Any?) { pasteItems?() }
}

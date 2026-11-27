import AppKit

extension BoardStore {
    var showsWorkspaceOverview: Bool {
        workspaceOverviewsEnabled
            && ((board.parentID == nil && board.cards.isEmpty) || board.isFolder == true
                || !workspace.pages(in: board.id).isEmpty)
    }
}

final class PagePreviewButton: NSButton {
    var subtitle: String?
    var page: Board
    unowned let store: BoardStore
    var isFolder = false
    var childCount = 0
    var selectedForMerge = false { didSet { needsDisplay = true } }
    var showsSelection = false { didSet { needsDisplay = true } }
    private(set) var interactionModifiers: NSEvent.ModifierFlags = []
    var selectionKeyAction: ((NSEvent) -> Bool)?
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    init(page: Board, store: BoardStore, target: AnyObject, action: Selector) {
        self.page = page
        self.store = store
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        identifier = .init(page.id.uuidString)
        setAccessibilityLabel("Open board \(page.name), \(page.cards.count) items")
        toolTip = "Open \(page.name) · ⌘-click to select · Right-click to rename or delete"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(
            rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(hoverArea!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        interactionModifiers = event.modifierFlags
        defer { interactionModifiers = [] }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if selectionKeyAction?(event) == true { return }
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 {
            interactionModifiers = event.modifierFlags
            performClick(nil)
            interactionModifiers = []
        } else {
            super.keyDown(with: event)
        }
    }
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.pasteboardSurface.setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        shape.fill()
        (selectedForMerge
            ? NSColor.pasteboardAccent
            : hovering ? NSColor.pasteboardAccent.withAlphaComponent(0.4) : NSColor.pasteboardBorder.withAlphaComponent(0.75)).setStroke()
        shape.lineWidth = selectedForMerge ? 2 : 1
        shape.stroke()
        if isFolder, bounds.height < 150 {
            drawCompactFolder()
            drawKeyboardFocus()
            return
        }
        let preview = CGRect(x: 9, y: 9, width: bounds.width - 18, height: bounds.height - 77)
        NSColor.pasteboardCanvas.setFill()
        NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8).fill()
        if isFolder {
            let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .light).applying(
                .init(paletteColors: [NSColor.pasteboardAccent.withAlphaComponent(0.8)]))
            NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?.draw(
                    in: CGRect(x: preview.midX - 26, y: preview.midY - 26, width: 52, height: 44))
            let text = "\(childCount) \(childCount == 1 ? "board or folder" : "boards & folders")"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.pasteboardMuted,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: preview.midX - size.width / 2, y: preview.midY + 25),
                withAttributes: attributes)
        } else if let first = page.cards.first {
            let box = page.cards.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            let scale = min(
                (preview.width - 16) / max(1, box.width), (preview.height - 16) / max(1, box.height))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8).addClip()
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
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .light).applying(
                .init(paletteColors: [NSColor.pasteboardMuted.withAlphaComponent(0.6)]))
            NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?.draw(
                    in: CGRect(x: preview.midX - 17, y: preview.midY - 17, width: 34, height: 34))
        }
        let truncation = NSMutableParagraphStyle()
        truncation.lineBreakMode = .byTruncatingTail
        (page.name as NSString).draw(
            in: CGRect(x: 15, y: bounds.height - 51, width: bounds.width - 32, height: 23),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.pasteboardInk, .paragraphStyle: truncation,
            ])
        ((subtitle ?? "\(page.cards.count) \(page.cards.count == 1 ? "item" : "items")") as NSString).draw(
            in: CGRect(x: 15, y: bounds.height - 28, width: bounds.width - 32, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.pasteboardMuted,
                .paragraphStyle: truncation,
            ])
        if showsSelection && !isFolder {
            let circle = CGRect(x: bounds.width - 39, y: 21, width: 20, height: 20)
            (selectedForMerge ? NSColor.pasteboardAccent : NSColor.pasteboardSurface).setFill()
            NSBezierPath(ovalIn: circle).fill()
            (selectedForMerge ? NSColor.pasteboardAccent : NSColor.pasteboardBorder).setStroke()
            NSBezierPath(ovalIn: circle).stroke()
            if selectedForMerge {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: circle.minX + 5, y: circle.midY))
                path.line(to: CGPoint(x: circle.minX + 9, y: circle.midY + 4))
                path.line(to: CGPoint(x: circle.minX + 15, y: circle.minY + 6))
                path.lineWidth = 1.7
                path.lineCapStyle = .round
                NSColor.white.setStroke()
                path.stroke()
            }
        }
        drawKeyboardFocus()
    }
    private func drawKeyboardFocus() {
        if window?.firstResponder === self {
            NSColor.pasteboardAccent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
    private func drawCompactFolder() {
        let iconRect = CGRect(x: 16, y: bounds.midY - 22, width: 44, height: 44)
        NSColor.pasteboardAccent.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 10, yRadius: 10).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
            .applying(.init(paletteColors: [NSColor.pasteboardAccent.withAlphaComponent(0.8)]))
        NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.draw(in: iconRect.insetBy(dx: 10, dy: 10))
        let truncation = NSMutableParagraphStyle()
        truncation.lineBreakMode = .byTruncatingTail
        (page.name as NSString).draw(
            in: CGRect(x: 74, y: bounds.midY - 19, width: bounds.width - 105, height: 21),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.pasteboardInk, .paragraphStyle: truncation,
            ])
        let count = childCount == 0 ? "Empty folder" : "\(childCount) \(childCount == 1 ? "board or folder" : "boards & folders")"
        (count as NSString).draw(
            in: CGRect(x: 74, y: bounds.midY + 4, width: bounds.width - 105, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.pasteboardMuted,
                .paragraphStyle: truncation,
            ])
        let arrow = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            .applying(.init(paletteColors: [NSColor.pasteboardMuted.withAlphaComponent(0.6)]))
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(arrow)?.draw(
                in: CGRect(x: bounds.width - 24, y: bounds.midY - 5, width: 8, height: 10))
    }
}

final class WorkspaceOverview: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView()
    private let document = Document()
    private let heading = NSTextField(labelWithString: "Boards & folders")
    private let detail = NSTextField(
        labelWithString: "A place for each idea. Bring boards together when you’re ready.")
    private let create = PasteboardToolbarButton(title: "New Board", target: nil, action: nil)
    private let createFolder = PasteboardToolbarButton(title: "New Folder", target: nil, action: nil)
    private let select = PasteboardToolbarButton(title: "Select boards", target: nil, action: nil)
    private let merge = PasteboardToolbarButton(title: "Merge Boards", target: nil, action: nil)
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let selectionHint = NSTextField(
        labelWithString: "Select two or more boards to merge into sections.")
    private let empty = NSTextField(
        wrappingLabelWithString:
            "A little room for your ideas.\nCreate a board or folder, or paste to start a board.")
    private let readyHeading = NSTextField(labelWithString: "Ready to post")
    private let readyDetail = NSTextField(
        labelWithString: "Images and frames you’ve marked across this workspace.")
    private let readyEmpty = NSTextField(
        wrappingLabelWithString: "Select an image or frame on a board, then right-click → Mark Ready to Post."
    )
    private var readyTiles: [PagePreviewButton] = []
    private var readySnapshot: [SocialPost] = []
    private var readyPaths: [String] = []
    var openPost: ((UUID, UUID) -> Void)?
    private var tiles: [PagePreviewButton] = []
    private var pageSnapshot: [Board] = []
    private var childCounts: [UUID: Int] = [:]
    private var rootID: UUID?
    private var parentID: UUID?
    private var global = false
    private(set) var selecting = false
    private(set) var selectedPageIDs = Set<UUID>()
    private(set) var selectionAnchor: UUID?
    var openPage: ((UUID) -> Void)?
    var newPage: (() -> Void)?
    var newFolder: (() -> Void)?
    var mergePages: ((Set<UUID>) -> Void)?
    var selectionChanged: ((Set<UUID>, Bool) -> Void)?
    var goBack: (() -> Void)?
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
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        heading.textColor = .pasteboardInk
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .pasteboardMuted
        detail.lineBreakMode = .byTruncatingTail
        selectionHint.font = .systemFont(ofSize: 12)
        selectionHint.textColor = .pasteboardMuted
        selectionHint.lineBreakMode = .byTruncatingTail
        for (button, action) in [
            (create, #selector(addPage(_:))), (createFolder, #selector(addFolder(_:))),
            (select, #selector(toggleSelection(_:))), (merge, #selector(mergeSelection(_:))),
            (back, #selector(goToParent(_:))),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        create.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        createFolder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        select.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        merge.primary = true
        create.setAccessibilityLabel("Create a board in this folder")
        createFolder.setAccessibilityLabel("Create a folder")
        merge.toolTip = "Combine selected boards into one board, with a named section for each design"
        select.toolTip = "Choose boards to combine · ⌘-click also selects boards"
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.imagePosition = .imageLeading
        back.isBordered = false
        empty.font = .systemFont(ofSize: 17)
        empty.textColor = .pasteboardMuted
        empty.alignment = .center
        readyHeading.font = .systemFont(ofSize: 21, weight: .semibold)
        readyHeading.textColor = .pasteboardInk
        readyDetail.font = .systemFont(ofSize: 12)
        readyDetail.textColor = .pasteboardMuted
        readyDetail.lineBreakMode = .byTruncatingTail
        readyEmpty.font = .systemFont(ofSize: 13)
        readyEmpty.textColor = .pasteboardMuted
        for view in [
            heading, detail, create, createFolder, select, merge, back, selectionHint,
            empty, readyHeading, readyDetail, readyEmpty,
        ] {
            document.addSubview(view)
        }
        setAccessibilityLabel("Board and folder overview")
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(pages: [Board], store: BoardStore, globally: Bool = false) {
        let posts = globally ? store.allReadyPosts : store.readyPosts(in: store.board.id)
        let paths = posts.map { post in
            store.workspace.boards.first { $0.id == post.boardID }.map { store.workspace.path(for: $0) }
                ?? post.pageName
        }
        let counts = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.id, store.workspace.pages(in: $0.id).count) })
        guard
            global != globally || rootID != store.board.id || pageSnapshot != pages
                || readySnapshot != posts || readyPaths != paths || childCounts != counts
                || parentID != store.board.parentID
        else { return }
        if rootID != store.board.id || global != globally {
            selecting = false
            selectedPageIDs.removeAll()
            selectionAnchor = nil
            scroll.contentView.scroll(to: .zero)
        }
        global = globally
        parentID = store.board.parentID
        childCounts = counts
        readyDetail.stringValue =
            globally
            ? "Every ready image and frame, across all your workspaces."
            : "Marked images and frames from this \(parentID == nil ? "workspace" : "folder")."
        readyEmpty.stringValue =
            globally
            ? "Nothing marked yet. Select an image or frame in any workspace, then right-click → Mark Ready to Post."
            : "Mark an image or frame on a board to collect it here."
        heading.isHidden = globally
        detail.isHidden = globally
        create.isHidden = globally
        createFolder.isHidden = globally
        back.isHidden = globally || parentID == nil
        readySnapshot = posts
        readyPaths = paths
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
        let folderCount = pages.filter { $0.isFolder == true || (counts[$0.id] ?? 0) > 0 }.count
        let boardCount = pages.count - folderCount
        detail.stringValue = pages.isEmpty
            ? "Create a board or folder to make a start."
            : "\(boardCount) \(boardCount == 1 ? "board" : "boards") · \(folderCount) \(folderCount == 1 ? "folder" : "folders")"
        for tile in tiles { tile.removeFromSuperview() }
        tiles = []
        for page in pages {
            let tile = PagePreviewButton(page: page, store: store, target: self, action: #selector(open(_:)))
            tile.selectionKeyAction = { [weak self] in self?.handleSelectionKey($0) ?? false }
            tile.childCount = counts[page.id] ?? 0
            tile.isFolder = page.isFolder == true || tile.childCount > 0
            if tile.isFolder {
                tile.subtitle = "Folder"
                tile.toolTip = "Open \(page.name) · Right-click to rename or delete"
            } else if let sections = page.sections, !sections.isEmpty {
                tile.subtitle = "\(sections.count) sections · \(page.cards.count) items"
            }
            let menu = NSMenu()
            if !tile.isFolder {
                let item = menu.addItem(
                    withTitle: "Select for Merge", action: #selector(selectForMerge(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = page.id
                menu.addItem(.separator())
            }
            let kind = tile.isFolder ? "Folder" : "Board"
            for (title, action) in [
                ("Rename \(kind)…", #selector(rename(_:))), ("Delete \(kind)…", #selector(remove(_:))),
            ] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = page.id
            }
            tile.menu = menu
            tiles.append(tile)
            document.addSubview(tile)
        }
        selectedPageIDs.formIntersection(eligiblePageIDs)
        if let anchor = selectionAnchor, !eligiblePageIDs.contains(anchor) { selectionAnchor = nil }
        empty.isHidden = globally || !pages.isEmpty
        updateSelection()
        needsLayout = true
    }
    private var eligiblePageIDs: Set<UUID> { Set(tiles.filter { !$0.isFolder }.map { $0.page.id }) }
    private func updateSelection() {
        select.isHidden = global || eligiblePageIDs.isEmpty
        select.title = selecting ? "Done" : "Select boards"
        select.image = selecting ? nil : NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        merge.isHidden = global || !selecting
        merge.title = selectedPageIDs.isEmpty ? "Merge Boards" : "Merge \(selectedPageIDs.count) Boards"
        merge.isEnabled = selectedPageIDs.count >= 2
        merge.primary = merge.isEnabled
        selectionHint.isHidden = global || !selecting
        selectionHint.stringValue =
            selectedPageIDs.isEmpty
            ? "Select two or more boards. Each becomes a named section."
            : "\(selectedPageIDs.count) selected · Each board becomes a named section."
        detail.isHidden = global || selecting
        for tile in tiles {
            tile.selectedForMerge = selectedPageIDs.contains(tile.page.id)
            tile.showsSelection = selecting
            tile.setAccessibilityLabel(
                tile.isFolder
                    ? "Open folder \(tile.page.name), \(tile.childCount) boards and folders"
                    : "\(selectedPageIDs.contains(tile.page.id) ? "Selected" : selecting ? "Select" : "Open") board \(tile.page.name), \(tile.page.cards.count) items"
            )
            tile.setAccessibilityValue(selectedPageIDs.contains(tile.page.id) ? "Selected" : "")
        }
        needsLayout = true
    }
    // External navigation and the sidebar share this selection without recursive notifications.
    func setMergeSelection(_ ids: Set<UUID>, selecting: Bool, anchor: UUID? = nil) {
        self.selecting = selecting && !global
        selectedPageIDs = self.selecting ? ids.intersection(eligiblePageIDs) : []
        if let anchor, selectedPageIDs.contains(anchor) { selectionAnchor = anchor }
        if let anchor = selectionAnchor, !selectedPageIDs.contains(anchor) { selectionAnchor = nil }
        if self.selecting && selectionAnchor == nil {
            selectionAnchor = tiles.first { selectedPageIDs.contains($0.page.id) }?.page.id
        }
        updateSelection()
    }
    // Shared by pointer and keyboard actions so range selection has one anchor.
    func activatePage(_ id: UUID, modifiers: NSEvent.ModifierFlags = []) {
        guard let tile = tiles.first(where: { $0.page.id == id }) else { return }
        let selectingNow = selecting || modifiers.contains(.command) || modifiers.contains(.shift)
        guard selectingNow else {
            openPage?(id)
            return
        }
        guard !tile.isFolder else { return }
        selecting = true
        if modifiers.contains(.shift), let anchor = selectionAnchor,
            let start = tiles.firstIndex(where: { $0.page.id == anchor }),
            let end = tiles.firstIndex(where: { $0.page.id == id })
        {
            let range = Set(
                tiles[min(start, end)...max(start, end)].filter { !$0.isFolder }.map { $0.page.id })
            if modifiers.contains(.command) { selectedPageIDs.formUnion(range) }
            else { selectedPageIDs = range }
        } else {
            if !selectedPageIDs.insert(id).inserted { selectedPageIDs.remove(id) }
            selectionAnchor = id
        }
        updateSelection()
        selectionChanged?(selectedPageIDs, selecting)
    }
    func refreshImages() { for tile in tiles + readyTiles { tile.needsDisplay = true } }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = max(1, scroll.contentSize.width)
        let gap: CGFloat = 18
        let margin: CGFloat = width < 700 ? 24 : 32
        let columns = max(1, Int((width - margin * 2 + gap) / 258))
        let tileWidth = max(160, (width - margin * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let tileHeight: CGFloat = 218
        let rowHeight = tileHeight + gap
        let top: CGFloat = !back.isHidden ? 54 : 28
        back.frame = CGRect(x: margin - 5, y: 14, width: 70, height: 26)
        let folderFirst = !global && parentID != nil
        let readyRows = (readyTiles.count + columns - 1) / columns
        let readyHeight: CGFloat = readyTiles.isEmpty
            ? (global ? 164 : 108) : 86 + CGFloat(readyRows) * rowHeight
        // Keep an inner folder's boards and selection controls above its ready posts.
        let pageTop = folderFirst ? top : top + readyHeight
        heading.frame = CGRect(x: margin, y: pageTop, width: width - margin * 2, height: 29)
        detail.frame = CGRect(x: margin, y: pageTop + 33, width: width - margin * 2, height: 20)
        selectionHint.frame = detail.frame
        let toolbarY = pageTop + 68
        create.frame = CGRect(x: margin, y: toolbarY, width: 110, height: 32)
        createFolder.frame = CGRect(x: margin + 118, y: toolbarY, width: 116, height: 32)
        let selectWidth: CGFloat = selecting ? 64 : 120
        select.frame = CGRect(x: width - margin - selectWidth, y: toolbarY, width: selectWidth, height: 32)
        let compactSelection = selecting && width < 760
        merge.frame = CGRect(
            x: compactSelection ? margin : width - margin - selectWidth - 10 - 145,
            y: toolbarY + (compactSelection ? 42 : 0), width: 145, height: 32)
        let tileTop = toolbarY + (compactSelection ? 90 : 48)
        let boards = tiles.filter { !$0.isFolder }
        let folders = tiles.filter { $0.isFolder }
        for (index, tile) in boards.enumerated() {
            tile.frame = CGRect(
                x: margin + CGFloat(index % columns) * (tileWidth + gap),
                y: tileTop + CGFloat(index / columns) * rowHeight, width: tileWidth, height: tileHeight)
        }
        let boardRows = (boards.count + columns - 1) / columns
        // Folders are navigation, so give them a compact, recognizable row instead
        // of the large empty image preview used for a board.
        let folderTop = tileTop + CGFloat(boardRows) * rowHeight + (boards.isEmpty ? 0 : 4)
        for (index, tile) in folders.enumerated() {
            tile.frame = CGRect(
                x: margin + CGFloat(index % columns) * (tileWidth + gap),
                y: folderTop + CGFloat(index / columns) * 94, width: tileWidth, height: 80)
        }
        let folderRows = (folders.count + columns - 1) / columns
        let pageBottom = tiles.isEmpty ? tileTop + 180
            : folders.isEmpty ? tileTop + CGFloat(boardRows) * rowHeight
            : folderTop + CGFloat(folderRows) * 94
        empty.frame = CGRect(x: margin, y: tileTop + 50, width: width - margin * 2, height: 100)
        let readyTop = folderFirst ? pageBottom + 28 : top
        readyHeading.font = .systemFont(ofSize: global ? 23 : readyTiles.isEmpty ? 16 : 21, weight: .semibold)
        readyHeading.frame = CGRect(x: margin, y: readyTop, width: width - margin * 2, height: 29)
        readyDetail.isHidden = !global && readyTiles.isEmpty
        readyDetail.frame = CGRect(x: margin, y: readyTop + 33, width: width - margin * 2, height: 20)
        readyEmpty.frame = CGRect(
            x: margin, y: readyTop + (global ? 74 : 34), width: width - margin * 2,
            height: global ? 60 : 36)
        for (index, tile) in readyTiles.enumerated() {
            tile.frame = CGRect(
                x: margin + CGFloat(index % columns) * (tileWidth + gap),
                y: readyTop + 72 + CGFloat(index / columns) * rowHeight, width: tileWidth, height: tileHeight)
        }
        let contentBottom = global || folderFirst ? readyTop + readyHeight : pageBottom + 28
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(bounds.height, contentBottom))
    }

    override func keyDown(with event: NSEvent) {
        if !handleSelectionKey(event) { super.keyDown(with: event) }
    }
    private func handleSelectionKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, selecting {
            toggleSelection(nil)
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a",
            !global
        {
            selectAll(nil)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76, selecting, selectedPageIDs.count >= 2 {
            mergeSelection(nil)
            return true
        }
        return false
    }
    override func selectAll(_ sender: Any?) {
        guard !global else { return }
        selecting = true
        selectedPageIDs = eligiblePageIDs
        updateSelection()
        selectionChanged?(selectedPageIDs, selecting)
    }
    @objc private func openReady(_ sender: NSButton) {
        guard readySnapshot.indices.contains(sender.tag) else { return }
        let post = readySnapshot[sender.tag]
        openPost?(post.boardID, post.anchorID)
    }
    @objc private func addPage(_ sender: Any?) { newPage?() }
    @objc private func addFolder(_ sender: Any?) { newFolder?() }
    @objc private func goToParent(_ sender: Any?) { goBack?() }
    @objc private func toggleSelection(_ sender: Any?) {
        selecting.toggle()
        selectedPageIDs.removeAll()
        selectionAnchor = nil
        updateSelection()
        selectionChanged?(selectedPageIDs, selecting)
        window?.makeFirstResponder(self)
    }
    @objc private func mergeSelection(_ sender: Any?) {
        let ids = selectedPageIDs.intersection(eligiblePageIDs)
        guard ids.count >= 2 else { return }
        mergePages?(ids)
    }
    @objc private func selectForMerge(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        activatePage(id, modifiers: .command)
        window?.makeFirstResponder(self)
    }
    @objc private func open(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        activatePage(id, modifiers: (sender as? PagePreviewButton)?.interactionModifiers ?? [])
    }
    @objc private func rename(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { renamePage?(id) }
    }
    @objc private func remove(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { deletePage?(id) }
    }
    @objc func paste(_ sender: Any?) { pasteItems?() }
}

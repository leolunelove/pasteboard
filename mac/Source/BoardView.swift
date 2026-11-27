import AppKit
import QuartzCore
import UniformTypeIdentifiers

final class BoardView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let store: BoardStore
    var selection = Set<UUID>() {
        didSet { selection = store.board.expandedSelection(selection) }
    }
    var onViewport: (() -> Void)?
    var onRequestPage: (() -> Void)?
    var onOpenSocialPost: ((UUID, UUID) -> Void)?
    var onPlayVideo: ((Card) -> Void)?
    var onSelection: (() -> Void)?
    var onSidebarHover: ((CGPoint, Set<UUID>) -> UUID?)?
    var onSidebarDrop: ((UUID, Set<UUID>) -> Bool)?
    var onSidebarDragEnded: (() -> Void)?
    private var overSidebar = false
    private var dragBoardID: UUID?
    private var lastBoard: UUID?
    private var dragStart = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var original: [Card] = []
    private var dragOrigins: [UUID: Card] = [:]
    private var dragBounds: CGRect?
    private var snapTargets: [SnapTarget] = []
    private var snapSession = SnapSession()
    private(set) var alignmentGuides: [AlignmentGuide] = []
    private(set) var spacingGuides: [SpacingGuide] = []
    var snappingEnabled = true {
        didSet {
            snapSession.reset()
            alignmentGuides = []
            spacingGuides = []
            if dragging && dragEngaged { updateDrag(at: lastPoint, modifiers: NSEvent.modifierFlags) }
            needsDisplay = true
        }
    }
    private let scene = CanvasScene()
    private let grid = BoardGrid()
    private(set) lazy var minimap = BoardMinimap(canvas: self)
    var minimapEnabled = true { didSet { updateMinimap() } }
    private var tracking: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private var contextPoint: CGPoint?
    private var contextCardID: UUID?
    private(set) var cropOverlay: CropOverlay?
    var isCropping: Bool { cropOverlay != nil }
    private var dragEngaged = false
    private var pendingToggle: UUID?
    private var zoomTimer: Timer?
    private var zoomTarget: CGFloat?
    private var pasteInFlight = 0
    private var pendingImageCount = 0
    private let importIndicator = ImportIndicator()
    private var deferredImports: [() -> Void] = []
    var hasPendingImports: Bool { pasteInFlight > 0 }
    private var resizing: UUID?
    private struct GroupResize {
        let ids: Set<UUID>
        let anchor: CGPoint
        let corner: CGPoint
    }
    private var resizingGroup: GroupResize?
    private var dragging = false
    private var panning = false
    private var marquee: CGRect?
    private var baseSelection = Set<UUID>()
    private var spaceDown = false
    private var dropHighlight = false
    var hasPointerInteraction: Bool {
        dragging || panning || resizing != nil || resizingGroup != nil || marquee != nil
    }
    private var editor: NSTextView?
    private var editingID: UUID?
    private var editingWasNew = false
    private var editingOriginal: Card?
    private let textHistory = UndoManager()
    private let internalType = NSPasteboard.PasteboardType("fun.leolune.gather.cards")
    private let imageTypes: [NSPasteboard.PasteboardType] =
        SVGImage.pasteboardTypes + [
            .png, .init("public.jpeg"), .init("public.heic"), .init("com.compuserve.gif"),
            .init("org.webmproject.webp"), .tiff,
        ]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { store.history }
    var zoom: CGFloat { store.board.zoom }
    var offset: CGPoint { CGPoint(x: store.board.offsetX, y: store.board.offsetY) }
    var worldCenter: CGPoint { world(CGPoint(x: bounds.midX, y: bounds.midY)) }

    init(store: BoardStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(scene.root)
        store.imageReady = { [weak self] in self?.needsDisplay = true }
        registerForDraggedTypes(
            [.fileURL, .init("public.url"), .string, .html] + VideoMedia.pasteboardTypes + imageTypes)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            "Infinite board. Tab and Shift Tab cycle through items. Paste with Command V. Add a note with T or a colour swatch with S. Hold Space and drag to pan."
        )
        addSubview(minimap)
        addSubview(importIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        minimap.needsDisplay = true
    }

    override func layout() {
        super.layout()
        minimap.frame = CGRect(
            x: max(12, bounds.width - 224), y: max(12, bounds.height - 174), width: 208, height: 158)
        importIndicator.frame = CGRect(
            x: max(12, bounds.midX - 100), y: 18, width: max(0, min(200, bounds.width - 24)), height: 38)
        updateMinimap()
    }
    func updateMinimap() {
        minimap.isHidden =
            !minimapEnabled || store.board.cards.isEmpty || isCropping || editor != nil || bounds.width < 300
            || bounds.height < 230
        minimap.needsDisplay = true
    }
    var canNavigateMinimap: Bool {
        !isCropping && !dragging && !panning && resizing == nil && resizingGroup == nil && marquee == nil
    }
    func navigateMinimap(to point: CGPoint) {
        guard canNavigateMinimap, point.x.isFinite, point.y.isFinite else { return }
        stopZoomAnimation()
        finishEditing()
        store.board.offsetX = bounds.midX - point.x * zoom
        store.board.offsetY = bounds.midY - point.y * zoom
        store.scheduleSave()
        needsDisplay = true
        updateMinimap()
        onViewport?()
    }

    func refresh() {
        if let crop = cropOverlay,
            crop.boardID != store.board.id
                || store.board.cards.first(where: { $0.id == crop.original.id }) != crop.original
        {
            cancelCropping(nil)
        }
        if lastBoard != store.board.id {
            lastBoard = store.board.id
            minimap.cancelNavigation()
            cancelPointerInteraction()
            stopZoomAnimation()
            snapSession.reset()
            alignmentGuides = []
            spacingGuides = []
            finishEditing()
            selection.removeAll()
        }
        selection.formIntersection(Set(store.board.cards.map(\.id)))
        needsDisplay = true
        onViewport?()
        onSelection?()
        updateMinimap()
    }

    func world(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom) }
    func screen(_ r: CGRect) -> CGRect {
        CGRect(
            x: r.minX * zoom + offset.x, y: r.minY * zoom + offset.y, width: r.width * zoom,
            height: r.height * zoom)
    }
    func hit(_ point: CGPoint) -> Card? {
        let p = world(point)
        let cards = store.board.cards
        if let direct = cards.reversed().first(where: { $0.rect.contains(p) }) { return direct }
        let groups = store.board.groupBounds(for: Set(cards.map(\.id)))
        return cards.reversed().first { $0.groupID.flatMap { groups[$0]?.contains(p) } == true }
    }
    func handle(_ card: Card) -> CGRect {
        let r = screen(card.rect)
        return CGRect(x: r.maxX - 7, y: r.maxY - 7, width: 14, height: 14)
    }
    private func groupResize(at point: CGPoint) -> GroupResize? {
        for (group, rect) in store.board.groupBounds(for: selection) {
            guard
                !store.board.cards.contains(where: {
                    $0.groupID == group && store.board.lockedIDs.contains($0.id)
                })
            else { continue }
            let outline = screen(rect).insetBy(dx: -9, dy: -9)
            for corner in GroupCorner.allCases {
                let location = corner.point(in: outline)
                if CGRect(x: location.x - 11, y: location.y - 11, width: 22, height: 22).contains(point) {
                    return GroupResize(
                        ids: Set(store.board.cards.filter { $0.groupID == group }.map(\.id)),
                        anchor: corner.opposite.point(in: rect), corner: corner.point(in: rect))
                }
            }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        contextPoint = nil
        if spaceDown {
            NSCursor.openHand.set()
        } else if groupResize(at: point) != nil {
            NSCursor.crosshair.set()
        } else if selection.count == 1,
            let card = store.board.cards.first(where: {
                selection.contains($0.id) && !store.board.lockedIDs.contains($0.id)
            }), handle(card).insetBy(dx: -4, dy: -4).contains(point)
        {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }
    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        NSCursor.arrow.set()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        updateMinimap()
        NSColor.pasteboardCanvas.setFill()
        bounds.fill()
        let spacing = 24 * zoom * (zoom < 0.4 ? 4 : (zoom < 0.7 ? 2 : 1))
        if let context = NSGraphicsContext.current?.cgContext {
            grid.draw(in: context, bounds: bounds, spacing: spacing, offset: offset)
        }
        if store.board.cards.isEmpty { drawWelcome() }
        let visible = CGRect(
            origin: world(.zero), size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
        ).insetBy(dx: -200 / zoom, dy: -200 / zoom)
        scene.update(
            cards: store.board.cards.filter {
                $0.rect.intersects(visible) && $0.id != cropOverlay?.original.id
            }, selection: isCropping ? [] : selection,
            groups: isCropping ? [:] : store.board.groupBounds(for: selection), guides: alignmentGuides,
            spacingGuides: spacingGuides, editing: editingID, zoom: zoom, offset: offset, store: store,
            color: noteColor, backingScale: window?.backingScaleFactor ?? 2, appearance: effectiveAppearance)
        cropOverlay?.needsDisplay = true
        if let marquee {
            NSColor.pasteboardAccent.withAlphaComponent(0.08).setFill()
            marquee.fill()
            NSColor.pasteboardAccent.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: marquee).stroke()
        }
        if dropHighlight {
            NSColor.pasteboardAccent.setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: 14, yRadius: 14)
            p.lineWidth = 3
            p.stroke()
        }
    }

    func noteColor(_ tone: Int) -> NSColor {
        [NSColor.white, NSColor(hex: 0xFCF0C9), NSColor(hex: 0xDFEBDD), NSColor(hex: 0xF4DFD7)][
            max(0, min(3, tone))]
    }

    private func drawWelcome() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY - 35)
        if let context = NSGraphicsContext.current?.cgContext {
            PasteboardArtwork.draw(
                in: context, rect: CGRect(x: center.x - 48, y: center.y - 112, width: 96, height: 96))
        }
        centered(
            "A place to lay your ideas out.", y: center.y + 5,
            font: .systemFont(ofSize: 26, weight: .semibold), color: .pasteboardInk)
        centered(
            "Images, notes, colours. Bring them together.", y: center.y + 47, font: .systemFont(ofSize: 14),
            color: .pasteboardMuted)
        let pill = CGRect(x: center.x - 113, y: center.y + 91, width: 226, height: 42)
        NSColor.pasteboardAccent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        centered(
            "Paste something    ⌘V", y: center.y + 103, font: .systemFont(ofSize: 13, weight: .medium),
            color: .white)
        centered(
            "or drop files here · double-click to add a note", y: center.y + 155,
            font: .systemFont(ofSize: 12), color: .pasteboardMuted)
    }

    private func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        stopZoomAnimation()
        contextPoint = nil
        contextCardID = nil
        let point = convert(event.locationInWindow, from: nil)
        if let editor, editor.frame.contains(point) { return }
        finishEditing()
        window?.makeFirstResponder(self)
        dragStart = point
        lastPoint = point
        original = store.board.cards
        dragEngaged = false
        pendingToggle = nil
        dragBoardID = store.board.id
        overSidebar = false
        snapSession.reset()
        alignmentGuides = []
        spacingGuides = []
        dragBounds = nil
        snapTargets = []
        if spaceDown || event.buttonNumber == 2 {
            panning = true
            NSCursor.closedHand.set()
            return
        }
        if let resize = groupResize(at: point) {
            selection = resize.ids
            resizingGroup = resize
            needsDisplay = true
            onSelection?()
            return
        }
        if selection.count == 1,
            let selected = store.board.cards.first(where: {
                selection.contains($0.id) && !store.board.lockedIDs.contains($0.id)
            }), handle(selected).insetBy(dx: -4, dy: -4).contains(point)
        {
            resizing = selected.id
            return
        }
        if let card = hit(point) {
            if event.clickCount == 2, card.hex != nil, card.rect.contains(world(point)) {
                showSwatchEditor(card: card)
                return
            }
            if event.clickCount == 2, card.asset != nil, !card.isVideo, card.rect.contains(world(point)) {
                beginCropping(card.id)
                return
            }
            if card.isVideo && (event.clickCount == 2 || videoPlayRect(card).contains(point)) {
                selection = [card.id]
                onSelection?()
                needsDisplay = true
                onPlayVideo?(card)
                return
            }
            if event.clickCount == 2, card.text != nil, card.rect.contains(world(point)) {
                startEditing(card.id)
                return
            }
            if event.modifierFlags.contains(.shift) {
                if selection.contains(card.id) { pendingToggle = card.id } else { selection.insert(card.id) }
            } else if !selection.contains(card.id) {
                selection = [card.id]
            }
            if store.board.lockedIDs.contains(card.id) {
                needsDisplay = true
                onSelection?()
                store.status?("Locked · ⇧⌘L to unlock")
                return
            }
            dragging = true
            let movable = selection.subtracting(store.board.lockedIDs)
            dragOrigins = Dictionary(
                uniqueKeysWithValues: original.filter { movable.contains($0.id) }.map { ($0.id, $0) })
            dragBounds = original.filter { movable.contains($0.id) }.reduce(nil as CGRect?) {
                $0?.union($1.rect) ?? $1.rect
            }
            let nearby = CGRect(
                origin: world(.zero), size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
            ).insetBy(dx: -200 / zoom, dy: -200 / zoom)
            snapTargets = SnapTarget.objects(in: original, excluding: movable).filter {
                $0.rect.intersects(nearby)
            }
        } else if event.clickCount == 2 {
            addNote(at: world(point))
            return
        } else {
            if store.board.cards.isEmpty {
                let pill = CGRect(x: bounds.midX - 113, y: bounds.midY + 56, width: 226, height: 42)
                if pill.contains(point) {
                    paste(nil)
                    return
                }
            }
            baseSelection = event.modifierFlags.contains(.shift) ? selection : []
            selection = baseSelection
            marquee = CGRect(origin: point, size: .zero)
        }
        needsDisplay = true
        onSelection?()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if panning {
            store.board.offsetX += point.x - lastPoint.x
            store.board.offsetY += point.y - lastPoint.y
            lastPoint = point
            onViewport?()
        } else if let resize = resizingGroup {
            let diagonal = CGPoint(x: resize.corner.x - resize.anchor.x, y: resize.corner.y - resize.anchor.y)
            let delta = CGPoint(x: (point.x - dragStart.x) / zoom, y: (point.y - dragStart.y) / zoom)
            let factor =
                1 + (delta.x * diagonal.x + delta.y * diagonal.y)
                / (diagonal.x * diagonal.x + diagonal.y * diagonal.y)
            store.board.cards = Card.scaled(original, ids: resize.ids, around: resize.anchor, by: factor)
        } else if let id = resizing, let initial = original.first(where: { $0.id == id }),
            let i = store.board.cards.firstIndex(where: { $0.id == id })
        {
            let minimumWidth = initial.text == nil ? 80 : max(80, 80 * initial.renderScale)
            let requested = max(minimumWidth, initial.width + (point.x - dragStart.x) / zoom)
            let maximum =
                initial.crop == nil
                ? 99_999
                : min(
                    99_999 * initial.imageCrop.width,
                    99_999 * initial.imageCrop.height * initial.width / initial.height)
            let width = min(maximum, requested)
            store.board.cards[i].width = width
            store.board.cards[i].height =
                initial.asset != nil
                ? width * initial.height / initial.width
                : max(70 * initial.renderScale, initial.height + (point.y - dragStart.y) / zoom)
        } else if dragging {
            if !dragEngaged && hypot(point.x - dragStart.x, point.y - dragStart.y) < 3 { return }
            dragEngaged = true
            NSCursor.closedHand.set()
            if point.x < 0, onSidebarHover != nil {
                if !overSidebar {
                    restoreDragPreview()
                    store.scheduleSave()
                }
                overSidebar = true
                alignmentGuides = []
                spacingGuides = []
                _ = onSidebarHover?(event.locationInWindow, selection)
                needsDisplay = true
                return
            }
            if overSidebar {
                overSidebar = false
                onSidebarDragEnded?()
            }
            lastPoint = point
            updateDrag(at: point, modifiers: event.modifierFlags)
        } else if marquee != nil {
            let box = CGRect(
                x: min(dragStart.x, point.x), y: min(dragStart.y, point.y), width: abs(point.x - dragStart.x),
                height: abs(point.y - dragStart.y))
            marquee = box
            selection = baseSelection.union(
                store.board.cards.filter { screen($0.rect).intersects(box) }.map(\.id))
            onSelection?()
        }
        needsDisplay = true
    }

    private func updateDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        var delta = CGPoint(x: (point.x - dragStart.x) / zoom, y: (point.y - dragStart.y) / zoom)
        var xEnabled = true
        var yEnabled = true
        if modifiers.contains(.shift) {
            if abs(delta.x) > abs(delta.y) {
                delta.y = 0
                yEnabled = false
            } else {
                delta.x = 0
                xEnabled = false
            }
        }
        if snappingEnabled && !modifiers.contains(.option), let dragBounds {
            let result = snapSession.snap(
                dragBounds.offsetBy(dx: delta.x, dy: delta.y), to: snapTargets, zoom: zoom,
                xEnabled: xEnabled, yEnabled: yEnabled)
            delta = CGPoint(x: result.rect.minX - dragBounds.minX, y: result.rect.minY - dragBounds.minY)
            alignmentGuides = result.guides
            spacingGuides = result.spacingGuides
        } else {
            snapSession.reset()
            alignmentGuides = []
            spacingGuides = []
        }
        var cards = store.board.cards
        for i in cards.indices {
            if let initial = dragOrigins[cards[i].id] {
                cards[i].x = initial.x + delta.x
                cards[i].y = initial.y + delta.y
            }
        }
        store.board.cards = cards
    }
    override func flagsChanged(with event: NSEvent) {
        if dragging && dragEngaged && !overSidebar {
            updateDrag(at: lastPoint, modifiers: event.modifierFlags)
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragging && dragEngaged && point.x < 0 && onSidebarHover != nil {
            let target = onSidebarHover?(event.locationInWindow, selection)
            let ids = selection
            let sameBoard = dragBoardID == store.board.id
            restoreDragPreview()
            dragging = false
            dragEngaged = false
            overSidebar = false
            pendingToggle = nil
            dragOrigins.removeAll()
            alignmentGuides = []
            spacingGuides = []
            snapSession.reset()
            snapTargets = []
            dragBounds = nil
            onSidebarDragEnded?()
            NSCursor.arrow.set()
            needsDisplay = true
            if !sameBoard || target == nil || onSidebarDrop?(target!, ids) != true {
                store.scheduleSave()
                store.status?("Move cancelled")
            }
            flushDeferredImports()
            return
        }
        overSidebar = false
        onSidebarDragEnded?()
        alignmentGuides = []
        spacingGuides = []
        snapSession.reset()
        snapTargets = []
        dragBounds = nil
        if !dragEngaged, let pendingToggle {
            selection.subtract(store.board.expandedSelection([pendingToggle]))
            onSelection?()
        }
        pendingToggle = nil
        if (dragging && dragEngaged) || resizing != nil || resizingGroup != nil {
            store.commitDrag(
                from: original,
                name: resizingGroup != nil ? "Resize Group" : resizing == nil ? "Move" : "Resize")
        }
        if panning { store.scheduleSave() }
        dragging = false
        dragEngaged = false
        dragOrigins.removeAll()
        resizing = nil
        resizingGroup = nil
        panning = false
        marquee = nil
        (spaceDown ? NSCursor.openHand : NSCursor.arrow).set()
        needsDisplay = true
        flushDeferredImports()
    }

    // A cancelled pointer gesture never leaves an unregistered resize or move
    // behind. Restore only the items that gesture owns, even across a page switch.
    func cancelPointerInteraction() {
        guard hasPointerInteraction else { return }
        let ids: Set<UUID>
        if let resizingGroup {
            ids = resizingGroup.ids
        } else if let resizing {
            ids = [resizing]
        } else {
            ids = Set(dragOrigins.keys)
        }
        if let boardID = dragBoardID,
            let index = store.workspace.boards.firstIndex(where: { $0.id == boardID })
        {
            let before = Dictionary(
                uniqueKeysWithValues: original.filter { ids.contains($0.id) }.map { ($0.id, $0) })
            for i in store.workspace.boards[index].cards.indices {
                let id = store.workspace.boards[index].cards[i].id
                if let card = before[id] { store.workspace.boards[index].cards[i] = card }
            }
            if marquee != nil, boardID == store.board.id { selection = baseSelection }
        }
        dragging = false
        dragEngaged = false
        resizing = nil
        resizingGroup = nil
        panning = false
        marquee = nil
        pendingToggle = nil
        overSidebar = false
        dragOrigins.removeAll()
        snapTargets.removeAll()
        dragBounds = nil
        alignmentGuides = []
        spacingGuides = []
        snapSession.reset()
        onSidebarDragEnded?()
        (spaceDown ? NSCursor.openHand : NSCursor.arrow).set()
        store.scheduleSave()
        needsDisplay = true
        onSelection?()
        flushDeferredImports()
    }
    private func restoreDragPreview() {
        guard let id = dragBoardID, let index = store.workspace.boards.firstIndex(where: { $0.id == id })
        else { return }
        for i in store.workspace.boards[index].cards.indices {
            let card = store.workspace.boards[index].cards[i]
            if let original = dragOrigins[card.id] { store.workspace.boards[index].cards[i] = original }
        }
    }
    private func flushDeferredImports() {
        let completions = deferredImports
        deferredImports.removeAll()
        for completion in completions { completion() }
    }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard !hasPointerInteraction else { return }
        stopZoomAnimation()
        finishEditing()
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
            setZoom(
                zoom * exp(event.scrollingDeltaY * sensitivity),
                anchor: convert(event.locationInWindow, from: nil))
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            store.board.offsetX += event.scrollingDeltaX * scale
            store.board.offsetY += event.scrollingDeltaY * scale
            store.scheduleSave()
            needsDisplay = true
            onViewport?()
        }
    }
    override func magnify(with event: NSEvent) {
        guard !hasPointerInteraction else { return }
        stopZoomAnimation()
        finishEditing()
        setZoom(zoom * exp(event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }
    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        finishEditing()
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let before = world(anchor)
        guard value.isFinite else { return }
        store.board.zoom = min(4, max(0.1, value))
        store.board.offsetX = anchor.x - before.x * zoom
        store.board.offsetY = anchor.y - before.y * zoom
        store.scheduleSave()
        needsDisplay = true
        onViewport?()
    }
    var requestedZoom: CGFloat { zoomTarget ?? zoom }
    func stopZoomAnimation() {
        zoomTimer?.invalidate()
        zoomTimer = nil
        zoomTarget = nil
    }
    func animateZoom(to value: CGFloat, anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let target = min(4, max(0.1, value))
        let point = world(anchor)
        animateViewport(
            zoom: target, offset: CGPoint(x: anchor.x - point.x * target, y: anchor.y - point.y * target))
    }
    private func animateViewport(zoom target: CGFloat, offset destination: CGPoint) {
        finishEditing()
        stopZoomAnimation()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            store.board.zoom = target
            store.board.offsetX = destination.x
            store.board.offsetY = destination.y
            store.scheduleSave()
            needsDisplay = true
            onViewport?()
            return
        }
        let start = CACurrentMediaTime()
        let fromZoom = zoom
        let fromOffset = offset
        zoomTarget = target
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = min(1, (CACurrentMediaTime() - start) / 0.18)
            let t = 1 - pow(1 - progress, 3)
            // Linear scale and translation preserve the anchor throughout the transition.
            store.board.zoom = fromZoom + (target - fromZoom) * t
            store.board.offsetX = fromOffset.x + (destination.x - fromOffset.x) * t
            store.board.offsetY = fromOffset.y + (destination.y - fromOffset.y) * t
            needsDisplay = true
            onViewport?()
            if progress >= 1 {
                stopZoomAnimation()
                store.scheduleSave()
            }
        }
        zoomTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc func fitAll(_ sender: Any?) {
        finishEditing()
        fit(store.board.cards)
    }
    @objc func fitSelection(_ sender: Any?) {
        finishEditing()
        fit(store.board.cards.filter { selection.contains($0.id) })
    }
    private func fit(_ cards: [Card]) {
        guard !hasPointerInteraction else { return }
        guard let first = cards.first else {
            setZoom(1)
            return
        }
        let rect = cards.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let target = min(
            1.5, max(0.1, min((bounds.width - 130) / rect.width, (bounds.height - 130) / rect.height)))
        animateViewport(
            zoom: target,
            offset: CGPoint(x: bounds.midX - rect.midX * target, y: bounds.midY - rect.midY * target))
    }

    @objc func addText(_ sender: Any?) {
        if store.showsWorkspaceOverview {
            onRequestPage?()
            guard !store.showsWorkspaceOverview else { return }
        }
        addNote(at: placement(for: CGSize(width: 300, height: 180), near: insertionPoint()))
    }
    func addNote(at point: CGPoint) {
        cancelCropping(nil)
        finishEditing()
        let card = Card(x: point.x, y: point.y, width: 300, height: 180, text: "")
        store.replaceCards(store.board.cards + [card], name: "Add Note")
        selection = [card.id]
        startEditing(card.id)
        editingWasNew = true
    }
    func startEditing(_ id: UUID) {
        cancelCropping(nil)
        finishEditing()
        guard let card = store.board.cards.first(where: { $0.id == id }), card.text != nil else { return }
        guard !store.board.lockedIDs.contains(id) else {
            store.status?("Unlock this note to edit it")
            return
        }
        if window != nil {
            let target = min(2, max(zoom, 0.8))
            if target != zoom { setZoom(target, anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }
            let rect = screen(card.rect)
            if !bounds.insetBy(dx: 25, dy: 25).contains(rect) {
                store.board.offsetX = bounds.midX - card.rect.midX * zoom
                store.board.offsetY = bounds.midY - card.rect.midY * zoom
                store.scheduleSave()
                onViewport?()
            }
        }
        selection = [id]
        editingID = id
        editingOriginal = card
        let contentZoom = zoom * card.renderScale
        let text = NSTextView(frame: screen(card.rect).insetBy(dx: 17 * contentZoom, dy: 15 * contentZoom))
        text.isRichText = false
        text.allowsUndo = true
        textHistory.removeAllActions()
        text.font = .systemFont(ofSize: 18 * contentZoom)
        text.textColor = .pasteboardNoteInk
        text.insertionPointColor = .pasteboardNoteInk
        text.drawsBackground = true
        text.backgroundColor = noteColor(card.tone)
        text.textContainerInset = NSSize(width: 3 * contentZoom, height: 4 * contentZoom)
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.autoresizingMask = []
        text.textContainer?.widthTracksTextView = true
        text.string = card.text ?? ""
        text.delegate = self
        text.setAccessibilityLabel("Note text")
        addSubview(text)
        editor = text
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        needsDisplay = true
    }
    func textDidChange(_ notification: Notification) {
        // Persist in-progress text, keeping the whole editing session as one undo step.
        guard let editor, let id = editingID else { return }
        if let i = store.board.cards.firstIndex(where: { $0.id == id }) {
            store.board.cards[i].text = editor.string
            store.board.cards[i].height = max(
                store.board.cards[i].height, store.board.cards[i].textHeight(for: editor.string))
            let contentZoom = zoom * store.board.cards[i].renderScale
            editor.frame = screen(store.board.cards[i].rect).insetBy(
                dx: 17 * contentZoom, dy: 15 * contentZoom)
            needsDisplay = true
            store.scheduleSave()
        }
    }
    func finishEditing() {
        cancelPointerInteraction()
        guard let editor, let id = editingID else { return }
        let content = editor.string
        self.editor = nil
        editingID = nil
        editor.removeFromSuperview()
        var cards = store.board.cards
        if let i = cards.firstIndex(where: { $0.id == id }) {
            if editingWasNew && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cards.remove(at: i)
            } else {
                cards[i].text = content
                cards[i].height = max(cards[i].height, cards[i].textHeight(for: content))
            }
            if let editingOriginal, let originalIndex = store.board.cards.firstIndex(where: { $0.id == id }) {
                store.board.cards[originalIndex] = editingOriginal
            }
            store.replaceCards(cards, name: "Edit Note")
        }
        editingOriginal = nil
        editingWasNew = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing()
            return true
        }
        return false
    }
    func undoManager(for view: NSTextView) -> UndoManager? { textHistory }

    override func keyDown(with event: NSEvent) {
        if hasPointerInteraction && event.keyCode != 53 { return }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            cycleBoardFocus(backwards: event.modifierFlags.contains(.shift))
            return
        }
        switch event.keyCode {
        case 49:
            spaceDown = true
            NSCursor.openHand.set()
        case 51, 117: deleteSelection(nil)
        case 53:
            if hasPointerInteraction {
                cancelPointerInteraction()
            } else {
                selection.removeAll()
                needsDisplay = true
                onSelection?()
            }
        case 123, 124, 125, 126:
            let d: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            let movable = selection.subtracting(store.board.lockedIDs)
            var cards = store.board.cards
            for i in cards.indices where movable.contains(cards[i].id) {
                cards[i].x += event.keyCode == 123 ? -d : (event.keyCode == 124 ? d : 0)
                cards[i].y += event.keyCode == 126 ? -d : (event.keyCode == 125 ? d : 0)
            }
            store.replaceCards(cards, name: "Nudge")
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "s",
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            {
                addColourSwatch(nil)
            } else if event.charactersIgnoringModifiers?.lowercased() == "t",
                !event.modifierFlags.contains(.command)
            {
                addText(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            NSCursor.arrow.set()
        }
    }
    override func resignFirstResponder() -> Bool {
        deactivateInteraction()
        return super.resignFirstResponder()
    }
    func deactivateInteraction() {
        spaceDown = false
        cancelPointerInteraction()
        NSCursor.arrow.set()
    }

    override func selectAll(_ sender: Any?) {
        selection = Set(store.board.cards.map(\.id))
        needsDisplay = true
        onSelection?()
    }
    var canGroup: Bool {
        guard !isCropping else { return false }
        guard selection.isDisjoint(with: store.board.lockedIDs) else { return false }
        let cards = store.board.cards.filter { selection.contains($0.id) }
        guard cards.count >= 2 else { return false }
        return cards.contains { $0.groupID == nil } || Set(cards.compactMap(\.groupID)).count > 1
    }
    var canUngroup: Bool {
        !isCropping && selection.isDisjoint(with: store.board.lockedIDs)
            && store.board.cards.contains { selection.contains($0.id) && $0.groupID != nil }
    }
    @objc func toggleLock(_ sender: Any?) {
        finishEditing()
        guard !selection.isEmpty else { return }
        let lock = !selection.isSubset(of: store.board.lockedIDs)
        var cards = store.board.cards
        for i in cards.indices where selection.contains(cards[i].id) { cards[i].locked = lock ? true : nil }
        store.replaceCards(cards, name: lock ? "Lock" : "Unlock")
        needsDisplay = true
        onSelection?()
    }
    @objc func groupSelection(_ sender: Any?) {
        finishEditing()
        guard canGroup else { return }
        let group = UUID()
        var cards = store.board.cards
        for i in cards.indices where selection.contains(cards[i].id) { cards[i].groupID = group }
        store.replaceCards(cards, name: "Group")
        needsDisplay = true
        onSelection?()
    }
    @objc func ungroupSelection(_ sender: Any?) {
        finishEditing()
        guard canUngroup else { return }
        var cards = store.board.cards
        for i in cards.indices where selection.contains(cards[i].id) { cards[i].groupID = nil }
        store.replaceCards(cards, name: "Ungroup")
        needsDisplay = true
        onSelection?()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(fitSelection(_:)) {
            return !selection.isEmpty && !hasPointerInteraction && !isCropping
        }
        if menuItem.action == #selector(arrangeSelection(_:)),
            let value = menuItem.representedObject as? String, let mode = BoardArrangement(rawValue: value)
        {
            return !isCropping && editor == nil && !hasPointerInteraction
                && mode.canApply(to: store.board, selection: selection)
        }
        if menuItem.action == #selector(playVideo(_:)) {
            return !isCropping && !hasPointerInteraction && selectedVideo != nil
        }
        if menuItem.action == #selector(markReadyToPost(_:)) {
            return !isCropping && !hasPointerInteraction
                && !store.board.cards.contains { selection.contains($0.id) && $0.isVideo }
                && (store.selectedPost(selection)?.isComplete == true
                    || store.board.cards.contains { selection.contains($0.id) && $0.asset != nil })
        }
        if menuItem.action == #selector(previewSocialPost(_:))
            || menuItem.action == #selector(unmarkReadyToPost(_:))
        {
            return !isCropping && !hasPointerInteraction && store.selectedPost(selection) != nil
        }
        if hasPointerInteraction { return false }
        if menuItem.action == #selector(recolourSVG(_:)) {
            return !isCropping && svgColourCandidate.map { !store.board.lockedIDs.contains($0.id) } == true
        }
        if menuItem.action == #selector(editColourSwatch(_:)) {
            return !isCropping && swatchCandidate != nil
                && !store.board.lockedIDs.contains(swatchCandidate!.id)
        }
        if menuItem.action == #selector(copyHex(_:)) { return swatchCandidate != nil }
        if menuItem.action == #selector(cropImage(_:)) { return !isCropping && cropCandidate != nil }
        if menuItem.action == #selector(resetImageCrop(_:)) {
            return !isCropping && cropCandidate?.crop != nil
        }
        if isCropping { return false }
        if menuItem.action == #selector(groupSelection(_:)) { return canGroup && editor == nil }
        if menuItem.action == #selector(ungroupSelection(_:)) { return canUngroup && editor == nil }
        if menuItem.action == #selector(toggleLock(_:)) {
            menuItem.title =
                selection.isSubset(of: store.board.lockedIDs) && !selection.isEmpty
                ? "Unlock Selection" : "Lock Selection"
            return !selection.isEmpty && editor == nil
        }
        if menuItem.action == #selector(editSource(_:)) {
            return selection.count == 1 && selection.isDisjoint(with: store.board.lockedIDs)
        }
        if menuItem.action == #selector(openSource(_:)) { return selectedSource != nil }
        return true
    }
    @objc func arrangeSelection(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let mode = BoardArrangement(rawValue: value),
            !isCropping, !hasPointerInteraction
        else { return }
        finishEditing()
        store.replaceCards(mode.applying(to: store.board, selection: selection), name: mode.title)
    }
    func arrangementMenu() -> NSMenu {
        let menu = NSMenu(title: "Arrange")
        for mode in BoardArrangement.allCases {
            if mode == .horizontalSpacing { menu.addItem(.separator()) }
            let item = menu.addItem(
                withTitle: mode.title, action: #selector(arrangeSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
        }
        return menu
    }
    @objc func deleteSelection(_ sender: Any?) {
        finishEditing()
        let removable = selection.subtracting(store.board.lockedIDs)
        store.replaceCards(store.board.cards.filter { !removable.contains($0.id) }, name: "Delete")
    }
    @objc func duplicate(_ sender: Any?) {
        finishEditing()
        let copies = Card.copies(
            of: store.board.cards.filter { selection.contains($0.id) }, offset: CGPoint(x: 24, y: 24))
        store.replaceCards(store.board.cards + copies, name: "Duplicate")
        selection = Set(copies.map(\.id))
        needsDisplay = true
        onSelection?()
    }
    @objc func copy(_ sender: Any?) { _ = writeSelection(to: .general) }
    @discardableResult func writeSelection(to pb: NSPasteboard) -> Bool {
        guard let item = clipboardItem() else { return false }
        pb.clearContents()
        let written = pb.writeObjects([item])
        if !written { store.status?("The clipboard is unavailable. Nothing was removed.") }
        return written
    }
    func clipboardItem() -> NSPasteboardItem? {
        let cards = store.board.cards.filter { selection.contains($0.id) }
        guard !cards.isEmpty else { return nil }
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(cards) { item.setData(data, forType: internalType) }
        if cards.count == 1, let video = cards[0].video {
            if let file = video.file {
                item.setString(
                    store.directory.appendingPathComponent("Assets").appendingPathComponent(file)
                        .absoluteString, forType: .fileURL)
            }
            if let url = YouTubeLink.watchURL(video) {
                item.setString(url.absoluteString, forType: .string)
                item.setString(url.absoluteString, forType: .init("public.url"))
            }
            return item
        }
        if cards.count == 1, let asset = cards[0].asset {
            if BoardImageIO.isSVG(asset),
                let bytes = try? Data(
                    contentsOf: store.directory.appendingPathComponent("Assets").appendingPathComponent(asset)
                ), let svg = try? SVGImage(data: bytes),
                let data = try? svg.clipboardData(crop: cards[0].imageCrop)
            {
                for type in SVGImage.pasteboardTypes { item.setData(data, forType: type) }
                if let xml = String(data: data, encoding: .utf8) { item.setString(xml, forType: .string) }
                let scale = min(2, 4096 / max(cards[0].width, cards[0].height))
                if let png = try? BoardExport(
                    cards: cards, assets: store.directory.appendingPathComponent("Assets"), padding: 0
                ).png(scale: scale, transparent: true) {
                    item.setData(png, forType: .png)
                }
            } else if cards[0].crop != nil {
                if let png = try? BoardExport(
                    cards: cards, assets: store.directory.appendingPathComponent("Assets"), padding: 0
                ).png(scale: min(2, 4096 / max(cards[0].width, cards[0].height)), transparent: true) {
                    item.setData(png, forType: .png)
                }
            } else if let data = store.originalImageData(asset),
                let type = BoardImageIO.pasteboardType(for: data)
            {
                // Keep encoded originals on the clipboard instead of expanding a
                // large image into a full-resolution TIFF on the main thread.
                item.setData(data, forType: type)
            }
        }
        let texts = cards.compactMap { $0.hex ?? $0.text }
        if !texts.isEmpty { item.setString(texts.joined(separator: "\n\n"), forType: .string) }
        return item
    }
    @objc func cut(_ sender: Any?) {
        finishEditing()
        guard writeSelection(to: .general) else { return }
        deleteSelection(sender)
    }
    func insertionPoint() -> CGPoint {
        if let contextPoint { return contextPoint }
        if let hoverPoint, bounds.insetBy(dx: 35, dy: 35).contains(hoverPoint) { return world(hoverPoint) }
        return worldCenter
    }

    // Search open spaces beside existing cards before moving the camera.
    func placement(for size: CGSize, near point: CGPoint, occupied: [Card]? = nil) -> CGPoint {
        let cards = occupied ?? store.board.cards
        let gap: CGFloat = 28
        let preferred = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        var candidates = [preferred]
        for card in cards {
            candidates += [
                CGPoint(x: card.rect.maxX + gap, y: card.y), CGPoint(x: card.x, y: card.rect.maxY + gap),
                CGPoint(x: card.x - size.width - gap, y: card.y),
                CGPoint(x: card.x, y: card.y - size.height - gap),
            ]
        }
        let visible = CGRect(
            origin: world(CGPoint(x: 24, y: 24)),
            size: CGSize(width: max(0, bounds.width - 48) / zoom, height: max(0, bounds.height - 48) / zoom))
        let free = candidates.filter { candidate in
            !cards.contains {
                $0.rect.insetBy(dx: -14, dy: -14).intersects(CGRect(origin: candidate, size: size))
            }
        }
        let inside = free.filter { visible.contains(CGRect(origin: $0, size: size)) }
        return (inside.isEmpty ? free : inside).min {
            hypot($0.x - preferred.x, $0.y - preferred.y) < hypot($1.x - preferred.x, $1.y - preferred.y)
        } ?? CGPoint(x: (cards.map { $0.rect.maxX }.max() ?? preferred.x) + gap, y: preferred.y)
    }

    func place(_ incoming: [Card], near point: CGPoint, avoidOverlap: Bool, preserveLayout: Bool = false)
        -> [Card]
    {
        guard !incoming.isEmpty else { return [] }
        var cards = incoming
        if !preserveLayout {
            let columns = max(1, Int(ceil(sqrt(Double(cards.count)))))
            let columnWidth = (cards.map(\.width).max() ?? 340) + 28
            let rowHeight = (cards.map(\.height).max() ?? 180) + 28
            for i in cards.indices {
                cards[i].x = CGFloat(i % columns) * columnWidth
                cards[i].y = CGFloat(i / columns) * rowHeight
            }
        }
        let box = cards.dropFirst().reduce(cards[0].rect) { $0.union($1.rect) }
        let origin = avoidOverlap ? placement(for: box.size, near: point) : point
        for i in cards.indices {
            cards[i].x += origin.x - box.minX
            cards[i].y += origin.y - box.minY
        }
        return cards
    }

    @objc func paste(_ sender: Any?) {
        paste(from: .general)
    }
    func paste(from pb: NSPasteboard) {
        if store.showsWorkspaceOverview {
            onRequestPage?()
            guard !store.showsWorkspaceOverview else { return }
        }
        cancelCropping(nil)
        finishEditing()
        stopZoomAnimation()
        let point = insertionPoint()
        contextPoint = nil
        if let data = pb.data(forType: internalType), pasteInternalCards(data, at: point) { return }
        if !receive(pb, at: point, avoidOverlap: true) {
            NSSound.beep()
            store.status?("Copy an image, SVG artwork or markup, or some text, then paste here")
        }
    }
    @discardableResult func pasteInternalCards(_ data: Data, at point: CGPoint) -> Bool {
        guard let cards = try? JSONDecoder().decode([Card].self, from: data), !cards.isEmpty,
            cards.allSatisfy(BoardStore.valid),
            cards.allSatisfy({ $0.assetNames.allSatisfy(store.hasAsset) })
        else { return false }
        append(place(Card.copies(of: cards), near: point, avoidOverlap: true, preserveLayout: true))
        return true
    }
    func append(_ cards: [Card], reveal: Bool = true) {
        guard !cards.isEmpty else { return }
        store.replaceCards(store.board.cards + cards, name: "Add to Board")
        if editingID == nil { selection = Set(cards.map(\.id)) }
        needsDisplay = true
        onSelection?()
        if reveal && editingID == nil { revealCards(cards) }
    }
    func focusCards(_ ids: Set<UUID>) {
        cancelCropping(nil)
        finishEditing()
        selection = ids
        needsDisplay = true
        onSelection?()
        revealCards(store.board.cards.filter { selection.contains($0.id) })
    }
    func cycleBoardFocus(backwards: Bool = false) {
        // Keep text entry, crop controls and in-progress pointer gestures in charge.
        guard editor == nil, !isCropping, !dragging, !panning, resizing == nil, resizingGroup == nil,
            marquee == nil
        else { return }
        var stops: [Set<UUID>] = []
        var seenGroups = Set<UUID>()
        var members: [UUID: Set<UUID>] = [:]
        for card in store.board.cards {
            if let group = card.groupID { members[group, default: []].insert(card.id) }
        }
        for card in store.board.cards {
            if let group = card.groupID, !seenGroups.insert(group).inserted { continue }
            stops.append(card.groupID.flatMap { members[$0] } ?? [card.id])
        }
        guard !stops.isEmpty else { return }
        let selected = stops.indices.filter { !stops[$0].isDisjoint(with: selection) }
        let index: Int
        if let current = backwards ? selected.first : selected.last {
            index = (current + (backwards ? stops.count - 1 : 1)) % stops.count
        } else {
            index = backwards ? stops.count - 1 : 0
        }
        stopZoomAnimation()
        selection = stops[index]
        needsDisplay = true
        onSelection?()
        window?.makeFirstResponder(self)
        revealCards(store.board.cards.filter { selection.contains($0.id) }, minimumZoom: 0.75)
    }
    func revealCards(_ cards: [Card], minimumZoom: CGFloat = 0.1) {
        guard let first = cards.first, bounds.width > 0, bounds.height > 0 else { return }
        let box = cards.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        if zoom >= minimumZoom && bounds.insetBy(dx: 28, dy: 28).contains(screen(box)) { return }
        let target = min(
            max(zoom, minimumZoom),
            max(0.1, min((bounds.width - 100) / box.width, (bounds.height - 100) / box.height)))
        animateViewport(
            zoom: target,
            offset: CGPoint(x: bounds.midX - box.midX * target, y: bounds.midY - box.midY * target))
    }
    private func textCard(_ text: String) -> Card {
        let content = String(text.prefix(200_000)).replacingOccurrences(of: "\r\n", with: "\n")
        let measured = content.boundingRect(
            with: NSSize(width: 300, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 18)])
        return Card(
            x: 0, y: 0, width: 340, height: min(99_999, max(120, ceil(measured.height) + 42)), text: content)
    }
    private func importImageData(
        _ data: [Data], at point: CGPoint, avoidOverlap: Bool, sources: [String?] = []
    ) {
        guard !data.isEmpty else { return }
        let boardID = store.board.id
        pasteInFlight += 1
        pendingImageCount += data.count
        importIndicator.show(count: pendingImageCount)
        store.status?("Adding \(data.count == 1 ? "image" : "images")…")
        store.prepareImages(data, sourceURLs: sources) { [weak self] prepared, failed in
            guard let self else { return }
            let message = self.store.lastImageImportError
            let complete = { [weak self] in
                self?.completeImages(
                    prepared, failed: failed, message: message, boardID: boardID, point: point,
                    avoidOverlap: avoidOverlap)
            }
            if dragging || resizing != nil || resizingGroup != nil || panning {
                deferredImports.append { complete() }
            } else {
                complete()
            }
        }
    }
    private func completeImages(
        _ prepared: [PreparedImage], failed: Int, message: String?, boardID: UUID, point: CGPoint,
        avoidOverlap: Bool
    ) {
        pasteInFlight -= 1
        pendingImageCount = max(0, pendingImageCount - prepared.count - failed)
        importIndicator.show(count: pendingImageCount)
        let cards = prepared.map { store.card(for: $0, at: .zero) }
        // A paste belongs to the board where it began, even if the user switches.
        if store.board.id == boardID {
            append(place(cards, near: point, avoidOverlap: avoidOverlap))
        } else if let index = store.workspace.boards.firstIndex(where: { $0.id == boardID }) {
            var placed = cards
            var occupied = store.workspace.boards[index].cards
            for i in placed.indices {
                let origin = placement(for: placed[i].rect.size, near: point, occupied: occupied)
                placed[i].x = origin.x
                placed[i].y = origin.y
                occupied.append(placed[i])
            }
            store.workspace.boards[index].cards = occupied
            store.scheduleSave()
        }
        if failed > 0 { store.status?(message ?? "Some images couldn’t be opened") }
    }

    @discardableResult func receiveImageItems(
        _ items: [NSPasteboardItem], at point: CGPoint, source: String? = nil, avoidOverlap: Bool = false
    ) -> Bool {
        var images: [Data] = []
        for item in items {
            if let svg = SVGImage.clipboardData(from: item) {
                images.append(svg)
            } else if let data = imageTypes.lazy.filter({ item.types.contains($0) }).compactMap({
                item.data(forType: $0)
            }).first(where: { !$0.isEmpty }) {
                images.append(data)
            } else if let embedded = DesignClipboard.embeddedImage(item) {
                images.append(embedded)
            } else if let type = item.availableType(from: imageTypes), let data = item.data(forType: type),
                !data.isEmpty
            {
                images.append(data)
            }
        }
        guard !images.isEmpty else { return false }
        importImageData(
            images, at: point, avoidOverlap: avoidOverlap,
            sources: Array(repeating: source, count: images.count))
        return true
    }
    @discardableResult func receive(_ pb: NSPasteboard, at point: CGPoint, avoidOverlap: Bool = false) -> Bool
    {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            importFiles(urls, at: point, avoidOverlap: avoidOverlap)
            return true
        }
        if let type = pb.availableType(from: VideoMedia.pasteboardTypes), let data = pb.data(forType: type),
            !data.isEmpty
        {
            let ext = type.rawValue == "com.apple.quicktime-movie" ? "mov" : "mp4"
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString + "." + ext)
            do {
                try data.write(to: temp, options: .atomic)
                importVideoFiles([temp], at: point, avoidOverlap: avoidOverlap, temporary: true)
            } catch { showError(error) }
            return true
        }
        if receiveImageItems(
            pb.pasteboardItems ?? [], at: point, source: SourceLink.clipboard(pb), avoidOverlap: avoidOverlap)
        {
            return true
        }
        if let video = YouTubeLink.parse(
            pb.string(forType: .init("public.url")) ?? pb.string(forType: .string) ?? "")
        {
            do {
                append(place([try store.youtubeCard(video)], near: point, avoidOverlap: avoidOverlap))
            } catch { showError(error) }
            return true
        }
        if (pb.pasteboardItems ?? []).contains(where: DesignClipboard.nativeFigma) {
            let alert = NSAlert()
            alert.messageText = "Paste from Figma"
            alert.informativeText =
                "In Figma, right-click your selection and choose Copy/Paste as → Copy as SVG for recolourable artwork, or Copy as PNG for a complete image. Then paste here with ⌘V."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) }
            store.status?("Use Copy as SVG or Copy as PNG in Figma")
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            if SVGImage.looksLikeSVG(Data(text.utf8)) {
                importImageData(
                    [Data(text.utf8)], at: point, avoidOverlap: avoidOverlap,
                    sources: [SourceLink.clipboard(pb)])
                return true
            }
            var card = textCard(text)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            card.sourceURL = SourceLink.clipboard(pb) ?? SourceLink.url(clean)?.absoluteString
            append(place([card], near: point, avoidOverlap: avoidOverlap))
            return true
        }
        return false
    }
    func importFiles(_ urls: [URL], at point: CGPoint? = nil, avoidOverlap: Bool = true) {
        cancelCropping(nil)
        finishEditing()
        let point = point ?? insertionPoint()
        var cards: [Card] = []
        var images: [Data] = []
        var sources: [String?] = []
        var movies: [URL] = []
        var unsupported = 0
        for url in urls {
            do {
                if url.pathExtension.lowercased() == "gatherboard" {
                    try store.importBoard(data: Data(contentsOf: url))
                } else if VideoMedia.isMovie(url) {
                    movies.append(url)
                } else if ["txt", "md", "csv"].contains(url.pathExtension.lowercased()) {
                    var card = textCard(try String(contentsOf: url, encoding: .utf8))
                    card.sourceURL = url.absoluteString
                    cards.append(card)
                } else if url.pathExtension.lowercased() == "svg"
                    || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                {
                    images.append(try Data(contentsOf: url, options: .mappedIfSafe))
                    sources.append(url.absoluteString)
                } else {
                    unsupported += 1
                }
            } catch { showError(error) }
        }
        append(place(cards, near: point, avoidOverlap: avoidOverlap))
        importVideoFiles(movies, at: point, avoidOverlap: avoidOverlap)
        importImageData(images, at: point, avoidOverlap: avoidOverlap, sources: sources)
        if unsupported > 0 { store.status?("Use images, videos, SVG, .txt, .md, or .gatherboard files") }
    }
    var selectedVideo: Card? {
        let selected = store.board.cards.filter { selection.contains($0.id) }
        if let contextCardID, let card = selected.first(where: { $0.id == contextCardID && $0.isVideo }) {
            return card
        }
        let videos = selected.filter(\.isVideo)
        return videos.count == 1 ? videos[0] : nil
    }
    func videoPlayRect(_ card: Card) -> CGRect {
        let rect = screen(card.rect)
        let side = min(64, max(24, min(rect.width, rect.height) * 0.25))
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }
    @objc func playVideo(_ sender: Any?) { if let card = selectedVideo { onPlayVideo?(card) } }
    private func importVideoFiles(
        _ urls: [URL], at point: CGPoint, avoidOverlap: Bool, temporary: Bool = false
    ) {
        guard !urls.isEmpty else { return }
        let boardID = store.board.id
        let assets = store.directory.appendingPathComponent("Assets")
        pasteInFlight += 1
        pendingImageCount += urls.count
        importIndicator.show(count: pendingImageCount)
        store.status?("Adding video…")
        VideoMedia.queue.async { [weak self] in
            var prepared: [PreparedVideo] = []
            var errors: [String] = []
            for url in urls {
                defer { if temporary { try? FileManager.default.removeItem(at: url) } }
                do {
                    var clip = try VideoMedia.prepare(url, assets: assets)
                    if temporary { clip.video.title = "Pasted video" }
                    prepared.append(clip)
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let complete = { [weak self] in
                    guard let self else { return }
                    pasteInFlight -= 1
                    pendingImageCount = max(0, pendingImageCount - urls.count)
                    importIndicator.show(count: pendingImageCount)
                    let cards = prepared.map { self.store.videoCard($0) }
                    if store.board.id == boardID {
                        append(place(cards, near: point, avoidOverlap: avoidOverlap))
                    } else if let index = store.workspace.boards.firstIndex(where: { $0.id == boardID }) {
                        var occupied = store.workspace.boards[index].cards
                        for var card in cards {
                            let origin = placement(for: card.rect.size, near: point, occupied: occupied)
                            card.x = origin.x
                            card.y = origin.y
                            occupied.append(card)
                        }
                        store.replaceCards(occupied, name: "Add Videos", boardID: boardID)
                    }
                    if let error = errors.first { store.status?(error) }
                }
                if dragging || resizing != nil || resizingGroup != nil || panning {
                    deferredImports.append(complete)
                } else {
                    complete()
                }
            }
        }
    }
    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlight = true
        needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        needsDisplay = true
        return receive(sender.draggingPasteboard, at: world(convert(sender.draggingLocation, from: nil)))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        finishEditing()
        let point = convert(event.locationInWindow, from: nil)
        contextPoint = world(point)
        contextCardID = hit(point)?.id
        if let card = hit(point), !selection.contains(card.id) {
            selection = [card.id]
            needsDisplay = true
        }
        onSelection?()
        let menu = NSMenu()
        if !selection.isEmpty {
            if selectedVideo != nil {
                let play = menu.addItem(
                    withTitle: "Play Video…", action: #selector(playVideo(_:)), keyEquivalent: "")
                play.target = self
            }
            let hasVideo = store.board.cards.contains { selection.contains($0.id) && $0.isVideo }
            if !hasVideo, let post = store.selectedPost(selection) {
                let preview = menu.addItem(
                    withTitle: "Preview Social Post…", action: #selector(previewSocialPost(_:)),
                    keyEquivalent: "")
                preview.target = self
                let status = menu.addItem(
                    withTitle: post.draft.isReady ? "Unmark Ready to Post" : "Mark Ready to Post…",
                    action: post.draft.isReady
                        ? #selector(unmarkReadyToPost(_:)) : #selector(markReadyToPost(_:)), keyEquivalent: ""
                )
                status.target = self
            } else if !hasVideo
                && store.board.cards.contains(where: { selection.contains($0.id) && $0.asset != nil })
            {
                let item = menu.addItem(
                    withTitle: "Mark Ready to Post…", action: #selector(markReadyToPost(_:)),
                    keyEquivalent: "")
                item.target = self
            }
            menu.addItem(.separator())
            if svgColourCandidate != nil {
                let item = menu.addItem(
                    withTitle: "Recolour SVG…", action: #selector(recolourSVG(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(.separator())
            }
            if swatchCandidate != nil {
                for (title, action) in [
                    ("Edit Colour Swatch…", #selector(editColourSwatch(_:))),
                    ("Copy HEX", #selector(copyHex(_:))),
                ] {
                    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                    item.target = self
                }
                menu.addItem(.separator())
            }
            if cropCandidate != nil {
                let crop = menu.addItem(
                    withTitle: "Crop Image…", action: #selector(cropImage(_:)), keyEquivalent: "")
                crop.target = self
                if cropCandidate?.crop != nil {
                    let reset = menu.addItem(
                        withTitle: "Reset Image Crop", action: #selector(resetImageCrop(_:)),
                        keyEquivalent: "")
                    reset.target = self
                }
                menu.addItem(.separator())
            }
            let locked = selection.isSubset(of: store.board.lockedIDs)
            let lockItem = menu.addItem(
                withTitle: locked ? "Unlock Selection" : "Lock Selection", action: #selector(toggleLock(_:)),
                keyEquivalent: "")
            lockItem.target = self
            if selection.count == 1 {
                let source = menu.addItem(
                    withTitle: "Edit Source Link…", action: #selector(editSource(_:)), keyEquivalent: "")
                source.target = self
                if selectedSource != nil {
                    let open = menu.addItem(
                        withTitle: "Open Source", action: #selector(openSource(_:)), keyEquivalent: "")
                    open.target = self
                }
            }
            menu.addItem(.separator())
            if canGroup {
                let item = menu.addItem(
                    withTitle: "Group", action: #selector(groupSelection(_:)), keyEquivalent: "")
                item.target = self
            }
            if canUngroup {
                let item = menu.addItem(
                    withTitle: "Ungroup", action: #selector(ungroupSelection(_:)), keyEquivalent: "")
                item.target = self
            }
            if canGroup || canUngroup { menu.addItem(.separator()) }
            let arrange = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
            arrange.submenu = arrangementMenu()
            menu.addItem(arrange)
            let fit = menu.addItem(
                withTitle: "Fit Selection", action: #selector(fitSelection(_:)), keyEquivalent: "")
            fit.target = self
            menu.addItem(.separator())
            for (title, action) in [
                ("Copy", #selector(copy(_:))), ("Duplicate", #selector(duplicate(_:))),
                ("Bring to Front", #selector(bringToFront(_:))), ("Delete", #selector(deleteSelection(_:))),
            ] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
            }
            if store.board.cards.contains(where: { selection.contains($0.id) && $0.text != nil }) {
                menu.addItem(.separator())
                for (i, title) in ["White", "Butter", "Sage", "Rose"].enumerated() {
                    let item = menu.addItem(
                        withTitle: title, action: #selector(colorNote(_:)), keyEquivalent: "")
                    item.tag = i
                    item.target = self
                }
            }
        } else {
            let item = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
            item.target = self
            let note = menu.addItem(withTitle: "Add Note", action: #selector(addText(_:)), keyEquivalent: "")
            note.target = self
            let swatch = menu.addItem(
                withTitle: "Add Colour Swatch…", action: #selector(addColourSwatch(_:)), keyEquivalent: "")
            swatch.target = self
        }
        return menu
    }
    var swatchCandidate: Card? {
        let cards = store.board.cards.filter { selection.contains($0.id) && $0.hex != nil }
        if let contextCardID, let card = cards.first(where: { $0.id == contextCardID }) { return card }
        return cards.count == 1 ? cards[0] : nil
    }
    @objc func addColourSwatch(_ sender: Any?) { showSwatchEditor(card: nil) }
    @objc func editColourSwatch(_ sender: Any?) {
        if let card = swatchCandidate { showSwatchEditor(card: card) }
    }
    @objc func copyHex(_ sender: Any?) {
        guard let hex = swatchCandidate?.hex else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        store.status?("Copied \(hex)")
    }
    func showSwatchEditor(card: Card?) {
        if store.showsWorkspaceOverview {
            onRequestPage?()
            guard !store.showsWorkspaceOverview else { return }
        }
        finishEditing()
        cancelCropping(nil)
        guard let window else { return }
        if let card, store.board.lockedIDs.contains(card.id) {
            store.status?("Unlock this swatch to edit its colour")
            return
        }
        let boardID = store.board.id
        let point = insertionPoint()
        let alert = NSAlert()
        alert.messageText = card == nil ? "Add a colour swatch" : "Edit colour swatch"
        alert.informativeText = "A colour box with its HEX value visible on the board."
        let apply = alert.addButton(withTitle: card == nil ? "Add Swatch" : "Save Colour")
        alert.addButton(withTitle: "Cancel")
        let editor = SwatchEditor(hex: card?.hex ?? "#32654D")
        editor.validityChanged = { [weak apply] valid in apply?.isEnabled = valid }
        alert.accessoryView = editor
        alert.window.initialFirstResponder = editor.field
        alert.beginSheetModal(for: window) { [weak self] result in
            editor.well.deactivate()
            guard let self, result == .alertFirstButtonReturn, let hex = editor.hex else { return }
            if let card {
                _ = self.store.setSwatch(card.id, hex: hex, boardID: boardID)
            } else if self.store.board.id == boardID {
                let origin = self.placement(for: CGSize(width: 220, height: 180), near: point)
                if let id = self.store.addSwatch(hex: hex, at: origin) {
                    self.selection = [id]
                    self.needsDisplay = true
                    self.onSelection?()
                    self.revealCards(self.store.board.cards.filter { $0.id == id })
                }
            }
        }
    }
    @objc func colorNote(_ sender: NSMenuItem) {
        var cards = store.board.cards
        for i in cards.indices
        where selection.contains(cards[i].id) && cards[i].text != nil
            && !store.board.lockedIDs.contains(cards[i].id)
        { cards[i].tone = sender.tag }
        store.replaceCards(cards, name: "Note Color")
    }
    var cropCandidate: Card? {
        let images = store.board.cards.filter {
            selection.contains($0.id) && $0.asset != nil && !$0.isVideo
                && !store.board.lockedIDs.contains($0.id)
        }
        if let contextCardID, let card = images.first(where: { $0.id == contextCardID }) { return card }
        return images.count == 1 ? images[0] : nil
    }
    @objc func cropImage(_ sender: Any?) { if let card = cropCandidate { beginCropping(card.id) } }
    func beginCropping(_ id: UUID) {
        finishEditing()
        cancelCropping(nil)
        stopZoomAnimation()
        guard let card = store.board.cards.first(where: { $0.id == id }), card.asset != nil, !card.isVideo
        else { return }
        guard !store.board.lockedIDs.contains(id) else {
            store.status?("Unlock this image to crop it")
            return
        }
        selection = [id]
        let full = card.fullImageRect
        if window != nil {
            let target = min(
                zoom, max(0.1, min((bounds.width - 100) / full.width, (bounds.height - 150) / full.height)))
            setZoom(target)
            store.board.offsetX = bounds.midX - full.midX * zoom
            store.board.offsetY = bounds.midY + 30 - full.midY * zoom
            store.scheduleSave()
            onViewport?()
        }
        let overlay = CropOverlay(canvas: self, card: card)
        cropOverlay = overlay
        addSubview(overlay)
        window?.makeFirstResponder(overlay)
        needsDisplay = true
        onSelection?()
        store.status?("Drag crop edges or move the frame · Return to apply · Esc to cancel")
    }
    @objc func applyCropping(_ sender: Any?) {
        guard let overlay = cropOverlay else { return }
        let card = overlay.original
        let draft = overlay.draft
        let boardID = overlay.boardID
        cancelCropping(nil)
        guard store.board.id == boardID, !store.board.lockedIDs.contains(card.id),
            let index = store.board.cards.firstIndex(where: { $0.id == card.id }),
            store.board.cards[index] == card
        else { return }
        var cards = store.board.cards
        cards[index] = draft.applied(to: card)
        if cards[index] == card { store.status?("Crop unchanged") }
        store.replaceCards(cards, name: "Crop Image")
        selection = [card.id]
        needsDisplay = true
        onSelection?()
    }
    @objc func cancelCropping(_ sender: Any?) {
        guard let overlay = cropOverlay else { return }
        cropOverlay = nil
        overlay.removeFromSuperview()
        NSCursor.arrow.set()
        window?.makeFirstResponder(self)
        needsDisplay = true
        onSelection?()
        store.status?("Crop cancelled")
    }
    @objc func resetImageCrop(_ sender: Any?) {
        guard let card = cropCandidate, card.crop != nil else { return }
        var cards = store.board.cards
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = ImageCrop.full.applied(to: card)
            store.replaceCards(cards, name: "Reset Crop")
        }
    }
    @objc func bringToFront(_ sender: Any?) {
        let cards = store.board.cards
        let movable = selection.subtracting(store.board.lockedIDs)
        store.replaceCards(
            cards.filter { !movable.contains($0.id) } + cards.filter { movable.contains($0.id) },
            name: "Bring to Front")
    }
    var selectedSource: URL? {
        guard selection.count == 1, let card = store.board.cards.first(where: { selection.contains($0.id) }),
            let source = card.sourceURL
        else { return nil }
        return SourceLink.url(source)
    }
    @objc func openSource(_ sender: Any?) { if let url = selectedSource { NSWorkspace.shared.open(url) } }
    @objc func editSource(_ sender: Any?) {
        finishEditing()
        guard selection.count == 1, let card = store.board.cards.first(where: { selection.contains($0.id) }),
            !store.board.lockedIDs.contains(card.id), let window
        else { return }
        let alert = NSAlert()
        alert.messageText = "Source link"
        alert.informativeText = "Keep the original website or file with this item."
        alert.addButton(withTitle: "Save Link")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Link")
        let field = NSTextField(string: card.sourceURL ?? "")
        field.placeholderString = "https://example.com or a file path"
        field.frame = CGRect(x: 0, y: 0, width: 390, height: 26)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .alertSecondButtonReturn else { return }
            let source = response == .alertThirdButtonReturn ? nil : SourceLink.normalized(field.stringValue)
            if response != .alertThirdButtonReturn && source == nil {
                self.showError(
                    NSError(
                        domain: "Gather.Source", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Enter a website address or an absolute file path."
                        ]))
                return
            }
            var cards = self.store.board.cards
            if let index = cards.firstIndex(where: { $0.id == card.id }) {
                cards[index].sourceURL = source
                self.store.replaceCards(cards, name: "Source Link")
            }
        }
    }
}

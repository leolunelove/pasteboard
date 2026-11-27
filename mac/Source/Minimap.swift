import AppKit
import CoreText

struct MinimapGeometry: Equatable {
    let worldBounds: CGRect
    let frame: CGRect
    let scale: CGFloat

    init?(cards: [Card], viewport: CGRect, area: CGRect) {
        self.init(
            contentBounds: cards.reduce(CGRect.null) { $0.union($1.rect) }, viewport: viewport, area: area)
    }
    init?(contentBounds: CGRect, viewport: CGRect, area: CGRect) {
        guard viewport.width > 0, viewport.height > 0, area.width > 0, area.height > 0 else { return nil }
        let extent = contentBounds.union(viewport)
        let padding = max(1, max(extent.width, extent.height) * 0.06)
        worldBounds = extent.insetBy(dx: -padding, dy: -padding)
        scale = min(area.width / worldBounds.width, area.height / worldBounds.height)
        guard scale.isFinite, scale > 0 else { return nil }
        frame = CGRect(
            x: area.midX - worldBounds.width * scale / 2, y: area.midY - worldBounds.height * scale / 2,
            width: worldBounds.width * scale, height: worldBounds.height * scale)
    }
    func project(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: frame.minX + (point.x - worldBounds.minX) * scale,
            y: frame.minY + (point.y - worldBounds.minY) * scale)
    }
    func project(_ rect: CGRect) -> CGRect {
        CGRect(
            origin: project(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale)
        )
    }
    func worldPoint(_ point: CGPoint) -> CGPoint {
        // Letterboxing is not another distant part of the board.
        let x = min(frame.maxX, max(frame.minX, point.x))
        let y = min(frame.maxY, max(frame.minY, point.y))
        return CGPoint(
            x: worldBounds.minX + (x - frame.minX) / scale, y: worldBounds.minY + (y - frame.minY) / scale)
    }
}

final class BoardMinimap: NSView {
    unowned let canvas: BoardView
    private var dragGeometry: MinimapGeometry?
    private var dragBoardID: UUID?
    private var grabOffset = CGPoint.zero
    private var extentCards: [Card] = []
    private var extentSections: [BoardSection] = []
    private var contentBounds = CGRect.null
    private var artworkCards: [Card] = []
    private var artworkSections: [BoardSection] = []
    private var artworkSelection = Set<UUID>()
    private var artworkGeometry: MinimapGeometry?
    private var artworkDark: Bool?
    private var fills: [(CGPath, CGColor)] = []
    private var normalOutline = CGMutablePath()
    private var selectedOutline = CGMutablePath()
    private var sectionOutline = CGMutablePath()
    private(set) var artworkGeneration = 0
    override var isFlipped: Bool { true }
    var mapArea: CGRect {
        CGRect(x: 12, y: 30, width: max(0, bounds.width - 24), height: max(0, bounds.height - 54))
    }
    var viewport: CGRect {
        CGRect(
            origin: canvas.world(.zero),
            size: CGSize(width: canvas.bounds.width / canvas.zoom, height: canvas.bounds.height / canvas.zoom)
        )
    }
    var geometry: MinimapGeometry? {
        if dragBoardID == canvas.store.board.id, let dragGeometry { return dragGeometry }
        let cards = canvas.store.board.cards
        let sections = canvas.store.board.sections ?? []
        if cards != extentCards || sections != extentSections {
            contentBounds = sections.reduce(cards.reduce(CGRect.null) { $0.union($1.rect) }) {
                $0.union(canvas.store.board.sectionBounds($1))
            }
            extentCards = cards
            extentSections = sections
        }
        return MinimapGeometry(contentBounds: contentBounds, viewport: viewport, area: mapArea)
    }

    init(canvas: BoardView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = 10_000_000
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        toolTip = "Click to jump · drag the view to explore · View → Show Minimap to hide"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            "Board minimap. Click or drag to navigate. Tab on the board cycles through items.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(mapArea, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext { render(in: context) }
    }

    func render(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let panel = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(panel)
        context.setFillColor(NSColor.pasteboardSurface.cgColor)
        context.fillPath()
        context.addPath(panel)
        context.setStrokeColor(NSColor.pasteboardBorder.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        func label(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
            let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: value,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    ]))
            context.saveGState()
            context.translateBy(x: x, y: y + 12)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: 2)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        label("BOARD MAP", x: 12, y: 8, size: 9, color: NSColor.pasteboardMuted.cgColor)
        label(
            "\(Int((canvas.zoom * 100).rounded()))%", x: bounds.width - 47, y: 8, size: 9,
            color: NSColor.pasteboardMuted.cgColor)
        label(
            "Click or drag to move", x: 12, y: bounds.height - 20, size: 9,
            color: NSColor.pasteboardMuted.cgColor)
        guard let geometry else { return }
        context.saveGState()
        context.clip(to: mapArea)
        updateArtwork(geometry)
        context.addPath(sectionOutline)
        context.setFillColor(NSColor.pasteboardAccent.withAlphaComponent(0.04).cgColor)
        context.fillPath()
        context.addPath(sectionOutline)
        context.setStrokeColor(NSColor.pasteboardMuted.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(0.6)
        context.strokePath()
        for (path, color) in fills {
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        }
        context.addPath(normalOutline)
        context.setStrokeColor(NSColor.pasteboardMuted.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(0.5)
        context.strokePath()
        context.addPath(selectedOutline)
        context.setStrokeColor(NSColor.pasteboardAccent.cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        let raw = geometry.project(viewport)
        let view = CGRect(
            x: raw.midX - max(4, raw.width) / 2, y: raw.midY - max(4, raw.height) / 2,
            width: max(4, raw.width), height: max(4, raw.height))
        context.setFillColor(NSColor.pasteboardAccent.withAlphaComponent(0.07).cgColor)
        context.fill(view)
        context.setStrokeColor(NSColor.pasteboardAccent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(view)
        context.restoreGState()
    }

    private func updateArtwork(_ geometry: MinimapGeometry) {
        let cards = canvas.store.board.cards
        let sections = canvas.store.board.sections ?? []
        let dark = effectiveAppearance.isPasteboardDark
        guard
            artworkCards != cards || artworkSections != sections || artworkSelection != canvas.selection
                || artworkGeometry != geometry
                || artworkDark != dark
        else { return }
        artworkCards = cards
        artworkSections = sections
        artworkSelection = canvas.selection
        artworkGeometry = geometry
        artworkDark = dark
        artworkGeneration += 1
        var paths: [String: (CGMutablePath, CGColor)] = [:]
        normalOutline = CGMutablePath()
        selectedOutline = CGMutablePath()
        sectionOutline = CGMutablePath()
        for section in sections {
            sectionOutline.addRect(geometry.project(canvas.store.board.sectionBounds(section)))
        }
        for card in cards {
            let raw = geometry.project(card.rect)
            let rect = CGRect(
                x: raw.midX - max(2, raw.width) / 2, y: raw.midY - max(2, raw.height) / 2,
                width: max(2, raw.width), height: max(2, raw.height))
            let key = card.hex ?? (card.text != nil ? "note-\(card.tone)" : "image")
            let fill =
                card.hex.flatMap { SwatchColor($0)?.color }
                ?? (card.text != nil ? canvas.noteColor(card.tone).cgColor : NSColor(hex: 0xB2BAC9).cgColor)
            if paths[key] == nil { paths[key] = (CGMutablePath(), fill) }
            paths[key]?.0.addRect(rect)
            (canvas.selection.contains(card.id) ? selectedOutline : normalOutline).addRect(rect)
        }
        fills = paths.keys.sorted().compactMap { paths[$0].map { ($0.0, $0.1) } }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard mapArea.contains(point), canvas.canNavigateMinimap, let geometry else { return }
        dragGeometry = geometry
        dragBoardID = canvas.store.board.id
        let world = geometry.worldPoint(point)
        grabOffset =
            geometry.project(viewport).insetBy(dx: -3, dy: -3).contains(point)
            ? CGPoint(x: world.x - viewport.midX, y: world.y - viewport.midY) : .zero
        canvas.window?.makeFirstResponder(canvas)
        NSCursor.closedHand.set()
        move(to: point)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { move(to: convert(event.locationInWindow, from: nil)) }
    private func move(to point: CGPoint) {
        guard dragBoardID == canvas.store.board.id, let dragGeometry else { return }
        let target = dragGeometry.worldPoint(point)
        canvas.navigateMinimap(to: CGPoint(x: target.x - grabOffset.x, y: target.y - grabOffset.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        move(to: convert(event.locationInWindow, from: nil))
        cancelNavigation()
    }
    func cancelNavigation() {
        dragGeometry = nil
        dragBoardID = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) { canvas.scrollWheel(with: event) }
}

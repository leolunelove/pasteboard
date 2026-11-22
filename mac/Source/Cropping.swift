import AppKit

// Coordinates are fractions of the upright original image, measured from its top left.
struct ImageCrop: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    static let full = ImageCrop(x: 0, y: 0, width: 1, height: 1)
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.0004
            && height >= 0.0004 && x + width <= 1.000000001 && y + height <= 1.000000001
    }
    func frame(in full: CGRect) -> CGRect {
        CGRect(
            x: full.minX + x * full.width, y: full.minY + y * full.height, width: width * full.width,
            height: height * full.height)
    }
    func image(_ original: CGImage) -> CGImage? {
        guard isValid else { return nil }
        if self == .full { return original }
        let pixels = CGRect(
            x: x * Double(original.width), y: y * Double(original.height),
            width: width * Double(original.width), height: height * Double(original.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: original.width, height: original.height))
        return original.cropping(to: pixels)
    }
    func applied(to card: Card) -> Card {
        guard card.asset != nil, isValid else { return card }
        let frame = frame(in: card.fullImageRect)
        guard frame.width >= 40 - 0.000001, frame.height >= 40 - 0.000001, frame.width < 100_000,
            frame.height < 100_000
        else { return card }
        var result = card
        result.x = frame.minX
        result.y = frame.minY
        result.width = max(40, frame.width)
        result.height = max(40, frame.height)
        result.crop = self == .full ? nil : self
        return result
    }
    // Each gesture starts from the current crop, avoiding cumulative rounding drift.
    func adjusted(handle: CropHandle, delta: CGPoint, full: CGRect) -> ImageCrop {
        let dx = delta.x / full.width
        let dy = delta.y / full.height
        let minimumW = min(1, max(0.0004, 40 / full.width))
        let minimumH = min(1, max(0.0004, 40 / full.height))
        if handle == .move {
            return ImageCrop(
                x: min(1 - width, max(0, x + dx)), y: min(1 - height, max(0, y + dy)), width: width,
                height: height)
        }
        var left = x
        var top = y
        var right = x + width
        var bottom = y + height
        if handle.left { left = max(0, min(right - minimumW, left + dx)) }
        if handle.right { right = min(1, max(left + minimumW, right + dx)) }
        if handle.top { top = max(0, min(bottom - minimumH, top + dy)) }
        if handle.bottom { bottom = min(1, max(top + minimumH, bottom + dy)) }
        return ImageCrop(x: left, y: top, width: right - left, height: bottom - top)
    }
}

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    var left: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var right: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var top: Bool { [.topLeft, .top, .topRight].contains(self) }
    var bottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: left ? rect.minX : right ? rect.maxX : rect.midX,
            y: top ? rect.minY : bottom ? rect.maxY : rect.midY)
    }
}

final class CropOverlay: NSView {
    unowned let canvas: BoardView
    let original: Card
    let boardID: UUID
    private(set) var draft: ImageCrop
    private var dragHandle: CropHandle?
    private var dragOrigin = CGPoint.zero
    private var gestureCrop = ImageCrop.full
    private let toolbar = NSVisualEffectView()
    private let dimensions = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { canvas.store.history }
    var fullRect: CGRect { original.fullImageRect }
    var cropFrame: CGRect { canvas.screen(draft.frame(in: fullRect)) }
    init(canvas: BoardView, card: Card) {
        self.canvas = canvas
        original = card
        boardID = canvas.store.board.id
        draft = card.imageCrop
        super.init(frame: canvas.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityElement(false)
        toolbar.material = .popover
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        let title = NSTextField(labelWithString: "Crop image")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Reset", target: self, action: #selector(reset(_:)))
        let cancel = NSButton(
            title: "Cancel", target: canvas, action: #selector(BoardView.cancelCropping(_:)))
        let apply = NSButton(
            title: "Apply Crop", target: canvas, action: #selector(BoardView.applyCropping(_:)))
        apply.bezelColor = .pasteboardAccent
        apply.contentTintColor = .white
        for button in [reset, cancel, apply] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        reset.toolTip = "Show the full original image"
        cancel.toolTip = "Cancel crop (Esc)"
        apply.toolTip = "Apply crop (Return)"
        let stack = NSStackView(views: [title, dimensions, reset, cancel, apply])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -10),
        ])
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateLabel() {
        dimensions.stringValue = String(
            format: "%.0f × %.0f", draft.width * fullRect.width, draft.height * fullRect.height)
        needsDisplay = true
    }
    @objc func reset(_ sender: Any?) {
        draft = .full
        updateLabel()
        canvas.window?.makeFirstResponder(self)
    }
    override func draw(_ dirtyRect: NSRect) {
        if let asset = original.asset,
            let preview = canvas.store.preview(
                asset,
                pixelSize: max(fullRect.width, fullRect.height) * canvas.zoom
                    * (window?.backingScaleFactor ?? 2))
        {
            let image = NSImage(cgImage: preview, size: CGSize(width: preview.width, height: preview.height))
            image.draw(
                in: canvas.screen(fullRect), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
        }
        let crop = cropFrame
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(crop)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.47).setFill()
        shade.fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: crop)
        border.lineWidth = 1.5
        border.stroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.75
        for i in 1...2 {
            let fraction = CGFloat(i) / 3
            grid.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
            grid.line(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
            grid.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
            grid.line(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
        }
        NSColor.white.withAlphaComponent(0.45).setStroke()
        grid.stroke()
        for handle in CropHandle.allCases where handle != .move {
            let point = handle.point(in: crop)
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            NSColor.pasteboardAccent.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    func handle(at point: CGPoint) -> CropHandle? {
        for handle in CropHandle.allCases where handle != .move {
            let p = handle.point(in: cropFrame)
            if abs(point.x - p.x) <= 11 && abs(point.y - p.y) <= 11 { return handle }
        }
        return cropFrame.contains(point) ? .move : nil
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toolbar.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        switch handle(at: point) {
        case .move: NSCursor.openHand.set()
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case nil: NSCursor.arrow.set()
        default: NSCursor.crosshair.set()
        }
    }
    override func mouseDown(with event: NSEvent) {
        canvas.window?.makeFirstResponder(self)
        dragHandle = handle(at: convert(event.locationInWindow, from: nil))
        dragOrigin = canvas.world(convert(event.locationInWindow, from: nil))
        gestureCrop = draft
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragHandle else { return }
        let point = canvas.world(convert(event.locationInWindow, from: nil))
        draft = gestureCrop.adjusted(
            handle: dragHandle, delta: CGPoint(x: point.x - dragOrigin.x, y: point.y - dragOrigin.y),
            full: fullRect)
        updateLabel()
        (dragHandle == .move ? NSCursor.closedHand : NSCursor.crosshair).set()
    }
    override func mouseUp(with event: NSEvent) {
        dragHandle = nil
        NSCursor.arrow.set()
    }
    override func scrollWheel(with event: NSEvent) {
        guard dragHandle == nil else { return }
        canvas.scrollWheel(with: event)
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard dragHandle == nil else { return }
        canvas.magnify(with: event)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: canvas.cancelCropping(nil)
        case 36, 76: canvas.applyCropping(nil)
        case 123, 124, 125, 126:
            let amount: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            draft = draft.adjusted(
                handle: .move,
                delta: CGPoint(
                    x: event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0,
                    y: event.keyCode == 126 ? -amount : event.keyCode == 125 ? amount : 0), full: fullRect)
            updateLabel()
        default: super.keyDown(with: event)
        }
    }
}

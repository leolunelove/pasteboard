import AppKit

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            NSColor(hex: appearance.isPasteboardDark ? dark : light)
        }
    }
    static let pasteboardInk = adaptive("Ink", light: 0x242629, dark: 0xECEEF3)
    static let pasteboardAccent = adaptive("Accent", light: 0x3456C8, dark: 0x97ADFF)
    static let pasteboardAction = adaptive("Action", light: 0x3456C8, dark: 0x4564D9)
    static let pasteboardCanvas = adaptive("Canvas", light: 0xF7F7F5, dark: 0x191B20)
    static let pasteboardMuted = adaptive("Muted", light: 0x656A73, dark: 0xA1A7B3)
    static let pasteboardChrome = adaptive("Chrome", light: 0xEEEEEC, dark: 0x212329)
    static let pasteboardSurface = adaptive("Surface", light: 0xFFFFFF, dark: 0x2A2D35)
    static let pasteboardBorder = adaptive("Border", light: 0xDCDDD9, dark: 0x3B3F49)
    static let pasteboardGrid = adaptive("Grid", light: 0xDDDEDB, dark: 0x33363E)
    static let pasteboardSelection = adaptive("Selection", light: 0xE1E7FB, dark: 0x313D62)
    // Artwork remains paper coloured in either appearance, including exports.
    static let pasteboardNoteInk = NSColor(hex: 0x242629)
}

extension NSAppearance {
    var isPasteboardDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

enum PasteboardAppearance: String, CaseIterable {
    case system, light, dark
    static let defaultsKey = "PasteboardAppearance"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    func apply() { NSApp.appearance = appearance }
    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        apply()
    }
}

enum PasteboardArtwork {
    // A single vector original supplies the sidebar, empty state, and every
    // AppIcon size. Coordinates below use a 1024-point, top-left-origin tile.
    static func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
        let tile = CGPath(
            roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 200, cornerHeight: 200,
            transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 9), blur: 14, color: CGColor(gray: 0, alpha: 0.13))
        context.addPath(tile)
        context.setFillColor(NSColor(hex: 0x3456C8).cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(tile)
        context.clip()
        let colors = [NSColor(hex: 0x4D6DE1).cgColor, NSColor(hex: 0x2F49B3).cgColor] as CFArray
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 180, y: 64), end: CGPoint(x: 820, y: 960), options: [])
        context.restoreGState()
        context.addPath(tile)
        context.setLineWidth(2)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.strokePath()
        context.saveGState()
        context.translateBy(x: 435, y: 477)
        context.rotate(by: -0.16)
        let back = CGRect(x: -175, y: -246, width: 350, height: 474)
        context.setShadow(offset: CGSize(width: 0, height: 8), blur: 16, color: CGColor(gray: 0, alpha: 0.14))
        context.addPath(CGPath(roundedRect: back, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.setFillColor(NSColor(hex: 0xB9C9FA).cgColor)
        context.fillPath()
        context.restoreGState()
        let front = CGMutablePath()
        front.move(to: CGPoint(x: 404, y: 310))
        front.addLine(to: CGPoint(x: 638, y: 310))
        front.addLine(to: CGPoint(x: 750, y: 422))
        front.addLine(to: CGPoint(x: 750, y: 774))
        front.addQuadCurve(to: CGPoint(x: 726, y: 798), control: CGPoint(x: 750, y: 798))
        front.addLine(to: CGPoint(x: 404, y: 798))
        front.addQuadCurve(to: CGPoint(x: 380, y: 774), control: CGPoint(x: 380, y: 798))
        front.addLine(to: CGPoint(x: 380, y: 334))
        front.addQuadCurve(to: CGPoint(x: 404, y: 310), control: CGPoint(x: 380, y: 310))
        front.closeSubpath()
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 12), blur: 18, color: CGColor(gray: 0.05, alpha: 0.18))
        context.addPath(front)
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        context.restoreGState()
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: 638, y: 310))
        fold.addLine(to: CGPoint(x: 638, y: 398))
        fold.addQuadCurve(to: CGPoint(x: 662, y: 422), control: CGPoint(x: 638, y: 422))
        fold.addLine(to: CGPoint(x: 750, y: 422))
        fold.closeSubpath()
        context.addPath(fold)
        context.setFillColor(NSColor(hex: 0xDDE5FD).cgColor)
        context.fillPath()
        context.setFillColor(NSColor(hex: 0x3456C8).cgColor)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 430, y: 642, width: 62, height: 62), cornerWidth: 10, cornerHeight: 10,
                transform: nil))
        context.fillPath()
        for (y, width) in [(652.0, 153.0), (682, 106)] {
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 516, y: y, width: width, height: 10), cornerWidth: 5,
                    cornerHeight: 5, transform: nil))
            context.fillPath()
        }
    }
    static func icon(pixels: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        draw(in: context, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()!
    }
    static let smallIcon = NSImage(cgImage: icon(pixels: 128), size: CGSize(width: 32, height: 32))
}

class PasteboardHoverButton: NSButton {
    private(set) var hovering = false
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

final class PasteboardToolbarButton: PasteboardHoverButton {
    var primary = false
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        let foreground: NSColor = primary ? .white : .pasteboardInk
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        let fill: NSColor
        if primary {
            let opacity: CGFloat = pressed ? 0.8 : (hovering ? 0.9 : 1)
            fill = NSColor.pasteboardAction.withAlphaComponent(opacity)
        } else if pressed || (hovering && isEnabled) {
            fill = .pasteboardSelection
        } else {
            fill = NSColor.pasteboardSurface.withAlphaComponent(isEnabled ? 1 : 0.4)
        }
        fill.setFill()
        panel.fill()
        if !primary {
            NSColor.pasteboardBorder.setStroke()
            panel.lineWidth = 1
            panel.stroke()
        }
        let textFont = font ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont, .foregroundColor: foreground.withAlphaComponent(isEnabled ? 1 : 0.4),
        ]
        let text = title.size(withAttributes: attrs)
        let iconWidth: CGFloat = image == nil ? 0 : 15
        let gap: CGFloat = image == nil ? 0 : 6
        let left = (bounds.width - text.width - iconWidth - gap) / 2
        if let image {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(
                .init(paletteColors: [foreground.withAlphaComponent(isEnabled ? 1 : 0.4)]))
            (image.withSymbolConfiguration(config) ?? image).draw(
                in: CGRect(x: left, y: bounds.midY - 7.5, width: 15, height: 15))
        }
        title.draw(
            at: CGPoint(x: left + iconWidth + gap, y: bounds.midY - text.height / 2), withAttributes: attrs)
        if window?.firstResponder === self {
            NSColor.pasteboardAccent.withAlphaComponent(0.5).setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}

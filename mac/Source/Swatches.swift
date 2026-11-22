import AppKit
import CoreText

struct SwatchColor {
    let hex: String
    let red: Double
    let green: Double
    let blue: Double
    static func normalized(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard [3, 6].contains(value.count), value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        if value.count == 3 { value = value.map { String(repeating: String($0), count: 2) }.joined() }
        return "#" + value.uppercased()
    }
    static func hex(for color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let bytes = values.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
    init?(_ input: String) {
        guard let hex = Self.normalized(input), let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.hex = hex; red = Double((rgb >> 16) & 255) / 255; green = Double((rgb >> 8) & 255) / 255; blue = Double(rgb & 255) / 255
    }
    var color: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])! }
    var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    var lightText: Bool { 1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05 }
    var textColor: CGColor { CGColor(gray: lightText ? 1 : 0, alpha: 1) }
    var contrast: Double { lightText ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05 }
}

enum SwatchArtwork {
    struct Style {
        let font: CTFont
        let padding: CGFloat
        let frame: CGRect
        let color: SwatchColor
        var string: NSAttributedString {
            NSAttributedString(string: color.hex, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.textColor])
        }
    }
    static func style(hex: String, size: CGSize, scale: CGFloat) -> Style {
        let padding = min(18 * scale, size.width * 0.12, size.height * 0.12)
        let fontSize = max(1, min(18 * scale, (size.width - 2 * padding) / 4.4, (size.height - 2 * padding) / 1.4))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + 2)
        return Style(font: font, padding: padding, frame: CGRect(x: padding, y: size.height - padding - height, width: size.width - 2 * padding, height: height), color: SwatchColor(hex)!)
    }
    // Both the board layer and exports use this style; coordinates are top-left.
    static func draw(_ card: Card, in context: CGContext) {
        guard let hex = card.hex, SwatchColor(hex) != nil else { return }
        let style = style(hex: hex, size: card.rect.size, scale: card.renderScale)
        context.saveGState(); context.setFillColor(style.color.color)
        context.addPath(CGPath(roundedRect: card.rect, cornerWidth: 7 * card.renderScale, cornerHeight: 7 * card.renderScale, transform: nil)); context.fillPath()
        context.translateBy(x: card.x + style.padding, y: card.y + card.height - style.padding - CTFontGetDescent(style.font))
        context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(CTLineCreateWithAttributedString(style.string), context)
        context.restoreGState()
    }
}

extension BoardStore {
    @discardableResult func addSwatch(hex: String, at point: CGPoint) -> UUID? {
        guard let hex = SwatchColor.normalized(hex) else { return nil }
        let card = Card(x: point.x, y: point.y, width: 220, height: 180, hex: hex)
        replaceCards(board.cards + [card], name: "Add Colour Swatch"); return card.id
    }
    @discardableResult func setSwatch(_ id: UUID, hex: String, boardID: UUID) -> Bool {
        guard let hex = SwatchColor.normalized(hex), let boardIndex = workspace.boards.firstIndex(where: { $0.id == boardID }), let index = workspace.boards[boardIndex].cards.firstIndex(where: { $0.id == id && $0.hex != nil }), !workspace.boards[boardIndex].lockedIDs.contains(id) else { return false }
        var cards = workspace.boards[boardIndex].cards; cards[index].hex = hex
        replaceCards(cards, name: "Edit Colour Swatch", boardID: boardID); return true
    }
}

final class SwatchPreview: NSView {
    var hex = "#32654D" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        SwatchArtwork.draw(Card(x: 0, y: 0, width: bounds.width, height: bounds.height, hex: hex), in: context)
    }
}

final class SwatchEditor: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let well = NSColorWell()
    private let preview = SwatchPreview()
    private let error = NSTextField(labelWithString: "")
    var validityChanged: ((Bool) -> Void)?
    var hex: String? { SwatchColor.normalized(field.stringValue) }
    init(hex: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 180))
        preview.frame = CGRect(x: 0, y: 6, width: 170, height: 168); addSubview(preview)
        let label = NSTextField(labelWithString: "HEX colour"); label.frame = CGRect(x: 190, y: 142, width: 160, height: 20); label.font = .systemFont(ofSize: 12, weight: .medium); addSubview(label)
        field.frame = CGRect(x: 190, y: 104, width: 160, height: 28); field.font = .monospacedSystemFont(ofSize: 15, weight: .medium); field.placeholderString = "#32654D"; field.stringValue = hex; field.delegate = self; field.setAccessibilityLabel("HEX colour value"); addSubview(field)
        well.frame = CGRect(x: 190, y: 55, width: 58, height: 34); well.target = self; well.action = #selector(picked(_:)); well.setAccessibilityLabel("Choose swatch colour"); addSubview(well)
        error.frame = CGRect(x: 190, y: 10, width: 165, height: 34); error.font = .systemFont(ofSize: 10); error.textColor = .systemRed; error.maximumNumberOfLines = 2; error.lineBreakMode = .byWordWrapping; addSubview(error)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ obj: Notification) { update() }
    private func update() {
        if let color = SwatchColor(field.stringValue) {
            preview.hex = color.hex; well.color = NSColor(cgColor: color.color)!; error.stringValue = ""; validityChanged?(true)
        } else { error.stringValue = "Enter 3 or 6 hex digits, such as #32654D."; validityChanged?(false) }
    }
    @objc private func picked(_ sender: Any?) {
        guard let hex = SwatchColor.hex(for: well.color) else { return }
        field.stringValue = hex; update()
    }
}

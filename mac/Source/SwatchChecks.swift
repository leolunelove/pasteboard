import AppKit
import CoreText
import ImageIO

func swatchTest(directory: URL) throws {
    try check(SwatchColor.normalized(" #aBc \n") == "#AABBCC")
    try check(SwatchColor.normalized("00ffaa") == "#00FFAA")
    for bad in ["", "red", "#12", "#1234", "#12345678", "#GG0000", "##FFFFFF", "#１２３"] {
        try check(SwatchColor.normalized(bad) == nil)
    }
    try check(SwatchColor.hex(for: NSColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 0.2)) == "#FF0080")
    for level in 0...255 {
        let value = String(format: "#%02X%02X%02X", level, level, level)
        try check(SwatchColor(value)!.contrast >= 4.5)
    }
    let store = BoardStore(directory: directory)
    let note = Card(x: -300, y: 0, width: 220, height: 140, text: "Keep this note")
    store.board.cards = [note]
    let id = store.addSwatch(hex: "f0a", at: .zero)!
    try check(store.board.cards.last!.hex == "#FF00AA" && store.board.cards[0] == note)
    let original = store.board.cards.last!
    let boardID = store.board.id
    try check(BoardStore.valid(original) && store.setSwatch(id, hex: "#32654d", boardID: boardID))
    try check(store.board.cards.last!.hex == "#32654D")
    store.history.undo()
    try check(store.board.cards.last! == original)
    store.history.redo()
    try check(store.board.cards.last!.hex == "#32654D")
    try check(!store.setSwatch(id, hex: "bad hex", boardID: boardID))
    let group = UUID()
    store.board.cards[0].groupID = group
    store.board.cards[0].locked = true
    store.board.cards[1].groupID = group
    try check(!store.setSwatch(id, hex: "#000000", boardID: boardID))
    store.board.cards[0].locked = nil
    let swatch = store.board.cards.last!
    let copies = Card.copies(of: [swatch, store.board.cards[0]])
    try check(
        copies[0].hex == swatch.hex && copies[0].groupID != group && copies[0].groupID == copies[1].groupID)
    let scaled = Card.scaled([swatch], ids: [id], around: .zero, by: 2)[0]
    try check(scaled.hex == swatch.hex && scaled.renderScale == 2 && scaled.width == swatch.width * 2)
    try check(
        BoardSearch.results(in: store.workspace, imageText: [:], query: "32654d").contains {
            $0.cardID == id && $0.title == "#32654D" && $0.detail.contains("Colour swatch")
        })
    let target = store.newPage(in: boardID, name: "Palette")!
    let moved = store.moveCards([id], from: boardID, to: target, viewport: CGSize(width: 1000, height: 700))!
    try check(moved.count == 2 && store.board.cards.contains { $0.hex == "#32654D" })
    store.history.undo()
    try check(store.board.id == boardID && store.board.cards.last!.hex == swatch.hex)
    try check(store.save())
    let reopened = BoardStore(directory: directory)
    try check(reopened.board.cards == store.board.cards)
    try reopened.importBoard(data: store.portableData())
    try check(reopened.board.cards.contains { $0.hex == "#32654D" })
    let record = store.backups.records().first!
    let restored = try store.backups.restoredBoards(
        from: record, assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    try check(restored.contains { $0.cards.contains { $0.hex == "#32654D" } })
    try check(!BoardStore.valid(Card(x: 0, y: 0, width: 220, height: 180, hex: "#abc")))
    try check(!BoardStore.valid(Card(x: 0, y: 0, width: 220, height: 180, text: "ambiguous", hex: "#AABBCC")))
    let legacy = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(note))
    try check(legacy.hex == nil)

    // The exact visible HEX label is shared between retained layers and exports.
    for size in [
        CGSize(width: 40, height: 40), CGSize(width: 80, height: 200), CGSize(width: 600, height: 40),
        CGSize(width: 440, height: 360),
    ] {
        for scale in [0.02, 1.0, 2.0, 64.0] {
            let style = SwatchArtwork.style(hex: "#32654D", size: size, scale: scale)
            let line = CTLineCreateWithAttributedString(style.string)
            try check(
                style.string.string == "#32654D" && style.frame.minY >= 0 && style.frame.maxY <= size.height
                    && CTLineGetTypographicBounds(line, nil, nil, nil) <= style.frame.width)
        }
    }
    for hex in ["#FFAA00", "#32654D", "#FFFFFF"] {
        let card = Card(x: 0, y: 0, width: 220, height: 180, hex: hex)
        let export = BoardExport(cards: [card], assets: directory, padding: 0)
        let png = try export.png(scale: 1, transparent: true)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
        try check(image.width == 220 && image.height == 180)
        let context = CGContext(
            data: nil, width: 220, height: 180, bitsPerComponent: 8, bytesPerRow: 880,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 220, height: 180))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let color = SwatchColor(hex)!
        let at = (50 * 220 + 50) * 4
        try check(
            abs(Int(bytes[at]) - Int((color.red * 255).rounded())) <= 1
                && abs(Int(bytes[at + 1]) - Int((color.green * 255).rounded())) <= 1
                && abs(Int(bytes[at + 2]) - Int((color.blue * 255).rounded())) <= 1 && bytes[at + 3] == 255)
        var labelPixels = 0
        var topPixels = 0
        for y in 10..<170 {
            for x in 15..<180 {
                let i = (y * 220 + x) * 4
                let isLabel =
                    bytes[i + 3] > 200
                    && (color.lightText
                        ? bytes[i] > 230 && bytes[i + 1] > 230 && bytes[i + 2] > 230
                        : Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 100)
                if isLabel {
                    if y > 120 { labelPixels += 1 }
                    if y < 50 { topPixels += 1 }
                }
            }
        }
        try check(labelPixels > 50 && topPixels == 0)
        let pdf = try export.pdf(transparent: true)
        let document = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
        try check(
            document.numberOfPages == 1
                && document.page(at: 1)!.getBoxRect(.mediaBox).size == CGSize(width: 220, height: 180))
    }
    print(
        "PASS: HEX normalization, contrast, swatch edits/undo/locks, grouping and transfer, search, persistence/portable files/backups, readable labels at all sizes, PNG colour and visible label, PDF"
    )
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BoardExport {
    let cards: [Card]
    let assets: URL
    var padding: CGFloat = 24
    var bounds: CGRect { cards.reduce(CGRect.null) { $0.union($1.rect) }.insetBy(dx: -padding, dy: -padding) }
    static func error(_ message: String) -> NSError {
        NSError(domain: "Gather.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func draw(in context: CGContext, area: CGRect, scale: CGFloat, transparent: Bool) throws {
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        if !transparent {
            context.setFillColor(NSColor(hex: 0xF7F7F5).cgColor)
            context.fill(area)
        }
        for card in cards {
            if card.hex != nil {
                SwatchArtwork.draw(card, in: context)
            } else if let asset = card.asset, BoardImageIO.isSVG(asset) {
                let svg = try SVGImage(data: Data(contentsOf: assets.appendingPathComponent(asset)))
                svg.draw(card, in: context)
            } else if let asset = card.asset {
                guard
                    let source = CGImageSourceCreateWithURL(
                        assets.appendingPathComponent(asset) as CFURL, nil),
                    let original = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: min(
                                16000, max(card.fullImageRect.width, card.fullImageRect.height) * scale),
                        ] as CFDictionary), let image = card.imageCrop.image(original)
                else { throw Self.error("An image could not be read. Your board has not changed.") }
                context.saveGState()
                context.translateBy(x: card.x, y: card.y + card.height)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: card.width, height: card.height))
                context.restoreGState()
            } else {
                let tones: [NSColor] = [
                    .white, NSColor(hex: 0xFCF0C9), NSColor(hex: 0xDFEBDD), NSColor(hex: 0xF4DFD7),
                ]
                context.setFillColor(tones[max(0, min(3, card.tone))].cgColor)
                context.addPath(
                    CGPath(
                        roundedRect: card.rect, cornerWidth: 7 * card.renderScale,
                        cornerHeight: 7 * card.renderScale, transform: nil))
                context.fillPath()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                (card.text ?? "").draw(
                    with: card.rect.insetBy(dx: 20 * card.renderScale, dy: 19 * card.renderScale),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 18 * card.renderScale),
                        .foregroundColor: NSColor.pasteboardNoteInk, .paragraphStyle: paragraph,
                    ])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
    func png(scale: CGFloat, transparent: Bool) throws -> Data {
        guard !cards.isEmpty else { throw Self.error("Add something to the board before exporting.") }
        let area = bounds
        let width = ceil(area.width * scale)
        let height = ceil(area.height * scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 16000, height <= 16000,
            width * height <= 64_000_000
        else { throw Self.error("This export is too large. Select a smaller area or choose 1× size.") }
        guard
            let context = CGContext(
                data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Self.error("There isn’t enough memory to export this area.") }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        try draw(in: context, area: area, scale: scale, transparent: transparent)
        guard let image = context.makeImage() else { throw Self.error("The image could not be rendered.") }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw Self.error("PNG export is unavailable.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Self.error("PNG export could not finish.")
        }
        return data as Data
    }
    func pdf(transparent: Bool) throws -> Data {
        guard !cards.isEmpty else { throw Self.error("Add something to the board before exporting.") }
        let area = bounds
        let scale = min(1, 14400 / max(area.width, area.height))
        var page = CGRect(x: 0, y: 0, width: area.width * scale, height: area.height * scale)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &page, nil)
        else { throw Self.error("PDF export is unavailable.") }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: page.height)
        context.scaleBy(x: 1, y: -1)
        try draw(in: context, area: area, scale: scale, transparent: transparent)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

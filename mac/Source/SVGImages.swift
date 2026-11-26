import AppKit
import ImageIO
import UniformTypeIdentifiers

final class SVGImage {
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .init(UTType.svg.identifier), .init("public.svg"),
    ]
    static func clipboardData(from item: NSPasteboardItem) -> Data? {
        for type in pasteboardTypes where item.types.contains(type) {
            if let data = item.data(forType: type), !data.isEmpty { return data }
        }
        if let mime = item.types.first(where: { $0.rawValue == "image/svg+xml" }),
            let data = item.data(forType: mime), !data.isEmpty
        {
            return data
        }
        for type in [NSPasteboard.PasteboardType.string, .html] {
            if let text = item.string(forType: type) {
                let data = Data(text.utf8)
                if looksLikeSVG(data) { return data }
            }
        }
        return DesignClipboard.embeddedImage(item, svgOnly: true)
    }
    let original: Data
    let renderingData: Data
    let image: NSImage
    var size: CGSize { image.size }
    static func error(_ message: String) -> NSError {
        NSError(domain: "Gather.SVG", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func xmlText(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0x3c, 0x00]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0x00, 0x3c]) { return String(data: data, encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
    static func looksLikeSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(8192)
        guard let text = xmlText(Data(prefix)) else { return false }
        let value = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        return value.range(
            of:
                #"(?is)^\s*(?:<\?.*?\?>\s*|<!--.*?-->\s*|<!DOCTYPE\s+svg\b.*?>\s*)*<(?:[a-z_][\w.-]*:)?svg(?=[\s>/])"#,
            options: .regularExpression) != nil
    }
    init(data: Data) throws {
        guard data.count <= 32 * 1024 * 1024 else {
            throw Self.error("This SVG is too large to import. Try a smaller SVG.")
        }
        guard let text = Self.xmlText(data), text.range(of: "<!ENTITY", options: .caseInsensitive) == nil
        else { throw Self.error("This SVG contains unsupported entity definitions.") }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), (root.localName ?? root.name)?.lowercased() == "svg" else {
            throw Self.error("The clipboard does not contain a valid SVG image.")
        }
        var stack: [(XMLElement, Int)] = [(root, 0)]
        var count = 0
        let forbidden = Set([
            "script", "foreignobject", "iframe", "object", "embed", "audio", "video", "animate",
            "animatemotion", "animatetransform", "set",
        ])
        let urls = try NSRegularExpression(pattern: #"(?is)url\s*\(\s*([^)]*)\)"#)
        func localReference(_ value: String) -> Bool {
            let value = value.trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            if value.isEmpty || value.hasPrefix("#") { return true }
            guard
                [
                    "data:image/png;base64,", "data:image/jpeg;base64,", "data:image/jpg;base64,",
                    "data:image/gif;base64,", "data:image/webp;base64,",
                ].contains(where: { value.lowercased().hasPrefix($0) }),
                let comma = value.firstIndex(of: ","),
                let bytes = Data(
                    base64Encoded: String(value[value.index(after: comma)...]),
                    options: .ignoreUnknownCharacters),
                let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                CGImageSourceGetType(source) != nil
            else { return false }
            return true
        }
        func checkURLs(_ value: String) throws {
            guard value.range(of: "@import", options: .caseInsensitive) == nil else {
                throw Self.error("Embed linked images and styles before importing this SVG.")
            }
            for match in urls.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                if let range = Range(match.range(at: 1), in: value), !localReference(String(value[range])) {
                    throw Self.error("Embed linked images and styles before importing this SVG.")
                }
            }
        }
        while let (element, depth) = stack.popLast() {
            count += 1
            guard depth <= 128, count <= 100_000 else {
                throw Self.error("This SVG is too complex to import.")
            }
            let name = (element.localName ?? element.name ?? "").lowercased()
            guard !forbidden.contains(name) else {
                throw Self.error("Use a static SVG without scripts, animation, or embedded HTML.")
            }
            for attribute in element.attributes ?? [] {
                let key = (attribute.localName ?? attribute.name ?? "").lowercased()
                let value = attribute.stringValue ?? ""
                guard !key.hasPrefix("on"), key != "base" else {
                    throw Self.error("Use a static, self-contained SVG image.")
                }
                if ["href", "src"].contains(key), !localReference(value) {
                    if name == "a" {
                        element.removeAttribute(forName: attribute.name!)
                        continue
                    }
                    throw Self.error("Embed linked images before importing this SVG.")
                }
                try checkURLs(value)
            }
            if name == "style" { try checkURLs(element.stringValue ?? "") }
            for child in element.children ?? [] {
                if child.kind == .processingInstruction {
                    child.detach()
                } else if let child = child as? XMLElement {
                    stack.append((child, depth + 1))
                }
            }
        }
        // Serialize only the SVG root: the original bytes are retained, but DTDs
        // and processing instructions are never handed to the image renderer.
        let safeData = Data(root.xmlString.utf8)
        guard let image = NSImage(data: safeData), image.size.width.isFinite, image.size.height.isFinite,
            image.size.width > 0, image.size.height > 0
        else { throw Self.error("This SVG could not be rendered.") }
        image.cacheMode = .never
        original = data
        renderingData = safeData
        self.image = image
    }
    func rasterized(maxPixel: Int, crop: ImageCrop = .full) throws -> CGImage {
        guard crop.isValid else { throw Self.error("The SVG crop is invalid.") }
        let area = crop.frame(in: CGRect(origin: .zero, size: size)).size
        let limit = CGFloat(min(4096, max(64, maxPixel)))
        let factor = limit / max(area.width, area.height)
        let width = min(Int(limit), max(1, Int(ceil(area.width * factor))))
        let height = min(Int(limit), max(1, Int(ceil(area.height * factor))))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Self.error("There isn’t enough memory to preview this SVG.") }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / area.width, y: -CGFloat(height) / area.height)
        draw(Card(x: 0, y: 0, width: area.width, height: area.height, crop: crop), in: context)
        guard let result = context.makeImage() else { throw Self.error("This SVG could not be previewed.") }
        return result
    }
    func draw(_ card: Card, in context: CGContext) {
        context.saveGState()
        context.clip(to: card.rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(
            in: card.fullImageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
    func clipboardData(crop: ImageCrop) throws -> Data {
        guard crop.isValid else { throw Self.error("The SVG crop is invalid.") }
        if crop == .full { return original }
        let innerDocument = try XMLDocument(data: renderingData)
        let inner = innerDocument.rootElement()!
        for (key, value) in [
            ("x", "0"), ("y", "0"), ("width", String(Double(size.width))),
            ("height", String(Double(size.height))),
        ] {
            inner.removeAttribute(forName: key)
            inner.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
        let area = crop.frame(in: CGRect(origin: .zero, size: size))
        return Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(area.width)\" height=\"\(area.height)\" viewBox=\"\(area.minX) \(area.minY) \(area.width) \(area.height)\">\(inner.xmlString)</svg>"
                .utf8)
    }
}

enum BoardImageIO {
    struct Decoded {
        let preview: CGImage
        let size: CGSize
        let fileExtension: String
    }
    static func pasteboardType(for data: Data) -> NSPasteboard.PasteboardType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source)
        else { return nil }
        return .init(type as String)
    }
    static func previewLevel(_ size: CGFloat) -> Int {
        let pixels = size.isFinite ? min(4096, max(512, size)) : 2048
        return pixels <= 512 ? 512 : pixels <= 1024 ? 1024 : pixels <= 2048 ? 2048 : 4096
    }
    static func decode(_ data: Data) throws -> Decoded {
        if SVGImage.looksLikeSVG(data) {
            let svg = try SVGImage(data: data)
            guard max(svg.size.width, svg.size.height) / min(svg.size.width, svg.size.height) < 2499 else {
                throw SVGImage.error("Use a tighter artboard for this very narrow SVG.")
            }
            return Decoded(preview: try svg.rasterized(maxPixel: 1024), size: svg.size, fileExtension: "svg")
        }
        let (source, image) = try LocalRead.retry {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = thumbnail(source, maxPixel: 2048)
            else { throw CocoaError(.fileReadCorruptFile) }
            return (source, image)
        }
        let ext =
            CGImageSourceGetType(source).flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "png"
        // Thumbnail rounding must not change the original's aspect ratio.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(image.width)
        let height =
            (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(image.height)
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = [5, 6, 7, 8].contains(orientation)
        let size = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            max(width, height) / min(width, height) < 2499
        else {
            throw SVGImage.error("Use a tighter crop for this very narrow image.")
        }
        return Decoded(preview: image, size: size, fileExtension: ext)
    }
    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }
    static func vectorKey(_ name: String, level: Int, crop: ImageCrop) -> String {
        name + "@\(level)" + (crop == .full ? "" : ":\(crop.x),\(crop.y),\(crop.width),\(crop.height)")
    }
    static func preview(at url: URL, maxPixel: Int = 2048, crop: ImageCrop = .full) -> CGImage? {
        if url.pathExtension.lowercased() == "svg" {
            return try? SVGImage(data: Data(contentsOf: url)).rasterized(maxPixel: maxPixel, crop: crop)
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { thumbnail($0, maxPixel: maxPixel) }
    }
    static func isSVG(_ name: String) -> Bool {
        URL(fileURLWithPath: name).pathExtension.lowercased() == "svg"
    }
}

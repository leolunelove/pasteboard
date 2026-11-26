import AppKit

// Clipboard exports only: no network requests or proprietary Figma node decoding.
enum DesignClipboard {
    static let limit = 32 * 1024 * 1024
    static func nativeFigma(_ item: NSPasteboardItem) -> Bool {
        if item.types.contains(where: { $0.rawValue.lowercased().contains("figma") }) { return true }
        guard let html = item.string(forType: .html), html.utf8.count <= limit else { return false }
        return html.contains("(figma)") || html.contains("(figmeta)")
    }
    static func embeddedImage(_ item: NSPasteboardItem, svgOnly: Bool = false) -> Data? {
        guard let html = item.string(forType: .html), html.utf8.count <= limit else { return nil }
        if let range = html.range(of: #"(?is)<svg\b[^>]*>.*?</svg\s*>"#, options: .regularExpression) {
            return Data(html[range].utf8)
        }
        guard let regex = try? NSRegularExpression(pattern: #"(?is)\bsrc\s*=\s*["'](data:image/[^"']+)["']"#)
        else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let comma = value.firstIndex(of: ",") else { continue }
            let header = value[..<comma].lowercased()
            let svg = header.hasPrefix("data:image/svg+xml")
            guard !svgOnly || svg else { continue }
            guard
                svg
                    || ["data:image/png", "data:image/jpeg", "data:image/webp", "data:image/gif"].contains(
                        where: { header.hasPrefix($0 + ";") || header == $0 })
            else { continue }
            let payload = String(value[value.index(after: comma)...])
            let bytes =
                header.contains(";base64")
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                : payload.removingPercentEncoding.map { Data($0.utf8) }
            if let bytes, !bytes.isEmpty, bytes.count <= limit, !svg || SVGImage.looksLikeSVG(bytes) {
                return bytes
            }
        }
        return nil
    }
}

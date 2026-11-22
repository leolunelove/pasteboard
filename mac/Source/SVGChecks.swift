import AppKit
import ImageIO

func svgTest(directory: URL) throws {
    let source = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="100" viewBox="0 0 200 100">
      <defs><linearGradient id="fade"><stop stop-color="#32654D"/><stop offset="1" stop-color="#80B89B"/></linearGradient><clipPath id="clip"><rect x="100" y="15" width="80" height="70" rx="10"/></clipPath></defs>
      <path d="M10 10 H80 V40 H10Z" fill="#FF0000"/>
      <g transform="translate(10,60)"><circle cx="25" cy="15" r="12" fill="#0000FF"/></g>
      <rect x="100" y="15" width="80" height="70" fill="url(#fade)" clip-path="url(#clip)"/>
      <use xlink:href="#nothing"/>
    </svg>
    """#
    let bytes = Data(source.utf8), svg = try SVGImage(data: bytes)
    try check(SVGImage.looksLikeSVG(bytes) && svg.size == CGSize(width: 200, height: 100))
    try check(!String(data: svg.renderingData, encoding: .utf8)!.contains("DOCTYPE"))
    try check(!SVGImage.looksLikeSVG(Data("A note about <svg> syntax".utf8)))
    let clipboard = NSPasteboardItem(); clipboard.setData(Data([1, 2, 3]), forType: .png); clipboard.setData(bytes, forType: SVGImage.pasteboardTypes[0])
    try check(SVGImage.clipboardData(from: clipboard) == bytes)
    let markup = NSPasteboardItem(); markup.setString(source, forType: .string); markup.setData(Data([1]), forType: .png)
    try check(SVGImage.clipboardData(from: markup) == bytes)
    let utf16 = source.replacingOccurrences(of: "UTF-8", with: "UTF-16").data(using: .utf16)!
    try check(SVGImage.looksLikeSVG(utf16)); let alternate = try SVGImage(data: utf16); try check(alternate.size == svg.size)
    let store = BoardStore(directory: directory)
    var prepared: [PreparedImage] = []; var failed = 0; var ready = false
    store.prepareImages([bytes], sourceURLs: ["https://example.com/original.svg"]) { images, failures in prepared = images; failed = failures; ready = true }
    try waitFor { ready }; try check(failed == 0 && prepared.count == 1)
    let asset = prepared[0].asset, url = directory.appendingPathComponent("Assets").appendingPathComponent(asset)
    let savedOriginal = try Data(contentsOf: url); try check(asset.hasSuffix(".svg") && savedOriginal == bytes && prepared[0].size == svg.size)
    var card = store.card(for: prepared[0], at: .zero); card.width = 200; card.height = 100
    try check(card.sourceURL == "https://example.com/original.svg")
    store.board.cards = [card]
    try waitFor { store.preview(asset, pixelSize: 4096).map { max($0.width, $0.height) == 4096 } == true }
    try check(store.preview(asset, pixelSize: 4096)!.width == 4096)
    let crop = ImageCrop(x: 0, y: 0, width: 0.5, height: 0.5)
    let highCrop = try svg.rasterized(maxPixel: 2048, crop: crop)
    try check(highCrop.width == 2048 && highCrop.height == 1024)
    // Actual rendered pixels prove alpha, upright orientation, paths, gradients and clips.
    func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let ptr = context.data!.assumingMemoryBound(to: UInt8.self) + (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: ptr, count: 4))
    }
    let raster = try svg.rasterized(maxPixel: 200)
    try check(rgba(raster, 0, 0)[3] == 0)
    try check(rgba(raster, 30, 20)[0] > 240 && rgba(raster, 30, 20)[2] < 10)
    try check(rgba(raster, 35, 75)[2] > 240 && rgba(raster, 35, 75)[0] < 10)
    try check(rgba(raster, 140, 50)[1] > rgba(raster, 140, 50)[0])
    try check(rgba(raster, 101, 16)[3] == 0 && rgba(raster, 110, 50)[0] < rgba(raster, 170, 50)[0])
    let export = BoardExport(cards: [card], assets: directory.appendingPathComponent("Assets"), padding: 0)
    let png = try export.png(scale: 4, transparent: true)
    let rendered = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
    try check(rendered.width == 800 && rendered.height == 400 && rgba(rendered, 0, 0)[3] == 0 && rgba(rendered, 120, 80)[0] > 240)
    let pdf = try export.pdf(transparent: true)
    try check(!String(decoding: pdf, as: UTF8.self).contains("/Subtype /Image"))
    let pdfDocument = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
    try check(pdfDocument.numberOfPages == 1 && pdfDocument.page(at: 1)!.getBoxRect(.mediaBox).size == CGSize(width: 200, height: 100))
    let croppedData = try svg.clipboardData(crop: crop), croppedSVG = try SVGImage(data: croppedData)
    try check(croppedSVG.size == CGSize(width: 100, height: 50))
    let cropped = try croppedSVG.rasterized(maxPixel: 200)
    try check(rgba(cropped, 60, 40)[0] > 240 && rgba(cropped, 60, 40)[2] < 10)
    store.board.cards[0] = crop.applied(to: card)
    try check(store.save()); let reopened = BoardStore(directory: directory); try check(reopened.board.cards == store.board.cards)
    try reopened.importBoard(data: store.portableData()); try check(reopened.board.cards[0].asset!.hasSuffix(".svg") && reopened.board.cards[0].crop == crop)
    let reimported = try Data(contentsOf: directory.appendingPathComponent("Assets").appendingPathComponent(reopened.board.cards[0].asset!)); try check(reimported == bytes)
    let record = store.backups.records().first!, restored = try store.backups.restoredBoards(from: record, assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    try check(restored[0].cards[0].asset!.hasSuffix(".svg"))
    let restoredBytes = try Data(contentsOf: directory.appendingPathComponent("RestoredAssets").appendingPathComponent(restored[0].cards[0].asset!)); try check(restoredBytes == bytes)
    for unsupported in [
        #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/remote.png"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><style>@import 'https://example.com/style.css';</style></svg>"#,
        #"<!DOCTYPE svg [<!ENTITY external SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg"><text>&external;</text></svg>"#
    ] { try check((try? SVGImage(data: Data(unsupported.utf8))) == nil) }
    let viewBoxOnly = try SVGImage(data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 40"><rect width="80" height="40" fill="#32654D"/></svg>"##.utf8))
    try check(abs(viewBoxOnly.size.width / viewBoxOnly.size.height - 2) < 0.001)
    let wide = try BoardImageIO.decode(Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="10"><rect width="1000" height="10"/></svg>"#.utf8))
    let wideCard = store.card(for: PreparedImage(asset: "wide.svg", preview: wide.preview, size: wide.size), at: .zero)
    try check(abs(wideCard.width / wideCard.height - 100) < 0.001)
    // Exercise the real receive/import entry points without using the user's clipboard.
    let pasteStore = BoardStore(directory: directory.appendingPathComponent("paste")), originalPage = pasteStore.board.id
    let view = BoardView(store: pasteStore)
    let pb = NSPasteboard(name: .init("Gather-SVG-check-" + UUID().uuidString)); defer { pb.releaseGlobally() }
    if pb.writeObjects([clipboard]) { try check(view.receive(pb, at: .zero)) }
    else { try check(view.receiveImageItems([clipboard], at: .zero)) }
    pasteStore.newBoard(name: "Other page")
    try waitFor { !view.hasPendingImports }
    let firstPaste = pasteStore.workspace.boards.first(where: { $0.id == originalPage })!.cards
    try check(firstPaste.count == 1 && firstPaste[0].asset!.hasSuffix(".svg") && pasteStore.board.cards.isEmpty)
    pb.clearContents()
    if pb.setString(source, forType: .string) { try check(view.receive(pb, at: .zero)) }
    else { try check(view.receiveImageItems([markup], at: .zero)) }
    try waitFor { !view.hasPendingImports }
    try check(pasteStore.board.cards.last!.asset!.hasSuffix(".svg") && pasteStore.board.cards.last!.text == nil)
    let fallback = NSPasteboardItem(); fallback.setData(Data(), forType: SVGImage.pasteboardTypes[0]); fallback.setData(png, forType: .png)
    try check(view.receiveImageItems([fallback], at: .zero)); try waitFor { !view.hasPendingImports }
    try check(pasteStore.board.cards.last!.asset!.hasSuffix(".png"))
    let file = directory.appendingPathComponent("Original.svg"); try bytes.write(to: file)
    view.importFiles([file]); try waitFor { !view.hasPendingImports }
    try check(pasteStore.board.cards.count == 3 && pasteStore.board.cards.last!.sourceURL == file.absoluteString)
    // Retained canvas content must replace its old full-image preview after a crop.
    var displayCard = card; displayCard.x = 0; displayCard.y = 0
    let root = CALayer(); root.bounds = CGRect(x: 0, y: 0, width: 200, height: 100); root.isGeometryFlipped = true
    let scene = CanvasScene(); root.addSublayer(scene.root)
    func update(_ item: Card) { store.board.cards = [item]; scene.update(cards: [item], selection: [], groups: [:], guides: [], editing: nil, zoom: 1, offset: .zero, store: store, color: { _ in .white }, backingScale: 1) }
    update(displayCard)
    displayCard = ImageCrop(x: 0.5, y: 0, width: 0.5, height: 1).applied(to: displayCard); displayCard.x = 0
    update(displayCard)
    try waitFor { store.preview(asset, pixelSize: 512, crop: displayCard.imageCrop) != nil }
    update(displayCard)
    func display(_ layer: CALayer) { layer.displayIfNeeded(); for child in layer.sublayers ?? [] { display(child) } }
    display(root); CATransaction.flush()
    let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1); root.render(in: context)
    let retained = rgba(context.makeImage()!, 40, 50)
    try check(retained[1] > retained[0] && retained[3] == 255)
    try png.write(to: directory.appendingPathComponent("SVG-export.png")); try pdf.write(to: directory.appendingPathComponent("SVG-export.pdf"))
    print("PASS: SVG MIME/plain markup priority, original bytes, alpha/orientation, gradients/clips, resolution upgrades, cropped vectors, PNG and vector PDF, file persistence/portable/backup, unsupported external content and wide aspect ratios")
}

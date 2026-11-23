import AppKit
import ImageIO
import UniformTypeIdentifiers

func imagePipelineTest(directory: URL) throws {
    var attempts = 0
    let recovered = try LocalRead.retry {
        attempts += 1
        if attempts == 1 { throw CocoaError(.fileReadCorruptFile) }
        return "readable"
    }
    try check(recovered == "readable" && attempts == 2)
    attempts = 0
    do {
        _ = try LocalRead.retry { () throws -> String in
            attempts += 1
            throw CocoaError(.fileReadCorruptFile)
        }
        try check(false)
    } catch { try check(attempts == 2) }
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    func imageData(width: Int, height: Int, type: UTType = .png, orientation: Int = 1) throws -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.6))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try check(CGImageDestinationFinalize(destination))
        return data as Data
    }
    for (width, height) in [(4097, 79), (64, 4096), (4096, 64), (257, 129)] {
        let bytes = try imageData(width: width, height: height)
        let decoded = try BoardImageIO.decode(bytes)
        try check(decoded.size == CGSize(width: width, height: height))
        var prepared: [PreparedImage] = []
        var done = false
        store.prepareImages([bytes]) { images, failed in
            prepared = images
            done = failed == 0
        }
        try waitFor { done }
        let card = store.card(for: prepared[0], at: .zero)
        try check(BoardStore.valid(card))
        try check(abs(card.width / card.height - Double(width) / Double(height)) < 0.000001)
        store.board.cards = [card]
        view.selection = [card.id]
        let item = view.clipboardItem()!
        try check(item.data(forType: .png) == bytes)
        try check(!item.types.contains(.tiff))
        try check(view.pasteInternalCards(item.data(forType: .init("fun.leolune.gather.cards"))!, at: .zero))
        try check(!view.hasPendingImports && store.board.cards.count == 2)
        let pasted = store.board.cards.last!
        try check(pasted.asset == card.asset && pasted.id != card.id)
        try check(pasted.width == card.width && pasted.height == card.height)
        try check(store.originalImageData(card.asset!) == bytes)
    }
    let rotated = try BoardImageIO.decode(imageData(width: 128, height: 64, type: .tiff, orientation: 6))
    try check(rotated.size == CGSize(width: 64, height: 128))
    try check(rotated.preview.height > rotated.preview.width)
    try check(!store.hasAsset("../outside.png") && !store.hasAsset("missing.png"))
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("Assets/folder"), withIntermediateDirectories: true)
    try check(!store.hasAsset("folder"))
    print(
        "PASS: original PNG clipboard bytes/alpha, instant internal paste, wide/tall aspect ratios, thumbnail rounding, rotated image metadata and asset validation"
    )
}

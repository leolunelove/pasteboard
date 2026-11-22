import AppKit
import ImageIO

func croppingTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let image = NSImage(size: NSSize(width: 400, height: 300))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 150, width: 200, height: 150).fill()
    NSColor.green.setFill()
    NSRect(x: 200, y: 150, width: 200, height: 150).fill()
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: 200, height: 150).fill()
    image.unlockFocus()
    var card = try store.imageCard(image, at: CGPoint(x: 100, y: 100))
    card.width = 400
    card.height = 300
    card.sourceURL = "https://example.com/original"
    let assets = directory.appendingPathComponent("Assets")
    let originalData = try Data(contentsOf: assets.appendingPathComponent(card.asset!))
    let group = UUID()
    card.groupID = group
    let note = Card(x: 600, y: 100, width: 240, height: 180, text: "Keep me here", groupID: group)
    let original = [card, note]
    store.replaceCards(original, name: "Fixture")
    let view = BoardView(store: store)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func gesture(_ overlay: CropOverlay, _ handle: CropHandle, _ delta: CGPoint) {
        let start = handle.point(in: overlay.cropFrame)
        let end = CGPoint(x: start.x + delta.x * view.zoom, y: start.y + delta.y * view.zoom)
        overlay.mouseDown(with: event(.leftMouseDown, start))
        overlay.mouseDragged(with: event(.leftMouseDragged, end))
        overlay.mouseUp(with: event(.leftMouseUp, end))
    }
    for handle in CropHandle.allCases where handle != .move {
        view.setZoom(0.625)
        view.beginCropping(card.id)
        let overlay = view.cropOverlay!
        gesture(
            overlay, handle,
            CGPoint(
                x: handle.left ? 30 : handle.right ? -40 : 0, y: handle.top ? 25 : handle.bottom ? -35 : 0))
        try check(store.board.cards == original)  // A draft never leaks into autosave/backups.
        let expected = overlay.draft.applied(to: card)
        try check(expected.width < card.width || expected.height < card.height)
        view.applyCropping(nil)
        try check(!view.isCropping && store.board.cards == [expected, note])
        store.history.undo()
        try check(store.board.cards == original)
        store.history.redo()
        try check(store.board.cards == [expected, note])
        store.history.undo()
    }
    let topRight = ImageCrop(x: 0.5, y: 0, width: 0.5, height: 0.5)
    let cropped = topRight.applied(to: card)
    try check(
        cropped.rect == CGRect(x: 300, y: 100, width: 200, height: 150) && cropped.fullImageRect == card.rect
            && cropped.groupID == group && cropped.sourceURL == card.sourceURL)
    store.replaceCards([cropped, note], name: "Crop Image")
    view.beginCropping(card.id)
    let overlay = view.cropOverlay!
    gesture(overlay, .move, CGPoint(x: -1000, y: 1000))
    try check(overlay.draft.x == 0 && overlay.draft.y == 0.5 && overlay.draft.width == 0.5)
    view.cancelCropping(nil)
    try check(store.board.cards == [cropped, note])
    view.beginCropping(card.id)
    view.cropOverlay!.reset(nil)
    view.applyCropping(nil)
    try check(store.board.cards == original)
    store.history.undo()
    try check(store.board.cards[0] == cropped)
    view.selection = [card.id]
    view.resetImageCrop(nil)
    try check(store.board.cards == original)
    store.history.undo()
    // Locks also protect a member of a locked group from crop/reset.
    view.selection = [card.id]
    view.toggleLock(nil)
    view.beginCropping(card.id)
    try check(!view.isCropping && view.cropCandidate == nil)
    store.history.undo()
    // Crop bounds cannot cross or leave the original, even with extreme drags.
    for handle in CropHandle.allCases {
        for delta in [CGPoint(x: -1e8, y: -1e8), CGPoint(x: 1e8, y: 1e8)] {
            let result = topRight.adjusted(handle: handle, delta: delta, full: card.rect)
            try check(
                result.isValid && result.width * 400 >= 40 - 0.00001 && result.height * 300 >= 40 - 0.00001)
        }
    }
    try check(
        !BoardStore.valid(
            Card(
                x: 0, y: 0, width: 100, height: 100, asset: card.asset,
                crop: ImageCrop(x: -0.1, y: 0, width: 0.5, height: 1))))
    try check(
        !BoardStore.valid(
            Card(
                x: 0, y: 0, width: 100, height: 100, asset: card.asset,
                crop: ImageCrop(x: 0, y: 0, width: .nan, height: 1))))
    let legacy = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
    try check(legacy.crop == nil && legacy.imageCrop == .full)
    // Upright quadrants distinguish crop origin, colour, alpha, and export clipping.
    func rgba(_ data: Data) -> [UInt8] {
        let image = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 4))
    }
    for (region, channel) in [
        (topRight, 1), (ImageCrop(x: 0, y: 0.5, width: 0.5, height: 0.5), 2),
        (ImageCrop(x: 0.5, y: 0.5, width: 0.5, height: 0.5), 3),
    ] {
        let item = region.applied(to: card)
        let export = BoardExport(cards: [item], assets: assets, padding: 0)
        let png = try export.png(scale: 2, transparent: true)
        let sample = rgba(png)
        if channel == 3 {
            try check(sample[3] == 0)
        } else {
            try check(sample[channel] > 240 && sample[3] == 255)
        }
        let pdf = try export.pdf(transparent: true)
        let doc = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
        try check(doc.page(at: 1)!.getBoxRect(.mediaBox).size == CGSize(width: 200, height: 150))
        if channel == 1 {
            try png.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent("Gather-Crop-Export.png"))
        }
    }
    // The retained canvas uses the same normalized, upright crop as exported artwork.
    let scene = CanvasScene()
    store.board.cards = [cropped]
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
    root.isGeometryFlipped = true
    root.addSublayer(scene.root)
    scene.update(
        cards: [cropped], selection: [], groups: [:], guides: [], editing: nil, zoom: 1,
        offset: CGPoint(x: -300, y: -100), store: store, color: view.noteColor, backingScale: 1)
    let ctx = CGContext(
        data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        for child in layer.sublayers ?? [] { display(child) }
    }
    display(root)
    CATransaction.flush()
    ctx.translateBy(x: 0, y: 150)
    ctx.scaleBy(x: 1, y: -1)
    root.render(in: ctx)
    let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let center = (75 * 200 + 100) * 4
    let sample = Array(UnsafeBufferPointer(start: pixels + center, count: 4))
    if !(sample[1] > 240 && sample[0] < 10 && sample[3] == 255) {
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("Gather-Crop-Canvas.png"))
        throw NSError(
            domain: "Gather.Check", code: 85,
            userInfo: [NSLocalizedDescriptionKey: "Crop canvas pixel: \(sample)"])
    }
    store.board.cards = [cropped, note]
    try check(store.save())
    let reopened = BoardStore(directory: directory)
    try check(reopened.board.cards == [cropped, note])
    try reopened.importBoard(data: store.portableData())
    try check(reopened.board.cards[0].crop == topRight)
    let copied = Card.copies(of: [cropped, note])
    try check(
        copied[0].crop == topRight && copied[0].asset == cropped.asset
            && copied[0].groupID == copied[1].groupID && copied[0].groupID != group)
    let scaled = Card.scaled([cropped, note], ids: [cropped.id, note.id], around: .zero, by: 1.5)
    try check(scaled[0].crop == topRight && scaled[0].width == 300 && scaled[0].fullImageRect.width == 600)
    let checkpoint = store.backups.records().first!
    let restored = try store.backups.restoredBoards(
        from: checkpoint, assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    try check(restored[0].cards[0].crop == topRight)
    let unchanged = try Data(contentsOf: assets.appendingPathComponent(card.asset!))
    try check(unchanged == originalData)
    print(
        "PASS: crop handles/movement, draft isolation, undo/reset, locked groups, bounds, colour/alpha/orientation, canvas/PNG/PDF, save/import/copies/backups, proportional resize and unchanged originals"
    )
}

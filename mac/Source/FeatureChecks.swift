import AppKit
import ImageIO

func collectionFeaturesTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let group = UUID()
    var note = Card(x: 0, y: 0, width: 240, height: 160, text: "Café reference", groupID: group)
    note.sourceURL = "https://example.com/reference"
    let second = Card(x: 280, y: 0, width: 240, height: 160, text: "Second", groupID: group)
    store.replaceCards([note, second], name: "Add")
    let view = BoardView(store: store); view.frame = CGRect(x: 0, y: 0, width: 900, height: 650)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
    view.selection = [note.id]; view.toggleLock(nil)
    try check(store.board.cards.allSatisfy(\.isLocked) && store.board.lockedIDs.count == 2)
    let protected = store.board.cards
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    for start in [view.screen(note.rect).origin.applying(CGAffineTransform(translationX: 25, y: 25)), CGPoint(x: view.screen(second.rect).maxX + 9, y: view.screen(second.rect).maxY + 9)] {
        let end = CGPoint(x: start.x + 150, y: start.y + 120)
        view.mouseDown(with: mouse(.leftMouseDown, start)); view.mouseDragged(with: mouse(.leftMouseDragged, end)); view.mouseUp(with: mouse(.leftMouseUp, end))
        try check(store.board.cards == protected)
    }
    view.selection = [note.id]
    view.deleteSelection(nil); view.ungroupSelection(nil); view.startEditing(note.id)
    try check(store.board.cards == protected && !view.canGroup && !view.canUngroup && view.subviews.isEmpty)
    let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
    view.keyDown(with: arrow); try check(store.board.cards == protected)
    view.toggleLock(nil); try check(store.board.lockedIDs.isEmpty)
    store.history.undo(); try check(store.board.cards == protected)
    view.duplicate(nil); try check(store.board.cards.suffix(2).allSatisfy { !$0.isLocked } && store.board.cards.last?.sourceURL == second.sourceURL)
    try check(store.save()); try check(BoardStore(directory: directory).board.cards == store.board.cards)
    try check(BoardSearch.results(in: store.workspace, imageText: [:], query: "cafe reference").contains { $0.cardID == note.id })
    try check(BoardSearch.results(in: store.workspace, imageText: [:], query: "example.com").contains { $0.cardID == note.id })
    try check(SourceLink.normalized("example.com/page") == "https://example.com/page")
    try check(SourceLink.url("javascript:alert(1)") == nil)
    let pb = NSPasteboard(name: .init("Gather-feature-" + UUID().uuidString)); defer { pb.releaseGlobally() }
    pb.setString("<img src=\"https://example.com/image.png?a=1&amp;b=2\">", forType: .html)
    try check(SourceLink.clipboard(pb) == "https://example.com/image.png?a=1&b=2")

    // A real PNG with clear corners and an opaque red centre must survive paste,
    // persisted original bytes, board rendering, portable files and export.
    let bitmap = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(NSColor.red.cgColor); bitmap.fill(CGRect(x: 30, y: 30, width: 40, height: 60))
    let png = NSMutableData(), destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil); try check(CGImageDestinationFinalize(destination))
    pb.clearContents(); pb.setData(png as Data, forType: .png); pb.setString("https://example.com/image.png", forType: .URL)
    let count = store.board.cards.count
    try check(view.receive(pb, at: CGPoint(x: 600, y: 400)))
    try waitFor { store.board.cards.count == count + 1 }
    let pasted = store.board.cards.last!, assets = directory.appendingPathComponent("Assets")
    let original = try Data(contentsOf: assets.appendingPathComponent(pasted.asset!))
    try check(original == png as Data && pasted.sourceURL == "https://example.com/image.png")
    try check(BoardSearch.results(in: store.workspace, imageText: [pasted.asset!: "Architectural inspiration"], query: "architectural").last?.cardID == pasted.id)
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let ptr = context.data!.assumingMemoryBound(to: UInt8.self), offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: ptr + offset, count: 4))
    }
    var imageCard = pasted; imageCard.x = 0; imageCard.y = 0; imageCard.width = 100; imageCard.height = 100
    let export = BoardExport(cards: [imageCard], assets: assets)
    let output = try export.png(scale: 2, transparent: true)
    let exported = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(output as CFData, nil)!, 0, nil)!
    try check(exported.width == 296 && exported.height == 296)
    try check(pixel(exported, 60, 60)[3] == 0 && pixel(exported, 148, 148)[3] == 255)
    // The asymmetric red block starts nearer the top, so export must stay upright.
    try check(pixel(exported, 148, 78)[3] == 255 && pixel(exported, 148, 218)[3] == 0)
    let opaqueData = try export.png(scale: 1, transparent: false)
    let opaque = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(opaqueData as CFData, nil)!, 0, nil)!
    try check(pixel(opaque, 1, 1)[3] == 255)
    let pdf = try export.pdf(transparent: true)
    let doc = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
    try check(doc.numberOfPages == 1 && doc.page(at: 1)!.getBoxRect(.mediaBox).width == 148)
    try output.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("Gather-Transparent-Export.png"))
    // Check the actual retained canvas layers, not just the export renderer.
    store.board.cards = [imageCard]
    let scene = CanvasScene(); scene.root.bounds = CGRect(x: 0, y: 0, width: 148, height: 148)
    scene.update(cards: [imageCard], selection: [], groups: [:], guides: [], editing: nil, zoom: 1, offset: CGPoint(x: 24, y: 24), store: store, color: view.noteColor, backingScale: 1)
    let canvas = CGContext(data: nil, width: 148, height: 148, bitsPerComponent: 8, bytesPerRow: 592, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scene.root.render(in: canvas)
    try check(pixel(canvas.makeImage()!, 30, 30)[3] == 0)
    try store.importBoard(data: store.portableData())
    let portableImage = try Data(contentsOf: assets.appendingPathComponent(store.board.cards[0].asset!)); try check(portableImage == original)

    // Checkpoints include independent image links; restore survives loss of the
    // original, and restoring creates fresh IDs while retaining source metadata.
    let manager = LocalBackups(directory: directory.appendingPathComponent("backup-check"))
    try FileManager.default.createDirectory(at: manager.assets, withIntermediateDirectories: true)
    try original.write(to: manager.assets.appendingPathComponent(imageCard.asset!))
    var workspace = Workspace(boards: [Board(name: "Saved", cards: [imageCard])], active: nil)
    let now = Date()
    try manager.capture(workspace, now: now); try check(manager.records().count == 1)
    workspace.boards[0].offsetX += 10; try manager.capture(workspace, now: now.addingTimeInterval(301)); try check(manager.records().count == 1)
    workspace.boards[0].cards[0].locked = true
    try manager.capture(workspace, now: now.addingTimeInterval(100)); try check(manager.records().count == 1)
    try manager.capture(workspace, force: true, now: now.addingTimeInterval(101)); try check(manager.records().count == 2)
    let record = manager.records()[0]
    try FileManager.default.removeItem(at: manager.assets.appendingPathComponent(imageCard.asset!))
    let restored = try manager.restoredBoards(from: record, assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    try check(restored[0].id != workspace.boards[0].id && restored[0].cards[0].id != imageCard.id && restored[0].cards[0].isLocked && restored[0].cards[0].sourceURL == imageCard.sourceURL)
    let restoredImage = try Data(contentsOf: directory.appendingPathComponent("RestoredAssets").appendingPathComponent(restored[0].cards[0].asset!)); try check(restoredImage == original)
    workspace.boards[0].cards = [note]
    for i in 0..<50 { workspace.boards[0].cards[0].x = Double(i); try manager.capture(workspace, force: true, now: now.addingTimeInterval(Double(200 + i))) }
    try check(manager.records().count == 40)
    let failingBackups = BoardStore(directory: directory.appendingPathComponent("failed-backup"))
    failingBackups.board.cards = [Card(x: 0, y: 0, width: 100, height: 100, asset: "unavailable.png")]
    try check(failingBackups.save())
    try check(BoardStore(directory: failingBackups.directory).board.cards == failingBackups.board.cards)
    // Actual local OCR on a high contrast screenshot fixture.
    let ocrImage = NSImage(size: NSSize(width: 900, height: 200))
    ocrImage.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 200).fill()
    "GATHER SEARCH CHECK".draw(at: CGPoint(x: 35, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.black]); ocrImage.unlockFocus()
    let ocrURL = directory.appendingPathComponent("OCR.tiff"); try ocrImage.tiffRepresentation!.write(to: ocrURL)
    let recognized = try ImageTextIndex.recognize(at: ocrURL)
    try check(recognized.uppercased().contains("GATHER SEARCH CHECK"))
    print("PASS: locks, local search and OCR, source links, transparent PNG paste/render/export, PDF, independent backups and recovery")
}

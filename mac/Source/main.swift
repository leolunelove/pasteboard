import AppKit
import QuartzCore

func check(_ condition: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) throws {
    if !condition() {
        throw NSError(
            domain: "Gather.Check", code: line,
            userInfo: [NSLocalizedDescriptionKey: "Self-check failed at \(file):\(line)"])
    }
}

func waitFor(_ condition: () -> Bool, timeout: Double = 10, file: String = #fileID, line: Int = #line) throws
{
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try check(condition(), file: file, line: line)
}

func selfTest() throws {
    let interactionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Pasteboard-interactions-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: interactionDirectory) }
    try socialPostTest(directory: interactionDirectory.appendingPathComponent("social"))
    try workspaceOverviewTest(directory: interactionDirectory.appendingPathComponent("overview"))
    try designPasteAndColourTest(directory: interactionDirectory.appendingPathComponent("design-paste"))
    try interactionTest(directory: interactionDirectory.appendingPathComponent("pointer"))
    try arrangementTest(directory: interactionDirectory.appendingPathComponent("arrange"))
    try imagePipelineTest(directory: interactionDirectory.appendingPathComponent("image-pipeline"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Gather-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BoardStore(directory: directory)
    let card = Card(x: -250, y: 120, width: 300, height: 180, text: "A thought ✨\nSecond line")
    store.replaceCards([card], name: "Add")
    try check(store.board.cards.count == 1)
    store.history.undo()
    try check(store.board.cards.isEmpty)
    store.history.redo()
    try check(store.board.cards == [card])
    let image = NSImage(size: NSSize(width: 200, height: 100))
    image.lockFocus()
    NSColor.pasteboardAccent.setFill()
    NSRect(x: 0, y: 0, width: 200, height: 100).fill()
    image.unlockFocus()
    let photo = try store.imageCard(image, at: CGPoint(x: 50, y: -70))
    try check(photo.width / photo.height == 2)
    store.replaceCards([card, photo], name: "Image")
    try check(store.save())
    let reloaded = BoardStore(directory: directory)
    try check(reloaded.board.cards == [card, photo])
    try check(reloaded.image(photo.asset!) != nil)
    let portable = try reloaded.portableData()
    try reloaded.importBoard(data: portable)
    try check(reloaded.workspace.boards.count == 2)
    try check(reloaded.board.cards[0].text == card.text)
    try check(reloaded.board.cards[1].asset != photo.asset)
    try check(reloaded.image(reloaded.board.cards[1].asset!) != nil)
    let view = BoardView(store: reloaded)
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let rect = view.screen(card.rect)
    let point = view.world(rect.origin)
    try check(abs(point.x - card.x) < 0.001 && abs(point.y - card.y) < 0.001)
    let anchor = CGPoint(x: 450, y: 350)
    let before = view.world(CGPoint(x: 450, y: 350))
    view.setZoom(2, anchor: anchor)
    try check(abs(view.world(anchor).x - before.x) < 0.001)
    view.selection = [card.id]
    view.duplicate(nil)
    try check(reloaded.board.cards.count == 3)
    view.deleteSelection(nil)
    try check(reloaded.board.cards.count == 2)
    reloaded.history.undo()
    try check(reloaded.board.cards.count == 3)
    let pasteboard = NSPasteboard(name: .init("Gather-test-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Pasted note", forType: .string)
    try check(view.receive(pasteboard, at: .zero))
    try check(reloaded.board.cards.last?.text == "Pasted note")
    pasteboard.clearContents()
    pasteboard.setData(image.tiffRepresentation!, forType: .tiff)
    let beforeImageCount = reloaded.board.cards.count
    try check(view.receive(pasteboard, at: .zero))
    try waitFor { reloaded.board.cards.count == beforeImageCount + 1 }
    try check(reloaded.board.cards.last?.asset != nil)
    view.stopZoomAnimation()
    // In-progress text must survive saving and finishing must remain undoable.
    view.startEditing(card.id)
    if let editor = view.subviews.first(where: { $0 is NSTextView }) as? NSTextView {
        editor.string = "Edited note"
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        try check(reloaded.board.cards.first?.text == "Edited note")
        try check(reloaded.save())
        try check(BoardStore(directory: directory).board.cards.first?.text == "Edited note")
        view.finishEditing()
        reloaded.history.undo()
        try check(reloaded.board.cards.first?.text == card.text)
    } else {
        throw NSError(
            domain: "Gather.Check", code: 0, userInfo: [NSLocalizedDescriptionKey: "Editor did not open"])
    }
    try check(!BoardStore.valid(Card(x: .infinity, y: 0, width: 100, height: 100, text: "bad")))
    try check(!BoardStore.valid(Card(x: 0, y: 0, width: 100, height: 100, asset: "../escape.png")))
    try check(reloaded.save())

    // Repeated pastes must leave every existing item accessible.
    let placementStore = BoardStore(directory: directory.appendingPathComponent("placement"))
    let placementView = BoardView(store: placementStore)
    placementView.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    for i in 0..<24 {
        let newCard = Card(x: 0, y: 0, width: 200, height: 100, text: "Note \(i)")
        let placed = placementView.place([newCard], near: .zero, avoidOverlap: true)
        try check(!placementStore.board.cards.contains { $0.rect.intersects(placed[0].rect) })
        placementStore.replaceCards(placementStore.board.cards + placed, name: "Paste")
    }
    let batch = placementView.place([card, photo], near: .zero, avoidOverlap: true)
    try check(!batch[0].rect.intersects(batch[1].rect))
    try check(
        !placementStore.board.cards.contains { existing in
            batch.contains { existing.rect.intersects($0.rect) }
        })
    let anchorPoint = CGPoint(x: 137, y: 421)
    let anchorBefore = placementView.world(CGPoint(x: 137, y: 421))
    placementView.animateZoom(to: 2.4, anchor: anchorPoint)
    try waitFor { abs(placementView.zoom - 2.4) < 0.0001 }
    try check(
        hypot(
            placementView.world(anchorPoint).x - anchorBefore.x,
            placementView.world(anchorPoint).y - anchorBefore.y) < 0.001)
    placementView.animateZoom(to: 4)
    placementView.stopZoomAnimation()
    let stopped = placementView.zoom
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    try check(placementView.zoom == stopped)

    // Imports are routed back to their original board if navigation happens mid-decode.
    let originID = placementStore.board.id
    let originalCount = placementStore.board.cards.count
    pasteboard.clearContents()
    pasteboard.setData(image.tiffRepresentation!, forType: .tiff)
    try check(placementView.receive(pasteboard, at: .zero, avoidOverlap: true))
    placementStore.newBoard(name: "Other board")
    try waitFor {
        placementStore.workspace.boards.first(where: { $0.id == originID })!.cards.count == originalCount + 1
    }
    try check(placementStore.board.cards.isEmpty)
    var results: [PreparedImage] = []
    var failures = 0
    var completed = false
    placementStore.prepareImages([Data("not an image".utf8)]) { images, failed in
        results = images
        failures = failed
        completed = true
    }
    try waitFor { completed }
    try check(results.isEmpty && failures == 1)
    // Completing an image paste must not close a note or cause undo to drop the image.
    let editingCard = Card(x: 0, y: 0, width: 300, height: 180, text: "Before editing")
    placementStore.replaceCards([editingCard], name: "Note")
    placementView.startEditing(editingCard.id)
    let liveEditor = placementView.subviews.first(where: { $0 is NSTextView }) as! NSTextView
    liveEditor.string = "Still typing"
    placementView.textDidChange(Notification(name: NSText.didChangeNotification, object: liveEditor))
    try check(placementView.receive(pasteboard, at: CGPoint(x: 500, y: 0)))
    try waitFor { placementStore.board.cards.count == 2 }
    try check(placementView.subviews.contains(liveEditor))
    placementView.finishEditing()
    placementStore.history.undo()
    try check(
        placementStore.board.cards.count == 2 && placementStore.board.cards.first?.text == "Before editing")
    try check(placementStore.save())
    try minimapTest(directory: directory.appendingPathComponent("minimap"))
    try boardNavigationTest(directory: directory.appendingPathComponent("navigation"))
    try svgTest(directory: directory.appendingPathComponent("svg"))
    try swatchTest(directory: directory.appendingPathComponent("swatches"))
    try workspaceDeletionTest(directory: directory.appendingPathComponent("deletion"))
    try pageTransferTest(directory: directory.appendingPathComponent("page-transfers"), image: image)
    try localUpdaterTest(directory: directory.appendingPathComponent("updater"))
    try pageHierarchyTest(directory: directory.appendingPathComponent("pages"))
    try croppingTest(directory: directory.appendingPathComponent("cropping"))
    try collectionFeaturesTest(directory: directory.appendingPathComponent("collection"))
    try groupingTest(directory: directory.appendingPathComponent("grouping"), image: image)
    try groupResizeTest(directory: directory.appendingPathComponent("group-resize"), image: image)
    try snappingTest(directory: directory.appendingPathComponent("snapping"), image: image)
    try spacingMathTest()
    try spacingDragTest(directory: directory.appendingPathComponent("spacing-drag"), image: image)
    try updateChannelTest(directory: directory.appendingPathComponent("updates"))
    print(
        "PASS: paste/storage/save/undo; non-overlapping repeated and batch paste; animated anchored zoom and interruption; background import routing and failure handling"
    )
}

func snappingTest(directory: URL, image: NSImage) throws {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    let target = SnapTarget(id: UUID(), rect: CGRect(x: 300, y: 200, width: 200, height: 120))
    for (raw, aligned) in [(305.0, 300.0), (395, 400), (353, 350), (503, 500), (197, 200)] {
        var session = SnapSession()
        let result = session.snap(CGRect(x: raw, y: 450, width: 100, height: 80), to: [target], zoom: 1)
        try check(close(result.rect.minX, aligned) && result.guides.contains { $0.axis == .x })
    }
    for (raw, aligned) in [(205.0, 200.0), (235, 240), (222, 220), (323, 320), (117, 120)] {
        var session = SnapSession()
        let result = session.snap(CGRect(x: 0, y: raw, width: 100, height: 80), to: [target], zoom: 1)
        try check(close(result.rect.minY, aligned) && result.guides.contains { $0.axis == .y })
    }
    var session = SnapSession()
    _ = session.snap(CGRect(x: 305, y: 450, width: 100, height: 80), to: [target], zoom: 1)
    try check(
        session.snap(CGRect(x: 308, y: 450, width: 100, height: 80), to: [target], zoom: 1).rect.minX == 300)
    try check(
        session.snap(CGRect(x: 311, y: 450, width: 100, height: 80), to: [target], zoom: 1).rect.minX == 311)
    let large = SnapTarget(id: UUID(), rect: CGRect(x: 300, y: 200, width: 1000, height: 1000))
    for zoom in [0.1, 0.625, 1, 2, 4] {
        var session = SnapSession()
        let result = session.snap(
            CGRect(x: 300 + 5 / zoom, y: 1250, width: 1000, height: 1000), to: [large], zoom: zoom)
        try check(close(result.rect.minX, 300))
        session.reset()
        let outside = session.snap(
            CGRect(x: 300 + 11 / zoom, y: 1250, width: 1000, height: 1000), to: [large], zoom: zoom)
        try check(!outside.guides.contains { $0.axis == .x })
    }
    var nearest = SnapSession()
    let closer = SnapTarget(id: UUID(), rect: target.rect.offsetBy(dx: 6, dy: 0))
    try check(
        nearest.snap(CGRect(x: 304, y: 450, width: 100, height: 80), to: [target, closer], zoom: 1).rect.minX
            == 306)
    var distant = SnapSession()
    try check(
        distant.snap(CGRect(x: 304, y: 10_000, width: 100, height: 80), to: [target], zoom: 1).guides.isEmpty)

    let store = BoardStore(directory: directory)
    // Use the same native event path as ordinary mouse dragging.
    let canvas = BoardView(store: store)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    defer { window.close() }
    let movingGroup = UUID()
    let stationaryGroup = UUID()
    var note = Card(x: 0, y: 0, width: 200, height: 140, text: "Move us\ntogether.")
    note.groupID = movingGroup
    var photo = try store.imageCard(image, at: CGPoint(x: 240, y: 0))
    photo.width = 240
    photo.height = 120
    photo.groupID = movingGroup
    var targetNote = Card(x: 650, y: 260, width: 200, height: 140, text: "Line up here.")
    targetNote.groupID = stationaryGroup
    var targetPhoto = photo
    targetPhoto.id = UUID()
    targetPhoto.x = 890
    targetPhoto.y = 260
    targetPhoto.groupID = stationaryGroup
    let original = [note, photo, targetNote, targetPhoto]
    let targets = SnapTarget.objects(in: original, excluding: [note.id])
    try check(targets.count == 1 && targets[0].id == stationaryGroup && targets[0].rect.width == 480)
    store.replaceCards(original, name: "Fixture")
    canvas.refresh()
    canvas.setZoom(0.75)
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent
    {
        NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = canvas.screen(note.rect).origin.applying(CGAffineTransform(translationX: 25, y: 25))
    let end = CGPoint(x: start.x + 166 * canvas.zoom, y: start.y + 257 * canvas.zoom)
    canvas.mouseDown(with: mouse(.leftMouseDown, at: start))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    try check(close(store.board.cards[0].x, 170) && close(store.board.cards[0].y, 260))
    try check(close(store.board.cards[1].x - photo.x, 170) && close(store.board.cards[1].y, 260))
    try check(canvas.alignmentGuides.count == 2)
    try check(Array(store.board.cards.suffix(2)) == Array(original.suffix(2)))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, modifiers: .option))
    try check(
        close(store.board.cards[0].x, 166) && close(store.board.cards[0].y, 257)
            && canvas.alignmentGuides.isEmpty)
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, modifiers: .shift))
    try check(store.board.cards[0].x == 0 && close(store.board.cards[0].y, 260))
    try check(!canvas.alignmentGuides.contains { $0.axis == .x })
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    try renderSnapPreview(
        cards: store.board.cards, selection: canvas.selection, guides: canvas.alignmentGuides,
        zoom: canvas.zoom, offset: canvas.offset, store: store, color: canvas.noteColor)
    canvas.mouseUp(with: mouse(.leftMouseUp, at: end))
    let snapped = store.board.cards
    try check(canvas.alignmentGuides.isEmpty)
    store.history.undo()
    try check(store.board.cards == original)
    store.history.redo()
    try check(store.board.cards == snapped)
    try check(store.save())
    try check(BoardStore(directory: directory).board.cards == snapped)
    store.replaceCards(original, name: "Reset Fixture")
    canvas.snappingEnabled = false
    canvas.mouseDown(with: mouse(.leftMouseDown, at: start))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: end))
    try check(close(store.board.cards[0].x, 166) && canvas.alignmentGuides.isEmpty)
    store.history.undo()
    canvas.snappingEnabled = true
    store.history.removeAllActions()
    canvas.mouseDown(with: mouse(.leftMouseDown, at: start))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    func savedCards() -> [Card]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("Workspace.json")),
            let saved = try? JSONDecoder().decode(Workspace.self, from: data)
        else { return nil }
        return saved.boards[0].cards
    }
    // Simulate a pending autosave completing during the gesture.
    let preview = store.board.cards
    store.scheduleSave()
    try waitFor { savedCards() == preview }
    let escape = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
        keyCode: 53)!
    canvas.keyDown(with: escape)
    canvas.mouseUp(with: mouse(.leftMouseUp, at: end))
    try check(store.board.cards == original && canvas.alignmentGuides.isEmpty && !store.history.canUndo)
    try waitFor { savedCards() == original }
    // Returning to the starting point must replace a saved preview too.
    canvas.mouseDown(with: mouse(.leftMouseDown, at: start))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    store.scheduleSave()
    try waitFor { savedCards() == preview }
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: start))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: start))
    try check(store.board.cards == original && !store.history.canUndo)
    try waitFor { savedCards() == original }
    try check(store.save())
    print(
        "PASS: edge/centre/adjacent snapping, capture/release at all zooms, nearest targets, group exclusion, Option bypass, Shift constraints, guides, undo/save and cancellation"
    )
}

func renderSnapPreview(
    cards: [Card], selection: Set<UUID>, guides: [AlignmentGuide], zoom: CGFloat, offset: CGPoint,
    store: BoardStore, color: (Int) -> NSColor, spacingGuides: [SpacingGuide] = [],
    filename: String = "Gather-Snapping-Preview.png"
) throws {
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
    root.isGeometryFlipped = true
    root.backgroundColor = NSColor.pasteboardCanvas.cgColor
    let scene = CanvasScene()
    root.addSublayer(scene.root)
    scene.update(
        cards: cards, selection: selection, groups: store.board.groupBounds(for: selection), guides: guides,
        spacingGuides: spacingGuides, editing: nil, zoom: zoom, offset: offset, store: store, color: color,
        backingScale: 2)
    func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        for child in layer.sublayers ?? [] { display(child) }
    }
    display(root)
    let context = CGContext(
        data: nil, width: 2800, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: 0, y: 900)
    context.scaleBy(x: 1, y: -1)
    root.render(in: context)
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(
        to: FileManager.default.temporaryDirectory.appendingPathComponent(filename), options: .atomic)
}

func spacingDragTest(directory: URL, image: NSImage) throws {
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    let first = Card(x: 0, y: 0, width: 200, height: 140, text: "Keep this gap.")
    var second = try store.imageCard(image, at: CGPoint(x: 240, y: 0))
    second.width = 240
    second.height = 120
    let group = UUID()
    var note = Card(x: 550, y: 0, width: 140, height: 120, text: "Move our\ngroup.")
    note.groupID = group
    var photo = second
    photo.id = UUID()
    photo.x = 710
    photo.width = 140
    photo.height = 70
    photo.groupID = group
    let original = [first, second, note, photo]
    store.replaceCards(original, name: "Fixture")
    view.refresh()
    view.setZoom(0.75)
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent
    {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = view.screen(note.rect).origin.applying(CGAffineTransform(translationX: 25, y: 25))
    let end = CGPoint(x: start.x - 34 * view.zoom, y: start.y)
    view.mouseDown(with: mouse(.leftMouseDown, at: start))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    try check(abs(store.board.cards[2].x - 520) < 0.000001)
    try check(abs(store.board.cards[3].x - 680) < 0.000001)
    try check(view.spacingGuides.count == 1 && view.spacingGuides[0].distance == 40)
    try check(Array(store.board.cards.prefix(2)) == Array(original.prefix(2)))
    try check(store.board.cards[2].width == note.width && store.board.cards[3].width == photo.width)
    view.mouseDragged(with: mouse(.leftMouseDragged, at: end, modifiers: .option))
    try check(
        abs(store.board.cards[2].x - 516) < 0.000001 && view.spacingGuides.isEmpty
            && view.alignmentGuides.isEmpty)
    view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    try renderSnapPreview(
        cards: store.board.cards, selection: view.selection, guides: view.alignmentGuides, zoom: view.zoom,
        offset: view.offset, store: store, color: view.noteColor, spacingGuides: view.spacingGuides,
        filename: "Gather-Spacing-Preview.png")
    view.mouseUp(with: mouse(.leftMouseUp, at: end))
    let spaced = store.board.cards
    try check(view.spacingGuides.isEmpty && view.alignmentGuides.isEmpty)
    store.history.undo()
    try check(store.board.cards == original)
    store.history.redo()
    try check(store.board.cards == spaced)
    try check(store.save())
    try check(BoardStore(directory: directory).board.cards == spaced)
    print(
        "PASS: native equal-spacing group drag, Option bypass, preview/guide cleanup, unchanged dimensions, undo and save/reopen"
    )
}

func groupResizeTest(directory: URL, image: NSImage) throws {
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    let note = Card(x: 0, y: 0, width: 300, height: 180, text: "Keep this note\nand image together.")
    let photo = try store.imageCard(image, at: CGPoint(x: 360, y: 20))
    let loose = Card(x: -300, y: 300, width: 200, height: 150, text: "Leave me alone")
    store.replaceCards([note, photo, loose], name: "Fixture")
    view.refresh()
    view.selection = [note.id, photo.id]
    view.groupSelection(nil)
    let original = store.board.cards
    let ids = view.selection
    let group = original[0].groupID!
    let bounds = store.board.groupBounds(for: ids)[group]!
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    // Exercise every actual corner handle at a non-default zoom.
    view.setZoom(0.625)
    for corner in GroupCorner.allCases {
        let start = corner.point(in: view.screen(bounds).insetBy(dx: -9, dy: -9))
        let anchor = corner.opposite.point(in: bounds)
        let point = corner.point(in: bounds)
        let end = CGPoint(
            x: start.x + (point.x - anchor.x) * 0.5 * view.zoom,
            y: start.y + (point.y - anchor.y) * 0.5 * view.zoom)
        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        view.mouseUp(with: mouse(.leftMouseUp, at: end))
        let scaled = store.board.cards
        for (before, after) in zip(original.prefix(2), scaled.prefix(2)) {
            try check(close(after.width / before.width, 1.5) && close(after.height / before.height, 1.5))
            try check(close(after.width / after.height, before.width / before.height))
            try check(
                close(after.x, anchor.x + (before.x - anchor.x) * 1.5)
                    && close(after.y, anchor.y + (before.y - anchor.y) * 1.5))
            try check(close(after.renderScale, 1.5) && after.groupID == group)
        }
        try check(close(scaled[0].textHeight(for: note.text!), original[0].textHeight(for: note.text!) * 1.5))
        try check(scaled[2] == loose && scaled.allSatisfy(BoardStore.valid))
        store.history.undo()
        try check(store.board.cards == original)
        store.history.redo()
        try check(store.board.cards == scaled)
        store.history.undo()
    }
    let scaled = Card.scaled(original, ids: ids, around: bounds.origin, by: 1.75)
    store.replaceCards(scaled, name: "Resize Group")
    try check(store.save())
    try check(BoardStore(directory: directory).board.cards == scaled)
    let exported = try store.portableData()
    try store.importBoard(data: exported)
    try check(
        close(store.board.cards[0].renderScale, 1.75)
            && close(store.board.cards[1].width, original[1].width * 1.75))
    // Editing after scaling must use the enlarged font and preserve the scale on exit.
    view.selection = [note.id]
    view.startEditing(note.id)
    let editor = view.subviews.first(where: { $0 is NSTextView }) as! NSTextView
    try check(close(editor.font!.pointSize, 18 * 1.75 * view.zoom))
    editor.string += "\nAn extra thought."
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    view.finishEditing()
    try check(close(store.board.cards[0].renderScale, 1.75))
    let smallest = Card.scaled(original, ids: ids, around: bounds.origin, by: -5)
    let largest = Card.scaled(original, ids: ids, around: bounds.origin, by: 1_000_000)
    try check(smallest.allSatisfy(BoardStore.valid) && largest.allSatisfy(BoardStore.valid))
    try check(close(smallest[0].width / original[0].width, smallest[1].width / original[1].width))
    try check(largest[2] == loose)
    let legacy = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(note))
    try check(legacy.renderScale == 1)
    try check(store.save())
    print(
        "PASS: four proportional group-resize handles, non-default zoom, note font/padding scale, image aspect ratios, fixed anchors, undo/redo, save/export/import, editing and size limits"
    )
}

func groupingTest(directory: URL, image: NSImage) throws {
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    let note = Card(x: 0, y: 0, width: 300, height: 180, text: "Grouped note")
    let photo = try store.imageCard(image, at: CGPoint(x: 360, y: 0))
    let loose = Card(x: 0, y: 320, width: 300, height: 140, text: "Independent note")
    store.replaceCards([note, photo, loose], name: "Fixture")
    view.refresh()
    view.selection = [note.id, photo.id]
    try check(view.canGroup && !view.canUngroup)
    view.groupSelection(nil)
    let grouped = store.board.cards
    let group = grouped[0].groupID!
    try check(grouped[1].groupID == group && grouped[2].groupID == nil)
    try check(!view.canGroup && view.canUngroup)
    view.selection = [note.id]
    try check(view.selection == [note.id, photo.id])
    let bounds = store.board.groupBounds(for: view.selection)[group]!
    try check(bounds.contains(note.rect) && bounds.contains(photo.rect))
    // Mouse events are injected into this hidden test view, not the user's board.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = view.screen(note.rect).origin.applying(CGAffineTransform(translationX: 30, y: 30))
    let end = CGPoint(x: start.x + 64, y: start.y + 48)
    view.selection = []
    view.mouseDown(with: mouse(.leftMouseDown, at: start))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    view.mouseUp(with: mouse(.leftMouseUp, at: end))
    try check(store.board.cards[0].x == note.x + 64 && store.board.cards[0].y == note.y + 48)
    try check(store.board.cards[1].x == photo.x + 64 && store.board.cards[1].y == photo.y + 48)
    try check(store.board.cards[2] == loose)
    store.history.undo()
    try check(store.board.cards == grouped)
    store.history.undo()
    try check(store.board.cards == [note, photo, loose])
    store.history.redo()
    try check(store.board.cards == grouped)
    view.selection = [photo.id]
    view.duplicate(nil)
    let copies = Array(store.board.cards.suffix(2))
    try check(
        copies[0].groupID != nil && copies[0].groupID != group && copies[0].groupID == copies[1].groupID)
    try check(Set(copies.map(\.id)).isDisjoint(with: Set(grouped.map(\.id))))
    view.selection = [copies[0].id]
    try check(view.selection == Set(copies.map(\.id)))
    view.ungroupSelection(nil)
    try check(store.board.cards.suffix(2).allSatisfy { $0.groupID == nil })
    try check(store.board.cards[0].groupID == group)
    store.history.undo()
    try check(store.board.cards.suffix(2).allSatisfy { $0.groupID == copies[0].groupID })
    try check(store.save())
    let reopened = BoardStore(directory: directory)
    try check(reopened.board.cards == store.board.cards)
    try reopened.importBoard(data: store.portableData())
    try check(reopened.board.expandedSelection([note.id]) == [note.id, photo.id])
    try check(reopened.board.cards[0].groupID == group)
    // Existing 0.1/0.2 cards have no groupID field and must continue to load.
    let legacyData = try JSONEncoder().encode(note)
    let legacy = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
    try check(legacy["groupID"] == nil)
    let legacyCard = try JSONDecoder().decode(Card.self, from: legacyData)
    try check(legacyCard.groupID == nil)
    let copiedGroups = Card.copies(of: grouped + copies)
    try check(copiedGroups[0].groupID == copiedGroups[1].groupID && copiedGroups[0].groupID != group)
    try check(
        copiedGroups[3].groupID == copiedGroups[4].groupID && copiedGroups[3].groupID != copies[0].groupID
            && copiedGroups[3].groupID != copiedGroups[0].groupID)
    try check(reopened.save())
    print(
        "PASS: mixed image/note grouping, click-and-drag as a unit, independent copies, undo/redo, ungroup, persistence, portable export/import and legacy boards"
    )
}

let application = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    do { try selfTest() } catch {
        fputs("Self-test failed: \(error)\n", stderr)
        exit(1)
    }
} else {
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}

import AppKit
import QuartzCore

func sectionCanvasTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let canvas = BoardView(store: store)
    canvas.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
    let first = Card(x: 100, y: 160, width: 300, height: 220, text: "First design")
    let second = Card(x: 1100, y: 160, width: 300, height: 220, text: "Second design")
    let a = BoardSection(name: "Printed shirts", memberIDs: [first.id], x: 0, y: 0, width: 400, height: 320)
    let b = BoardSection(
        name: "Embroidered shirts", memberIDs: [second.id], x: 1000, y: 0, width: 400, height: 320)
    let c = BoardSection(name: "Next idea", memberIDs: [], x: 2000, y: 96, width: 400, height: 320)
    store.board.cards = [first, second]
    store.board.sections = [a, b, c]
    store.board.offsetX = 0
    store.board.offsetY = 0
    canvas.refresh()
    canvas.layout()
    store.history.removeAllActions()
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func settled(on rect: CGRect) throws {
        try waitFor {
            canvas.requestedZoom == canvas.zoom
                && hypot(canvas.worldCenter.x - rect.midX, canvas.worldCenter.y - rect.midY) < 0.001
        }
    }
    let header = canvas.sectionHeaderRect(a)
    let titlePoint = CGPoint(x: header.midX, y: header.midY)
    canvas.mouseDown(with: mouse(.leftMouseDown, titlePoint))
    canvas.mouseUp(with: mouse(.leftMouseUp, titlePoint))
    try settled(on: store.board.sectionBounds(a))
    try check(canvas.bounds.contains(canvas.screen(store.board.sectionBounds(a))))
    try check(abs(canvas.worldCenter.x - store.board.sectionBounds(a).midX) < 0.001)
    try check(canvas.selection.isEmpty && !canvas.hasPointerInteraction && !store.history.canUndo)

    // Card clicks retain the normal selection/drag interaction inside a section.
    let cardRect = canvas.screen(first.rect)
    let cardPoint = CGPoint(x: cardRect.midX, y: cardRect.midY)
    canvas.mouseDown(with: mouse(.leftMouseDown, cardPoint))
    try check(canvas.selection == [first.id] && canvas.hasPointerInteraction)
    canvas.mouseUp(with: mouse(.leftMouseUp, cardPoint))
    try check(store.board.cards == [first, second] && !store.history.canUndo)

    // Rapid keyboard section jumps follow the pending camera destination.
    func nextSection() {
        canvas.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option],
                timestamp: 0, windowNumber: 0, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48)!)
    }
    nextSection()
    nextSection()
    try settled(on: c.rect)
    try check(abs(canvas.worldCenter.x - c.rect.midX) < 0.001)
    let empty = canvas.screen(c.rect)
    let emptyPoint = CGPoint(x: empty.midX, y: empty.midY)
    canvas.mouseDown(with: mouse(.leftMouseDown, emptyPoint, clicks: 2))
    canvas.mouseUp(with: mouse(.leftMouseUp, emptyPoint, clicks: 2))
    try settled(on: c.rect)
    try check(store.board.cards == [first, second])

    let emptyHeader = canvas.sectionHeaderRect(c)
    let menu = canvas.menu(for: mouse(.rightMouseDown, CGPoint(x: emptyHeader.midX, y: emptyHeader.midY)))
    try check(menu?.items.map(\.title) == ["Zoom to Section", "Rename Section…", "Show All Sections"])
    canvas.fitAll(nil)
    try settled(on: [a, b, c].reduce(CGRect.null) { $0.union(store.board.sectionBounds($1)) })
    for section in [a, b, c] {
        let rect = store.board.sectionBounds(section)
        try check(canvas.bounds.contains(canvas.screen(rect)))
        try check(canvas.minimap.geometry!.worldBounds.contains(rect))
    }
    try check(!canvas.minimap.isHidden)

    // Retained section artwork does no section rebuilding while merely panning.
    let scene = CanvasScene()
    func render(_ offset: CGPoint, appearance: NSAppearance = NSAppearance(named: .aqua)!) {
        scene.update(
            cards: store.board.cards, selection: [], groups: [:], guides: [], editing: nil,
            zoom: canvas.zoom, offset: offset, store: store, color: canvas.noteColor, backingScale: 2,
            appearance: appearance)
    }
    render(.zero)
    let generation = scene.sectionGeneration
    render(CGPoint(x: 200, y: 400))
    try check(scene.sectionGeneration == generation)
    let frames = scene.root.sublayers!.compactMap { $0 as? CAShapeLayer }.filter { $0.zPosition == -100 }
    try check(frames.count == 3)
    let light = frames[0].fillColor
    render(.zero, appearance: NSAppearance(named: .darkAqua)!)
    try check(scene.sectionGeneration > generation && frames[0].fillColor != light)

    // Switching boards cancels an in-flight jump and hides section controls.
    canvas.zoomToSection(b.id)
    store.newBoard(name: "Plain board")
    canvas.refresh()
    let offset = canvas.offset
    RunLoop.current.run(until: Date().addingTimeInterval(0.22))
    try check(canvas.offset == offset && canvas.minimap.isHidden)
    try check(canvas.subviews.compactMap { $0 as? NSPopUpButton }.allSatisfy(\.isHidden))
    store.board.sections = [c]
    canvas.refresh()
    try check(!canvas.minimap.isHidden)
    try check(store.board.cards.isEmpty && !store.history.canUndo)

    // Empty sections have no welcome artwork and must not retain its invisible paste target.
    let formerPasteTarget = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY + 72)
    canvas.mouseDown(with: mouse(.leftMouseDown, formerPasteTarget))
    try check(canvas.hasPointerInteraction && store.board.cards.isEmpty)
    canvas.cancelPointerInteraction()
    canvas.mouseUp(with: mouse(.leftMouseUp, formerPasteTarget))

    // Image decoding can complete after navigation. It still joins the original section
    // and remains one undoable insertion on the original board.
    let imageContext = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8,
        bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    imageContext.setFillColor(NSColor.systemBlue.cgColor)
    imageContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let image = NSBitmapImageRep(cgImage: imageContext.makeImage()!)
        .representation(using: .png, properties: [:])!
    let destination = store.board.id
    let imageItem = NSPasteboardItem()
    imageItem.setData(image, forType: .png)
    try check(
        canvas.receiveImageItems([imageItem], at: CGPoint(x: c.rect.midX, y: c.rect.midY), avoidOverlap: true)
    )
    store.newBoard(name: "Browse while importing")
    canvas.refresh()
    try waitFor { !canvas.hasPendingImports }
    let imported = store.workspace.boards.first { $0.id == destination }!
    try check(imported.cards.count == 1 && imported.sections![0].memberIDs.contains(imported.cards[0].id))
    try check(store.board.cards.isEmpty && store.history.canUndo)
    store.history.undo()
    try check(store.board.id == destination && store.board.cards.isEmpty)
    store.history.redo()
    try check(
        store.board.cards.count == 1 && store.board.sections![0].memberIDs.contains(store.board.cards[0].id))

    // Collision avoidance moves the second image outside the old frame. Its original
    // insertion point still makes it part of the section, which expands around both.
    let previousFrame = store.board.sectionBounds(store.board.sections![0])
    let originalCard = store.board.cards[0]
    try check(
        canvas.receiveImageItems(
            [imageItem], at: CGPoint(x: originalCard.rect.midX, y: originalCard.rect.midY),
            avoidOverlap: true))
    try waitFor { !canvas.hasPendingImports }
    let added = store.board.cards.first { $0.id != originalCard.id }!
    try check(!previousFrame.contains(CGPoint(x: added.rect.midX, y: added.rect.midY)))
    try check(store.board.sections![0].memberIDs.contains(added.id))
    try check(store.board.sectionBounds(store.board.sections![0]).contains(added.rect))
    store.history.undo()
    try check(store.board.cards == [originalCard])
    store.history.redo()
    try check(store.board.cards.count == 2 && store.board.sections![0].memberIDs.contains(added.id))
    print(
        "PASS: section title/empty-frame zoom, regular card selection, rapid keyboard jumps, overview fit, contextual rename entry, minimap frames, retained panning, appearance, board-switch cancellation, empty-section clicks, background import and collision-avoiding paste membership/undo"
    )
}

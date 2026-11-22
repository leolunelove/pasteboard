import AppKit

func pageTransferTest(directory: URL, image: NSImage) throws {
    let store = BoardStore(directory: directory), source = store.board.id
    let group = UUID()
    var photo = try store.imageCard(image, at: CGPoint(x: 0, y: 0)); photo.groupID = group; photo.sourceURL = "https://example.com/keep"
    photo = ImageCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8).applied(to: photo)
    let note = Card(x: 480, y: 20, width: 240, height: 180, text: "Travel together", tone: 2, groupID: group, contentScale: 1.25)
    let untouched = Card(x: 0, y: 400, width: 200, height: 140, text: "Stay here")
    let locked = Card(x: 260, y: 400, width: 200, height: 140, text: "Protected", locked: true)
    let originals = [untouched, photo, note, locked]
    store.board.cards = originals
    let destination = store.newPage(in: source, name: "Destination")!
    var collision = photo; collision.x = 0; collision.y = 0
    store.board.cards = [collision]; let existing = store.board.cards
    store.newBoard(name: "Elsewhere"); let elsewhere = store.board.id
    store.activate(source)
    try check(!store.canMoveCards([locked.id], from: source, to: destination))
    try check(!store.canMoveCards([note.id, locked.id], from: source, to: destination))
    try check(!store.canMoveCards([note.id], from: source, to: source))
    try check(!store.canMoveCards([UUID()], from: source, to: destination))
    let ids = store.moveCards([note.id], from: source, to: destination, viewport: CGSize(width: 1000, height: 650))!
    try check(ids.count == 2 && !ids.contains(photo.id) && ids.contains(note.id))
    let moved = store.board.cards.filter { ids.contains($0.id) }
    try check(store.board.id == destination && moved.count == 2 && moved[0].groupID == moved[1].groupID && moved[0].groupID != group)
    try check(moved[0].crop == photo.crop && moved[0].asset == photo.asset && moved[0].sourceURL == photo.sourceURL && moved[1].text == note.text && moved[1].renderScale == 1.25)
    try check(abs((moved[1].x - moved[0].x) - (note.x - photo.x)) < 0.00001 && moved[0].width == photo.width && moved[1].height == note.height)
    try check(!moved.contains { $0.rect.intersects(existing[0].rect) })
    try check(store.workspace.boards.first(where: { $0.id == source })!.cards == [untouched, locked])
    let late = Card(x: 0, y: 800, width: 200, height: 100, text: "Late import")
    store.board.cards.append(late)
    store.activate(elsewhere); store.history.undo()
    try check(store.board.id == source && store.board.cards == originals)
    try check(store.workspace.boards.first(where: { $0.id == destination })!.cards == existing + [late])
    store.history.redo(); try check(store.board.id == destination && store.board.cards == existing + [late] + moved)
    var edited = store.board.cards; let index = edited.firstIndex(where: { $0.id == note.id })!; edited[index].text = "Edited after moving"
    store.replaceCards(edited, name: "Edit Note")
    let later = Card(x: 0, y: 1000, width: 200, height: 100, text: "Another late import")
    store.board.cards.append(later); store.activate(elsewhere); store.history.undo()
    try check(store.board.id == destination && store.board.cards.contains(later) && store.board.cards.first(where: { $0.id == note.id })!.text == note.text)
    store.history.undo(); try check(store.board.id == source && store.board.cards == originals)
    store.history.redo(); try check(store.board.id == destination && store.board.cards.contains(later))
    try check(store.save()); let saved = BoardStore(directory: directory); try check(saved.board.cards == store.board.cards && saved.workspace.boards.first(where: { $0.id == source })!.cards == [untouched, locked])

    // Exercise the actual board mouse path crossing into the sidebar, including
    // hover autosave, cancellation, returning to the canvas, and a late image import.
    let dragStore = BoardStore(directory: directory.appendingPathComponent("drag")), a = dragStore.board.id
    let b = dragStore.newPage(in: a, name: "Drop here")!; dragStore.activate(a)
    let card = Card(x: 0, y: 0, width: 200, height: 140, text: "Drag me")
    dragStore.board.cards = [card]; dragStore.history.removeAllActions()
    let view = BoardView(store: dragStore)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
    var valid = true, drops = 0, highlightsCleared = 0
    view.onSidebarHover = { _, ids in valid && dragStore.canMoveCards(ids, from: dragStore.board.id, to: b) ? b : nil }
    view.onSidebarDragEnded = { highlightsCleared += 1 }
    view.onSidebarDrop = { id, ids in drops += 1; return dragStore.moveCards(ids, from: dragStore.board.id, to: id, viewport: view.bounds.size) != nil }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)! }
    func start() -> CGPoint { let r = view.screen(card.rect); return CGPoint(x: r.minX + 30, y: r.minY + 30) }
    let side = CGPoint(x: -50, y: 120)
    view.mouseDown(with: mouse(.leftMouseDown, start())); view.mouseDragged(with: mouse(.leftMouseDragged, side))
    try check(dragStore.board.cards == [card]); try check(dragStore.save()); try check(BoardStore(directory: dragStore.directory).board.cards == [card])
    view.mouseUp(with: mouse(.leftMouseUp, side)); try check(drops == 1 && dragStore.board.id == b && dragStore.board.cards.count == 1 && highlightsCleared > 0)
    dragStore.history.undo(); try check(dragStore.board.id == a && dragStore.board.cards == [card]); dragStore.history.removeAllActions()
    view.mouseDown(with: mouse(.leftMouseDown, start())); view.mouseDragged(with: mouse(.leftMouseDragged, side))
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    view.keyDown(with: escape); view.mouseUp(with: mouse(.leftMouseUp, side)); try check(drops == 1 && dragStore.board.cards == [card] && !dragStore.history.canUndo)
    valid = false
    view.mouseDown(with: mouse(.leftMouseDown, start())); view.mouseDragged(with: mouse(.leftMouseDragged, side)); view.mouseUp(with: mouse(.leftMouseUp, side))
    try check(drops == 1 && dragStore.board.cards == [card] && !dragStore.history.canUndo)
    valid = true
    let begin = start(), end = CGPoint(x: begin.x + 80, y: begin.y + 50)
    view.mouseDown(with: mouse(.leftMouseDown, begin)); view.mouseDragged(with: mouse(.leftMouseDragged, side)); view.mouseDragged(with: mouse(.leftMouseDragged, end)); view.mouseUp(with: mouse(.leftMouseUp, end))
    try check(dragStore.board.cards[0].x == card.x + 80 && dragStore.board.cards[0].y == card.y + 50)
    dragStore.history.undo(); try check(dragStore.board.cards == [card])
    let pb = NSPasteboard(name: .init("Gather-transfer-" + UUID().uuidString)); defer { pb.releaseGlobally() }; pb.setData(image.tiffRepresentation!, forType: .tiff)
    view.mouseDown(with: mouse(.leftMouseDown, start())); view.mouseDragged(with: mouse(.leftMouseDragged, side)); try check(view.receive(pb, at: .zero))
    view.mouseUp(with: mouse(.leftMouseUp, side)); try waitFor { !view.hasPendingImports }
    try check(dragStore.workspace.boards.first(where: { $0.id == a })!.cards.count == 1 && dragStore.board.id == b)
    dragStore.history.undo(); try check(dragStore.board.id == a && dragStore.board.cards.contains(card) && dragStore.board.cards.contains { $0.asset != nil })
    print("PASS: sidebar page transfer, mixed groups, locks, collision-safe identity, placement, cross-page undo/redo, background imports, mouse hover/drop/cancel and save/reload")
}

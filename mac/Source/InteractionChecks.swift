import AppKit

func interactionTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    store.board.zoom = 1
    store.board.offsetX = 0
    store.board.offsetY = 0
    let image = Card(x: 100, y: 100, width: 200, height: 140, asset: "fixture.png")
    let note = Card(x: 400, y: 100, width: 220, height: 140, text: "Keep this thought")
    store.board.cards = [image, note]
    view.refresh()
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil),
            modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func key(_ code: UInt16, shift: Bool = false) {
        view.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
    }
    view.selection = [image.id]
    let handle = CGPoint(x: image.rect.maxX, y: image.rect.maxY)
    view.mouseDown(with: mouse(.leftMouseDown, handle))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: handle.x + 100, y: handle.y + 80)))
    try check(view.hasPointerInteraction && store.board.cards[0].width == 300)
    // Other edits remain blocked while the resize owns the pointer.
    key(51)
    try check(store.board.cards.count == 2)
    key(53)
    try check(!view.hasPointerInteraction && store.board.cards == [image, note] && !store.history.canUndo)
    view.mouseUp(with: mouse(.leftMouseUp, handle))
    try check(store.board.cards == [image, note] && !store.history.canUndo)

    // Cancelling a move restores only the moved card, preserving independent work.
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 180, y: 160)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 250, y: 210)))
    store.board.cards[1].text = "An unrelated edit"
    view.cancelPointerInteraction()
    try check(store.board.cards[0] == image && store.board.cards[1].text == "An unrelated edit")

    // Shift-marquee cancellation restores the original selection.
    view.selection = [image.id]
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 700, y: 400), shift: true))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 380, y: 80), shift: true))
    try check(view.selection.contains(note.id))
    key(53)
    try check(view.selection == [image.id])

    // Switching pages during a resize rolls the old page back, not the new one.
    let previous = store.board.id
    view.mouseDown(with: mouse(.leftMouseDown, handle))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 440, y: 300)))
    store.newBoard(name: "Another page")
    view.refresh()
    try check(!view.hasPointerInteraction && store.board.cards.isEmpty)
    try check(store.workspace.boards.first(where: { $0.id == previous })!.cards[0] == image)
    view.mouseUp(with: mouse(.leftMouseUp, handle))
    try check(store.board.cards.isEmpty)

    store.activate(previous)
    view.refresh()
    // Locked groups stay still under both small and large arrow nudges.
    let group = UUID()
    var a = image
    var b = note
    a.groupID = group
    b.groupID = group
    b.locked = true
    store.board.cards = [a, b]
    view.selection = [a.id]
    key(124, shift: true)
    try check(store.board.cards == [a, b])
    store.board.cards[1].locked = nil
    key(124, shift: true)
    try check(store.board.cards[0].x == a.x + 10 && store.board.cards[1].x == b.x + 10)
    store.history.undo()
    try check(store.board.cards[0].x == a.x && store.board.cards[1].x == b.x)
    print(
        "PASS: resize/move/marquee cancellation, stale mouse-up, page changes, edit isolation and locked-group nudging"
    )
}

func arrangementTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let group = UUID()
    let cards = [
        Card(x: -300, y: 50, width: 120, height: 80, text: "A"),
        Card(x: 0, y: 150, width: 200, height: 100, asset: "image.png", groupID: group),
        Card(x: 220, y: 180, width: 100, height: 80, text: "Grouped", groupID: group),
        Card(x: 700, y: -120, width: 80, height: 160, hex: "#3296AD"),
        Card(x: 900, y: 600, width: 180, height: 90, text: "Unselected"),
    ]
    store.board.cards = cards
    let selection: Set<UUID> = [cards[0].id, cards[1].id, cards[3].id]
    for mode in BoardArrangement.allCases {
        try check(mode.canApply(to: store.board, selection: selection))
        let result = mode.applying(to: store.board, selection: selection)
        try check(result[4] == cards[4])
        try check(abs((result[2].x - result[1].x) - (cards[2].x - cards[1].x)) < 0.000001)
        try check(abs((result[2].y - result[1].y) - (cards[2].y - cards[1].y)) < 0.000001)
        for i in cards.indices {
            var moved = result[i]
            moved.x = cards[i].x
            moved.y = cards[i].y
            try check(moved == cards[i])
        }
        let units = [result[0].rect, result[1].rect.union(result[2].rect), result[3].rect]
        switch mode {
        case .left: try check(Set(units.map(\.minX)).count == 1)
        case .right: try check(Set(units.map(\.maxX)).count == 1)
        case .horizontalCenter: try check(Set(units.map(\.midX)).count == 1)
        case .top: try check(Set(units.map(\.minY)).count == 1)
        case .bottom: try check(Set(units.map(\.maxY)).count == 1)
        case .verticalCenter: try check(Set(units.map(\.midY)).count == 1)
        case .horizontalSpacing:
            let sorted = units.sorted { $0.minX < $1.minX }
            try check(abs((sorted[1].minX - sorted[0].maxX) - (sorted[2].minX - sorted[1].maxX)) < 0.000001)
            try check(result[0] == cards[0] && result[3] == cards[3])
        case .verticalSpacing:
            let sorted = units.sorted { $0.minY < $1.minY }
            try check(abs((sorted[1].minY - sorted[0].maxY) - (sorted[2].minY - sorted[1].maxY)) < 0.000001)
        }
        store.replaceCards(result, name: mode.title)
        store.history.undo()
        try check(store.board.cards == cards)
        store.history.redo()
        try check(store.board.cards == result)
        store.board.cards = cards
        store.history.removeAllActions()
    }
    store.board.cards[2].locked = true
    for mode in BoardArrangement.allCases {
        try check(!mode.canApply(to: store.board, selection: selection))
        try check(mode.applying(to: store.board, selection: selection) == store.board.cards)
    }
    let overlapping = (0..<3).map { Card(x: Double($0) * 10, y: 0, width: 200, height: 100, text: "Overlap") }
    store.board.cards = overlapping
    let overlappingIDs = Set(overlapping.map(\.id))
    for mode in [BoardArrangement.horizontalSpacing, .verticalSpacing] {
        try check(!mode.canApply(to: store.board, selection: overlappingIDs))
        try check(mode.applying(to: store.board, selection: overlappingIDs) == overlapping)
    }
    print(
        "PASS: all alignment/distribution actions, groups as units, negative coordinates, locked groups, identity and undo/redo"
    )
}

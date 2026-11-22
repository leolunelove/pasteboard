import AppKit

func boardNavigationTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    func tab(_ backwards: Bool = false) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: backwards ? [.shift] : [], timestamp: 0,
            windowNumber: 0, context: nil, characters: backwards ? "\u{19}" : "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        view.keyDown(with: event)
    }
    tab()
    try check(view.selection.isEmpty)
    let group = UUID()
    let a = Card(x: 0, y: 0, width: 200, height: 100, asset: "sample.svg")
    let b = Card(x: 400, y: 0, width: 200, height: 100, text: "Grouped note", groupID: group)
    let c = Card(x: 9000, y: -8000, width: 200, height: 100, locked: true, hex: "#32654D")
    let d = Card(x: 650, y: 0, width: 200, height: 100, asset: "sample.png", groupID: group)
    let original = [a, b, c, d]
    store.board.cards = original
    view.refresh()
    store.history.removeAllActions()
    tab()
    try check(view.selection == [a.id])
    let before = view.offset
    tab()
    try check(view.selection == [b.id, d.id])
    tab()
    try check(view.selection == [c.id])
    try waitFor { view.screen(c.rect).contains(CGPoint(x: view.bounds.midX, y: view.bounds.midY)) }
    try check(view.offset != before)
    tab()
    try check(view.selection == [a.id])
    tab(true)
    try check(view.selection == [c.id])
    tab(true)
    try check(view.selection == [b.id, d.id])
    view.selection = []
    tab(true)
    try check(view.selection == [c.id])
    view.selection = [a.id, b.id]
    tab()
    try check(view.selection == [c.id])
    view.selection = [b.id, c.id]
    tab(true)
    try check(view.selection == [a.id])
    // Repeated tabs must cancel an older camera target, including when the next
    // selection is already visible and would not otherwise start an animation.
    view.stopZoomAnimation()
    store.board.zoom = 1
    store.board.offsetX = 50
    store.board.offsetY = 50
    view.selection = [b.id]
    tab()
    tab()
    try waitFor { view.requestedZoom == view.zoom }
    try check(view.selection == [a.id] && view.screen(a.rect).intersects(view.bounds))
    let stable = view.offset
    RunLoop.current.run(until: Date().addingTimeInterval(0.22))
    try check(view.offset == stable)
    // Recover from being zoomed out; a visible selection remains in place once readable.
    view.setZoom(0.1)
    view.selection = []
    tab()
    try waitFor { view.zoom == 0.75 }
    let readable = view.offset
    view.selection = []
    tab()
    RunLoop.current.run(until: Date().addingTimeInterval(0.22))
    try check(view.offset == readable)
    // Oversized groups fit in the viewport without distorting their content.
    store.board.cards = [Card(x: -3000, y: -1000, width: 6000, height: 3000, text: "Large")]
    view.selection = []
    tab()
    try waitFor { view.requestedZoom == view.zoom }
    try check(view.bounds.contains(view.screen(store.board.cards[0].rect)))
    store.board.cards = original
    try check(!store.history.canUndo && store.board.cards == original)
    store.newBoard(name: "Empty page")
    view.refresh()
    tab(true)
    try check(view.selection.isEmpty)
    print(
        "PASS: actual Tab/Shift-Tab events, wraparound, groups, locked items, multi-selection, offscreen reveal, rapid-tab camera cancellation, readable zoom, oversized fit, page changes and no content/undo mutation"
    )
}

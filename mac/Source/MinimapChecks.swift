import AppKit

func minimapTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let view = BoardView(store: store)
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    view.layout()
    let map = view.minimap
    try check(map.isHidden)
    let group = UUID()
    let cards = [
        Card(x: -1200, y: -800, width: 420, height: 300, asset: "image.svg"),
        Card(x: -650, y: -800, width: 280, height: 220, text: "Note", tone: 1),
        Card(x: 100, y: 0, width: 350, height: 250, asset: "photo.png", groupID: group),
        Card(x: 500, y: 0, width: 220, height: 180, text: "Grouped", groupID: group),
        Card(x: 4000, y: 2000, width: 250, height: 200, locked: true, hex: "#C86B53"),
    ]
    store.board.cards = cards
    view.refresh()
    store.history.removeAllActions()
    try check(!map.isHidden && view.bounds.contains(map.frame))
    let geometry = map.geometry!
    for card in cards {
        try check(
            geometry.worldBounds.contains(card.rect) && map.mapArea.contains(geometry.project(card.rect)))
    }
    for point in [CGPoint(x: -1000, y: -700), CGPoint(x: 4100, y: 2100), view.worldCenter] {
        let result = geometry.worldPoint(geometry.project(point))
        try check(hypot(point.x - result.x, point.y - result.y) < 0.00001)
    }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: map.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let target = CGPoint(x: cards[4].rect.midX, y: cards[4].rect.midY)
    let click = geometry.project(target)
    let zoom = view.zoom
    map.mouseDown(with: event(.leftMouseDown, click))
    map.mouseUp(with: event(.leftMouseUp, click))
    try check(
        hypot(view.worldCenter.x - target.x, view.worldCenter.y - target.y) < 0.00001 && view.zoom == zoom)
    try check(view.selection.isEmpty && store.board.cards == cards && !store.history.canUndo)
    // A viewport grab keeps the pointer's original offset, and map scale stays
    // fixed throughout the drag rather than chasing the camera.
    let frozen = map.geometry!
    let startCenter = view.worldCenter
    let grab = frozen.project(CGPoint(x: startCenter.x + 100, y: startCenter.y + 50))
    map.mouseDown(with: event(.leftMouseDown, grab))
    try check(hypot(view.worldCenter.x - startCenter.x, view.worldCenter.y - startCenter.y) < 0.00001)
    let end = CGPoint(x: grab.x - 12, y: grab.y - 8)
    map.mouseDragged(with: event(.leftMouseDragged, end))
    try check(map.geometry!.worldBounds == frozen.worldBounds)
    try check(
        abs(view.worldCenter.x - (startCenter.x - 12 / frozen.scale)) < 0.00001
            && abs(view.worldCenter.y - (startCenter.y - 8 / frozen.scale)) < 0.00001)
    map.mouseUp(with: event(.leftMouseUp, end))
    // Jumping interrupts an existing zoom animation instead of drifting away later.
    view.animateZoom(to: 2)
    let next = map.geometry!.project(CGPoint(x: -1000, y: -650))
    map.mouseDown(with: event(.leftMouseDown, next))
    map.mouseUp(with: event(.leftMouseUp, next))
    let stable = view.offset
    let stableZoom = view.zoom
    RunLoop.current.run(until: Date().addingTimeInterval(0.22))
    try check(view.offset == stable && view.zoom == stableZoom)
    // A lost camera is still shown, along with the content it can jump back to.
    view.navigateMinimap(to: CGPoint(x: 80_000, y: -90_000))
    try check(
        map.geometry!.worldBounds.contains(map.viewport) && map.geometry!.worldBounds.contains(cards[0].rect))
    view.minimapEnabled = false
    try check(map.isHidden)
    view.minimapEnabled = true
    try check(!map.isHidden)
    view.frame.size = CGSize(width: 280, height: 200)
    view.layout()
    try check(map.isHidden)
    view.frame.size = CGSize(width: 1000, height: 700)
    view.layout()
    try check(!map.isHidden)
    // Page changes invalidate an in-progress drag, including a queued mouse-up.
    let old = map.geometry!.project(view.worldCenter)
    map.mouseDown(with: event(.leftMouseDown, old))
    store.newBoard(name: "Another page")
    view.refresh()
    let emptyViewport = view.offset
    map.mouseDragged(with: event(.leftMouseDragged, end))
    map.mouseUp(with: event(.leftMouseUp, end))
    try check(map.isHidden && view.offset == emptyViewport)
    // Exercise the actual overlay renderer without decoding any image assets.
    store.board.cards = cards
    view.selection = [cards[2].id]
    view.navigateMinimap(to: CGPoint(x: 350, y: 150))
    view.updateMinimap()
    let revision = store.imageRevision
    let context = CGContext(
        data: nil, width: 416, height: 316, bitsPerComponent: 8, bytesPerRow: 1664,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: 316)
    context.scaleBy(x: 2, y: -2)
    map.render(in: context)
    let image = context.makeImage()!
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try png.write(to: directory.appendingPathComponent("Minimap.png"))
    try check(store.imageRevision == revision && store.board.cards == cards)
    print(
        "PASS: minimap projection/negative coordinates, click-to-jump, anchored drag with frozen scale, viewport recovery, interrupted animation, unchanged zoom/content/undo, visibility/resize, page-change cancellation and lightweight rendering"
    )
}

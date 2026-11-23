import AppKit
import QuartzCore

func check(_ value: @autoclosure () -> Bool, line: Int = #line) throws {
    if !value() {
        throw NSError(
            domain: "SceneCheck", code: line,
            userInfo: [NSLocalizedDescriptionKey: "Scene check failed at line \(line)"])
    }
}
let directory = URL(fileURLWithPath: "/private/tmp/PasteboardScene-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let app = NSApplication.shared
let store = BoardStore(directory: directory)
let scene = CanvasScene()
let group = UUID()
let first = Card(x: 0, y: 0, width: 100, height: 80, text: "Visible", groupID: group)
var second = Card(x: 120, y: 0, width: 100, height: 80, text: "Offscreen", groupID: group)
store.board.cards = [first, second]
var groups = [group: CGRect(x: 0, y: 0, width: 220, height: 80)]
let selection: Set<UUID> = [first.id, second.id]
let guides = [AlignmentGuide(axis: .x, position: 10, from: 0, to: 200)]
let spacing = [SpacingGuide(axis: .x, position: 50, distance: 20, spans: [GapSpan(from: 100, to: 120)])]
func frame(zoom: CGFloat = 1, offset: CGPoint = .zero, drawGroups: Bool = true, drawGuides: Bool = true) {
    scene.update(
        cards: [first], selection: selection, groups: drawGroups ? groups : [:],
        guides: drawGuides ? guides : [], spacingGuides: drawGuides ? spacing : [], editing: nil, zoom: zoom,
        offset: offset, store: store, color: { _ in .white }, backingScale: 2)
}
do {
    frame()
    let outline = scene.root.sublayers!.first { $0.zPosition == 1_000_000 } as! CAShapeLayer
    let label = scene.root.sublayers!.first { $0.zPosition == 1_000_001 } as! CATextLayer
    let grip = scene.root.sublayers!.first { $0.zPosition == 1_000_002 }!
    let guide = scene.root.sublayers!.first { $0.zPosition == 2_000_000 } as! CAShapeLayer
    let gap = scene.root.sublayers!.first { $0.zPosition == 2_000_001 } as! CAShapeLayer
    let outlinePath = outline.path
    let guidePath = guide.path
    let gapPath = gap.path
    frame(offset: CGPoint(x: 40, y: -20))
    try check(scene.root.position == CGPoint(x: 40, y: -20))
    try check(outline.path === outlinePath && guide.path === guidePath && gap.path === gapPath)
    frame(zoom: 0.5)
    try check(abs(outline.lineWidth - 3.4) < 0.001)
    groups[group] = CGRect(x: 100, y: 0, width: 220, height: 80)
    frame()
    try check(outline.path!.boundingBox.minX == 91)
    second.locked = true
    store.board.cards = [first, second]
    frame()
    try check(grip.isHidden && (label.string as? NSAttributedString)?.string == "Locked group")
    second.locked = false
    store.board.cards = [first, second]
    frame()
    try check(!grip.isHidden && (label.string as? NSAttributedString)?.string == "Group")
    let groupedGapY = gap.path!.boundingBox.minY
    frame(drawGroups: false)
    try check(gap.path!.boundingBox.minY == groupedGapY + 24)
    frame(drawGroups: false, drawGuides: false)
    try check(guide.isHidden && gap.isHidden && guide.path == nil)
    let light = NSAppearance(named: .aqua)!
    let dark = NSAppearance(named: .darkAqua)!
    func themedFrame(_ appearance: NSAppearance) {
        scene.update(
            cards: [first], selection: selection, groups: groups, guides: guides,
            spacingGuides: spacing, editing: nil, zoom: 1, offset: .zero, store: store,
            color: { _ in .white }, backingScale: 2, appearance: appearance)
    }
    themedFrame(light)
    let lightStroke = guide.strokeColor!
    themedFrame(dark)
    let themedOutline = scene.root.sublayers!.first { $0.zPosition == 1_000_000 } as! CAShapeLayer
    try check(guide.strokeColor != lightStroke && themedOutline.strokeColor == guide.strokeColor)
    themedFrame(light)
    try check(guide.strokeColor == lightStroke)

    let context = CGContext(
        data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let grid = BoardGrid()
    grid.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 512, height: 512), spacing: 24, offset: .zero)
    let generation = grid.generation
    for x in 1...100 {
        grid.draw(
            in: context, bounds: CGRect(x: 0, y: 0, width: 512, height: 512), spacing: 24,
            offset: CGPoint(x: x, y: -x))
    }
    try check(grid.generation == generation)
    grid.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 512, height: 512), spacing: 32, offset: .zero)
    try check(grid.generation == generation + 1)

    let canvas = BoardView(store: store)
    canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    store.board.cards = [Card(x: -2000, y: -2000, width: 4000, height: 4000, text: "Map extent")]
    store.board.zoom = 1
    store.board.offsetX = 0
    store.board.offsetY = 0
    canvas.minimap.frame = CGRect(x: 0, y: 0, width: 208, height: 158)
    canvas.minimap.render(in: context)
    let mapGeneration = canvas.minimap.artworkGeneration
    store.board.offsetX = 40
    canvas.minimap.render(in: context)
    try check(canvas.minimap.artworkGeneration == mapGeneration)
    canvas.selection = [store.board.cards[0].id]
    canvas.minimap.render(in: context)
    try check(canvas.minimap.artworkGeneration == mapGeneration + 1)
    store.board.cards[0].x += 10
    canvas.minimap.render(in: context)
    try check(canvas.minimap.artworkGeneration == mapGeneration + 2)

    let exported = BoardExport(cards: [first], assets: directory.appendingPathComponent("Assets"))
    var lightPNG: Data!
    var darkPNG: Data!
    light.performAsCurrentDrawingAppearance { lightPNG = try? exported.png(scale: 1, transparent: false) }
    dark.performAsCurrentDrawingAppearance { darkPNG = try? exported.png(scale: 1, transparent: false) }
    try check(lightPNG != nil && lightPNG == darkPNG)
    // Repeated gesture saves must persist the final viewport after the burst.
    for x in 0..<100 {
        store.board.offsetX = Double(x)
        store.scheduleSave()
    }
    let deadline = Date(timeIntervalSinceNow: 3)
    while Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        if let data = try? Data(contentsOf: directory.appendingPathComponent("Workspace.json")),
            let saved = try? JSONDecoder().decode(Workspace.self, from: data),
            saved.boards.first(where: { $0.id == store.board.id })?.offsetX == 99
        {
            break
        }
    }
    let saved = try JSONDecoder().decode(
        Workspace.self, from: Data(contentsOf: directory.appendingPathComponent("Workspace.json")))
    try check(saved.boards.first(where: { $0.id == store.board.id })?.offsetX == 99)
    let missing = Card(x: 0, y: 0, width: 240, height: 160, asset: "missing-preview.png")
    let imageScene = CanvasScene()
    func imageFrame(_ card: Card) {
        store.board.cards = [card]
        imageScene.update(
            cards: [card], selection: [], groups: [:], guides: [], editing: nil,
            zoom: 1, offset: .zero, store: store, color: { _ in .white }, backingScale: 2, appearance: dark)
    }
    func visibleText(_ layer: CALayer) -> [String] {
        guard !layer.isHidden else { return [] }
        let text = (layer as? CATextLayer)?.string as? NSAttributedString
        return (text.map { [$0.string] } ?? []) + (layer.sublayers ?? []).flatMap(visibleText)
    }
    imageFrame(missing)
    try check(visibleText(imageScene.root).contains("Loading image…"))
    let failureDeadline = Date(timeIntervalSinceNow: 5)
    while !store.previewHasFailed("missing-preview.png", pixelSize: 480, crop: .full)
        && Date() < failureDeadline
    {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    imageFrame(missing)
    try check(visibleText(imageScene.root).contains("Image unavailable"))
    let transparent = CGContext(
        data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    transparent.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.5))
    transparent.fillEllipse(in: CGRect(x: 32, y: 32, width: 64, height: 64))
    let card = try store.imageCard(
        NSImage(cgImage: transparent.makeImage()!, size: CGSize(width: 128, height: 128)), at: .zero)
    imageFrame(card)
    let artwork = imageScene.root.sublayers!.first { $0.zPosition == 0 }!
    let content = artwork.sublayers!.first!
    try check(content.backgroundColor == nil && content.contents != nil)
    try check(!visibleText(imageScene.root).contains("Loading image…"))
    print(
        "PASS: retained scene, appearance changes, cached grid/minimap invalidation, export colours, gesture autosave, visible loading/failure states and transparent image surfaces"
    )
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}

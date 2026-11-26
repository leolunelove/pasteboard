import AppKit

func workspaceOverviewTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let root = store.board.id
    let group = UUID()
    let note = Card(
        x: -200, y: 35, width: 300, height: 140, text: "Keep this note", groupID: group, locked: true,
        sourceURL: "https://example.com/reference")
    let swatch = Card(x: 130, y: 35, width: 220, height: 180, groupID: group, hex: "#336699")
    store.board.cards = [note, swatch]
    store.board.zoom = 0.625
    store.board.offsetX = -123
    store.board.offsetY = 42
    let page = store.newPage(in: root, name: "Board")!
    let existing = Card(x: 1, y: 2, width: 200, height: 120, text: "Existing inner page")
    store.board.cards = [existing]
    store.activate(root)
    try check(store.save())
    let before = store.workspace
    try store.enableWorkspaceOverviews()
    try check(store.showsWorkspaceOverview && store.board.id == root && store.board.cards.isEmpty)
    let pages = store.workspace.pages(in: root)
    try check(pages.count == 2 && pages[0].id == page && pages[0].cards == [existing])
    let migrated = pages[1]
    try check(
        migrated.name == "Board 2" && migrated.cards == [note, swatch] && migrated.zoom == 0.625
            && migrated.offsetX == -123 && migrated.offsetY == 42)
    try check(migrated.id != root && migrated.parentID == root)
    let count = store.workspace.boards.count
    try store.enableWorkspaceOverviews()
    try check(store.workspace.boards.count == count)
    let record = store.backups.records().first!
    let saved = try JSONDecoder().decode(
        Workspace.self,
        from: Data(
            contentsOf: store.backups.folder.appendingPathComponent(record.folderName).appendingPathComponent(
                "Workspace.json")))
    try check(saved.boards == before.boards)
    let reopened = BoardStore(directory: directory)
    try reopened.enableWorkspaceOverviews()
    try check(reopened.workspace.boards == store.workspace.boards)
    reopened.activate(migrated.id)
    try check(!reopened.showsWorkspaceOverview)
    let failed = BoardStore(directory: directory.appendingPathComponent("blocked"))
    failed.board.cards = [note]
    try Data("blocked".utf8).write(to: failed.directory.appendingPathComponent("Backups"))
    do {
        try failed.enableWorkspaceOverviews()
        try check(false)
    } catch {
        try check(failed.board.cards == [note] && !failed.workspaceOverviewsEnabled)
    }
    print(
        "PASS: workspace overview migration, backup, card identity/group/lock/source and camera preservation, existing page names, idempotence and failed-backup protection"
    )
}

func designPasteAndColourTest(directory: URL) throws {
    let xml = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><defs><mask id="m"><rect width="120" height="80" fill="white"/></mask></defs><rect width="120" height="80" fill="#FF0000" fill-opacity="0.5"/><path d="M5 5 L100 5" fill="none" stroke="#000000" stroke-width="3"/><style>.accent {fill: #00FF00; stroke: none;}</style></svg>
        """
    let wrapped = NSPasteboardItem()
    wrapped.setString(
        "<meta charset='utf-8'><!--StartFragment-->" + xml + "<!--EndFragment-->", forType: .html)
    try check(SVGImage.clipboardData(from: wrapped) == Data(xml.utf8))
    let encoded = NSPasteboardItem()
    encoded.setString(
        "<img src='data:image/svg+xml;base64,\(Data(xml.utf8).base64EncodedString())'>", forType: .html)
    try check(SVGImage.clipboardData(from: encoded) == Data(xml.utf8))
    let native = NSPasteboardItem()
    native.setString("<span data-buffer='<!--(figma)PRIVATE(/figma)-->'></span>", forType: .html)
    try check(DesignClipboard.nativeFigma(native) && SVGImage.clipboardData(from: native) == nil)
    let remote = NSPasteboardItem()
    remote.setString("<img src='https://example.com/not-fetched.png'>", forType: .html)
    try check(DesignClipboard.embeddedImage(remote) == nil)
    let changed = try SVGImage(data: Data(xml.utf8)).recoloured(hex: "#336699")
    let document = try XMLDocument(data: changed)
    let root = document.rootElement()!
    let rects = try root.nodes(forXPath: "//*[local-name()='rect']") as! [XMLElement]
    try check(rects[0].attribute(forName: "fill")?.stringValue == "white")
    try check(
        rects[1].attribute(forName: "fill")?.stringValue == "#336699"
            && rects[1].attribute(forName: "fill-opacity")?.stringValue == "0.5")
    let path = try root.nodes(forXPath: "//*[local-name()='path']").first as! XMLElement
    try check(
        path.attribute(forName: "fill")?.stringValue == "none"
            && path.attribute(forName: "stroke")?.stringValue == "#336699")
    let image = try SVGImage(data: changed).rasterized(maxPixel: 512)
    try check(image.alphaInfo != .none)
    let pasteStore = BoardStore(directory: directory.appendingPathComponent("clipboard"))
    let pasteView = BoardView(store: pasteStore)
    pasteView.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
    let pasteboard = NSPasteboard(name: .init("Pasteboard.design-check." + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([wrapped])
    try check(pasteView.receive(pasteboard, at: .zero))
    try waitFor { !pasteView.hasPendingImports }
    try check(
        pasteStore.board.cards.count == 1 && pasteStore.board.cards[0].asset.map(BoardImageIO.isSVG) == true)
    pasteboard.clearContents()
    pasteboard.writeObjects([native])
    var message = ""
    pasteStore.status = { message = $0 }
    try check(pasteView.receive(pasteboard, at: .zero))
    try check(pasteStore.board.cards.count == 1 && message.contains("Figma"))
    let store = BoardStore(directory: directory)
    var done = false
    var imported: [PreparedImage] = []
    store.prepareImages([Data(xml.utf8)]) { values, _ in
        imported = values
        done = true
    }
    try waitFor { done }
    try check(imported.count == 1)
    var card = store.card(for: imported[0], at: CGPoint(x: 20, y: 30))
    card.crop = ImageCrop(x: 0.1, y: 0, width: 0.8, height: 1)
    card.sourceURL = "https://figma.com/design/example"
    var duplicate = card
    duplicate.id = UUID()
    duplicate.x = 400
    store.replaceCards([card, duplicate], name: "Fixture")
    let boardID = store.board.id
    done = false
    var success = false
    store.recolourSVG(card.id, hex: "#123456", boardID: boardID) { result in
        success = (try? result.get()) != nil
        done = true
    }
    try waitFor { done }
    try check(success)
    let recoloured = store.board.cards[0]
    try check(
        recoloured.asset != card.asset && store.board.cards[1] == duplicate && recoloured.crop == card.crop
            && recoloured.sourceURL == card.sourceURL && recoloured.rect == card.rect)
    try check(store.originalImageData(card.asset!) == Data(xml.utf8))
    let newBytes = store.originalImageData(recoloured.asset!)!
    try check(String(data: newBytes, encoding: .utf8)!.contains("#123456"))
    let export = BoardExport(cards: [recoloured], assets: store.directory.appendingPathComponent("Assets"))
    let exported = try export.png(scale: 1, transparent: true)
    try check(!exported.isEmpty)
    store.history.undo()
    try check(store.board.cards == [card, duplicate])
    store.history.redo()
    try check(store.board.cards[0] == recoloured)
    store.board.cards[0].locked = true
    done = false
    success = true
    store.recolourSVG(card.id, hex: "#FFFFFF", boardID: boardID) { result in
        success = (try? result.get()) != nil
        done = true
    }
    try waitFor { done }
    try check(!success && store.board.cards[0].asset == recoloured.asset)
    try check(store.save())
    try check(BoardStore(directory: directory).board.cards == store.board.cards)
    print(
        "PASS: Figma-compatible wrapped SVG/data URLs, private payload detection, local-only imports, SVG fill/stroke/CSS/alpha/mask recolouring, immutable shared originals, crop/source persistence, export, locking and undo/redo"
    )
}

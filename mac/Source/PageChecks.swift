import AppKit
import ImageIO

func pageHierarchyTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let root = store.board.id
    store.renameBoard(root, name: " Project One \n")
    let originalNote = Card(x: -100, y: 200, width: 250, height: 120, text: "Keep the workspace canvas")
    store.board.cards = [originalNote]; store.board.zoom = 0.625; store.board.offsetX = -235
    let originalRoot = store.board
    // Legacy documents have no parentID; loading must retain IDs, cards and camera.
    try check(store.save())
    let legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Workspace.json"))) as! [String: Any]
    try check(((legacyJSON["boards"] as! [[String: Any]])[0])["parentID"] == nil)
    let legacy = BoardStore(directory: directory)
    try check(legacy.board.id == root && legacy.board.cards == [originalNote] && legacy.board.zoom == 0.625)

    let first = store.newPage(in: root, name: "References")!
    try check(store.board.id == first && store.board.parentID == root && store.board.cards.isEmpty && store.board.zoom == 1)
    let bitmap = CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(NSColor.red.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 160))
    let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil); try check(CGImageDestinationFinalize(destination))
    var images: [PreparedImage] = []; var finished = false
    store.prepareImages([bytes as Data], sourceURLs: ["https://example.com/reference"]) { values, _ in images = values; finished = true }
    try waitFor { finished }; try check(images.count == 1)
    var photo = store.card(for: images[0], at: CGPoint(x: 150, y: 120)); photo = ImageCrop(x: 0, y: 0, width: 0.5, height: 1).applied(to: photo); photo.locked = true
    store.replaceCards([photo], name: "Paste"); store.board.zoom = 1.25; store.board.offsetX = 77
    let second = store.newPage(in: first, name: "Drafts")!
    try check(store.board.parentID == root && store.workspace.pages(in: root).map(\.id) == [first, second])
    let secondNote = Card(x: 0, y: 0, width: 200, height: 140, text: "Separate page")
    store.replaceCards([secondNote], name: "Paste")
    store.renameBoard(first, name: "  Moodboard  "); store.renameBoard(first, name: " \n")
    try check(store.workspace.boards.first(where: { $0.id == first })!.name == "Moodboard")
    try check(store.workspace.path(for: store.workspace.boards.first(where: { $0.id == first })!) == "Project One / Moodboard")
    store.activate(root); try check(store.board.cards == originalRoot.cards && store.board.offsetX == -235 && store.board.zoom == 0.625)
    store.newBoard(name: "Project Two"); let other = store.board.id
    let otherPage = store.newPage(in: other, name: "Moodboard")!
    store.renameBoard(first, name: "Final references") // Renaming a background page targets its stable ID.
    try check(store.board.id == otherPage && store.board.name == "Moodboard")
    try check(store.newPage(in: UUID(), name: "Invalid") == nil && store.newPage(in: root, name: " ") == nil)
    let results = BoardSearch.results(in: store.workspace, imageText: [:], query: "project one final")
    try check(results.contains { $0.boardID == first && $0.cardID == nil && $0.detail.contains("Project One / Final references") })
    store.activate(first); try check(store.board.cards == [photo] && store.board.zoom == 1.25 && store.board.offsetX == 77)
    try check(store.save())
    let reopened = BoardStore(directory: directory)
    try check(reopened.board.id == first && reopened.board.parentID == root && reopened.board.cards == [photo] && Workspace.validHierarchy(reopened.workspace.boards))

    // Workspace export includes all of its pages and their images; page export stands alone.
    store.activate(root)
    let portable = try store.portableData(), decoded = try JSONDecoder().decode(PortableBoard.self, from: portable)
    try check(decoded.board.id == root && decoded.pages?.map(\.id) == [first, second] && decoded.assets[photo.asset!] == bytes as Data)
    let count = store.workspace.boards.count
    try store.importBoard(data: portable)
    let importedRoot = store.board.id, importedPages = store.workspace.pages(in: importedRoot)
    try check(store.workspace.boards.count == count + 3 && importedRoot != root && importedPages.count == 2 && importedPages[0].id != first && importedPages[0].parentID == importedRoot)
    try check(importedPages[0].cards[0].crop == photo.crop && importedPages[0].cards[0].sourceURL == photo.sourceURL && importedPages[0].cards[0].isLocked)
    let importedImage = try Data(contentsOf: directory.appendingPathComponent("Assets").appendingPathComponent(importedPages[0].cards[0].asset!)); try check(importedImage == bytes as Data)
    store.activate(first)
    let pageCopy = try store.portableData(), pageData = try JSONDecoder().decode(PortableBoard.self, from: pageCopy)
    try check(pageData.board.parentID == nil && pageData.pages == nil)
    try store.importBoard(data: pageCopy); try check(store.board.parentID == nil && store.board.cards[0].crop == photo.crop)
    var broken = decoded; broken.pages![0].parentID = UUID()
    do { try store.importBoard(data: JSONEncoder().encode(broken)); throw NSError(domain: "Gather.Check", code: 1) }
    catch let error as NSError { try check(error.domain != "Gather.Check") }
    var orphan = Board(name: "Orphan", parentID: UUID())
    try check(!Workspace.validHierarchy([orphan]))
    orphan.parentID = orphan.id; try check(!Workspace.validHierarchy([orphan]))
    try check(!Workspace.validHierarchy([originalRoot, originalRoot]))

    // Restored pages must reference the new workspace IDs, never an old live workspace.
    try check(store.save())
    var captured = false
    store.backupNow { result in captured = (try? result.get()) != nil }
    try waitFor { captured }
    let record = store.backups.records().first!, before = store.workspace.boards
    let restored = try store.backups.restoredBoards(from: record, assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    try check(Workspace.validHierarchy(restored) && Set(restored.map(\.id)).isDisjoint(with: Set(before.map(\.id))))
    let restoredFirst = restored.first { $0.name == "Final references (restored)" }!
    let restoredRoot = restored.first { $0.id == restoredFirst.parentID }!
    try check(restoredRoot.name == "Project One (restored)" && restoredFirst.cards[0].crop == photo.crop)
    let parentBefore = store.workspace.boards.first { $0.id == root }!
    store.removeBoard(second)
    try check(store.workspace.pages(in: root).map(\.id) == [first] && store.workspace.boards.first(where: { $0.id == root })!.cards == parentBefore.cards)
    store.activate(first); store.removeBoard(root)
    try check(!store.workspace.boards.contains { $0.id == root || $0.id == first || $0.parentID == root } && store.workspace.boards.contains { $0.id == otherPage } && Workspace.validHierarchy(store.workspace.boards))
    try check(store.save())
    print("PASS: workspace pages, independent canvases/cameras, stable rename, legacy loading, hierarchy validation, search paths, workspace/page portable files, cropped images, backup ID remapping and scoped deletion")
}

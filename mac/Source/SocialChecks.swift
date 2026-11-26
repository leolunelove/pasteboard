import AppKit
import ImageIO

func socialPostTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let root = store.board.id
    let page = store.newPage(in: root, name: "Campaign")!
    let image = NSImage(size: CGSize(width: 160, height: 100))
    image.lockFocus()
    NSColor.clear.setFill()
    CGRect(x: 0, y: 0, width: 160, height: 100).fill(using: .copy)
    NSColor.systemPink.setFill()
    CGRect(x: 20, y: 20, width: 100, height: 60).fill()
    image.unlockFocus()
    let photo = try store.imageCard(image, at: CGPoint(x: -80, y: 10))
    let note = Card(x: 110, y: 10, width: 150, height: 100, text: "Summer launch")
    store.replaceCards([photo, note], name: "Fixture")
    let before = store.board.cards
    var post = try store.markReady(Set(before.map(\.id)))
    try check(post.isComplete && post.cards.count == 2 && store.readyPosts(in: root).count == 1)
    let geometry = store.board.cards.map(\.rect)
    post.draft.caption = "A little room for new ideas. ✨\n#design"
    post.draft.platform = .linkedin
    post.draft.format = .square
    try check(store.updateSocialDraft(post.draft, boardID: page, anchorID: post.anchorID))
    try check(store.board.cards.map(\.rect) == geometry)
    store.history.undo()
    try check(store.readyPosts(in: root).first?.draft.caption == "")
    store.history.redo()
    try check(store.readyPosts(in: root).first?.draft == post.draft)
    try check(Card.copies(of: store.board.cards).allSatisfy { $0.socialPost == nil })
    let legacy = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(photo))
    try check(legacy.socialPost == nil)
    try check(store.save())
    try store.backups.capture(store.workspace, force: true)
    let restored = try store.backups.restoredBoards(
        from: store.backups.records().first!,
        assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    let restoredPage = restored.first { $0.name == "Campaign (restored)" }!
    let restoredDraft = restoredPage.cards.first { $0.socialPost != nil }!.socialPost!
    try check(Set(restoredDraft.memberIDs) == Set(restoredPage.cards.map(\.id)))
    try check(restoredDraft.caption == post.draft.caption && restoredPage.cards.allSatisfy(BoardStore.valid))
    let portableStore = BoardStore(directory: directory.appendingPathComponent("Portable"))
    try portableStore.importBoard(data: store.portableData())
    try check(portableStore.readyPosts(in: portableStore.board.id).first?.isComplete == true)
    try check(portableStore.readyPosts(in: portableStore.board.id).first?.draft.caption == post.draft.caption)
    let reopened = BoardStore(directory: directory)
    try check(reopened.readyPosts(in: root).first?.draft == post.draft)
    reopened.newBoard(name: "Other")
    let other = reopened.board.id
    try check(reopened.readyPosts(in: other).isEmpty)
    reopened.activate(page)
    let current = reopened.socialPost(boardID: page, anchorID: post.anchorID)!
    let assets = reopened.directory.appendingPathComponent("Assets")
    let png = try SocialArtwork(post: current, assets: assets).imagePNG()
    let source = CGImageSourceCreateWithData(png as CFData, nil)!
    let rendered = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    try check(rendered.width > rendered.height)
    try check(rendered.alphaInfo == .last || rendered.alphaInfo == .premultipliedLast)
    for platform in SocialPlatform.allCases {
        var draft = current.draft
        draft.platform = platform
        let data = try SocialArtwork.previewPNG(imageData: png, draft: draft)
        let preview = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        try check(preview.width == 1200 && preview.height > 1000)
    }
    let solo = SocialPost(
        boardID: page, anchorID: photo.id, pageName: "Campaign",
        draft: SocialDraft(memberIDs: [photo.id]), cards: [photo])
    let soloPNG = try SocialArtwork(post: solo, assets: assets).imagePNG()
    let soloImage = CGImageSourceCreateImageAtIndex(
        CGImageSourceCreateWithData(soloPNG as CFData, nil)!, 0, nil)!
    // Image-only export has no social border or caption, and preserves original proportions.
    try check(abs(Double(soloImage.width) / Double(soloImage.height) - photo.width / photo.height) < 0.01)
    let pixel = NSBitmapImageRep(data: soloPNG)!
    try check(pixel.colorAt(x: 0, y: 0)!.alphaComponent < 0.01)
    let destination = reopened.newPage(in: root, name: "Ready assets")!
    _ = reopened.moveCards(
        Set(current.cards.map(\.id)), from: page, to: destination, viewport: CGSize(width: 800, height: 600))
    try check(reopened.readyPosts(in: root).count == 1)
    try check(reopened.socialPost(boardID: destination, anchorID: post.anchorID)!.isComplete)
    reopened.history.undo()
    try check(reopened.socialPost(boardID: page, anchorID: post.anchorID)!.isComplete)
    _ = reopened.moveCards([note.id], from: page, to: destination, viewport: CGSize(width: 800, height: 600))
    let incomplete = reopened.socialPost(boardID: page, anchorID: post.anchorID)!
    try check(!incomplete.isComplete)
    do {
        _ = try SocialArtwork(post: incomplete, assets: assets).imagePNG()
        throw BoardExport.error("Incomplete frame unexpectedly exported")
    } catch { try check(error.localizedDescription.contains("missing items")) }
    reopened.history.undo()
    var draft = reopened.socialPost(boardID: page, anchorID: post.anchorID)!.draft
    draft.isReady = false
    reopened.updateSocialDraft(draft, boardID: page, anchorID: post.anchorID)
    try check(reopened.readyPosts(in: root).isEmpty)
    try check(
        reopened.socialPost(boardID: page, anchorID: post.anchorID)!.draft.caption == post.draft.caption)
    reopened.history.undo()
    try check(reopened.readyPosts(in: root).count == 1)
    // Imported copies can share card IDs across pages. Transferring a frame remaps its references too.
    reopened.activate(destination)
    reopened.replaceCards([photo], name: "ID collision fixture")
    _ = reopened.moveCards(
        Set(current.cards.map(\.id)), from: page, to: destination,
        viewport: CGSize(width: 800, height: 600))
    let transferredAnchor = reopened.board.cards.first { $0.socialPost != nil }!
    try check(transferredAnchor.id != photo.id)
    try check(reopened.socialPost(boardID: destination, anchorID: transferredAnchor.id)!.isComplete)
    print(
        "PASS: ready posts, frame integrity, captions, undo, duplicates, persistence, page transfers, alpha and all social previews"
    )
}

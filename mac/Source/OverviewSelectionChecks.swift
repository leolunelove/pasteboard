import AppKit

func overviewSelectionTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let root = Board(name: "Design studio")
    let folder = Board(name: "Shirts", parentID: root.id, isFolder: true)
    let first = Board(
        name: "Sun shirt", cards: [Card(x: 0, y: 0, width: 220, height: 140, text: "Front")],
        parentID: folder.id)
    let nested = Board(name: "Archive", parentID: folder.id, isFolder: true)
    let second = Board(name: "Moon shirt", parentID: folder.id)
    let third = Board(name: "Stripe shirt", parentID: folder.id)
    store.workspace.boards = [root, folder, first, nested, second, third]
    store.workspace.active = folder.id
    try store.enableWorkspaceOverviews()
    try check(store.showsWorkspaceOverview)
    let view = WorkspaceOverview()
    view.frame = CGRect(x: 0, y: 0, width: 650, height: 580)
    var opened: UUID?
    var merged = Set<UUID>()
    var selectionEvents: [(Set<UUID>, Bool)] = []
    view.selectionChanged = { selectionEvents.append(($0, $1)) }
    view.openPage = { opened = $0 }
    view.mergePages = { merged = $0 }
    func render() {
        view.show(pages: store.workspace.pages(in: folder.id), store: store)
        view.layoutSubtreeIfNeeded()
    }
    func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [], to target: NSView? = nil)
    {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        (target ?? view).keyDown(with: event)
    }
    render()
    // Sidebar synchronization filters out other folders and never echoes an event.
    view.setMergeSelection([first.id, nested.id, UUID()], selecting: true)
    try check(view.selectedPageIDs == [first.id] && view.selecting && selectionEvents.isEmpty)
    view.setMergeSelection([first.id, third.id], selecting: true)
    view.activatePage(second.id, modifiers: .shift)
    try check(view.selectedPageIDs == [first.id, second.id])
    view.activatePage(third.id, modifiers: [.command, .shift])
    try check(view.selectedPageIDs == [first.id, second.id, third.id])
    selectionEvents.removeAll()
    view.setMergeSelection([], selecting: false)
    try check(view.selectedPageIDs.isEmpty && !view.selecting && selectionEvents.isEmpty)
    let tiles = buttons(in: view).compactMap { $0 as? PagePreviewButton }
    try check(tiles.count == 4 && tiles.first { $0.page.id == nested.id }?.isFolder == true)
    tiles.first { $0.page.id == first.id }!.performClick(nil)
    try check(opened == first.id && !view.selecting)
    opened = nil
    let select = buttons(in: view).first { $0.title == "Select boards" }!
    select.performClick(nil)
    try check(view.selecting && view.selectedPageIDs.isEmpty)
    try check(selectionEvents.last?.0.isEmpty == true && selectionEvents.last?.1 == true)
    tiles.first { $0.page.id == first.id }!.performClick(nil)
    try check(view.selectedPageIDs == [first.id] && opened == nil)
    tiles.first { $0.page.id == nested.id }!.performClick(nil)
    try check(view.selectedPageIDs == [first.id] && opened == nil)
    view.activatePage(third.id, modifiers: .shift)
    try check(view.selectedPageIDs == [first.id, second.id, third.id])
    view.activatePage(second.id, modifiers: .command)
    try check(view.selectedPageIDs == [first.id, third.id])
    key(36, characters: "\r", to: tiles.first { $0.page.id == first.id })
    try check(merged == [first.id, third.id])
    key(53, characters: "\u{1B}", to: tiles.first { $0.page.id == first.id })
    try check(!view.selecting && view.selectedPageIDs.isEmpty)
    try check(selectionEvents.last?.0.isEmpty == true && selectionEvents.last?.1 == false)
    key(0, characters: "a", flags: .command)
    try check(view.selectedPageIDs == [first.id, second.id, third.id])
    view.layoutSubtreeIfNeeded()
    let toolbar = buttons(in: view).filter {
        ["New Board", "New Folder", "Done", "Merge 3 Boards"].contains($0.title)
    }
    try check(toolbar.count == 4)
    for a in toolbar {
        try check(a.frame.minX >= 0 && a.frame.maxX <= view.bounds.width)
        for b in toolbar where a !== b { try check(!a.frame.intersects(b.frame)) }
    }
    // Deleted or moved pages cannot remain selected in a pending merge.
    store.workspace.boards.removeAll { $0.id == second.id }
    render()
    try check(view.selectedPageIDs == [first.id, third.id])
    // Ready posts must not push a folder's design boards below the viewport.
    var readyCard = Card(x: 0, y: 0, width: 200, height: 160, asset: "ready-preview.png")
    readyCard.socialPost = SocialDraft(memberIDs: [readyCard.id])
    let thirdIndex = store.workspace.boards.firstIndex { $0.id == third.id }!
    store.workspace.boards[thirdIndex].cards = [readyCard]
    view.frame.size = CGSize(width: 640, height: 456)
    render()
    let folderTiles = buttons(in: view).compactMap { $0 as? PagePreviewButton }
    let firstTile = folderTiles.first { $0.page.id == first.id }!
    let readyTile = folderTiles.first { $0.page.name == "Image" }!
    try check(firstTile.frame.maxY <= view.bounds.height)
    let folderTile = folderTiles.first { $0.page.id == nested.id }!
    try check(folderTile.frame.height == 80 && folderTile.frame.minY > firstTile.frame.maxY)
    try check(folderTiles.filter { $0 !== readyTile }.allSatisfy { $0.frame.maxY < readyTile.frame.minY })
    store.activate(root.id)
    view.show(pages: store.workspace.pages(in: root.id), store: store)
    view.layoutSubtreeIfNeeded()
    let rootTiles = buttons(in: view).compactMap { $0 as? PagePreviewButton }
    try check(
        rootTiles.first { $0.page.name == "Image" }!.frame.maxY
            < rootTiles.first { $0.page.id == folder.id }!.frame.minY)
    view.show(pages: [], store: store, globally: true)
    try check(!view.selecting && view.selectedPageIDs.isEmpty)
    try check(
        buttons(in: view).filter { $0.title == "New Board" || $0.title == "New Folder" }.allSatisfy(
            \.isHidden))
    store.activate(first.id)
    try check(!store.showsWorkspaceOverview)
    try check(store.workspace.boards.first { $0.id == first.id }?.cards == first.cards)
    print(
        "PASS: nested folder overview, real tile/select-button actions, safe folder exclusion, range/toggle selection, keyboard merge/escape/select-all, sidebar selection synchronization, compact toolbar and folder cards, folder-first design access, workspace ready-first layout and stale-selection cleanup"
    )
}

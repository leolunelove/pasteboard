import AppKit

func sidebarSelectionTest(directory: URL) throws {
    let previousMenu = NSApp.mainMenu
    let previousWindowsMenu = NSApp.windowsMenu
    let previousAppearance = NSApp.appearance
    let delegate = AppDelegate(directory: directory, presentsWindow: false)
    let store = delegate.store
    let root = Board(name: "Design studio")
    let folder = Board(name: "Shirts", parentID: root.id, isFolder: true)
    let first = Board(
        name: "After hours", cards: [Card(x: 10, y: 20, width: 240, height: 160, text: "Front")],
        parentID: folder.id)
    let archive = Board(name: "Archive", parentID: folder.id, isFolder: true)
    let second = Board(
        name: "Slow mornings", cards: [Card(x: -40, y: 60, width: 260, height: 180, text: "Back")],
        parentID: folder.id)
    let third = Board(name: "Out of office", parentID: folder.id)
    let otherFolder = Board(name: "Posters", parentID: root.id, isFolder: true)
    let other = Board(name: "A different collection", parentID: otherFolder.id)
    store.workspace.boards = [root, folder, first, archive, second, third, otherFolder, other]
    store.workspace.active = folder.id
    try store.enableWorkspaceOverviews()
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer {
        delegate.window.delegate = nil
        delegate.window.close()
        NSApp.mainMenu = previousMenu
        NSApp.windowsMenu = previousWindowsMenu
        NSApp.appearance = previousAppearance
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let overview = descendants(delegate.window.contentView!).compactMap { $0 as? WorkspaceOverview }.first!
    let panel = descendants(delegate.window.contentView!).compactMap { $0 as? SidebarMergePanel }.first!
    func row(_ id: UUID) -> BoardButton? {
        descendants(delegate.rows).compactMap { $0 as? BoardButton }.first {
            $0.identifier?.rawValue == id.uuidString
        }
    }
    func context(_ title: String, on id: UUID) throws {
        guard let menu = row(id)?.menu,
            let item = menu.items.first(where: { $0.title == title }), let action = item.action
        else { try check(false); return }
        menu.update()
        try check(item.isEnabled)
        try check(NSApp.sendAction(action, to: item.target, from: item))
    }
    func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws {
        guard let target = delegate.window.firstResponder as? BoardButton else {
            try check(false); return
        }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: delegate.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        target.keyDown(with: event)
    }
    func modifiedClick(_ id: UUID, flags: NSEvent.ModifierFlags, count: Int = 1) throws {
        guard let target = row(id) else { try check(false); return }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: delegate.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        target.mouseDown(with: event)
    }

    // The left-side context action starts selection without opening the board.
    try context("Select for Merge", on: first.id)
    try check(delegate.sidebarSelection.selecting)
    try check(delegate.sidebarSelection.ids == [first.id] && store.board.id == folder.id)
    try check(row(first.id)?.selectedForMerge == true)
    try check(row(second.id)?.showsMergeSelection == true)
    try check(row(archive.id)?.showsMergeSelection == false)
    try check(overview.selectedPageIDs == [first.id] && overview.selecting)
    row(second.id)!.performClick(nil)
    try check(delegate.sidebarSelection.ids == [first.id, second.id])
    try check(store.board.id == folder.id)
    try check(delegate.window.firstResponder === row(second.id))
    overview.activatePage(third.id, modifiers: .command)
    try check(delegate.sidebarSelection.ids == [first.id, second.id, third.id])
    try check(row(third.id)?.selectedForMerge == true)
    overview.activatePage(third.id, modifiers: .command)
    try check(delegate.sidebarSelection.ids == [first.id, second.id])

    // The last clicked board remains the range anchor when switching surfaces.
    delegate.cancelSidebarMerge(nil)
    try modifiedClick(first.id, flags: .command)
    try modifiedClick(third.id, flags: .command)
    overview.activatePage(second.id, modifiers: .shift)
    try check(delegate.sidebarSelection.ids == [second.id, third.id])
    try check(overview.selectedPageIDs == [second.id, third.id])
    delegate.cancelSidebarMerge(nil)
    overview.activatePage(first.id, modifiers: .command)
    overview.activatePage(third.id, modifiers: .command)
    try modifiedClick(second.id, flags: .shift)
    try check(delegate.sidebarSelection.ids == [second.id, third.id])
    try check(overview.selectedPageIDs == [second.id, third.id])

    // Shift ranges follow sibling order and exclude intervening folders.
    delegate.cancelSidebarMerge(nil)
    try modifiedClick(first.id, flags: .command)
    try modifiedClick(third.id, flags: .shift)
    try check(delegate.sidebarSelection.ids == [first.id, second.id, third.id])
    try modifiedClick(second.id, flags: .command, count: 2)
    try check(delegate.sidebarSelection.ids == [first.id, third.id])
    try check(delegate.window.attachedSheet == nil)
    let updatingIndex = store.workspace.boards.firstIndex { $0.id == second.id }!
    store.workspace.boards[updatingIndex].cards.append(
        Card(x: 0, y: 0, width: 200, height: 140, text: "An import finished"))
    delegate.refresh()
    try check(delegate.window.firstResponder === row(second.id))
    store.workspace.boards[updatingIndex] = second
    delegate.refresh()
    try check(delegate.window.firstResponder === row(second.id))
    let selectAll = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: delegate.window.windowNumber, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    try check(row(second.id)!.performKeyEquivalent(with: selectAll))
    try check(delegate.sidebarSelection.ids == [first.id, second.id, third.id])
    try key(53, characters: "\u{1B}")
    try check(!delegate.sidebarSelection.selecting && delegate.sidebarSelection.ids.isEmpty)

    // A different collection starts a new scope instead of an invalid cross-folder merge.
    delegate.activateSidebarBoard(first.id, modifiers: .command)
    delegate.activateSidebarBoard(other.id, modifiers: .command)
    try check(delegate.sidebarSelection.ids == [other.id])
    try check(delegate.sidebarSelection.parentID == otherFolder.id)
    delegate.activateSidebarBoard(folder.id)
    try check(!delegate.sidebarSelection.selecting && delegate.sidebarSelection.ids.isEmpty)
    try check(store.board.id == folder.id)
    try check(row(folder.id)?.menu?.items.contains { $0.title == "Select for Merge" } == false)

    // Creating or importing a workspace can activate it through the store directly.
    // That path must also clear the old collection and move keyboard focus with navigation.
    delegate.activateSidebarBoard(first.id, modifiers: .command)
    delegate.activateSidebarBoard(second.id, modifiers: .command)
    store.newBoard(name: "Fresh workspace")
    try check(store.board.name == "Fresh workspace")
    try check(!delegate.sidebarSelection.selecting && delegate.sidebarSelection.ids.isEmpty)
    try check(!overview.selecting && overview.selectedPageIDs.isEmpty && panel.isHidden)
    try check(delegate.window.firstResponder === overview)
    try check(row(first.id)?.selectedForMerge == false)
    delegate.navigate(to: folder.id)

    // Removed and converted boards must disappear from a pending selection.
    delegate.activateSidebarBoard(first.id, modifiers: .command)
    delegate.activateSidebarBoard(third.id, modifiers: .command)
    store.workspace.boards.removeAll { $0.id == third.id }
    delegate.refresh()
    try check(delegate.sidebarSelection.ids == [first.id])
    let firstIndex = store.workspace.boards.firstIndex { $0.id == first.id }!
    store.workspace.boards[firstIndex].isFolder = true
    delegate.refresh()
    try check(delegate.sidebarSelection.ids.isEmpty)
    store.workspace.boards[firstIndex] = first
    delegate.cancelSidebarMerge(nil)
    delegate.refresh()

    // The global view and ordinary board navigation both leave merge mode cleanly.
    delegate.activateSidebarBoard(first.id, modifiers: .command)
    delegate.showAllReady(nil)
    try check(!delegate.sidebarSelection.selecting && delegate.sidebarSelection.ids.isEmpty)
    delegate.navigate(to: folder.id)
    row(first.id)!.performClick(nil)
    try check(store.board.id == first.id && !delegate.sidebarSelection.selecting)
    delegate.navigate(to: folder.id)

    // Exercise the same naming sheet and backed-up merge used by the sidebar button.
    try context("Select for Merge", on: first.id)
    row(second.id)!.performClick(nil)
    try check(!panel.isHidden && panel.merge.isEnabled)
    panel.merge.performClick(nil)
    try waitFor { delegate.window.attachedSheet != nil }
    let cancel = descendants(delegate.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == "Cancel" }!
    cancel.performClick(nil)
    try waitFor { delegate.window.attachedSheet == nil }
    try check(delegate.sidebarSelection.ids == [first.id, second.id])
    try context("Merge 2 Boards…", on: first.id)
    try waitFor { delegate.window.attachedSheet != nil }
    let sheet = delegate.window.attachedSheet!
    let name = descendants(sheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    name.stringValue = "Shirts collection"
    let confirm = descendants(sheet.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == "Merge Boards" }!
    confirm.performClick(nil)
    try waitFor { delegate.window.attachedSheet == nil && store.board.name == "Shirts collection" }
    let mergedID = store.board.id
    try check(store.board.cards.count == 2 && store.board.sections?.count == 2)
    try check(!delegate.sidebarSelection.selecting && delegate.sidebarSelection.ids.isEmpty)
    try check(!store.workspace.boards.contains { $0.id == first.id || $0.id == second.id })
    store.history.undo()
    try check(store.workspace.boards.contains(first) && store.workspace.boards.contains(second))
    store.history.redo()
    try check(store.workspace.boards.contains { $0.id == mergedID })
    try check(store.save())
    try check(BoardStore(directory: directory).workspace.boards == store.workspace.boards)
    print(
        "PASS: sidebar/overview shared selection, real row and context actions, focus retention, sibling ranges, cross-folder scope, stale-selection cleanup, Escape/select-all, navigation reset, merge cancellation/confirmation, named sections, undo/redo and persistence"
    )
}

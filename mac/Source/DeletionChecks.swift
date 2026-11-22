import Foundation

func workspaceDeletionTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let keep = store.board.id
    store.renameBoard(keep, name: "Keep this workspace")
    let note = Card(x: 12, y: 25, width: 200, height: 120, text: "Do not change")
    store.board.cards = [note]
    store.newBoard(name: "Delete this workspace")
    let remove = store.board.id
    let rootNote = Card(x: 50, y: 70, width: 200, height: 120, text: "Workspace content")
    store.board.cards = [rootNote]
    let page = store.newPage(in: remove, name: "Child page")!
    let pageNote = Card(x: 50, y: 70, width: 200, height: 120, text: "Page content")
    store.board.cards = [pageNote]
    let second = store.newPage(in: remove, name: "Another page")!
    store.activate(keep)
    let kept = store.board
    try check(store.deletionScope(for: remove).map(\.id) == [remove, page, second])
    var result: Result<Void, Error>?
    store.deleteBoardWithBackup(remove) { result = $0 }
    try waitFor { result != nil }
    try result!.get()
    try check(store.board == kept && store.workspace.boards == [kept])
    let record = store.backups.records().first!
    let restored = try store.backups.restoredBoards(
        from: record, assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    try check(Workspace.validHierarchy(restored))
    let restoredRoot = restored.first { $0.name == "Delete this workspace (restored)" }!
    try check(
        restoredRoot.cards
            == [rootNote].map { card in
                var copy = card
                copy.id = restoredRoot.cards[0].id
                return copy
            })
    let children = restored.filter { $0.parentID == restoredRoot.id }
    try check(
        children.count == 2
            && children.contains {
                $0.name == "Child page (restored)" && $0.cards.first?.text == pageNote.text
            })
    try check(store.save())
    try check(BoardStore(directory: directory).workspace.boards == [kept])

    // Deleting one page preserves its workspace and sibling pages; deleting the
    // final workspace always leaves a fresh usable canvas.
    let a = store.newPage(in: keep, name: "Remove only me")!
    let b = store.newPage(in: keep, name: "Keep sibling")!
    store.board.cards = [pageNote]
    store.activate(a)
    result = nil
    store.deleteBoardWithBackup(a) { result = $0 }
    try waitFor { result != nil }
    try result!.get()
    try check(
        store.board.id == keep && store.board.cards == [note]
            && store.workspace.boards.contains { $0.id == b && $0.cards == [pageNote] })
    result = nil
    store.deleteBoardWithBackup(keep) { result = $0 }
    try waitFor { result != nil }
    try result!.get()
    try check(
        store.workspace.boards.count == 1 && store.board.parentID == nil && store.board.cards.isEmpty
            && store.board.id != keep)

    // A failed backup must never delete content.
    let blocked = BoardStore(directory: directory.appendingPathComponent("blocked"))
    blocked.board.cards = [note]
    let protected = blocked.workspace.boards
    try Data("not a backup directory".utf8).write(to: blocked.directory.appendingPathComponent("Backups"))
    var failure: Result<Void, Error>?
    blocked.deleteBoardWithBackup(blocked.board.id) { failure = $0 }
    try waitFor { failure != nil }
    if case .success = failure! { try check(false) }
    try check(blocked.workspace.boards == protected)

    // If a page receives new content after the backup snapshot, keep it and ask
    // for a fresh deletion attempt rather than removing unbacked work.
    let concurrent = BoardStore(directory: directory.appendingPathComponent("changed"))
    let id = concurrent.board.id
    concurrent.board.cards = [note]
    result = nil
    concurrent.deleteBoardWithBackup(id) { result = $0 }
    concurrent.board.cards.append(pageNote)
    try waitFor { result != nil }
    if case .success = result! { try check(false) }
    try check(concurrent.board.id == id && concurrent.board.cards == [note, pageNote])
    result = nil
    concurrent.deleteBoardWithBackup(UUID()) { result = $0 }
    if case .success = result! { try check(false) }
    try check(concurrent.board.cards == [note, pageNote])
    print(
        "PASS: targeted workspace/page deletion, complete backup restoration, sibling and active-workspace preservation, save/reload, last-workspace fallback, failed backup and concurrent edits"
    )
}

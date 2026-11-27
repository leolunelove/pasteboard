import AppKit

func nestedSectionsTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    try store.enableWorkspaceOverviews()
    let root = store.board.id
    store.renameBoard(root, name: "Designs")
    let shirts = store.newFolder(in: root, name: "Shirts")!
    let summer = store.newFolder(in: shirts, name: "Summer")!
    let frontID = store.newPage(in: summer, name: "Front")!
    let group = UUID()
    let note = Card(x: -400, y: 80, width: 240, height: 120, text: "Front notes", groupID: group)
    let swatch = Card(x: -120, y: 80, width: 200, height: 160, groupID: group, locked: true, hex: "#24774E")
    store.replaceCards([note, swatch], name: "Fixture")
    let front = store.board
    let backID = store.newPage(in: frontID, name: "Back")!
    // A page command from a leaf adds a sibling; folders can be nested explicitly.
    try check(store.board.parentID == summer)
    var duplicateIdentity = note
    duplicateIdentity.text = "Back notes"
    duplicateIdentity.x = 900
    store.replaceCards([duplicateIdentity], name: "Fixture")
    let back = store.board
    try check(store.workspace.rootID(for: frontID) == root)
    try check(store.workspace.ancestors(of: frontID).map(\.id) == [summer, shirts, root])
    try check(store.workspace.path(for: front) == "Designs / Shirts / Summer / Front")
    try check(store.workspace.descendants(of: shirts).map(\.id) == [summer, frontID, backID])
    try check(Workspace.validHierarchy(store.workspace.boards))
    var cycle = store.workspace.boards
    cycle[cycle.firstIndex(where: { $0.id == shirts })!].parentID = summer
    try check(!Workspace.validHierarchy(cycle))
    try check(!store.canMergeBoards([shirts, frontID]))
    try check(!store.canMoveCards([note.id], from: frontID, to: summer))
    try check(store.canMergeBoards([frontID, backID]))
    var result: Result<UUID, Error>?
    store.mergeBoards([frontID, backID], name: "Summer designs") { result = $0 }
    try waitFor { result != nil }
    let combinedID = try result!.get()
    let combined = store.board
    try check(combined.id == combinedID && combined.parentID == summer)
    try check(combined.cards.count == 3 && Set(combined.cards.map(\.id)).count == 3)
    try check(combined.sections?.map(\.name) == ["Front", "Back"])
    let firstSection = combined.sections![0]
    let secondSection = combined.sections![1]
    try check(!combined.sectionBounds(firstSection).intersects(combined.sectionBounds(secondSection)))
    let frontCards = combined.cards.filter { firstSection.memberIDs.contains($0.id) }
    try check(frontCards[1].x - frontCards[0].x == swatch.x - note.x)
    try check(frontCards[1].y - frontCards[0].y == swatch.y - note.y)
    try check(frontCards[1].isLocked && frontCards[0].groupID == frontCards[1].groupID)
    try check(frontCards[0].width == note.width && frontCards[1].hex == swatch.hex)
    try check(combined.cards.last!.groupID != frontCards[0].groupID)
    try check(store.workspace.pages(in: summer).map(\.id) == [combinedID])
    store.history.undo()
    try check(store.workspace.pages(in: summer) == [front, back])
    store.history.redo()
    try check(store.board == combined)
    store.renameSection(firstSection.id, name: "Front print")
    try check(store.board.sections![0].name == "Front print")
    store.history.undo()
    try check(store.board.sections![0].name == "Front")
    store.history.redo()
    try check(store.board.sections![0].name == "Front print")
    let sectionResults = BoardSearch.results(in: store.workspace, imageText: [:], query: "front print")
    try check(sectionResults.contains { $0.boardID == combinedID && $0.sectionID == firstSection.id })
    try check(store.save())
    let reopened = BoardStore(directory: directory)
    try check(reopened.board == store.board && reopened.board.validSections)

    // Pasting near a section edge attaches the new content and grows its frame.
    let pasteFrame = store.board.sectionBounds(store.board.sections![0])
    let pasted = Card(
        x: pasteFrame.maxX - 110, y: pasteFrame.maxY - 60,
        width: 200, height: 100, text: "New idea in this design")
    store.replaceCards(store.board.cards + [pasted], name: "Paste")
    try check(store.board.sections![0].memberIDs.contains(pasted.id))
    try check(store.board.sectionBounds(store.board.sections![0]).maxX > pasteFrame.maxX)
    store.history.undo()
    try check(!store.board.cards.contains { $0.id == pasted.id })
    try check(store.board.sectionBounds(store.board.sections![0]) == pasteFrame)
    store.history.redo()
    try check(store.board.cards.contains { $0.id == pasted.id })
    try check(store.board.sections![0].memberIDs.filter { $0 == pasted.id }.count == 1)
    store.history.undo()

    // Collision avoidance may place a paste outside the frame; keep its original target.
    let spaced = Card(
        x: pasteFrame.maxX + 400, y: pasteFrame.maxY + 300,
        width: 200, height: 100, text: "Paste placed around existing artwork")
    store.replaceCards(
        store.board.cards + [spaced], name: "Paste",
        insertionPoint: CGPoint(x: pasteFrame.midX, y: pasteFrame.midY))
    try check(store.board.sections![0].memberIDs.contains(spaced.id))
    try check(store.board.sectionBounds(store.board.sections![0]).contains(spaced.rect))
    store.history.undo()
    try check(store.board.sectionBounds(store.board.sections![0]) == pasteFrame)
    store.history.redo()
    try check(store.board.sections![0].memberIDs.filter { $0 == spaced.id }.count == 1)
    store.history.undo()

    // Complete sections follow their content between boards and undo restores both sides.
    // Retained IDs for deleted/undone members must not prevent a complete live transfer.
    let retiredMember = UUID()
    store.board.sections![1].memberIDs.append(retiredMember)
    let transferSource = store.board
    let transferTarget = store.newPage(in: summer, name: "Transfer target")!
    let sourceSections = transferSource.sections!
    let transferSection = sourceSections[1]
    let moved = store.moveCards(
        Set(transferSection.memberIDs).intersection(Set(transferSource.cards.map(\.id))), from: combinedID,
        to: transferTarget,
        viewport: CGSize(width: 900, height: 600))
    try check(moved != nil && store.board.sections?.first?.name == "Back")
    try check(store.board.sections!.first!.memberIDs.contains(retiredMember))
    try check(store.workspace.boards.first { $0.id == combinedID }!.sections?.count == 1)
    store.history.undo()
    try check(store.board == transferSource)
    try check(store.workspace.boards.first { $0.id == transferTarget }!.sections == nil)
    store.removeBoard(transferTarget)

    // Folder exports include every depth, and restored section membership follows new IDs.
    store.activate(shirts)
    let portable = try store.portableData()
    let decoded = try JSONDecoder().decode(PortableBoard.self, from: portable)
    try check(decoded.pages?.count == 2 && decoded.board.isFolder == true)
    try store.importBoard(data: portable)
    let imported = store.board
    let importedDescendants = store.workspace.descendants(of: imported.id)
    try check(imported.isFolder == true && importedDescendants.count == 2)
    try check(importedDescendants.last!.sections?.first?.name == "Front print")
    var captured = false
    store.backupNow { captured = (try? $0.get()) != nil }
    try waitFor { captured }
    let restored = try store.backups.restoredBoards(
        from: store.backups.records().first!,
        assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    let restoredCombined = restored.first { $0.name == "Summer designs (restored)" }!
    try check(Workspace.validHierarchy(restored))
    let restoredMembership = Set(restoredCombined.sections![0].memberIDs)
    let restoredCardIDs = Set(restoredCombined.cards.map(\.id))
    try check(
        restoredMembership.intersection(restoredCardIDs) == Set(restoredCombined.cards.prefix(2).map(\.id)))
    try check(restoredMembership.subtracting(restoredCardIDs) == [pasted.id, spaced.id])
    try check(Set(restoredCombined.cards.map(\.id)).isDisjoint(with: Set(combined.cards.map(\.id))))
    store.removeBoard(imported.id)
    try check(
        store.workspace.descendants(of: imported.id).isEmpty
            && Workspace.validHierarchy(store.workspace.boards))

    // Conversion preserves the original composition and camera in a child board.
    store.activate(combinedID)
    let beforeConversion = store.board
    var conversion: Result<UUID?, Error>?
    store.convertToFolder(combinedID) { conversion = $0 }
    try waitFor { conversion != nil }
    let preservedID = try conversion!.get()!
    let preserved = store.workspace.boards.first { $0.id == preservedID }!
    try check(store.board.isFolder == true && store.board.cards.isEmpty && store.board.sections == nil)
    try check(preserved.cards == beforeConversion.cards && preserved.sections == beforeConversion.sections)
    try check(preserved.zoom == beforeConversion.zoom && preserved.offsetX == beforeConversion.offsetX)
    store.history.undo()
    try check(store.board == beforeConversion && store.workspace.pages(in: combinedID).isEmpty)
    store.history.redo()
    try check(store.workspace.pages(in: combinedID).count == 1)
    let newChild = store.newPage(in: combinedID, name: "Another design")!
    store.history.undo()
    try check(store.workspace.boards.contains { $0.id == newChild })
    try check(store.workspace.boards.first { $0.id == combinedID }!.isFolder == true)
    try check(Workspace.validHierarchy(store.workspace.boards))

    // Colliding imported identities cannot connect independent social drafts or groups.
    var art = Card(
        x: 0, y: 0, width: 240, height: 160, asset: "fixture.png", groupID: UUID(),
        sourceURL: "https://example.com/design", crop: ImageCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    let caption = Card(x: 300, y: 0, width: 200, height: 100, text: "Caption", groupID: art.groupID)
    art.socialPost = SocialDraft(caption: "Keep this caption", memberIDs: [art.id, caption.id])
    let draftSource = Board(name: "Art", cards: [art, caption], parentID: summer)
    let drafts = BoardStore.combinedBoard([draftSource, draftSource], name: "Drafts")
    try check(drafts.cards.count == 4 && Set(drafts.cards.map(\.id)).count == 4)
    for offset in [0, 2] {
        let image = drafts.cards[offset]
        try check(image.crop == art.crop && image.sourceURL == art.sourceURL)
        try check(image.socialPost?.caption == "Keep this caption")
        try check(image.socialPost?.memberIDs == [image.id, drafts.cards[offset + 1].id])
    }
    try check(drafts.cards[0].groupID != drafts.cards[2].groupID)

    // Failure to checkpoint leaves source boards completely unchanged.
    let blocked = BoardStore(directory: directory.appendingPathComponent("blocked"))
    let parent = blocked.board.id
    let a = blocked.newPage(in: parent, name: "A")!
    let b = blocked.newPage(in: parent, name: "B")!
    try Data("blocked".utf8).write(to: blocked.directory.appendingPathComponent("Backups"))
    let unchanged = blocked.workspace.boards
    var failed: Result<UUID, Error>?
    blocked.mergeBoards([a, b], name: "Combined") { failed = $0 }
    try waitFor { failed != nil }
    try check((try? failed!.get()) == nil && blocked.workspace.boards == unchanged)
    var failedConversion: Result<UUID?, Error>?
    blocked.convertToFolder(a) { failedConversion = $0 }
    try waitFor { failedConversion != nil }
    if case .success = failedConversion! { try check(false) }
    try check(blocked.workspace.boards == unchanged)

    // A backup completion cannot overwrite content that changed during the checkpoint.
    let racing = BoardStore(directory: directory.appendingPathComponent("racing"))
    let racingRoot = racing.board.id
    let r1 = racing.newPage(in: racingRoot, name: "One")!
    let r2 = racing.newPage(in: racingRoot, name: "Two")!
    var raced: Result<UUID, Error>?
    racing.mergeBoards([r1, r2], name: "Merge") { raced = $0 }
    racing.board.cards = [Card(x: 0, y: 0, width: 100, height: 100, text: "Arrived during backup")]
    try waitFor { raced != nil }
    try check((try? raced!.get()) == nil && racing.board.cards.count == 1)
    try check(racing.workspace.pages(in: racingRoot).count == 2)
    // Imported inner containers with existing artwork get a visible preserved board.
    let migration = BoardStore(directory: directory.appendingPathComponent("nested-migration"))
    try migration.enableWorkspaceOverviews()
    let importedRoot = Board(name: "Imported workspace")
    let importedParent = Board(
        name: "Shirts", cards: [note], parentID: importedRoot.id, isFolder: true,
        sections: [
            BoardSection(
                name: "Keep this section", memberIDs: [note.id],
                x: -450, y: 0, width: 400, height: 260)
        ])
    let importedChild = Board(name: "Existing design", parentID: importedParent.id)
    let nestedPortable = try JSONEncoder().encode(
        PortableBoard(
            board: importedRoot,
            assets: [:], pages: [importedParent, importedChild]))
    try migration.importBoard(data: nestedPortable)
    let nestedParent = migration.workspace.descendants(of: migration.board.id).first { $0.name == "Shirts" }!
    try check(nestedParent.cards.isEmpty && nestedParent.sections == nil)
    let preservedNested = migration.workspace.pages(in: nestedParent.id).first { $0.name == "Board" }!
    try check(preservedNested.cards == [note] && preservedNested.sections == importedParent.sections)
    try check(migration.workspace.pages(in: nestedParent.id).count == 2)

    // Migration failure rolls back imports rather than leaving hidden partial structure.
    let rollback = BoardStore(directory: directory.appendingPathComponent("rollback"))
    try rollback.enableWorkspaceOverviews()
    let beforeImport = rollback.workspace.boards
    try Data("blocked".utf8).write(to: rollback.directory.appendingPathComponent("Backups"))
    do {
        try rollback.importBoard(data: nestedPortable)
        try check(false)
    } catch {
        try check(rollback.workspace.boards == beforeImport)
    }

    // Restoring old nested parents applies the same content-preserving migration.
    let donorDirectory = directory.appendingPathComponent("restore-donor")
    let donor = LocalBackups(directory: donorDirectory)
    try FileManager.default.createDirectory(at: donorDirectory, withIntermediateDirectories: true)
    try donor.capture(Workspace(boards: [importedRoot, importedParent, importedChild]), force: true)
    let donorRecord = donor.records().first!
    let restoration = BoardStore(directory: directory.appendingPathComponent("restoration"))
    try restoration.enableWorkspaceOverviews()
    try FileManager.default.createDirectory(at: restoration.backups.folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: donor.folder.appendingPathComponent(donorRecord.folderName),
        to: restoration.backups.folder.appendingPathComponent(donorRecord.folderName))
    var restoredResult: Result<Void, Error>?
    restoration.restoreBackup(donorRecord) { restoredResult = $0 }
    try waitFor { restoredResult != nil }
    try restoredResult!.get()
    let restoredParent = restoration.workspace.boards.first { $0.name == "Shirts (restored)" }!
    try check(restoredParent.cards.isEmpty && restoration.workspace.pages(in: restoredParent.id).count == 2)
    try check(
        restoration.workspace.pages(in: restoredParent.id).contains { $0.cards.first?.text == note.text })

    let beforeFailedRestore = restoration.workspace.boards
    let blockedSave = restoration.directory.appendingPathComponent("Workspace.json")
    try FileManager.default.removeItem(at: blockedSave)
    try FileManager.default.createDirectory(at: blockedSave, withIntermediateDirectories: true)
    var failedRestore: Result<Void, Error>?
    restoration.restoreBackup(donorRecord) { failedRestore = $0 }
    try waitFor { failedRestore != nil }
    if case .success = failedRestore! { try check(false) }
    try check(restoration.workspace.boards == beforeFailedRestore)

    // Forced checkpoints re-create removed or corrupted snapshots even with identical content.
    let integrityDirectory = directory.appendingPathComponent("checkpoint-integrity")
    try FileManager.default.createDirectory(at: integrityDirectory, withIntermediateDirectories: true)
    let integrity = LocalBackups(directory: integrityDirectory)
    let snapshot = Workspace(boards: [Board(name: "Keep me", cards: [note])])
    try integrity.capture(snapshot, force: true)
    let firstRecord = integrity.records().first!
    try FileManager.default.removeItem(at: integrity.folder.appendingPathComponent(firstRecord.folderName))
    try integrity.capture(snapshot, force: true)
    let replacementRecord = integrity.records().first!
    try check(replacementRecord.id != firstRecord.id)
    try Data("corrupt".utf8).write(
        to: integrity.folder.appendingPathComponent(replacementRecord.folderName)
            .appendingPathComponent("Workspace.json"))
    try integrity.capture(snapshot, force: true)
    try check(integrity.records().first!.id != replacementRecord.id)

    print(
        "PASS: nested folders, hierarchy cycles/paths, backed-up section merge, identity/group/layout preservation, merge and rename undo/redo, folder conversion, recursive portable files/backups/deletion, failure and concurrent-change protection"
    )
}

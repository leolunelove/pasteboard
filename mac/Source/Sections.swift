import AppKit

// Optional metadata leaves existing boards readable without a migration.
struct BoardSection: Codable, Equatable {
    var id = UUID()
    var name: String
    var memberIDs: [UUID]
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        BoardStore.cleanName(name) != nil && name.count <= 100
            && memberIDs.count <= 100_000 && Set(memberIDs).count == memberIDs.count
            && [x, y, width, height].allSatisfy(\.isFinite)
            && width >= 1 && height >= 1 && width < 10_000_000 && height < 10_000_000
    }
}

extension Board {
    var validSections: Bool {
        guard let sections else { return true }
        return sections.count <= 10_000 && Set(sections.map(\.id)).count == sections.count
            && sections.allSatisfy(\.isValid)
    }
    // Newly pasted or transferred cards join the smallest section containing their centre.
    // Retain deleted member IDs so undo restores membership along with the original card.
    func sectionsIncludingInsertedCards(_ next: [Card], insertionPoint: CGPoint? = nil) -> [BoardSection]? {
        guard var sections, !sections.isEmpty else { return self.sections }
        let previousIDs = Set(cards.map(\.id))
        var assigned = Set(sections.flatMap(\.memberIDs))
        let frames = sections.map { sectionBounds($0) }
        func containingSection(_ point: CGPoint) -> Int? {
            frames.indices.filter { frames[$0].contains(point) }.min {
                frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height
            }
        }
        let intendedSection = insertionPoint.flatMap(containingSection)
        for card in next where !previousIDs.contains(card.id) && !assigned.contains(card.id) {
            let index =
                insertionPoint == nil
                ? containingSection(CGPoint(x: card.rect.midX, y: card.rect.midY)) : intendedSection
            if let index {
                sections[index].memberIDs.append(card.id)
                assigned.insert(card.id)
            }
        }
        return sections
    }

    func sectionBounds(_ section: BoardSection) -> CGRect {
        let ids = Set(section.memberIDs)
        let members = cards.filter { ids.contains($0.id) }
        guard let first = members.first else { return section.rect }
        let content = members.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        return CGRect(
            x: content.minX - 36, y: content.minY - 64,
            width: content.width + 72, height: content.height + 100)
    }
}

extension BoardStore {
    @discardableResult func newFolder(in parentID: UUID, name: String) -> UUID? {
        guard workspace.isContainer(parentID), let name = Self.cleanName(name) else { return nil }
        let folder = Board(name: name, parentID: parentID, isFolder: true)
        workspace.boards.append(folder)
        activate(folder.id)
        return folder.id
    }

    // A board can become a folder without flattening, copying, or losing its content.
    // A reliable checkpoint must exist before its cards move into the first child.
    func convertToFolder(_ id: UUID, completion: @escaping (Result<UUID?, Error>) -> Void) {
        guard let original = workspace.boards.first(where: { $0.id == id }) else {
            completion(.failure(Self.structureError("This board no longer exists.")))
            return
        }
        if workspace.isContainer(id) {
            completion(.success(nil))
            return
        }
        backupNow { [weak self] result in
            guard let self else { return }
            do {
                try result.get()
                guard self.workspace.boards.first(where: { $0.id == id }) == original,
                    self.workspace.pages(in: id).isEmpty
                else {
                    throw Self.structureError(
                        "This board changed while its backup was saving. Please try again.")
                }
                var folder = original
                folder.cards = []
                folder.sections = nil
                folder.isFolder = true
                folder.zoom = 1
                folder.offsetX = 160
                folder.offsetY = 140
                var replacements = [folder]
                var childID: UUID?
                if !original.cards.isEmpty || !(original.sections ?? []).isEmpty {
                    var child = original
                    child.id = UUID()
                    child.name = "Board"
                    child.parentID = original.id
                    child.isFolder = nil
                    replacements.append(child)
                    childID = child.id
                }
                self.replaceStructure(
                    removing: [original], inserting: replacements,
                    active: id, name: "Turn Board into Folder")
                completion(.success(childID))
            } catch { completion(.failure(error)) }
        }
    }

    func canMergeBoards(_ ids: Set<UUID>) -> Bool {
        let selected = workspace.boards.filter { ids.contains($0.id) }
        guard ids.count >= 2, selected.count == ids.count, let parent = selected.first?.parentID else {
            return false
        }
        return selected.allSatisfy { $0.parentID == parent && !workspace.isContainer($0.id) }
    }

    func mergeBoards(
        _ ids: Set<UUID>, name: String,
        completion: @escaping (Result<UUID, Error>) -> Void
    ) {
        guard canMergeBoards(ids), let name = Self.cleanName(name) else {
            completion(
                .failure(Self.structureError("Select at least two boards in the same folder to merge.")))
            return
        }
        let originals = workspace.boards.filter { ids.contains($0.id) }
        backupNow { [weak self] result in
            guard let self else { return }
            do {
                try result.get()
                guard self.canMergeBoards(ids),
                    self.workspace.boards.filter({ ids.contains($0.id) }) == originals
                else {
                    throw Self.structureError(
                        "The selected boards changed while their backup was saving. Nothing was merged. Please try again."
                    )
                }
                let combined = Self.combinedBoard(originals, name: name)
                guard combined.validSections && combined.cards.allSatisfy(Self.valid) else {
                    throw Self.structureError(
                        "These boards are too spread out to merge. Move their items closer together and try again."
                    )
                }
                self.replaceStructure(
                    removing: originals, inserting: [combined],
                    active: combined.id, name: "Merge Boards")
                completion(.success(combined.id))
            } catch { completion(.failure(error)) }
        }
    }

    // Place each original composition intact in a spacious grid. Within a source board,
    // image sizes, relative positions, crop, groups, source links and drafts do not change.
    static func combinedBoard(_ originals: [Board], name: String) -> Board {
        var result = Board(name: name, parentID: originals.first?.parentID)
        result.sections = []
        let columns = max(1, Int(ceil(sqrt(Double(originals.count)))))
        var usedCards = Set<UUID>()
        var usedGroups = Set<UUID>()
        var usedSections = Set<UUID>()
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        for (index, source) in originals.enumerated() {
            var outer: CGRect
            if let first = source.cards.first {
                let content = source.cards.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                outer = CGRect(
                    x: content.minX - 36, y: content.minY - 64,
                    width: content.width + 72, height: content.height + 100)
            } else {
                outer = CGRect.null
            }
            for section in source.sections ?? [] { outer = outer.union(source.sectionBounds(section)) }
            if outer.isNull { outer = CGRect(x: 0, y: 0, width: 480, height: 340) }
            let dx = cursor.x - outer.minX
            let dy = cursor.y - outer.minY
            var identities: [UUID: UUID] = [:]
            var groupIDs: [UUID: UUID] = [:]
            for card in source.cards {
                let id = usedCards.contains(card.id) ? UUID() : card.id
                identities[card.id] = id
                usedCards.insert(id)
                if let group = card.groupID, groupIDs[group] == nil {
                    let next = usedGroups.contains(group) ? UUID() : group
                    groupIDs[group] = next
                    usedGroups.insert(next)
                }
            }
            // Missing draft/section members stay missing rather than accidentally referring
            // to a similarly identified card from another imported board.
            for id in source.cards.flatMap({ $0.socialPost?.memberIDs ?? [] })
                + (source.sections ?? []).flatMap(\.memberIDs) where identities[id] == nil
            {
                identities[id] = UUID()
            }
            let translated = source.cards.map { original -> Card in
                var card = original
                card.id = identities[original.id]!
                card.x += dx
                card.y += dy
                card.groupID = original.groupID.flatMap { groupIDs[$0] }
                if var draft = card.socialPost {
                    draft.memberIDs = draft.memberIDs.map { identities[$0]! }
                    card.socialPost = draft
                }
                return card
            }
            result.cards.append(contentsOf: translated)
            let existing = source.sections ?? []
            if existing.isEmpty {
                result.sections!.append(
                    BoardSection(
                        name: Self.cleanName(source.name) ?? "Board",
                        memberIDs: translated.map(\.id), x: cursor.x, y: cursor.y,
                        width: outer.width, height: outer.height))
            } else {
                for section in existing {
                    var copy = section
                    if usedSections.contains(copy.id) { copy.id = UUID() }
                    usedSections.insert(copy.id)
                    copy.name = String((source.name + " / " + section.name).prefix(100))
                    copy.memberIDs = section.memberIDs.map { identities[$0]! }
                    copy.x += dx
                    copy.y += dy
                    result.sections!.append(copy)
                }
                let assigned = Set(existing.flatMap(\.memberIDs))
                let remaining = source.cards.enumerated().filter { !assigned.contains($0.element.id) }
                    .map { translated[$0.offset] }
                if !remaining.isEmpty {
                    result.sections!.append(
                        BoardSection(
                            name: Self.cleanName(source.name) ?? "Board",
                            memberIDs: remaining.map(\.id), x: cursor.x, y: cursor.y,
                            width: outer.width, height: outer.height))
                }
            }
            rowHeight = max(rowHeight, outer.height)
            if (index + 1) % columns == 0 {
                cursor.x = 0
                cursor.y += rowHeight + 320
                rowHeight = 0
            } else {
                cursor.x += outer.width + 100
            }
        }
        return result
    }

    func renameSection(_ id: UUID, name: String, boardID: UUID? = nil) {
        let target = boardID ?? board.id
        guard let name = Self.cleanName(name),
            let page = workspace.boards.first(where: { $0.id == target }),
            var sections = page.sections, let index = sections.firstIndex(where: { $0.id == id }),
            sections[index].name != name
        else { return }
        sections[index].name = name
        replaceSections(sections, boardID: target, name: "Rename Section")
    }

    private func replaceSections(_ sections: [BoardSection], boardID: UUID, name: String) {
        guard let index = workspace.boards.firstIndex(where: { $0.id == boardID }) else { return }
        let previous = workspace.boards[index].sections ?? []
        let ownsGroup = !history.isUndoing && !history.isRedoing
        if ownsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { $0.replaceSections(previous, boardID: boardID, name: name) }
        history.setActionName(name)
        if ownsGroup { history.endUndoGrouping() }
        workspace.boards[index].sections = sections
        scheduleSave()
        changed?()
    }

    private func replaceStructure(
        removing: [Board], inserting: [Board], active: UUID, name: String,
        positions: [UUID: Int]? = nil
    ) {
        let removedIDs = Set(removing.map(\.id))
        let current = workspace.boards.filter { removedIDs.contains($0.id) }
        guard current.count == removing.count else { return }
        let originalPositions = Dictionary(
            uniqueKeysWithValues: workspace.boards.enumerated()
                .filter { removedIDs.contains($0.element.id) }.map { ($0.element.id, $0.offset) })
        let previousActive = workspace.active ?? current[0].id
        let insertion = originalPositions.values.min() ?? workspace.boards.count
        var next = workspace.boards.filter { !removedIDs.contains($0.id) }
        let ordered = inserting.enumerated().sorted {
            (positions?[$0.element.id] ?? insertion + $0.offset)
                < (positions?[$1.element.id] ?? insertion + $1.offset)
        }
        for (offset, board) in ordered {
            next.insert(board, at: min(positions?[board.id] ?? insertion + offset, next.count))
        }
        // Later, non-undoable folder creation must never leave an orphan on undo.
        guard Workspace.validHierarchy(next),
            !inserting.contains(where: { board in
                board.parentID != nil && board.isFolder != true
                    && next.contains { $0.parentID == board.id }
            })
        else {
            status?("Keep this folder while it contains newly added boards.")
            return
        }
        let ownsGroup = !history.isUndoing && !history.isRedoing
        if ownsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) {
            $0.replaceStructure(
                removing: inserting, inserting: current, active: previousActive,
                name: name, positions: originalPositions)
        }
        history.setActionName(name)
        if ownsGroup { history.endUndoGrouping() }
        workspace.boards = next
        workspace.active = workspace.boards.contains { $0.id == active } ? active : inserting.first?.id
        scheduleSave()
        changed?()
    }

    private static func structureError(_ message: String) -> NSError {
        NSError(
            domain: "Pasteboard.Structure", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import AppKit

struct PageTransfer {
    struct Original { let index: Int; let card: Card }
    let source: UUID
    let destination: UUID
    let originals: [Original]
    let moved: [Card]
}

extension BoardStore {
    func canMoveCards(_ ids: Set<UUID>, from sourceID: UUID, to destinationID: UUID) -> Bool {
        guard sourceID != destinationID,
              let source = workspace.boards.first(where: { $0.id == sourceID }),
              workspace.boards.contains(where: { $0.id == destinationID }), !ids.isEmpty,
              ids.isSubset(of: Set(source.cards.map(\.id))) else { return false }
        return source.expandedSelection(ids).isDisjoint(with: source.lockedIDs)
    }
    @discardableResult func moveCards(_ ids: Set<UUID>, from sourceID: UUID, to destinationID: UUID, viewport: CGSize) -> Set<UUID>? {
        guard canMoveCards(ids, from: sourceID, to: destinationID), let source = workspace.boards.first(where: { $0.id == sourceID }), let destination = workspace.boards.first(where: { $0.id == destinationID }) else { return nil }
        let expanded = source.expandedSelection(ids)
        let originals = source.cards.enumerated().filter { expanded.contains($0.element.id) }.map { PageTransfer.Original(index: $0.offset, card: $0.element) }
        var moved = originals.map(\.card)
        let existingIDs = Set(destination.cards.map(\.id)), existingGroups = Set(destination.cards.compactMap(\.groupID))
        var groups: [UUID: UUID] = [:]
        for i in moved.indices {
            if existingIDs.contains(moved[i].id) { moved[i].id = UUID() }
            if let group = moved[i].groupID, existingGroups.contains(group) {
                if groups[group] == nil { groups[group] = UUID() }; moved[i].groupID = groups[group]
            }
        }
        moved = Self.placeTransferred(moved, on: destination, viewport: viewport)
        let command = PageTransfer(source: sourceID, destination: destinationID, originals: originals, moved: moved)
        backupNow()
        guard applyTransfer(command, forward: true) else { return nil }
        return Set(moved.map(\.id))
    }
    static func placeTransferred(_ cards: [Card], on destination: Board, viewport: CGSize) -> [Card] {
        guard let first = cards.first else { return [] }
        let box = cards.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let centre = CGPoint(x: (viewport.width / 2 - destination.offsetX) / destination.zoom, y: (viewport.height / 2 - destination.offsetY) / destination.zoom)
        let preferred = CGPoint(x: centre.x - box.width / 2, y: centre.y - box.height / 2), gap: CGFloat = 32
        var candidates = [preferred]
        for card in destination.cards {
            candidates += [CGPoint(x: card.rect.maxX + gap, y: card.y), CGPoint(x: card.x, y: card.rect.maxY + gap), CGPoint(x: card.x - box.width - gap, y: card.y), CGPoint(x: card.x, y: card.y - box.height - gap)]
        }
        candidates.append(CGPoint(x: (destination.cards.map { $0.rect.maxX }.max() ?? preferred.x) + gap, y: preferred.y))
        let free = candidates.filter { point in !destination.cards.contains { $0.rect.insetBy(dx: -12, dy: -12).intersects(CGRect(origin: point, size: box.size)) } }
        let position = free.min { hypot($0.x - preferred.x, $0.y - preferred.y) < hypot($1.x - preferred.x, $1.y - preferred.y) } ?? candidates.last!
        return cards.map { card in var next = card; next.x += position.x - box.minX; next.y += position.y - box.minY; return next }
    }
    @discardableResult private func applyTransfer(_ transfer: PageTransfer, forward: Bool) -> Bool {
        guard let source = workspace.boards.firstIndex(where: { $0.id == transfer.source }), let destination = workspace.boards.firstIndex(where: { $0.id == transfer.destination }) else { return false }
        let sourceIDs = Set(transfer.originals.map { $0.card.id }), movedIDs = Set(transfer.moved.map(\.id))
        if forward {
            guard sourceIDs.isSubset(of: Set(workspace.boards[source].cards.map(\.id))), movedIDs.isDisjoint(with: Set(workspace.boards[destination].cards.map(\.id))) else { return false }
        } else {
            guard movedIDs.isSubset(of: Set(workspace.boards[destination].cards.map(\.id))), sourceIDs.isDisjoint(with: Set(workspace.boards[source].cards.map(\.id))) else { return false }
        }
        let ownsGroup = !history.isUndoing && !history.isRedoing
        if ownsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { $0.applyTransfer(transfer, forward: !forward) }
        history.setActionName("Move Between Pages")
        if ownsGroup { history.endUndoGrouping() }
        if forward {
            workspace.boards[source].cards.removeAll { sourceIDs.contains($0.id) }
            workspace.boards[destination].cards.append(contentsOf: transfer.moved)
        } else {
            workspace.boards[destination].cards.removeAll { movedIDs.contains($0.id) }
            for original in transfer.originals { workspace.boards[source].cards.insert(original.card, at: min(original.index, workspace.boards[source].cards.count)) }
        }
        workspace.active = forward ? transfer.destination : transfer.source
        scheduleSave(); changed?()
        let target = workspace.boards[forward ? destination : source].name
        status?("\(forward ? "Moved" : "Restored") \(transfer.moved.count) items to \(target)")
        return true
    }
}

final class TransferBadge: NSView {
    let label = NSTextField(labelWithString: "")
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init() {
        super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .white; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ text: String, at point: CGPoint, in parent: NSView, valid: Bool) {
        label.stringValue = text; label.sizeToFit(); frame = CGRect(x: max(8, min(parent.bounds.width - label.frame.width - 32, point.x + 14)), y: max(8, min(parent.bounds.height - 38, point.y - 38)), width: label.frame.width + 24, height: 30)
        label.frame.origin = CGPoint(x: 12, y: 7); layer?.backgroundColor = (valid ? NSColor.pasteboardAccent : .pasteboardMuted).cgColor
        if superview !== parent { parent.addSubview(self) }
    }
}

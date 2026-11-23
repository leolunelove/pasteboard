import AppKit

enum BoardArrangement: String, CaseIterable {
    case left, horizontalCenter, right, top, verticalCenter, bottom
    case horizontalSpacing, verticalSpacing

    var title: String {
        switch self {
        case .left: return "Align Left"
        case .horizontalCenter: return "Align Horizontal Centres"
        case .right: return "Align Right"
        case .top: return "Align Top"
        case .verticalCenter: return "Align Vertical Centres"
        case .bottom: return "Align Bottom"
        case .horizontalSpacing: return "Distribute Horizontal Spacing"
        case .verticalSpacing: return "Distribute Vertical Spacing"
        }
    }
    var distributes: Bool { self == .horizontalSpacing || self == .verticalSpacing }
    private var horizontal: Bool {
        [.left, .horizontalCenter, .right, .horizontalSpacing].contains(self)
    }

    private enum Key: Hashable {
        case item(UUID)
        case group(UUID)
    }
    private struct Unit {
        var ids: Set<UUID>
        var rect: CGRect
    }
    // Treat each complete group as one object, preserving its internal layout.
    private func units(in board: Board, selection: Set<UUID>) -> [Unit] {
        let ids = board.expandedSelection(selection)
        guard ids.isDisjoint(with: board.lockedIDs) else { return [] }
        var units: [Unit] = []
        var indices: [Key: Int] = [:]
        for card in board.cards where ids.contains(card.id) {
            let key = card.groupID.map(Key.group) ?? .item(card.id)
            if let index = indices[key] {
                units[index].ids.insert(card.id)
                units[index].rect = units[index].rect.union(card.rect)
            } else {
                indices[key] = units.count
                units.append(Unit(ids: [card.id], rect: card.rect))
            }
        }
        return units
    }
    func canApply(to board: Board, selection: Set<UUID>) -> Bool {
        let units = ordered(units(in: board, selection: selection))
        guard units.count >= (distributes ? 3 : 2) else { return false }
        guard distributes else { return true }
        let total = units.reduce(CGFloat.zero) { $0 + (horizontal ? $1.rect.width : $1.rect.height) }
        let first = horizontal ? units[0].rect.minX : units[0].rect.minY
        let last = horizontal ? units.last!.rect.maxX : units.last!.rect.maxY
        return total <= last - first
    }
    private func ordered(_ units: [Unit]) -> [Unit] {
        units.enumerated().sorted {
            let a = horizontal ? $0.element.rect.minX : $0.element.rect.minY
            let b = horizontal ? $1.element.rect.minX : $1.element.rect.minY
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    func applying(to board: Board, selection: Set<UUID>) -> [Card] {
        var units = units(in: board, selection: selection)
        guard units.count >= (distributes ? 3 : 2) else { return board.cards }
        let extent = units.reduce(CGRect.null) { $0.union($1.rect) }
        var translations: [UUID: CGPoint] = [:]
        if distributes {
            // Stable ordering keeps equal-position items predictable.
            units = ordered(units)
            let first = horizontal ? units[0].rect.minX : units[0].rect.minY
            let last = horizontal ? units.last!.rect.maxX : units.last!.rect.maxY
            let total = units.reduce(CGFloat.zero) { $0 + (horizontal ? $1.rect.width : $1.rect.height) }
            let gap = (last - first - total) / CGFloat(units.count - 1)
            guard gap >= 0 else { return board.cards }
            var cursor = first
            for (index, unit) in units.enumerated() {
                let position = horizontal ? unit.rect.minX : unit.rect.minY
                let destination = index == units.count - 1 ? position : cursor
                let delta = destination - position
                for id in unit.ids {
                    translations[id] = horizontal ? CGPoint(x: delta, y: 0) : CGPoint(x: 0, y: delta)
                }
                cursor += (horizontal ? unit.rect.width : unit.rect.height) + gap
            }
        } else {
            for unit in units {
                let delta: CGPoint
                switch self {
                case .left: delta = CGPoint(x: extent.minX - unit.rect.minX, y: 0)
                case .horizontalCenter: delta = CGPoint(x: extent.midX - unit.rect.midX, y: 0)
                case .right: delta = CGPoint(x: extent.maxX - unit.rect.maxX, y: 0)
                case .top: delta = CGPoint(x: 0, y: extent.minY - unit.rect.minY)
                case .verticalCenter: delta = CGPoint(x: 0, y: extent.midY - unit.rect.midY)
                case .bottom: delta = CGPoint(x: 0, y: extent.maxY - unit.rect.maxY)
                default: delta = .zero
                }
                for id in unit.ids { translations[id] = delta }
            }
        }
        return board.cards.map { card in
            guard let delta = translations[card.id] else { return card }
            var result = card
            result.x += delta.x
            result.y += delta.y
            return result
        }
    }
}

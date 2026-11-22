import Foundation

enum AlignmentAxis { case x, y }

struct AlignmentGuide: Equatable {
    let axis: AlignmentAxis
    let position: Double
    let from: Double
    let to: Double
}

struct GapSpan: Equatable {
    let from: Double
    let to: Double
}

struct SpacingGuide: Equatable {
    let axis: AlignmentAxis
    let position: Double
    let distance: Double
    let spans: [GapSpan]
}

struct SnapTarget: Equatable {
    let id: UUID
    var rect: CGRect

    // A stationary group is one target; none of its moving members can snap
    // against another member of the same group.
    static func objects(in cards: [Card], excluding ids: Set<UUID>) -> [SnapTarget] {
        let excludedGroups = Set(cards.filter { ids.contains($0.id) }.compactMap(\.groupID))
        var result: [SnapTarget] = [], indices: [UUID: Int] = [:]
        for card in cards where !ids.contains(card.id) && card.groupID.map(excludedGroups.contains) != true {
            let id = card.groupID ?? card.id
            if let index = indices[id] { result[index].rect = result[index].rect.union(card.rect) }
            else { indices[id] = result.count; result.append(SnapTarget(id: id, rect: card.rect)) }
        }
        return result
    }
}

struct SnapResult {
    let rect: CGRect
    let guides: [AlignmentGuide]
    var spacingGuides: [SpacingGuide] = []
}

struct SnapSession {
    private struct Lock {
        let id: UUID
        let movingAnchor: Int
        let targetAnchor: Int
    }
    private struct Match {
        let lock: Lock
        let target: CGRect
        let position: Double
        let correction: Double
        let priority: Int
        let distance: Double
        var held = false
    }
    private enum SpacingMode: CaseIterable { case before, between, after }
    private struct Pair {
        let first: SnapTarget
        let second: SnapTarget
    }
    private struct SpacingLock: Equatable {
        let first: UUID
        let second: UUID
        let mode: SpacingMode
    }
    private struct SpacingMatch {
        let lock: SpacingLock
        let pair: Pair
        let origin: Double
        let gap: Double
        let correction: Double
        let held: Bool
    }
    private struct Resolution {
        var edge: Match?
        var spacing: SpacingMatch?
        var correction: Double { spacing?.correction ?? edge?.correction ?? 0 }
    }
    private var lockX: Lock?
    private var lockY: Lock?
    private var spacingLockX: SpacingLock?
    private var spacingLockY: SpacingLock?
    private var cachedTargets: [SnapTarget] = []
    private var pairsX: [Pair] = []
    private var pairsY: [Pair] = []
    mutating func reset() { lockX = nil; lockY = nil; spacingLockX = nil; spacingLockY = nil }

    mutating func snap(_ moving: CGRect, to targets: [SnapTarget], zoom: Double, xEnabled: Bool = true, yEnabled: Bool = true) -> SnapResult {
        guard zoom.isFinite, zoom > 0 else { reset(); return SnapResult(rect: moving, guides: []) }
        if cachedTargets != targets {
            cachedTargets = targets
            pairsX = neighborPairs(.x, targets: targets); pairsY = neighborPairs(.y, targets: targets)
        }
        let x = xEnabled ? match(.x, moving: moving, targets: targets, zoom: zoom, previous: lockX) : nil
        let y = yEnabled ? match(.y, moving: moving, targets: targets, zoom: zoom, previous: lockY) : nil
        let sx = xEnabled ? spacingMatch(.x, moving: moving, pairs: pairsX, zoom: zoom, previous: spacingLockX) : nil
        let sy = yEnabled ? spacingMatch(.y, moving: moving, pairs: pairsY, zoom: zoom, previous: spacingLockY) : nil
        var rx = resolve(edge: x, spacing: sx), ry = resolve(edge: y, spacing: sy)
        var final = moving.offsetBy(dx: rx.correction, dy: ry.correction)
        // A perpendicular snap must not turn a row/column measurement into a
        // match against unrelated objects in another lane.
        if let spacing = rx.spacing, !sharesLane(.x, final, spacing.pair) { rx = Resolution(edge: x); final = moving.offsetBy(dx: rx.correction, dy: ry.correction) }
        if let spacing = ry.spacing, !sharesLane(.y, final, spacing.pair) { ry = Resolution(edge: y); final = moving.offsetBy(dx: rx.correction, dy: ry.correction) }
        lockX = rx.edge?.lock; lockY = ry.edge?.lock
        spacingLockX = rx.spacing?.lock; spacingLockY = ry.spacing?.lock
        var guides: [AlignmentGuide] = []
        if let x = rx.edge { guides.append(AlignmentGuide(axis: .x, position: x.position, from: min(final.minY, x.target.minY), to: max(final.maxY, x.target.maxY))) }
        if let y = ry.edge { guides.append(AlignmentGuide(axis: .y, position: y.position, from: min(final.minX, y.target.minX), to: max(final.maxX, y.target.maxX))) }
        var spacingGuides: [SpacingGuide] = []
        if let spacing = rx.spacing ?? sx, abs(final.minX - spacing.origin) < 0.000001, sharesLane(.x, final, spacing.pair) { spacingGuides.append(spacingGuide(.x, moving: final, match: spacing)) }
        if let spacing = ry.spacing ?? sy, abs(final.minY - spacing.origin) < 0.000001, sharesLane(.y, final, spacing.pair) { spacingGuides.append(spacingGuide(.y, moving: final, match: spacing)) }
        return SnapResult(rect: final, guides: guides, spacingGuides: spacingGuides)
    }

    private func resolve(edge: Match?, spacing: SpacingMatch?) -> Resolution {
        if let spacing, spacing.held { return Resolution(spacing: spacing) }
        if let edge, edge.held { return Resolution(edge: edge) }
        if let spacing, edge == nil || abs(spacing.correction) < abs(edge!.correction) - 0.000000001 { return Resolution(spacing: spacing) }
        return Resolution(edge: edge)
    }
    private func range(_ axis: AlignmentAxis, _ rect: CGRect) -> (min: Double, max: Double) {
        axis == .x ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
    }
    private func perpendicular(_ axis: AlignmentAxis, _ rect: CGRect) -> (min: Double, max: Double) { range(axis == .x ? .y : .x, rect) }
    private func sharesLane(_ axis: AlignmentAxis, _ moving: CGRect, _ pair: Pair) -> Bool {
        let a = perpendicular(axis, pair.first.rect), b = perpendicular(axis, pair.second.rect), m = perpendicular(axis, moving)
        return min(a.max, b.max, m.max) - max(a.min, b.min, m.min) > 0.000001
    }
    private func neighborPairs(_ axis: AlignmentAxis, targets: [SnapTarget]) -> [Pair] {
        let sorted = targets.sorted { range(axis, $0.rect).min < range(axis, $1.rect).min }
        var pairs: [Pair] = []
        for (i, a) in sorted.enumerated() {
            let alongA = range(axis, a.rect), acrossA = perpendicular(axis, a.rect)
            for b in sorted.dropFirst(i + 1) {
                let acrossB = perpendicular(axis, b.rect), alongB = range(axis, b.rect)
                guard min(acrossA.max, acrossB.max) - max(acrossA.min, acrossB.min) > 0.000001 else { continue }
                if alongB.min > alongA.max + 0.000001 {
                    let lane = (min: max(acrossA.min, acrossB.min), max: min(acrossA.max, acrossB.max))
                    let blocked = sorted.contains { other in
                        guard other.id != a.id && other.id != b.id else { return false }
                        let along = range(axis, other.rect), across = perpendicular(axis, other.rect)
                        return along.max > alongA.max + 0.000001 && along.min < alongB.min - 0.000001 && min(across.max, lane.max) > max(across.min, lane.min)
                    }
                    if !blocked { pairs.append(Pair(first: a, second: b)) }
                }
                break
            }
        }
        return pairs
    }
    private func spacingMatch(_ axis: AlignmentAxis, moving: CGRect, pairs: [Pair], zoom: Double, previous: SpacingLock?) -> SpacingMatch? {
        let m = range(axis, moving), length = m.max - m.min
        var best: SpacingMatch?
        for pair in pairs where sharesLane(axis, moving, pair) {
            let a = range(axis, pair.first.rect), b = range(axis, pair.second.rect)
            let referenceGap = b.min - a.max
            guard referenceGap > 0 else { continue }
            for mode in SpacingMode.allCases {
                let origin: Double, gap: Double
                switch mode {
                case .before: gap = referenceGap; origin = a.min - gap - length
                case .between: gap = (referenceGap - length) / 2; origin = a.max + gap
                case .after: gap = referenceGap; origin = b.max + gap
                }
                guard gap > 0.000001, gap * zoom <= 600 else { continue }
                let key = SpacingLock(first: pair.first.id, second: pair.second.id, mode: mode)
                let held = key == previous, correction = origin - m.min
                guard abs(correction) * zoom <= (held ? 10 : 6) else { continue }
                let candidate = SpacingMatch(lock: key, pair: pair, origin: origin, gap: gap, correction: correction, held: held)
                if held { return candidate }
                if best == nil || abs(correction) < abs(best!.correction) - 0.000000001 { best = candidate }
            }
        }
        return best
    }
    private func spacingGuide(_ axis: AlignmentAxis, moving: CGRect, match: SpacingMatch) -> SpacingGuide {
        let a = range(axis, match.pair.first.rect), b = range(axis, match.pair.second.rect), m = range(axis, moving)
        let spans: [GapSpan]
        switch match.lock.mode {
        case .before: spans = [GapSpan(from: m.max, to: a.min), GapSpan(from: a.max, to: b.min)]
        case .between: spans = [GapSpan(from: a.max, to: m.min), GapSpan(from: m.max, to: b.min)]
        case .after: spans = [GapSpan(from: a.max, to: b.min), GapSpan(from: b.max, to: m.min)]
        }
        let position = min(perpendicular(axis, moving).min, perpendicular(axis, match.pair.first.rect).min, perpendicular(axis, match.pair.second.rect).min)
        return SpacingGuide(axis: axis, position: position, distance: match.gap, spans: spans)
    }

    private func anchors(_ axis: AlignmentAxis, _ rect: CGRect) -> [Double] {
        axis == .x ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
    }
    private func perpendicularDistance(_ axis: AlignmentAxis, _ a: CGRect, _ b: CGRect) -> Double {
        axis == .x ? max(0, a.minY - b.maxY, b.minY - a.maxY) : max(0, a.minX - b.maxX, b.minX - a.maxX)
    }
    private func match(_ axis: AlignmentAxis, moving: CGRect, targets: [SnapTarget], zoom: Double, previous: Lock?) -> Match? {
        let source = anchors(axis, moving)
        // Capture within six screen points, release beyond ten. Using the raw
        // pointer position each time avoids accumulating snapped movement.
        if let previous, let target = targets.first(where: { $0.id == previous.id }) {
            let value = anchors(axis, target.rect)[previous.targetAnchor]
            let correction = value - source[previous.movingAnchor]
            let distance = perpendicularDistance(axis, moving, target.rect)
            if abs(correction) * zoom <= 10 && distance * zoom <= 600 {
                return Match(lock: previous, target: target.rect, position: value, correction: correction, priority: 0, distance: distance, held: true)
            }
        }
        // Match like edges, centres, or adjacent edges; centre-to-edge matches
        // are intentionally omitted to keep ordinary rows and columns calm.
        let pairs = [(0, 0, 0), (2, 2, 0), (1, 1, 1), (0, 2, 2), (2, 0, 2)]
        var best: Match?
        for target in targets {
            let distance = perpendicularDistance(axis, moving, target.rect)
            guard distance * zoom <= 600 else { continue }
            let destination = anchors(axis, target.rect)
            for (sourceAnchor, targetAnchor, priority) in pairs {
                let correction = destination[targetAnchor] - source[sourceAnchor]
                guard abs(correction) * zoom <= 6 else { continue }
                let candidate = Match(lock: Lock(id: target.id, movingAnchor: sourceAnchor, targetAnchor: targetAnchor), target: target.rect, position: destination[targetAnchor], correction: correction, priority: priority, distance: distance)
                if let current = best {
                    let difference = abs(candidate.correction) - abs(current.correction)
                    if difference < -0.000000001 || (abs(difference) <= 0.000000001 && (priority < current.priority || (priority == current.priority && distance < current.distance))) { best = candidate }
                } else { best = candidate }
            }
        }
        return best
    }
}

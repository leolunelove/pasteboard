import AppKit
import QuartzCore

// Retained artwork: panning and zooming transform existing layers instead of
// decoding images and laying out every note for each gesture event.
final class CanvasScene {
    let root = CALayer()
    private final class Artwork {
        let layer = CALayer()
        let content = CALayer()
        let text = CATextLayer()
        let outline = CAShapeLayer()
        let grip = CAShapeLayer()
        let lock = CATextLayer()
        var card: Card?
        var selected = false
        var preview: CGImage?
        var previewAsset: String?
        var previewCrop = ImageCrop.full
        init() {
            layer.anchorPoint = .zero
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.08
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: 2)
            content.cornerRadius = 7
            content.masksToBounds = true
            content.contentsGravity = .resize
            content.minificationFilter = .trilinear
            content.magnificationFilter = .linear
            text.isWrapped = true
            text.truncationMode = .none
            content.addSublayer(text)
            layer.addSublayer(content)
            outline.fillColor = nil
            outline.strokeColor = NSColor.pasteboardAccent.cgColor
            grip.fillColor = NSColor.white.cgColor
            grip.strokeColor = NSColor.pasteboardAccent.cgColor
            layer.addSublayer(outline)
            layer.addSublayer(grip)
            lock.alignmentMode = .center
            lock.backgroundColor = NSColor.pasteboardAccent.cgColor
            lock.cornerRadius = 4
            lock.masksToBounds = true
            layer.addSublayer(lock)
        }
    }
    private var artwork: [UUID: Artwork] = [:]
    private var previousZoom: CGFloat = 0
    private var renderedCards: [Card] = []
    private var renderedSelection = Set<UUID>()
    private var renderedEditing: UUID?
    private var imageRevision = -1
    private var textScale: CGFloat = 0
    private var renderedBoardCards: [Card] = []
    private var cachedLockedIDs = Set<UUID>()
    private var cachedLockedGroups = Set<UUID>()
    private var renderedGroups: [UUID: CGRect] = [:]
    private var renderedGroupLocks = Set<UUID>()
    private var renderedGuides: [AlignmentGuide] = []
    private var renderedSpacing: [SpacingGuide] = []
    private var renderedBackingScale: CGFloat = 0
    private var groupOutlines: [UUID: CAShapeLayer] = [:]
    private var groupLabels: [UUID: CATextLayer] = [:]
    private var groupGrips: [UUID: CAShapeLayer] = [:]
    private let guideLayer = CAShapeLayer()
    private let spacingLayer = CAShapeLayer()
    private var spacingLabels: [CATextLayer] = []
    init() {
        root.anchorPoint = .zero
        root.isGeometryFlipped = false
        guideLayer.strokeColor = NSColor.pasteboardAccent.cgColor
        guideLayer.fillColor = nil
        guideLayer.zPosition = 2_000_000
        root.addSublayer(guideLayer)
        spacingLayer.strokeColor = NSColor.pasteboardAccent.cgColor
        spacingLayer.fillColor = nil
        spacingLayer.zPosition = 2_000_001
        root.addSublayer(spacingLayer)
    }

    func update(
        cards: [Card], selection: Set<UUID>, groups: [UUID: CGRect], guides: [AlignmentGuide],
        spacingGuides: [SpacingGuide] = [], editing: UUID?, zoom: CGFloat, offset: CGPoint, store: BoardStore,
        color: (Int) -> NSColor, backingScale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let zoomChanged = previousZoom != zoom
        root.position = offset
        if zoomChanged { root.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom)) }
        let boardCards = store.board.cards
        if renderedBoardCards != boardCards {
            cachedLockedIDs = store.board.lockedIDs
            cachedLockedGroups = Set(
                boardCards.filter { cachedLockedIDs.contains($0.id) }.compactMap(\.groupID))
            renderedBoardCards = boardCards
        }
        let locked = cachedLockedIDs
        let backingChanged = renderedBackingScale != backingScale
        let groupPresenceChanged = renderedGroups.isEmpty != groups.isEmpty
        if zoomChanged || backingChanged || renderedGroups != groups
            || renderedGroupLocks != cachedLockedGroups
        {
            updateGroups(groups, locked: cachedLockedGroups, zoom: zoom, backingScale: backingScale)
            renderedGroups = groups
            renderedGroupLocks = cachedLockedGroups
        }
        if zoomChanged || renderedGuides != guides {
            updateGuides(guides, zoom: zoom)
            renderedGuides = guides
        }
        if zoomChanged || backingChanged || groupPresenceChanged || renderedSpacing != spacingGuides {
            updateSpacingGuides(
                spacingGuides, zoom: zoom, backingScale: backingScale, hasGroups: !groups.isEmpty)
            renderedSpacing = spacingGuides
        }
        renderedBackingScale = backingScale
        let scale = backingScale * (zoom > 2 ? 4 : zoom > 1 ? 2 : 1)
        let artworkUnchanged =
            renderedCards == cards && renderedSelection == selection && renderedEditing == editing
            && imageRevision == store.imageRevision && scale == textScale
        // Panning only moves the retained root layer. Rebuild paths, labels and
        // preview requests when their inputs change, rather than every frame.
        if !artworkUnchanged || zoomChanged {
            for card in cards {
                if let asset = card.asset, BoardImageIO.isSVG(asset) {
                    let level = BoardImageIO.previewLevel(max(card.width, card.height) * zoom * backingScale)
                    if artwork[card.id]?.previewAsset != asset
                        || artwork[card.id]?.previewCrop != card.imageCrop
                        || max(artwork[card.id]?.preview?.width ?? 0, artwork[card.id]?.preview?.height ?? 0)
                            < level
                    {
                        _ = store.preview(asset, pixelSize: CGFloat(level), crop: card.imageCrop)
                    }
                }
            }
        }
        if artworkUnchanged {
            if previousZoom != zoom {
                for id in selection {
                    if let art = artwork[id], let card = art.card {
                        updateSelection(art, bounds: CGRect(origin: .zero, size: card.rect.size), zoom: zoom)
                    }
                }
                for art in artwork.values where !art.lock.isHidden {
                    updateLock(art, zoom: zoom, backingScale: backingScale)
                }
            }
            previousZoom = zoom
            return
        }
        let ids = Set(cards.map(\.id))
        for id in Array(artwork.keys) where !ids.contains(id) {
            artwork.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        for (i, card) in cards.enumerated() {
            let art: Artwork
            if let existing = artwork[card.id] {
                art = existing
            } else {
                art = Artwork()
                artwork[card.id] = art
                root.addSublayer(art.layer)
            }
            let selected = selection.contains(card.id) && card.groupID == nil
            if art.layer.zPosition != CGFloat(i) { art.layer.zPosition = CGFloat(i) }
            if art.card?.x != card.x || art.card?.y != card.y {
                art.layer.position = CGPoint(x: card.x, y: card.y)
            }
            let bounds = CGRect(x: 0, y: 0, width: card.width, height: card.height)
            let sizeChanged = art.card?.width != card.width || art.card?.height != card.height
            let styleChanged = art.card?.renderScale != card.renderScale
            if sizeChanged || styleChanged {
                art.layer.bounds = bounds
                art.content.frame = bounds
                let style = card.renderScale
                art.content.cornerRadius = card.asset == nil ? 7 * style : 0
                art.layer.shadowRadius = 6 * style
                art.layer.shadowOffset = CGSize(width: 0, height: 2 * style)
                art.layer.shadowPath =
                    card.asset == nil
                    ? CGPath(
                        roundedRect: bounds, cornerWidth: 7 * style, cornerHeight: 7 * style, transform: nil)
                    : nil
                art.layer.shadowOpacity = card.asset == nil ? 0.08 : 0
                art.text.frame = bounds.insetBy(dx: 20 * style, dy: 19 * style)
            }
            if art.card == nil || art.card?.tone != card.tone || art.card?.hex != card.hex {
                art.content.backgroundColor =
                    card.hex.flatMap(SwatchColor.init)?.color
                    ?? (card.asset == nil ? color(card.tone).cgColor : nil)
            }
            if let hex = card.hex {
                if art.card?.hex != hex || styleChanged || sizeChanged {
                    let style = SwatchArtwork.style(hex: hex, size: bounds.size, scale: card.renderScale)
                    art.text.frame = style.frame
                    art.text.string = style.string
                }
                art.text.isWrapped = false
            } else if art.card?.text != card.text || styleChanged {
                art.text.isWrapped = true
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                art.text.string = NSAttributedString(
                    string: card.text ?? "",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 18 * card.renderScale),
                        .foregroundColor: NSColor.pasteboardInk, .paragraphStyle: paragraph,
                    ])
            }
            art.text.isHidden = (card.text == nil && card.hex == nil) || card.id == editing
            if art.text.contentsScale != scale { art.text.contentsScale = scale }
            if let asset = card.asset {
                let vector = BoardImageIO.isSVG(asset)
                let pixels = max(card.width, card.height) * zoom * backingScale
                let sufficient =
                    vector && art.previewAsset == asset && art.previewCrop == card.imageCrop
                    && max(art.preview?.width ?? 0, art.preview?.height ?? 0)
                        >= BoardImageIO.previewLevel(pixels)
                var preview =
                    sufficient ? art.preview : store.preview(asset, pixelSize: pixels, crop: card.imageCrop)
                if preview == nil && vector {
                    preview = store.preview(asset, pixelSize: 512).flatMap { card.imageCrop.image($0) }
                }
                if let preview, art.preview !== preview || art.card?.crop != card.crop {
                    art.content.contents = vector ? preview : card.imageCrop.image(preview)
                    art.preview = preview
                    art.previewAsset = asset
                    art.previewCrop = vector ? card.imageCrop : .full
                }
            }
            if card.asset == nil {
                art.content.contents = nil
                art.preview = nil
                art.previewAsset = nil
                art.previewCrop = .full
            }
            art.outline.isHidden = !selected
            art.grip.isHidden = !selected || selection.count != 1 || locked.contains(card.id)
            art.lock.isHidden = !locked.contains(card.id) || card.groupID != nil
            if !art.lock.isHidden { updateLock(art, zoom: zoom, backingScale: backingScale) }
            if selected && (sizeChanged || !art.selected || previousZoom != zoom) {
                updateSelection(art, bounds: bounds, zoom: zoom)
            }
            art.card = card
            art.selected = selected
        }
        previousZoom = zoom
        renderedCards = cards
        renderedSelection = selection
        renderedEditing = editing
        imageRevision = store.imageRevision
        textScale = scale
    }
    private func updateSpacingGuides(
        _ guides: [SpacingGuide], zoom: CGFloat, backingScale: CGFloat, hasGroups: Bool
    ) {
        spacingLayer.isHidden = guides.isEmpty
        let path = CGMutablePath()
        var labelCount = 0
        for guide in guides {
            let position = guide.position - (hasGroups ? 40 : 16) / zoom
            for span in guide.spans {
                let horizontal = guide.axis == .x
                func point(_ along: Double, _ across: Double) -> CGPoint {
                    horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
                }
                path.move(to: point(span.from, position))
                path.addLine(to: point(span.to, position))
                for end in [span.from, span.to] {
                    path.move(to: point(end, position - 3.5 / zoom))
                    path.addLine(to: point(end, position + 3.5 / zoom))
                }
                if (span.to - span.from) * zoom >= 12 {
                    for (end, direction) in [(span.from, 1.0), (span.to, -1.0)] {
                        path.move(to: point(end + direction * 3 / zoom, position - 2 / zoom))
                        path.addLine(to: point(end, position))
                        path.addLine(to: point(end + direction * 3 / zoom, position + 2 / zoom))
                    }
                }
                guard (span.to - span.from) * zoom >= 26 else { continue }
                let text =
                    abs(guide.distance.rounded() - guide.distance) < 0.05
                    ? String(format: "%.0f", guide.distance) : String(format: "%.1f", guide.distance)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10.5 / zoom, weight: .medium),
                    .foregroundColor: NSColor.pasteboardAccent,
                ]
                let width = max(25 / zoom, text.size(withAttributes: attributes).width + 8 / zoom)
                let center = point((span.from + span.to) / 2, position)
                let label: CATextLayer
                if labelCount < spacingLabels.count {
                    label = spacingLabels[labelCount]
                } else {
                    label = CATextLayer()
                    label.alignmentMode = .center
                    label.backgroundColor = NSColor.pasteboardCanvas.cgColor
                    label.masksToBounds = true
                    label.zPosition = 2_000_002
                    spacingLabels.append(label)
                    root.addSublayer(label)
                }
                label.frame = CGRect(
                    x: center.x - width / 2, y: center.y - 7.5 / zoom, width: width, height: 15 / zoom)
                label.cornerRadius = 3 / zoom
                label.contentsScale = backingScale * zoom
                label.string = NSAttributedString(string: text, attributes: attributes)
                label.isHidden = false
                labelCount += 1
            }
        }
        for i in labelCount..<spacingLabels.count { spacingLabels[i].isHidden = true }
        spacingLayer.path = guides.isEmpty ? nil : path
        spacingLayer.lineWidth = 1 / zoom
    }
    private func updateGuides(_ guides: [AlignmentGuide], zoom: CGFloat) {
        guideLayer.isHidden = guides.isEmpty
        guard !guides.isEmpty else {
            guideLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let extensionLength = 9 / zoom
        let marker = 3 / zoom
        for guide in guides {
            let start: CGPoint
            let end: CGPoint
            if guide.axis == .x {
                start = CGPoint(x: guide.position, y: guide.from - extensionLength)
                end = CGPoint(x: guide.position, y: guide.to + extensionLength)
            } else {
                start = CGPoint(x: guide.from - extensionLength, y: guide.position)
                end = CGPoint(x: guide.to + extensionLength, y: guide.position)
            }
            path.move(to: start)
            path.addLine(to: end)
            for point in [start, end] {
                path.move(to: CGPoint(x: point.x - marker, y: point.y - marker))
                path.addLine(to: CGPoint(x: point.x + marker, y: point.y + marker))
                path.move(to: CGPoint(x: point.x - marker, y: point.y + marker))
                path.addLine(to: CGPoint(x: point.x + marker, y: point.y - marker))
            }
        }
        guideLayer.path = path
        guideLayer.lineWidth = 1 / zoom
    }
    private func updateGroups(
        _ groups: [UUID: CGRect], locked: Set<UUID>, zoom: CGFloat, backingScale: CGFloat
    ) {
        for id in Array(groupOutlines.keys) where groups[id] == nil {
            groupOutlines.removeValue(forKey: id)?.removeFromSuperlayer()
            groupLabels.removeValue(forKey: id)?.removeFromSuperlayer()
            groupGrips.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for (id, rect) in groups {
            let outline: CAShapeLayer
            let label: CATextLayer
            let grip: CAShapeLayer
            if let existing = groupOutlines[id], let existingLabel = groupLabels[id],
                let existingGrip = groupGrips[id]
            {
                outline = existing
                label = existingLabel
                grip = existingGrip
            } else {
                outline = CAShapeLayer()
                outline.fillColor = nil
                outline.strokeColor = NSColor.pasteboardAccent.cgColor
                outline.zPosition = 1_000_000
                label = CATextLayer()
                label.alignmentMode = .center
                label.backgroundColor = NSColor.pasteboardAccent.cgColor
                label.masksToBounds = true
                label.zPosition = 1_000_001
                grip = CAShapeLayer()
                grip.fillColor = NSColor.white.cgColor
                grip.strokeColor = NSColor.pasteboardAccent.cgColor
                grip.zPosition = 1_000_002
                groupOutlines[id] = outline
                groupLabels[id] = label
                groupGrips[id] = grip
                root.addSublayer(outline)
                root.addSublayer(label)
                root.addSublayer(grip)
            }
            let bounds = rect.insetBy(dx: -9 / zoom, dy: -9 / zoom)
            outline.path = CGPath(
                roundedRect: bounds, cornerWidth: 9 / zoom, cornerHeight: 9 / zoom, transform: nil)
            outline.lineWidth = 1.7 / zoom
            let handles = CGMutablePath()
            for corner in GroupCorner.allCases {
                let point = corner.point(in: bounds)
                handles.addRoundedRect(
                    in: CGRect(
                        x: point.x - 4 / zoom, y: point.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom),
                    cornerWidth: 2 / zoom, cornerHeight: 2 / zoom)
            }
            grip.path = handles
            grip.lineWidth = 1.6 / zoom
            grip.isHidden = locked.contains(id)
            label.frame = CGRect(
                x: bounds.minX, y: bounds.minY - 20 / zoom, width: (locked.contains(id) ? 94 : 48) / zoom,
                height: 17 / zoom)
            label.cornerRadius = 4 / zoom
            label.contentsScale = backingScale * zoom
            label.string = NSAttributedString(
                string: locked.contains(id) ? "Locked group" : "Group",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11 / zoom, weight: .medium),
                    .foregroundColor: NSColor.white,
                ])
        }
    }
    private func updateSelection(_ art: Artwork, bounds: CGRect, zoom: CGFloat) {
        art.outline.path = CGPath(
            roundedRect: bounds.insetBy(dx: -3 / zoom, dy: -3 / zoom), cornerWidth: 9 / zoom,
            cornerHeight: 9 / zoom, transform: nil)
        art.outline.lineWidth = 1.7 / zoom
        art.grip.path = CGPath(
            roundedRect: CGRect(
                x: bounds.maxX - 4 / zoom, y: bounds.maxY - 4 / zoom, width: 8 / zoom, height: 8 / zoom),
            cornerWidth: 2 / zoom, cornerHeight: 2 / zoom, transform: nil)
        art.grip.lineWidth = 1.6 / zoom
    }
    private func updateLock(_ art: Artwork, zoom: CGFloat, backingScale: CGFloat) {
        art.lock.frame = CGRect(x: 5 / zoom, y: 5 / zoom, width: 24 / zoom, height: 20 / zoom)
        art.lock.cornerRadius = 4 / zoom
        art.lock.contentsScale = backingScale * zoom
        art.lock.string = NSAttributedString(
            string: "🔒", attributes: [.font: NSFont.systemFont(ofSize: 11 / zoom)])
    }
}

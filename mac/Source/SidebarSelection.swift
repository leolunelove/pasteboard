import AppKit

/// Merge selection belongs to one folder. Navigation remains separate from selection.
struct SidebarMergeSelection {
    var ids = Set<UUID>()
    var parentID: UUID?
    var selecting = false
    private(set) var anchor: UUID?

    mutating func clear() { self = SidebarMergeSelection() }

    mutating func set(_ ids: Set<UUID>, parent: UUID, selecting: Bool, workspace: Workspace, anchor incomingAnchor: UUID? = nil) {
        self.parentID = selecting ? parent : nil
        self.selecting = selecting
        self.ids = selecting ? ids.intersection(eligible(in: parent, workspace: workspace)) : []
        if let incomingAnchor, self.ids.contains(incomingAnchor) { self.anchor = incomingAnchor }
        if let anchor, !self.ids.contains(anchor) { self.anchor = nil }
        if self.anchor == nil { self.anchor = eligible(in: parent, workspace: workspace).first { self.ids.contains($0) } }
    }

    func eligible(in parent: UUID, workspace: Workspace) -> [UUID] {
        workspace.pages(in: parent).filter { !workspace.isContainer($0.id) }.map(\.id)
    }

    mutating func activate(_ id: UUID, modifiers: NSEvent.ModifierFlags, workspace: Workspace) {
        guard let board = workspace.boards.first(where: { $0.id == id }),
            let parent = board.parentID, !workspace.isContainer(id) else { return }
        if parentID != parent { clear(); parentID = parent }
        selecting = true
        let siblings = eligible(in: parent, workspace: workspace)
        if modifiers.contains(.shift), let anchor,
            let start = siblings.firstIndex(of: anchor), let end = siblings.firstIndex(of: id) {
            let range = Set(siblings[min(start, end)...max(start, end)])
            ids = modifiers.contains(.command) ? ids.union(range) : range
        } else {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        }
    }

    mutating func reconcile(_ workspace: Workspace) {
        guard let parentID, workspace.isContainer(parentID) else { clear(); return }
        ids.formIntersection(eligible(in: parentID, workspace: workspace))
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
    }
}

final class SidebarMergePanel: NSView {
    let title = NSTextField(labelWithString: "Select boards")
    let detail = NSTextField(labelWithString: "Choose boards in one folder")
    let merge = PasteboardToolbarButton(title: "Merge boards", target: nil, action: nil)
    let cancel = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel board selection")!, target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .pasteboardInk
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .pasteboardMuted
        detail.lineBreakMode = .byTruncatingTail
        merge.primary = true
        merge.isBordered = false
        merge.font = .systemFont(ofSize: 11, weight: .semibold)
        merge.setAccessibilityLabel("Merge selected boards")
        cancel.isBordered = false
        cancel.contentTintColor = .pasteboardMuted
        cancel.toolTip = "Cancel selection (Esc)"
        for view in [title, detail, merge, cancel] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        title.frame = CGRect(x: 12, y: bounds.height - 29, width: bounds.width - 48, height: 17)
        cancel.frame = CGRect(x: bounds.width - 31, y: bounds.height - 31, width: 22, height: 22)
        detail.frame = CGRect(x: 12, y: bounds.height - 48, width: bounds.width - 24, height: 16)
        merge.frame = CGRect(x: 12, y: 11, width: bounds.width - 24, height: 29)
    }
    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.pasteboardSurface.setFill(); panel.fill()
        NSColor.pasteboardBorder.setStroke(); panel.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

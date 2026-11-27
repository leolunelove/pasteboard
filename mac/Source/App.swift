import AppKit
import UniformTypeIdentifiers

final class Surface: NSView {
    var fill: NSColor
    init(_ color: NSColor) {
        fill = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class BoardButton: PasteboardHoverButton {
    var active = false { didSet { needsDisplay = true } }
    var isPage = false
    var selectedForMerge = false { didSet { needsDisplay = true } }
    var showsMergeSelection = false { didSet { needsDisplay = true } }
    var activate: ((NSEvent.ModifierFlags) -> Void)?
    var selectionKeyAction: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, selectionKeyAction?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if selectionKeyAction?(event) == true { return }
        super.keyDown(with: event)
    }
    var symbolName = "square.grid.2x2"
    var badge: String?
    var rename: (() -> Void)?
    var dropTarget = false { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        if let activate, showsMergeSelection || !event.modifierFlags.intersection([.command, .shift]).isEmpty {
            window?.makeFirstResponder(self)
            activate(event.modifierFlags)
        } else if event.clickCount == 2, let rename { rename() }
        else { super.mouseDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        if active || selectedForMerge || dropTarget {
            NSColor.pasteboardSelection.setFill()
            shape.fill()
        } else if hovering {
            NSColor.pasteboardSurface.withAlphaComponent(0.65).setFill()
            shape.fill()
        }
        if dropTarget || window?.firstResponder === self {
            NSColor.pasteboardAccent.withAlphaComponent(0.8).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        let tint: NSColor = active || selectedForMerge ? .pasteboardAccent : .pasteboardMuted
        let symbol = NSImage(systemSymbolName: showsMergeSelection ? (selectedForMerge ? "checkmark.circle.fill" : "circle") : symbolName, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: active ? .semibold : .regular)
            .applying(.init(paletteColors: [tint]))
        if showsMergeSelection && selectedForMerge {
            NSColor.pasteboardAccent.setFill()
            NSBezierPath(ovalIn: CGRect(x: 11, y: bounds.midY - 7, width: 14, height: 14)).fill()
            let checkmark = NSBezierPath()
            checkmark.move(to: CGPoint(x: 14, y: bounds.midY))
            checkmark.line(to: CGPoint(x: 17, y: bounds.midY + 3))
            checkmark.line(to: CGPoint(x: 22, y: bounds.midY - 3))
            NSColor.pasteboardSurface.setStroke()
            checkmark.lineWidth = 1.6
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            checkmark.stroke()
        } else {
            symbol?.withSymbolConfiguration(config)?.draw(
                in: CGRect(x: 10, y: bounds.midY - 8, width: 16, height: 16))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let badgeWidth: CGFloat = badge == nil || showsMergeSelection ? 0 : 24
        title.draw(
            in: CGRect(x: 32, y: bounds.midY - 8, width: max(1, bounds.width - 40 - badgeWidth), height: 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: active || selectedForMerge ? .semibold : .regular),
                .foregroundColor: active || selectedForMerge ? NSColor.pasteboardInk : NSColor.pasteboardMuted,
                .paragraphStyle: paragraph,
            ])
        if let badge, !showsMergeSelection {
            let area = CGRect(x: bounds.maxX - 28, y: bounds.midY - 9, width: 22, height: 18)
            (active
                ? NSColor.pasteboardAccent.withAlphaComponent(0.10)
                : NSColor.clear).setFill()
            NSBezierPath(roundedRect: area, xRadius: 5, yRadius: 5).fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (badge as NSString).draw(
                in: area.offsetBy(dx: 0, dy: 1),
                withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: tint, .paragraphStyle: style,
                ])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let store: BoardStore
    let canvas: BoardView
    var window: NSWindow!
    var rows = NSStackView()
    let titleLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Saved on this Mac")
    var zoomButton: NSButton!
    var groupButton: NSButton!
    private let overview = WorkspaceOverview()
    private var socialWindow: SocialPreviewWindow?
    private var videoWindow: VideoPlayerWindow?
    private var showsGlobalReady = false
    private let readyButton = BoardButton(title: "Ready to post", target: nil, action: nil)
    private let backButton = NSButton()
    private var boardControls: [NSView] = []
    private var headerControls: [NSView] = []
    private var headerTitleLimit: NSLayoutConstraint?
    private var headerCountLimit: NSLayoutConstraint?
    private(set) var sidebarSelection = SidebarMergeSelection()
    private let sidebarMergePanel = SidebarMergePanel()
    private let sidebarSelectButton = NSButton()
    private var sidebarMergeHeight: NSLayoutConstraint?
    private let appearancePicker = NSPopUpButton()
    var itemLabel = NSTextField(labelWithString: "")
    private var sidebarSignature = ""
    private var revealedSidebarBoard: UUID?
    private var collapsedWorkspaces = Set<UUID>()
    private var sidebarTargets: [(NSView, UUID, BoardButton)] = []
    private var sidebarScroll: NSScrollView?
    private let transferBadge = TransferBadge()
    private var terminationTimer: Timer?
    private var backupTimer: Timer?
    private let installedRelease = InstalledRelease()
    private var updatesWindow: UpdatesWindowController?
    private var searchWindow: SearchWindowController?
    private var backupsWindow: BackupsWindowController?
    private let showsPreviewOnLaunch: Bool
    private let presentsWindow: Bool

    override convenience init() { self.init(directory: nil) }
    init(directory: URL?, presentsWindow: Bool = true) {
        self.presentsWindow = presentsWindow
        let testDirectory = Bundle.main.object(forInfoDictionaryKey: "GatherTestingDirectory") as? String
        showsPreviewOnLaunch = directory == nil && testDirectory == nil
        store = BoardStore(directory: directory ?? testDirectory.map { URL(fileURLWithPath: $0) })
        do { try store.enableWorkspaceOverviews() } catch {
            store.loadWarning =
                "Your boards are preserved. The workspace overview could not be prepared: \(error.localizedDescription)"
        }
        canvas = BoardView(store: store)
        super.init()
        canvas.onRequestPage = { [weak self] in self?.ensureCanvasPage() }
        canvas.snappingEnabled = UserDefaults.standard.object(forKey: "SnapToObjects") as? Bool ?? true
        canvas.minimapEnabled = UserDefaults.standard.object(forKey: "ShowMinimap") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PasteboardAppearance.current.apply()
        makeMenus()
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1220, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Pasteboard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 880, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .pasteboardCanvas
        let root = Surface(.pasteboardCanvas)
        window.contentView = root
        let sidebar = Surface(.pasteboardChrome)
        let header = Surface(.pasteboardCanvas)
        let footer = Surface(.pasteboardCanvas)
        for view in [sidebar, header, canvas, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 256),
            header.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 88),
            canvas.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: header.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 36),
        ])
        overview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overview)
        NSLayoutConstraint.activate([
            overview.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            overview.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            overview.topAnchor.constraint(equalTo: canvas.topAnchor),
            overview.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        canvas.onPlayVideo = { [weak self] card in
            guard let self else { return }
            videoWindow?.close()
            videoWindow = VideoPlayerWindow(store: store, boardID: store.board.id, card: card)
            videoWindow?.present()
        }
        canvas.onOpenSocialPost = { [weak self] board, anchor in
            self?.openSocialPost(boardID: board, anchorID: anchor)
        }
        overview.openPost = { [weak self] board, anchor in
            self?.openSocialPost(boardID: board, anchorID: anchor)
        }
        overview.openPage = { [weak self] in self?.navigate(to: $0) }
        overview.newPage = { [weak self] in self?.newPage(nil) }
        overview.newFolder = { [weak self] in self?.newFolder(nil) }
        overview.mergePages = { [weak self] in self?.mergePages($0) }
        overview.selectionChanged = { [weak self] ids, selecting in
            guard let self else { return }
            sidebarSelection.set(ids, parent: store.board.id, selecting: selecting, workspace: store.workspace, anchor: overview.selectionAnchor)
            refreshSidebarSelection()
        }
        overview.goBack = { [weak self] in self?.goToParent(nil) }
        overview.renamePage = { [weak self] in self?.rename(id: $0) }
        overview.deletePage = { [weak self] id in
            let item = NSMenuItem()
            item.representedObject = id.uuidString
            self?.deleteBoard(item)
        }
        overview.pasteItems = { [weak self] in self?.pasteToBoard(nil) }
        store.imageReady = { [weak self] in
            self?.canvas.needsDisplay = true
            self?.overview.refreshImages()
        }
        addLine(to: root, vertical: true, anchor: sidebar.trailingAnchor)
        addLine(to: header, vertical: false)
        makeSidebar(sidebar)
        makeHeader(header)
        makeFooter(footer)
        store.changed = { [weak self] in self?.refresh() }
        store.status = { [weak self] message in
            if self?.statusLabel.stringValue != message { self?.statusLabel.stringValue = message }
        }
        canvas.onViewport = { [weak self] in self?.updateViewport() }
        canvas.onSelection = { [weak self] in self?.updateCount() }
        canvas.onSidebarHover = { [weak self] point, ids in self?.hoverPage(at: point, ids: ids) }
        canvas.onSidebarDragEnded = { [weak self] in self?.clearPageHover() }
        canvas.onSidebarDrop = { [weak self] id, ids in
            guard let self else { return false }
            if let parent = store.workspace.boards.first(where: { $0.id == id })?.parentID {
                collapsedWorkspaces.remove(parent)
            }
            guard let moved = store.moveCards(ids, from: store.board.id, to: id, viewport: canvas.bounds.size)
            else { return false }
            canvas.focusCards(moved)
            return true
        }
        refresh()
        store.scheduleSave()
        backupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.store.backupNow()
        }
        if presentsWindow {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
            window.orderBack(nil)
        }
        revealActiveSidebarRow()
        window.makeFirstResponder((showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
        if let warning = store.loadWarning {
            let alert = NSAlert()
            alert.messageText = "Workspace recovery"
            alert.informativeText = warning
            alert.beginSheetModal(for: window) { [weak self] _ in self?.showPreviewIfNeeded() }
        } else {
            let failure = store.directory.appendingPathComponent("LastUpdateFailure.txt")
            if let text = try? String(contentsOf: failure, encoding: .utf8), !text.isEmpty {
                try? FileManager.default.removeItem(at: failure)
                let alert = NSAlert()
                alert.messageText = "Pasteboard update"
                alert.informativeText = text
                alert.beginSheetModal(for: window) { [weak self] _ in self?.showPreviewIfNeeded() }
            } else {
                showPreviewIfNeeded()
            }
        }
        if Bundle.main.object(forInfoDictionaryKey: "GatherRunChecksOnLaunch") as? Bool == true,
            let log = Bundle.main.object(forInfoDictionaryKey: "GatherTestingLog") as? String
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                do {
                    try selfTest()
                    try "PASS: all native checks\n".write(toFile: log, atomically: true, encoding: .utf8)
                    self?.statusLabel.stringValue = "QA: all checks passed"
                } catch {
                    try? ("FAIL: " + error.localizedDescription).write(
                        toFile: log, atomically: true, encoding: .utf8)
                    self?.statusLabel.stringValue = "QA: " + error.localizedDescription
                }
            }
        }
    }

    private func showPreviewIfNeeded() {
        guard showsPreviewOnLaunch, PreviewNotice.shouldShow(build: installedRelease.build) else { return }
        showPreviewNotice(nil)
    }
    @objc func showPreviewNotice(_ sender: Any?) {
        guard window.attachedSheet == nil else { return }
        canvas.finishEditing()
        PreviewNotice.alert().beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            PreviewNotice.acknowledge(build: installedRelease.build)
            window.makeFirstResponder((showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
        }
    }

    func label(
        _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .pasteboardInk
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    func button(_ title: String, symbol: String? = nil, action: Selector, primary: Bool = false) -> NSButton {
        let button = PasteboardToolbarButton(title: title, target: self, action: action)
        button.primary = primary
        button.bezelStyle = .rounded
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.controlSize = .large
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        if primary {
            button.bezelColor = .pasteboardAccent
            button.contentTintColor = .white
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(title)
        return button
    }
    func addLine(to view: NSView, vertical: Bool, anchor: NSLayoutXAxisAnchor? = nil) {
        let line = Surface(.pasteboardBorder)
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
        if vertical {
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: anchor!),
                line.widthAnchor.constraint(equalToConstant: 1),
                line.topAnchor.constraint(equalTo: view.topAnchor),
                line.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                line.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
    }

    func makeSidebar(_ sidebar: NSView) {
        let brand = label("Pasteboard", size: 20, weight: .semibold)
        let mark = NSImageView(image: PasteboardArtwork.smallIcon)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityLabel("Pasteboard")
        let subtitle = label("Room for your ideas.", size: 11, color: .pasteboardMuted)
        readyButton.target = self
        readyButton.action = #selector(showAllReady(_:))
        readyButton.isBordered = false
        readyButton.symbolName = "checkmark.circle"
        readyButton.setButtonType(.pushOnPushOff)
        readyButton.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        readyButton.imagePosition = .imageLeading
        readyButton.font = .systemFont(ofSize: 13, weight: .medium)
        readyButton.toolTip = "Ready images and frames from every workspace"
        readyButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarSelectButton.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Select boards for merge")
        sidebarSelectButton.isBordered = false
        sidebarSelectButton.contentTintColor = .pasteboardMuted
        sidebarSelectButton.target = self
        sidebarSelectButton.action = #selector(toggleSidebarSelection(_:))
        sidebarSelectButton.toolTip = "Select boards to merge · or ⌘-click boards"
        sidebarSelectButton.setAccessibilityLabel("Select boards for merge")
        sidebarSelectButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarMergePanel.translatesAutoresizingMaskIntoConstraints = false
        sidebarMergePanel.merge.target = self
        sidebarMergePanel.merge.action = #selector(mergeSidebarBoards(_:))
        sidebarMergePanel.cancel.target = self
        sidebarMergePanel.cancel.action = #selector(cancelSidebarMerge(_:))
        sidebarMergePanel.isHidden = true
        sidebarMergeHeight = sidebarMergePanel.heightAnchor.constraint(equalToConstant: 0)
        let section = label("WORKSPACES", size: 10, weight: .semibold, color: .pasteboardMuted)
        let plus = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Workspace")!,
            target: self, action: #selector(newBoard(_:)))
        plus.isBordered = false
        plus.contentTintColor = .pasteboardAccent
        plus.toolTip = "New workspace (⌘N)"
        plus.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll = scroll
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let appearanceLabel = label("Appearance", size: 10, weight: .medium, color: .pasteboardMuted)
        appearancePicker.addItems(withTitles: PasteboardAppearance.allCases.map(\.title))
        appearancePicker.selectItem(at: PasteboardAppearance.allCases.firstIndex(of: .current) ?? 0)
        appearancePicker.target = self
        appearancePicker.action = #selector(changeAppearance(_:))
        appearancePicker.font = .systemFont(ofSize: 11)
        appearancePicker.controlSize = .small
        appearancePicker.setAccessibilityLabel("Appearance")
        appearancePicker.toolTip = "Follow your Mac, or choose Light or Dark"
        appearancePicker.translatesAutoresizingMaskIntoConstraints = false
        let updates = NSButton(title: "App updates", target: self, action: #selector(showUpdates(_:)))
        let search = NSButton(title: "Search boards", target: self, action: #selector(showSearch(_:)))
        let backups = NSButton(title: "Local backups", target: self, action: #selector(showBackups(_:)))
        for (control, symbol) in [(search, "magnifyingglass"), (backups, "clock.arrow.circlepath")] {
            control.isBordered = false
            control.font = .systemFont(ofSize: 11, weight: .medium)
            control.contentTintColor = .pasteboardMuted
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            control.imagePosition = .imageLeading
            control.translatesAutoresizingMaskIntoConstraints = false
        }
        updates.isBordered = false
        updates.font = .systemFont(ofSize: 11, weight: .medium)
        updates.contentTintColor = .pasteboardMuted
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updates.imagePosition = .imageLeading
        updates.toolTip = "Check your version and find the latest Pasteboard build"
        updates.translatesAutoresizingMaskIntoConstraints = false
        for view in [
            mark, brand, subtitle, readyButton, section, plus, scroll, search, backups, updates,
            appearanceLabel,
            appearancePicker, sidebarSelectButton, sidebarMergePanel,
        ] {
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 55),
            mark.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            mark.widthAnchor.constraint(equalToConstant: 27),
            mark.heightAnchor.constraint(equalToConstant: 27),
            brand.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            brand.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 7),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -15),
            subtitle.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            readyButton.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            readyButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            readyButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            readyButton.heightAnchor.constraint(equalToConstant: 34),
            section.topAnchor.constraint(equalTo: readyButton.bottomAnchor, constant: 22),
            section.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            sidebarSelectButton.centerYAnchor.constraint(equalTo: section.centerYAnchor),
            sidebarSelectButton.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -5),
            sidebarSelectButton.widthAnchor.constraint(equalToConstant: 24),
            sidebarSelectButton.heightAnchor.constraint(equalToConstant: 24),
            plus.centerYAnchor.constraint(equalTo: section.centerYAnchor),
            plus.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -22),
            plus.widthAnchor.constraint(equalToConstant: 22),
            plus.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: sidebarMergePanel.topAnchor, constant: -12),
            sidebarMergePanel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarMergePanel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sidebarMergePanel.bottomAnchor.constraint(equalTo: search.topAnchor, constant: -14),
            sidebarMergeHeight!,
            search.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            search.bottomAnchor.constraint(equalTo: backups.topAnchor, constant: -3),
            search.heightAnchor.constraint(equalToConstant: 24),
            backups.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            backups.bottomAnchor.constraint(equalTo: updates.topAnchor, constant: -3),
            backups.heightAnchor.constraint(equalToConstant: 24),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: rows.heightAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            appearanceLabel.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            appearanceLabel.bottomAnchor.constraint(equalTo: appearancePicker.topAnchor, constant: -6),
            updates.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            updates.bottomAnchor.constraint(equalTo: appearanceLabel.topAnchor, constant: -18),
            updates.heightAnchor.constraint(equalToConstant: 24),
            appearancePicker.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            appearancePicker.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -25),
            appearancePicker.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -21),
        ])
    }

    func makeHeader(_ header: NSView) {
        let rename = NSClickGestureRecognizer(target: self, action: #selector(renameBoard(_:)))
        rename.numberOfClicksRequired = 2
        titleLabel.addGestureRecognizer(rename)
        titleLabel.toolTip = "Double-click to rename this workspace or page"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .pasteboardInk
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .pasteboardMuted
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        groupButton = button("Group", symbol: "square.3.layers.3d", action: #selector(toggleGrouping(_:)))
        groupButton.toolTip = "Group (⌘G) / Ungroup (⇧⌘G). Drag a group corner to resize in proportion."
        let colour = button("Colour", symbol: "paintpalette", action: #selector(addColour(_:)))
        colour.toolTip = "Add a colour box with a visible HEX value (S)"
        let note = button("Note", symbol: "text.badge.plus", action: #selector(addNote(_:)))
        note.toolTip = "Add a text note (T)"
        let image = button("Media", symbol: "photo.on.rectangle", action: #selector(importImages(_:)))
        image.toolTip = "Add images or videos from your Mac (⌘O)"
        let paste = button(
            "Paste", symbol: "doc.on.clipboard", action: #selector(pasteToBoard(_:)), primary: true)
        paste.toolTip = "Paste images, videos, YouTube links or text (⌘V)"
        backButton.image = NSImage(
            systemSymbolName: "chevron.left", accessibilityDescription: "Back to parent folder")
        backButton.isBordered = false
        backButton.contentTintColor = .pasteboardMuted
        backButton.target = self
        backButton.action = #selector(goToParent(_:))
        backButton.setAccessibilityLabel("Back to parent folder")
        for view in [backButton, titleLabel, countLabel, groupButton!, colour, note, image, paste] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        headerControls = [groupButton!, colour, note, image, paste]
        headerTitleLimit = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupButton.leadingAnchor, constant: -18)
        headerCountLimit = countLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupButton.leadingAnchor, constant: -16)
        NSLayoutConstraint.activate([
            headerTitleLimit!, headerCountLimit!,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -28),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -28),
            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 42),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 40),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            paste.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22),
            paste.centerYAnchor.constraint(equalTo: header.topAnchor, constant: 58),
            paste.heightAnchor.constraint(equalToConstant: 32),
            paste.widthAnchor.constraint(equalToConstant: 82),
            image.trailingAnchor.constraint(equalTo: paste.leadingAnchor, constant: -6),
            image.centerYAnchor.constraint(equalTo: paste.centerYAnchor),
            image.heightAnchor.constraint(equalTo: paste.heightAnchor),
            image.widthAnchor.constraint(equalToConstant: 74),
            note.trailingAnchor.constraint(equalTo: image.leadingAnchor, constant: -6),
            note.centerYAnchor.constraint(equalTo: paste.centerYAnchor),
            note.heightAnchor.constraint(equalTo: paste.heightAnchor),
            note.widthAnchor.constraint(equalToConstant: 68),
            colour.trailingAnchor.constraint(equalTo: note.leadingAnchor, constant: -6),
            colour.centerYAnchor.constraint(equalTo: paste.centerYAnchor),
            colour.heightAnchor.constraint(equalTo: paste.heightAnchor),
            colour.widthAnchor.constraint(equalToConstant: 78),
            groupButton.trailingAnchor.constraint(equalTo: colour.leadingAnchor, constant: -6),
            groupButton.centerYAnchor.constraint(equalTo: paste.centerYAnchor),
            groupButton.heightAnchor.constraint(equalTo: paste.heightAnchor),
            groupButton.widthAnchor.constraint(equalToConstant: 74),
        ])
    }

    func makeFooter(_ footer: NSView) {
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .pasteboardMuted
        statusLabel.lineBreakMode = .byTruncatingTail
        let help = label("Tab to find items  ·  Space + drag to pan", size: 10, color: .pasteboardMuted)
        let minus = NSButton(title: "−", target: self, action: #selector(zoomOut(_:)))
        let plus = NSButton(title: "+", target: self, action: #selector(zoomIn(_:)))
        zoomButton = NSButton(title: "100%", target: self, action: #selector(showZoomMenu(_:)))
        zoomButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        zoomButton.imagePosition = .imageTrailing
        zoomButton.toolTip = "Zoom presets, Fit Board and Fit Selection"
        zoomButton.setAccessibilityLabel("Zoom")
        let fit = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fit Board")!,
            target: canvas, action: #selector(BoardView.fitAll(_:)))
        fit.toolTip = "Fit everything (⌘0)"
        for button in [minus, plus, zoomButton!, fit] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .pasteboardInk
        }
        boardControls = [help, minus, plus, zoomButton!, fit]
        for view in [statusLabel, help, minus, plus, zoomButton!, fit] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 22),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
            help.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            help.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            help.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 16),
            fit.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -19),
            fit.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            fit.widthAnchor.constraint(equalToConstant: 26),
            plus.trailingAnchor.constraint(equalTo: fit.leadingAnchor, constant: -13),
            plus.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 24),
            zoomButton.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -2),
            zoomButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 64),
            minus.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -2),
            minus.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            minus.widthAnchor.constraint(equalToConstant: 24),
            help.trailingAnchor.constraint(lessThanOrEqualTo: minus.leadingAnchor, constant: -15),
        ])
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func refresh() {
        let focusedSidebarID = (window?.firstResponder as? BoardButton)?.identifier.flatMap { UUID(uuidString: $0.rawValue) }
        if revealedSidebarBoard != store.board.id {
            sidebarSelection.clear()
            overview.setMergeSelection([], selecting: false)
        }
        if revealedSidebarBoard != store.board.id, !showsGlobalReady {
            for ancestor in store.workspace.ancestors(of: store.board.id) {
                collapsedWorkspaces.remove(ancestor.id)
            }
        }
        sidebarSelection.reconcile(store.workspace)
        let isOverview = showsGlobalReady || store.showsWorkspaceOverview
        titleLabel.stringValue = showsGlobalReady ? "Ready to post" : store.board.name
        window?.title = "\(titleLabel.stringValue) — Pasteboard"
        readyButton.title = "Ready to post"
        let readyCount = store.allReadyPosts.count
        readyButton.badge = readyCount > 99 ? "99+" : "\(readyCount)"
        readyButton.active = showsGlobalReady
        readyButton.setAccessibilityLabel("Ready to post, \(readyCount) posts across all workspaces")
        backButton.isHidden = isOverview || store.board.parentID == nil
        backButton.toolTip = store.board.parentID.flatMap { parent in
            store.workspace.boards.first(where: { $0.id == parent }).map { "Back to " + $0.name }
        }
        readyButton.state = showsGlobalReady ? .on : .off
        let signature =
            store.workspace.boards.map {
                $0.id.uuidString + $0.name + ($0.parentID?.uuidString ?? "")
                    + "\($0.isFolder == true):\($0.cards.count):\($0.sections?.count ?? 0)"
            }
            .joined(separator: "|") + store.board.id.uuidString
            + collapsedWorkspaces.map(\.uuidString).sorted().joined()
            + (showsGlobalReady ? "global" : "board")
        if signature != sidebarSignature {
            sidebarSignature = signature
            sidebarTargets.removeAll()
            for view in rows.arrangedSubviews {
                rows.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            func append(_ board: Board, depth: Int) {
                addSidebarRow(board, depth: depth)
                if !collapsedWorkspaces.contains(board.id) {
                    for child in store.workspace.pages(in: board.id) { append(child, depth: depth + 1) }
                }
            }
            for root in store.workspace.roots { append(root, depth: 0) }
        }
        // Reveal the destination on launch and navigation, without pulling the
        // sidebar back while someone scrolls it to browse or transfer items.
        if revealedSidebarBoard != store.board.id {
            revealedSidebarBoard = store.board.id
            revealActiveSidebarRow()
            window?.makeFirstResponder(isOverview ? overview : canvas)
        }
        overview.isHidden = !isOverview
        canvas.isHidden = isOverview
        for control in boardControls + headerControls { control.isHidden = isOverview }
        headerTitleLimit?.isActive = !isOverview
        headerCountLimit?.isActive = !isOverview
        if isOverview {
            overview.show(
                pages: showsGlobalReady ? [] : store.workspace.pages(in: store.board.id), store: store,
                globally: showsGlobalReady)
        }
        refreshSidebarSelection()
        if sidebarSelection.selecting, let focusedSidebarID { focusSidebarBoard(focusedSidebarID) }
        canvas.refresh()
        updateCount()
        updateViewport()
        searchWindow?.reload()
        socialWindow?.refreshFromStore()
        videoWindow?.refreshFromStore()
    }
    private func revealActiveSidebarRow() {
        window?.contentView?.layoutSubtreeIfNeeded()
        if let row = sidebarTargets.first(where: { $0.1 == store.board.id })?.0 {
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -5))
        }
    }
    private func addSidebarRow(_ board: Board, depth: Int) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let children = store.workspace.pages(in: board.id)
        let container = board.parentID == nil || board.isFolder == true || !children.isEmpty
        let button = BoardButton(title: board.name, target: self, action: #selector(selectBoard(_:)))
        button.identifier = .init(board.id.uuidString)
        button.active = !showsGlobalReady && board.id == store.board.id
        button.symbolName =
            board.parentID == nil
            ? "square.grid.2x2"
            : container
                ? "folder"
                : (board.sections?.isEmpty == false ? "rectangle.3.group" : "rectangle.on.rectangle")
        let count = container ? children.count : board.cards.count
        button.badge = count > 99 ? "99+" : "\(count)"
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = store.workspace.path(for: board) + " · Right-click for options"
        button.setAccessibilityLabel(
            board.name + (board.parentID == nil ? " workspace" : container ? " folder" : " board")
                + ", \(count) \(container ? "boards and folders" : "items")")
        button.rename = { [weak self] in self?.rename(id: board.id) }
        button.activate = { [weak self] in self?.activateSidebarBoard(board.id, modifiers: $0) }
        button.selectionKeyAction = { [weak self] event in self?.handleSidebarSelectionKey(event) ?? false }
        let menu = NSMenu()
        var actions: [(String, Selector)] = []
        if container {
            actions += [("New Board…", #selector(newPage(_:))), ("New Folder…", #selector(newFolder(_:)))]
        } else {
            actions += [("Select for Merge", #selector(beginSidebarMerge(_:))),
                ("Turn into Folder…", #selector(convertToFolder(_:)))]
        }
        actions += [("Rename…", #selector(renameBoard(_:)))]
        for (title, selector) in actions {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = board.id.uuidString
        }
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "Delete…", action: #selector(deleteBoard(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = board.id.uuidString
        button.menu = menu
        row.addSubview(button)
        sidebarTargets.append((row, board.id, button))
        rows.addArrangedSubview(row)
        let indent = CGFloat(min(depth, 5)) * 10
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: rows.widthAnchor),
            row.heightAnchor.constraint(equalToConstant: 34),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent + 17),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: container ? -23 : -2),
        ])
        if container {
            let collapsed = collapsedWorkspaces.contains(board.id)
            let disclosure = NSButton(
                image: NSImage(
                    systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                    accessibilityDescription: (collapsed ? "Expand " : "Collapse ") + board.name)!,
                target: self, action: #selector(toggleWorkspace(_:)))
            disclosure.identifier = .init(board.id.uuidString)
            disclosure.isBordered = false
            disclosure.contentTintColor = .pasteboardMuted
            disclosure.image = disclosure.image?.withSymbolConfiguration(
                .init(pointSize: 8, weight: .semibold))
            let add = NSButton(
                image: NSImage(
                    systemSymbolName: "plus", accessibilityDescription: "New board in " + board.name)!,
                target: self, action: #selector(newPage(_:)))
            add.identifier = .init(board.id.uuidString)
            add.isBordered = false
            add.contentTintColor = .pasteboardMuted
            add.image = add.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            add.toolTip = "New board in " + board.name
            for control in [disclosure, add] {
                control.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(control)
            }
            NSLayoutConstraint.activate([
                disclosure.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
                disclosure.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                disclosure.widthAnchor.constraint(equalToConstant: 17),
                disclosure.heightAnchor.constraint(equalToConstant: 26),
                add.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                add.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                add.widthAnchor.constraint(equalToConstant: 23),
                add.heightAnchor.constraint(equalToConstant: 26),
            ])
        }
    }
    @objc func showAllReady(_ sender: Any?) {
        sidebarSelection.clear()
        canvas.finishEditing()
        canvas.cancelPointerInteraction()
        canvas.cancelCropping(nil)
        showsGlobalReady = true
        canvas.selection.removeAll()
        refresh()
        window.makeFirstResponder(overview)
    }
    func updateCount() {
        let count = store.board.cards.count
        let location =
            store.board.parentID.flatMap { id in store.workspace.boards.first(where: { $0.id == id })?.name }
            ?? "Workspace"
        let pageCount = store.workspace.pages(in: store.board.id).count
        countLabel.toolTip = store.workspace.path(for: store.board)
        countLabel.stringValue =
            "\(location)  ·  \(count) \(count == 1 ? "item" : "items")"
            + (pageCount > 0 ? "  ·  \(pageCount) pages" : "")
            + (canvas.selection.isEmpty ? "" : "  ·  \(canvas.selection.count) selected")
        if store.showsWorkspaceOverview {
            countLabel.stringValue =
                "\(store.board.parentID == nil ? "Workspace" : "Folder")  ·  \(pageCount) \(pageCount == 1 ? "board or folder" : "boards and folders")"
        }
        if showsGlobalReady {
            countLabel.stringValue = "All workspaces · \(store.allReadyPosts.count) ready posts"
        }
        let ungroup = !canvas.canGroup && canvas.canUngroup
        groupButton?.title = ungroup ? "Ungroup" : "Group"
        groupButton?.isEnabled = !showsGlobalReady && (canvas.canGroup || canvas.canUngroup)
        groupButton?.setAccessibilityLabel(ungroup ? "Ungroup selected items" : "Group selected items")
    }
    private func hoverPage(at point: CGPoint, ids: Set<UUID>) -> UUID? {
        var target: (NSView, UUID, BoardButton)?
        if let clip = sidebarScroll?.contentView, clip.bounds.contains(clip.convert(point, from: nil)) {
            target = sidebarTargets.first { row in
                row.0.bounds.contains(row.0.convert(point, from: nil))
                    && store.workspace.boards.contains(where: { $0.id == row.1 && $0.parentID != nil })
                    && store.canMoveCards(ids, from: store.board.id, to: row.1)
            }
        }
        for row in sidebarTargets { row.2.dropTarget = row.1 == target?.1 }
        if let content = window.contentView {
            let name = target.flatMap { row in store.workspace.boards.first(where: { $0.id == row.1 })?.name }
            let locked = !ids.isDisjoint(with: store.board.lockedIDs)
            transferBadge.show(
                name.map { "Move \(ids.count) items to \($0)" }
                    ?? (locked ? "Unlock items to move them" : "Choose another page"),
                at: content.convert(point, from: nil), in: content, valid: target != nil)
        }
        return target?.1
    }
    private func clearPageHover() {
        for row in sidebarTargets { row.2.dropTarget = false }
        transferBadge.removeFromSuperview()
    }
    func updateViewport() {
        let title = "\(Int((store.board.zoom * 100).rounded()))%"
        if zoomButton?.title != title {
            zoomButton?.title = title
            zoomButton?.setAccessibilityValue(title)
        }
    }
    @objc func showZoomMenu(_ sender: Any?) {
        canvas.finishEditing()
        let menu = NSMenu(title: "Zoom")
        for percent in [25, 50, 75, 100, 125, 150, 200, 400] {
            let item = menu.addItem(
                withTitle: "\(percent)%", action: #selector(chooseZoom(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = abs(canvas.zoom - Double(percent) / 100) < 0.005 ? .on : .off
        }
        menu.addItem(.separator())
        let board = menu.addItem(
            withTitle: "Fit Board", action: #selector(BoardView.fitAll(_:)), keyEquivalent: "")
        board.target = canvas
        let selection = menu.addItem(
            withTitle: "Fit Selection", action: #selector(BoardView.fitSelection(_:)), keyEquivalent: "")
        selection.target = canvas
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: zoomButton.bounds.maxY + 7), in: zoomButton)
    }
    @objc func chooseZoom(_ sender: NSMenuItem) { canvas.animateZoom(to: Double(sender.tag) / 100) }

    @objc func changeAppearance(_ sender: Any?) {
        let mode: PasteboardAppearance?
        if let item = sender as? NSMenuItem, let value = item.representedObject as? String {
            mode = PasteboardAppearance(rawValue: value)
        } else {
            mode =
                PasteboardAppearance.allCases.indices.contains(appearancePicker.indexOfSelectedItem)
                ? PasteboardAppearance.allCases[appearancePicker.indexOfSelectedItem] : nil
        }
        guard let mode else { return }
        mode.select()
        appearancePicker.selectItem(at: PasteboardAppearance.allCases.firstIndex(of: mode) ?? 0)
        window.backgroundColor = .pasteboardCanvas
        window.contentView?.needsDisplay = true
        canvas.needsDisplay = true
        window.makeFirstResponder((showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
    }

    private func targetID(_ sender: Any?) -> UUID? {
        if let button = sender as? NSButton, let value = button.identifier?.rawValue {
            return UUID(uuidString: value)
        }
        if let item = sender as? NSMenuItem, let value = item.representedObject as? String {
            return UUID(uuidString: value)
        }
        return nil
    }
    func navigate(to id: UUID) {
        sidebarSelection.clear()
        overview.setMergeSelection([], selecting: false)
        showsGlobalReady = false
        canvas.finishEditing()
        canvas.cancelCropping(nil)
        for ancestor in store.workspace.ancestors(of: id) { collapsedWorkspaces.remove(ancestor.id) }
        canvas.cancelPointerInteraction()
        canvas.selection.removeAll()
        store.activate(id)
        window.makeFirstResponder((showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
    }
    @objc func selectBoard(_ sender: NSButton) {
        if let id = targetID(sender) { activateSidebarBoard(id) }
    }
    func activateSidebarBoard(_ id: UUID, modifiers: NSEvent.ModifierFlags = []) {
        guard !store.workspace.isContainer(id),
            sidebarSelection.selecting || !modifiers.intersection([.command, .shift]).isEmpty else {
            navigate(to: id)
            return
        }
        sidebarSelection.activate(id, modifiers: modifiers, workspace: store.workspace)
        refreshSidebarSelection()
        focusSidebarBoard(id)
    }
    private func focusSidebarBoard(_ id: UUID) {
        if let button = sidebarTargets.first(where: { $0.1 == id })?.2 {
            window?.makeFirstResponder(button)
        }
    }
    private func refreshSidebarSelection() {
        sidebarSelection.reconcile(store.workspace)
        let selecting = sidebarSelection.selecting
        let ids = sidebarSelection.ids
        sidebarSelectButton.contentTintColor = selecting ? .pasteboardAccent : .pasteboardMuted
        sidebarSelectButton.setAccessibilityValue(selecting ? "Selecting boards" : "Not selecting")
        sidebarMergePanel.isHidden = !selecting
        sidebarMergeHeight?.constant = selecting ? 96 : 0
        sidebarMergePanel.title.stringValue = ids.isEmpty ? "Select boards to merge" : "\(ids.count) board\(ids.count == 1 ? "" : "s") selected"
        sidebarMergePanel.detail.stringValue = ids.count < 2 ? "Choose two or more in one folder" : "Each becomes a named section"
        sidebarMergePanel.merge.isEnabled = store.canMergeBoards(ids)
        sidebarMergePanel.merge.title = ids.count >= 2 ? "Merge \(ids.count) boards…" : "Merge boards"
        for (_, id, button) in sidebarTargets {
            let board = store.workspace.boards.first { $0.id == id }
            let eligible = !store.workspace.isContainer(id)
            button.selectedForMerge = ids.contains(id)
            button.showsMergeSelection = selecting && eligible && board?.parentID == sidebarSelection.parentID
            if let board {
                let count = eligible ? board.cards.count : store.workspace.pages(in: id).count
                button.setAccessibilityLabel(board.name + (eligible ? " board" : " folder")
                    + (ids.contains(id) ? ", selected for merge" : "") + ", \(count) \(eligible ? "items" : "boards and folders")")
                button.toolTip = store.workspace.path(for: board)
                    + (eligible ? " · ⌘-click to select for merge" : " · Right-click for options")
            }
            if let item = button.menu?.items.first(where: { $0.action == #selector(beginSidebarMerge(_:)) }) {
                item.title = ids.contains(id) ? "Deselect for Merge" : "Select for Merge"
            }
            if let previous = button.menu?.items.first(where: { $0.action == #selector(mergeSidebarBoards(_:)) }) {
                button.menu?.removeItem(previous)
            }
            if ids.contains(id), store.canMergeBoards(ids) {
                let item = NSMenuItem(title: "Merge \(ids.count) Boards…", action: #selector(mergeSidebarBoards(_:)), keyEquivalent: "")
                item.target = self
                button.menu?.insertItem(item, at: 1)
            }
        }
        if !showsGlobalReady && store.showsWorkspaceOverview {
            overview.setMergeSelection(sidebarSelection.parentID == store.board.id ? ids : [],
                selecting: selecting && sidebarSelection.parentID == store.board.id, anchor: sidebarSelection.anchor)
        }
    }
    @objc func toggleSidebarSelection(_ sender: Any?) {
        if sidebarSelection.selecting { cancelSidebarMerge(sender); return }
        let parent = store.workspace.isContainer(store.board.id) ? store.board.id : store.board.parentID
        guard let parent else { return }
        sidebarSelection.set([], parent: parent, selecting: true, workspace: store.workspace)
        refreshSidebarSelection()
        if let first = sidebarSelection.eligible(in: parent, workspace: store.workspace).first {
            focusSidebarBoard(first)
        }
    }
    @objc func beginSidebarMerge(_ sender: Any?) {
        guard let id = targetID(sender), !store.workspace.isContainer(id) else { return }
        sidebarSelection.activate(id, modifiers: .command, workspace: store.workspace)
        refreshSidebarSelection()
        focusSidebarBoard(id)
    }
    @objc func cancelSidebarMerge(_ sender: Any?) {
        sidebarSelection.clear()
        refreshSidebarSelection()
    }
    @objc func mergeSidebarBoards(_ sender: Any?) {
        sidebarSelection.reconcile(store.workspace)
        guard store.canMergeBoards(sidebarSelection.ids) else { refreshSidebarSelection(); return }
        mergePages(sidebarSelection.ids)
    }
    func handleSidebarSelectionKey(_ event: NSEvent) -> Bool {
        guard sidebarSelection.selecting else { return false }
        if event.keyCode == 53 { cancelSidebarMerge(nil); return true }
        if event.keyCode == 36 || event.keyCode == 76 { mergeSidebarBoards(nil); return true }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a",
            let parent = sidebarSelection.parentID {
            let ids = Set(sidebarSelection.eligible(in: parent, workspace: store.workspace))
            sidebarSelection.set(ids, parent: parent, selecting: true, workspace: store.workspace)
            refreshSidebarSelection()
            return true
        }
        return false
    }
    @objc func toggleWorkspace(_ sender: NSButton) {
        guard let id = targetID(sender) else { return }
        if !collapsedWorkspaces.insert(id).inserted { collapsedWorkspaces.remove(id) }
        refresh()
    }
    private func ensureCanvasPage() {
        if showsGlobalReady {
            showsGlobalReady = false
            refresh()
        }
        guard store.showsWorkspaceOverview else { return }
        if let id = store.newPage(in: store.board.id, name: "Untitled page") { navigate(to: id) }
    }
    @objc func addNote(_ sender: Any?) {
        ensureCanvasPage()
        canvas.addText(sender)
    }
    @objc func addColour(_ sender: Any?) {
        ensureCanvasPage()
        canvas.addColourSwatch(sender)
    }
    @objc func toggleGrouping(_ sender: Any?) {
        if canvas.canGroup { canvas.groupSelection(sender) } else { canvas.ungroupSelection(sender) }
        window.makeFirstResponder((showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
    }
    @objc func pasteToBoard(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            text.paste(sender)
        } else {
            ensureCanvasPage()
            window.makeFirstResponder((showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
            canvas.paste(sender)
        }
    }
    @objc func importImages(_ sender: Any?) {
        canvas.finishEditing()
        let panel = NSOpenPanel()
        panel.title = "Add to your board"
        panel.prompt = "Add to Board"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .image, .movie, .video, .svg, .plainText, UTType(filenameExtension: "gatherboard") ?? .data,
        ]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK else { return }
            if panel.urls.contains(where: { $0.pathExtension.lowercased() != "gatherboard" }) {
                self.ensureCanvasPage()
            }
            self.canvas.importFiles(panel.urls)
        }
    }
    @objc func newBoard(_ sender: Any?) {
        canvas.finishEditing()
        canvas.cancelCropping(nil)
        askName(title: "New workspace", initial: "Untitled workspace", button: "Create Workspace") {
            [weak self] name in
            self?.showsGlobalReady = false
            self?.store.newBoard(name: name)
        }
    }
    private func insertionParent(_ sender: Any?) -> Board? {
        guard
            let target = store.workspace.boards.first(where: { $0.id == (targetID(sender) ?? store.board.id) }
            )
        else { return nil }
        if store.workspace.isContainer(target.id) { return target }
        return store.workspace.boards.first { $0.id == target.parentID }
    }
    @objc func newPage(_ sender: Any?) {
        canvas.finishEditing()
        canvas.cancelCropping(nil)
        guard let parent = insertionParent(sender) else { return }
        askName(title: "New board in “\(parent.name)”", initial: "Untitled board", button: "Create Board") {
            [weak self] name in
            guard let self else { return }
            showsGlobalReady = false
            collapsedWorkspaces.remove(parent.id)
            if let id = store.newPage(in: parent.id, name: name) { navigate(to: id) }
        }
    }
    @objc func newFolder(_ sender: Any?) {
        canvas.finishEditing()
        canvas.cancelCropping(nil)
        guard let parent = insertionParent(sender) else { return }
        askName(title: "New folder in “\(parent.name)”", initial: "Untitled folder", button: "Create Folder")
        { [weak self] name in
            guard let self, let id = store.newFolder(in: parent.id, name: name) else { return }
            navigate(to: id)
        }
    }
    @objc func goToParent(_ sender: Any?) {
        if !showsGlobalReady, let parent = store.board.parentID { navigate(to: parent) }
    }
    @objc func convertToFolder(_ sender: Any?) {
        guard socialWindow?.flush() != false else { return }
        canvas.finishEditing()
        canvas.cancelPointerInteraction()
        canvas.cancelCropping(nil)
        let id = targetID(sender) ?? store.board.id
        guard !canvas.hasPendingImports, let board = store.workspace.boards.first(where: { $0.id == id }),
            board.parentID != nil, board.isFolder != true
        else { return }
        let alert = NSAlert()
        alert.messageText = "Turn “\(board.name)” into a folder?"
        alert.informativeText =
            "Its existing items will stay together in a board inside the folder. You can then add more design boards and merge them into sections. A local backup is saved first."
        alert.addButton(withTitle: "Create Folder")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            store.convertToFolder(id) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: navigate(to: id)
                case .failure(let error): canvas.showError(error)
                }
            }
        }
    }
    private func mergePages(_ ids: Set<UUID>) {
        guard socialWindow?.flush() != false else { return }
        canvas.finishEditing()
        canvas.cancelPointerInteraction()
        canvas.cancelCropping(nil)
        guard store.canMergeBoards(ids) else { return }
        guard !canvas.hasPendingImports else {
            let alert = NSAlert()
            alert.messageText = "Media is still importing"
            alert.informativeText =
                "Let the import finish before merging so the new board includes every item."
            alert.beginSheetModal(for: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge \(ids.count) boards"
        alert.informativeText =
            "Each board becomes a named section on one canvas. The originals are replaced by the merged board. You can undo the merge; a local backup is saved first."
        alert.addButton(withTitle: "Merge Boards")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "Combined designs")
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 26)
        field.setAccessibilityLabel("Merged board name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                let name = BoardStore.cleanName(field.stringValue), !canvas.hasPendingImports
            else { return }
            store.status?("Backing up and merging boards…")
            store.mergeBoards(ids, name: name) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let id):
                    navigate(to: id)
                    canvas.fitAll(nil)
                    store.status?("\(ids.count) boards merged · click a section name to zoom in")
                case .failure(let error): canvas.showError(error)
                }
            }
        }
    }
    @objc func renameBoard(_ sender: Any?) {
        guard !showsGlobalReady || targetID(sender) != nil else { return }
        rename(id: targetID(sender) ?? store.board.id)
    }
    func rename(id: UUID) {
        canvas.finishEditing()
        guard let board = store.workspace.boards.first(where: { $0.id == id }) else { return }
        askName(
            title: board.parentID == nil
                ? "Rename workspace" : board.isFolder == true ? "Rename folder" : "Rename board",
            initial: board.name,
            button: "Rename"
        ) { [weak self] name in self?.store.renameBoard(id, name: name) }
    }
    func askName(title: String, initial: String, button: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = CGRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !name.isEmpty { completion(String(name.prefix(100))) }
        }
    }
    @objc func deleteBoard(_ sender: Any?) {
        canvas.finishEditing()
        guard !canvas.hasPendingImports else {
            let alert = NSAlert()
            alert.messageText = "Media is still importing"
            alert.informativeText =
                "Let the import finish, then delete the workspace or page. This lets its backup include every imported file."
            alert.beginSheetModal(for: window)
            return
        }
        let id = targetID(sender) ?? store.board.id
        guard let board = store.workspace.boards.first(where: { $0.id == id }) else { return }
        let scope = store.deletionScope(for: id)
        let pages = max(0, scope.count - 1)
        let items = scope.reduce(0) { $0 + $1.cards.count }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "Delete \(board.parentID == nil ? "workspace" : board.isFolder == true ? "folder" : "board") “\(board.name)”?"
        let pageDescription =
            pages > 0
            ? " and its \(pages) nested \(pages == 1 ? "board or folder" : "boards and folders")" : ""
        alert.informativeText =
            "This removes the \(board.parentID == nil ? "workspace" : board.isFolder == true ? "folder" : "board")\(pageDescription), containing \(items) \(items == 1 ? "item" : "items"). A local backup is saved first. You can restore it from Local backups in the sidebar."
        let remove = alert.addButton(
            withTitle: board.parentID == nil
                ? "Delete Workspace" : board.isFolder == true ? "Delete Folder" : "Delete Board")
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            store.deleteBoardWithBackup(id) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    canvas.showError(error)
                    return
                }
                store.status?(
                    "\(board.parentID == nil ? "Workspace" : board.isFolder == true ? "Folder" : "Board") deleted · saved in Local backups"
                )
            }
        }
    }
    @objc func exportBoard(_ sender: Any?) {
        canvas.finishEditing()
        let panel = NSSavePanel()
        panel.title =
            store.workspace.isContainer(store.board.id) ? "Save folder and boards" : "Save a portable board"
        panel.nameFieldStringValue = store.board.name + ".gatherboard"
        panel.allowedContentTypes = [UTType(filenameExtension: "gatherboard") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                try store.portableData().write(to: url, options: .atomic)
                store.status?("Board copy saved")
            } catch { canvas.showError(error) }
        }
    }
    @objc func zoomIn(_ sender: Any?) { canvas.animateZoom(to: canvas.requestedZoom * 1.2) }
    @objc func showSearch(_ sender: Any?) {
        canvas.finishEditing()
        if searchWindow == nil {
            searchWindow = SearchWindowController(store: store)
            searchWindow?.openResult = { [weak self] result in
                guard let self else { return }
                navigate(to: result.boardID)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(
                    (showsGlobalReady || store.showsWorkspaceOverview) ? overview : canvas)
                if let section = result.sectionID {
                    canvas.zoomToSection(section)
                } else if let id = result.cardID {
                    canvas.focusCards([id])
                } else {
                    canvas.fitAll(nil)
                }
            }
        }
        searchWindow?.present()
    }
    @objc func showBackups(_ sender: Any?) {
        canvas.finishEditing()
        if backupsWindow == nil { backupsWindow = BackupsWindowController(store: store) }
        backupsWindow?.present()
    }
    @objc func exportPNG(_ sender: Any?) { exportArtwork(pdf: false) }
    @objc func exportPDF(_ sender: Any?) { exportArtwork(pdf: true) }
    func exportArtwork(pdf: Bool) {
        canvas.finishEditing()
        let panel = NSSavePanel()
        panel.title = pdf ? "Export PDF" : "Export PNG"
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        panel.nameFieldStringValue = store.board.name + (pdf ? ".pdf" : ".png")
        let scope = NSPopUpButton()
        scope.addItems(withTitles: ["Whole canvas", "Selected items"])
        scope.selectItem(at: canvas.selection.isEmpty ? 0 : 1)
        scope.menu?.autoenablesItems = false
        scope.item(at: 1)?.isEnabled = !canvas.selection.isEmpty
        let scale = NSPopUpButton()
        scale.addItems(withTitles: ["1× size", "2× size"])
        let transparent = NSButton(checkboxWithTitle: "Transparent background", target: nil, action: nil)
        transparent.state = .on
        let accessories = NSStackView(views: pdf ? [scope, transparent] : [scope, scale, transparent])
        accessories.orientation = .vertical
        accessories.alignment = .leading
        accessories.spacing = 8
        panel.accessoryView = accessories
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            let cards =
                scope.indexOfSelectedItem == 1
                ? store.board.cards.filter { self.canvas.selection.contains($0.id) } : store.board.cards
            let export = BoardExport(cards: cards, assets: store.directory.appendingPathComponent("Assets"))
            let alpha = transparent.state == .on
            let factor: CGFloat = scale.indexOfSelectedItem == 1 ? 2 : 1
            store.status?("Exporting…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data =
                        try pdf
                        ? export.pdf(transparent: alpha) : export.png(scale: factor, transparent: alpha)
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async { self.store.status?("\(pdf ? "PDF" : "PNG") exported") }
                } catch { DispatchQueue.main.async { self.canvas.showError(error) } }
            }
        }
    }
    @objc func zoomOut(_ sender: Any?) { canvas.animateZoom(to: canvas.requestedZoom / 1.2) }
    @objc func resetZoom(_ sender: Any?) { canvas.animateZoom(to: 1) }
    @objc func toggleMinimap(_ sender: Any?) {
        canvas.minimapEnabled.toggle()
        UserDefaults.standard.set(canvas.minimapEnabled, forKey: "ShowMinimap")
    }
    @objc func toggleSnapping(_ sender: Any?) {
        canvas.snappingEnabled.toggle()
        UserDefaults.standard.set(canvas.snappingEnabled, forKey: "SnapToObjects")
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if showsGlobalReady, menuItem.representedObject == nil, let action = menuItem.action,
            [
                #selector(renameBoard(_:)), #selector(deleteBoard(_:)), #selector(newPage(_:)),
                #selector(newFolder(_:)), #selector(convertToFolder(_:)),
            ].contains(action)
        {
            return false
        }
        if let action = menuItem.action,
            [#selector(exportPNG(_:)), #selector(exportPDF(_:)), #selector(exportBoard(_:))].contains(action)
        {
            if showsGlobalReady { return false }
            if action != #selector(exportBoard(_:)), store.showsWorkspaceOverview { return false }
        }
        if menuItem.action == #selector(goToParent(_:)) {
            return !showsGlobalReady && store.board.parentID != nil
        }
        if menuItem.action == #selector(convertToFolder(_:)) {
            let id = targetID(menuItem) ?? store.board.id
            guard let board = store.workspace.boards.first(where: { $0.id == id }) else { return false }
            return !canvas.hasPendingImports && !store.workspace.isContainer(board.id)
        }
        if menuItem.action == #selector(changeAppearance(_:)) {
            menuItem.state =
                (menuItem.representedObject as? String) == PasteboardAppearance.current.rawValue ? .on : .off
        }
        if menuItem.action == #selector(toggleMinimap(_:)) {
            menuItem.state = canvas.minimapEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleSnapping(_:)) {
            menuItem.state = canvas.snappingEnabled ? .on : .off
        }
        if menuItem.action == #selector(renameBoard(_:)), menuItem.representedObject == nil {
            menuItem.title =
                store.board.parentID == nil
                ? "Rename Workspace…" : store.board.isFolder == true ? "Rename Folder…" : "Rename Board…"
        }
        if menuItem.action == #selector(deleteBoard(_:)), menuItem.representedObject == nil {
            menuItem.title =
                store.board.parentID == nil
                ? "Delete Workspace…" : store.board.isFolder == true ? "Delete Folder…" : "Delete Board…"
        }
        return true
    }
    @objc func undo(_ sender: Any?) {
        if canvas.isCropping {
            canvas.cancelCropping(nil)
            return
        }
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.firstResponder?.undoManager?.undo()
        } else if let editor = window.firstResponder as? NSTextView {
            editor.undoManager?.undo()
        } else {
            store.history.undo()
        }
    }
    @objc func redo(_ sender: Any?) {
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.firstResponder?.undoManager?.redo()
        } else if let editor = window.firstResponder as? NSTextView {
            editor.undoManager?.redo()
        } else {
            store.history.redo()
        }
    }
    @objc func saveNow(_ sender: Any?) {
        guard socialWindow?.flush() != false else { return }
        canvas.finishEditing()
        store.save()
    }
    private func openSocialPost(boardID: UUID, anchorID: UUID) {
        guard socialWindow?.flush() != false,
            let post = store.socialPost(boardID: boardID, anchorID: anchorID)
        else { return }
        socialWindow?.close()
        socialWindow = SocialPreviewWindow(store: store, post: post)
        socialWindow?.onShowBoard = { [weak self] board, ids in
            guard let self else { return }
            navigate(to: board)
            canvas.selection = ids
            canvas.fitSelection(nil)
            canvas.needsDisplay = true
            window.makeKeyAndOrderFront(nil)
        }
        socialWindow?.present()
    }
    @objc func showWindow(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }
    @objc func showUpdates(_ sender: Any?) {
        canvas.finishEditing()
        if updatesWindow == nil {
            updatesWindow = UpdatesWindowController(
                installed: installedRelease, stateDirectory: store.directory)
            updatesWindow?.prepareForRelaunch = { [weak self] in
                guard let self, !canvas.hasPendingImports else { return false }
                return saveBeforeLeaving()
            }
        }
        updatesWindow?.present()
    }
    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Make yourself some space."
        alert.informativeText =
            "⌘N  New workspace\n⇧⌘N  New board in the current folder\nClick + beside a workspace or folder  Add a board\nFile → New Folder  Organise boards inside folders\nRight-click a board → Turn into Folder  Keep its items in an inner board\n⌘-click sidebar boards / right-click → Select for Merge\nShift-click  Select a range in one folder\nMerge boards in the sidebar or overview  Combine designs as named sections\nEsc / Done  Leave board selection\nClick a section title / Sections menu  Zoom into a design\n⌘[  Back to parent folder\nDouble-click a sidebar name or right-click → Rename\nRight-click a workspace or page → Delete\nLocal backups  Restore deleted content\nClick a workspace chevron  Collapse / expand pages\nDrag images, notes, or a group onto a sidebar page  Move them\n⌘Z / ⇧⌘Z  Undo / redo across pages\nApp updates → Update and Relaunch  Install the latest local build\n\nS / Colour  Add a colour swatch with a visible HEX code\nDouble-click a swatch  Edit its colour\nRight-click a swatch → Copy HEX\n\n⌘V  Paste images, SVG artwork/markup, or text\n⌘O  Add images, videos or text files\nPlay button / double-click video  Open the player\nPaste a YouTube link  Add a playable video card\nReady to post at top of sidebar  All marked images across workspaces\nT / double-click blank space  Add a note\nDouble-click a note  Edit its text\nEsc / click outside a note  Finish editing\nSpace + drag / two-finger scroll  Pan\nPinch / ⌘ + or −  Zoom\nTab / ⇧Tab  Focus next / previous item or group\nMinimap  Click to jump; drag the view to pan\nView → Show Minimap  Show / hide the overview\n⌘0  Fit everything\nEdges, centres, and equal gaps snap while dragging\nOption while dragging  Temporarily bypass snapping\nView → Snap to Objects  Turn snapping on or off\nShift-click / drag empty space  Select items\n⌘G / ⇧⌘G  Group / ungroup selection\nDrag a group corner  Scale images, notes, text, and spacing together\n⌘D  Duplicate selection\nDelete  Remove selection\n⌘Z / ⇧⌘Z  Undo / redo\nRight-click a note  Change its colour\n\nDouble-click an image / ⇧⌘C  Crop image\nDrag crop edges or corners; drag inside to reposition\nReturn / Esc  Apply / cancel crop\nEdit → Reset Image Crop  Restore the original\n⇧⌘L  Lock / unlock selection\n⌘F  Search notes, boards, sources and text in images\n⇧⌘E  Export PNG (selection or whole board)\nFile → Export PDF  Export a single-page PDF\nRight-click → Edit Source Link / Open Source\nSidebar → Local backups  Back up or restore as new boards\n\nEverything saves locally. Automatic checkpoints include images. File → Export Board Copy creates a portable backup containing the images too."
        alert.beginSheetModal(for: window)
    }
    @objc func runSelfCheck(_ sender: Any?) {
        let alert = NSAlert()
        do {
            try selfTest()
            if let log = Bundle.main.object(forInfoDictionaryKey: "GatherTestingLog") as? String {
                try? "PASS: all native checks\n".write(toFile: log, atomically: true, encoding: .utf8)
            }
            alert.messageText = "All checks passed"
            alert.informativeText =
                "Verified minimap click/drag, viewport projection and page-switch cancellation; Tab/Shift-Tab navigation, grouped focus and offscreen reveal; SVG clipboard/file import, transparent scalable previews, cropping and vector PDF; colour swatches, HEX values, readable labels and exports; backed-up workspace/page deletion, failure protection and restoration; sidebar transfers, cross-page undo/redo, update staging and rollback; workspace/page creation, independent canvases, renaming, search paths, export/import and backup hierarchy; image crop handles, movement, reset, undo, crop persistence and transparent exports; locking, local search and screenshot OCR, source links, transparent PNG paste and export, PDF export, backup restoration, grouping, snapping, spacing, zoom, undo, saving, and imports. Checks use temporary boards; your boards are untouched."
        } catch {
            if let log = Bundle.main.object(forInfoDictionaryKey: "GatherTestingLog") as? String {
                try? ("FAIL: " + error.localizedDescription).write(
                    toFile: log, atomically: true, encoding: .utf8)
            }
            alert.messageText = "A check needs attention"
            alert.informativeText = error.localizedDescription
        }
        alert.beginSheetModal(for: window)
    }
    func makeMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let sub = NSMenu(title: title)
            item.submenu = sub
            main.addItem(item)
            return sub
        }
        @discardableResult func item(
            _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
            _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
        ) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        let app = menu("Pasteboard")
        item(
            app, "About Pasteboard", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        item(app, "Check for Updates…", #selector(showUpdates(_:)), target: self)
        app.addItem(.separator())
        item(app, "Hide Pasteboard", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(
            app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option],
            target: NSApp)
        app.addItem(.separator())
        item(app, "Quit Pasteboard", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("File")
        item(file, "New Workspace…", #selector(newBoard(_:)), "n", target: self)
        item(file, "New Board…", #selector(newPage(_:)), "n", [.command, .shift], target: self)
        item(file, "New Folder…", #selector(newFolder(_:)), target: self)
        item(file, "Turn Board into Folder…", #selector(convertToFolder(_:)), target: self)
        item(file, "Rename…", #selector(renameBoard(_:)), target: self)
        item(file, "Delete…", #selector(deleteBoard(_:)), target: self)
        file.addItem(.separator())
        item(file, "Add Images, Videos or Open Board…", #selector(importImages(_:)), "o", target: self)
        item(file, "Add Colour Swatch…", #selector(addColour(_:)), target: self)
        item(file, "Save Now", #selector(saveNow(_:)), "s", target: self)
        item(file, "Export PNG…", #selector(exportPNG(_:)), "e", [.command, .shift], target: self)
        item(file, "Export PDF…", #selector(exportPDF(_:)), target: self)
        item(
            file, "Export Workspace or Page Copy…", #selector(exportBoard(_:)), "s", [.command, .shift],
            target: self)
        item(file, "Local Backups…", #selector(showBackups(_:)), target: self)
        file.addItem(.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        item(edit, "Undo", #selector(undo(_:)), "z", target: self)
        item(edit, "Redo", #selector(redo(_:)), "z", [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        item(edit, "Duplicate", #selector(BoardView.duplicate(_:)), "d", target: canvas)
        item(edit, "Play Video…", #selector(BoardView.playVideo(_:)), target: canvas)
        item(edit, "Mark Ready to Post…", #selector(BoardView.markReadyToPost(_:)), target: canvas)
        item(edit, "Preview Social Post…", #selector(BoardView.previewSocialPost(_:)), target: canvas)
        item(edit, "Unmark Ready to Post", #selector(BoardView.unmarkReadyToPost(_:)), target: canvas)
        item(edit, "Recolour SVG…", #selector(BoardView.recolourSVG(_:)), target: canvas)
        item(edit, "Edit Colour Swatch…", #selector(BoardView.editColourSwatch(_:)), target: canvas)
        item(edit, "Copy HEX", #selector(BoardView.copyHex(_:)), target: canvas)
        edit.addItem(.separator())
        item(edit, "Group", #selector(BoardView.groupSelection(_:)), "g", target: canvas)
        item(
            edit, "Ungroup", #selector(BoardView.ungroupSelection(_:)), "g", [.command, .shift],
            target: canvas)
        item(
            edit, "Crop Image…", #selector(BoardView.cropImage(_:)), "c", [.command, .shift], target: canvas)
        item(edit, "Reset Image Crop", #selector(BoardView.resetImageCrop(_:)), target: canvas)
        item(
            edit, "Lock Selection", #selector(BoardView.toggleLock(_:)), "l", [.command, .shift],
            target: canvas)
        edit.addItem(.separator())
        item(edit, "Edit Source Link…", #selector(BoardView.editSource(_:)), target: canvas)
        item(edit, "Open Source", #selector(BoardView.openSource(_:)), target: canvas)
        item(edit, "Search Boards…", #selector(showSearch(_:)), "f", target: self)
        let arrangeItem = NSMenuItem()
        arrangeItem.submenu = canvas.arrangementMenu()
        main.addItem(arrangeItem)
        let view = menu("View")
        item(view, "Back to Parent Folder", #selector(goToParent(_:)), "[", target: self)
        view.addItem(.separator())
        let appearance = NSMenu(title: "Appearance")
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        view.addItem(appearanceItem)
        for mode in PasteboardAppearance.allCases {
            let option = item(appearance, mode.title, #selector(changeAppearance(_:)), target: self)
            option.representedObject = mode.rawValue
        }
        view.addItem(.separator())
        item(view, "Show Minimap", #selector(toggleMinimap(_:)), target: self)
        view.addItem(.separator())
        item(view, "Zoom In", #selector(zoomIn(_:)), "=", target: self)
        item(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        item(view, "Actual Size", #selector(resetZoom(_:)), "1", target: self)
        item(view, "Fit Board", #selector(BoardView.fitAll(_:)), "0", target: canvas)
        item(
            view, "Fit Selection", #selector(BoardView.fitSelection(_:)), "0", [.command, .shift],
            target: canvas)
        view.addItem(.separator())
        item(view, "Snap to Objects", #selector(toggleSnapping(_:)), target: self)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let windowMenu = menu("Window")
        item(windowMenu, "Show Pasteboard", #selector(showWindow(_:)), target: self)
        item(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = windowMenu
        let help = menu("Help")
        item(help, "Pasteboard Shortcuts", #selector(showHelp(_:)), "?", target: self)
        item(help, "About This Preview…", #selector(showPreviewNotice(_:)), target: self)
        item(help, "Check for Updates…", #selector(showUpdates(_:)), target: self)
        item(help, "Run Self-Check", #selector(runSelfCheck(_:)), target: self)
        NSApp.mainMenu = main
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.finishEditing()
        return saveBeforeLeaving()
    }
    func windowDidResignKey(_ notification: Notification) { canvas.deactivateInteraction() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        canvas.finishEditing()
        if canvas.hasPendingImports {
            statusLabel.stringValue = "Finishing media import…"
            terminationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                if !canvas.hasPendingImports {
                    timer.invalidate()
                    terminationTimer = nil
                    sender.reply(toApplicationShouldTerminate: saveBeforeLeaving())
                }
            }
            return .terminateLater
        }
        return saveBeforeLeaving() ? .terminateNow : .terminateCancel
    }
    func saveBeforeLeaving() -> Bool {
        guard socialWindow?.flush() != false else { return false }
        canvas.cancelPointerInteraction()
        canvas.cancelCropping(nil)
        store.backupNow()
        if store.save() { return true }
        let alert = NSAlert()
        alert.messageText = "Your latest changes haven’t saved."
        alert.informativeText = "Keep Pasteboard open and use File → Export Board Copy to save a backup."
        alert.addButton(withTitle: "Keep Open")
        alert.runModal()
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        canvas.importFiles(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
}

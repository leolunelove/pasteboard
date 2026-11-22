import AppKit

final class SearchWindowController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    let store: BoardStore
    let field = NSSearchField()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    var results: [BoardSearchResult] = []
    var openResult: ((BoardSearchResult) -> Void)?
    init(store: BoardStore) {
        self.store = store
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 490),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Search workspaces and pages"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        let root = window.contentView!
        field.placeholderString = "Notes, text in images, pages, or source links"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 55
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(choose(_:))
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let open = NSButton(title: "Go to Item", target: self, action: #selector(choose(_:)))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        for view in [field, scroll, status, open] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -16),
            open.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -8),
        ])
        store.searchIndex.onChanged = { [weak self] in self?.reload() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        reload()
    }
    func reload() {
        guard window?.isVisible == true else { return }
        store.searchIndex.index(store.workspace)
        results = BoardSearch.results(
            in: store.workspace, imageText: store.searchIndex.text, query: field.stringValue)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let pending = store.searchIndex.pendingCount
        status.stringValue =
            pending > 0
            ? "Reading text in \(pending) images on this Mac…"
            : field.stringValue.isEmpty
                ? "Search all workspaces and pages. Images stay local."
                : "\(results.count) results"
                    + (store.searchIndex.failures > 0 ? " · Some image text unavailable" : "")
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = results[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: result.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: result.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
        ])
        return cell
    }
    @objc func choose(_ sender: Any?) {
        guard results.indices.contains(table.selectedRow) else { return }
        let result = results[table.selectedRow]
        window?.orderOut(nil)
        openResult?(result)
    }
}

final class BackupsWindowController: NSWindowController {
    let store: BoardStore
    let choices = NSPopUpButton()
    let detail = NSTextField(wrappingLabelWithString: "")
    let restore = NSButton(title: "Restore as New Workspaces", target: nil, action: nil)
    let create = NSButton(title: "Back Up Now", target: nil, action: nil)
    var records: [BackupRecord] = []
    init(store: BoardStore) {
        self.store = store
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Local backups"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = window.contentView!
        let intro = NSTextField(
            wrappingLabelWithString:
                "Pasteboard keeps local checkpoints as you work, up to once every five minutes when content changes. Images are included. Restoring adds new workspaces with their pages and keeps your current work."
        )
        let retention = NSTextField(
            wrappingLabelWithString:
                "Keeps 40 recent checkpoints, plus daily checkpoints for 14 days. Backups are stored on this Mac."
        )
        retention.font = .systemFont(ofSize: 11)
        retention.textColor = .secondaryLabelColor
        choices.target = self
        choices.action = #selector(selected(_:))
        restore.target = self
        restore.action = #selector(restoreSelected(_:))
        restore.bezelStyle = .rounded
        create.target = self
        create.action = #selector(createBackup(_:))
        create.bezelStyle = .rounded
        let folder = NSButton(title: "Show Folder", target: self, action: #selector(showFolder(_:)))
        folder.bezelStyle = .rounded
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        for view in [intro, choices, detail, retention, restore, create, folder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            choices.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            choices.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            choices.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 20),
            detail.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            detail.topAnchor.constraint(equalTo: choices.bottomAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            retention.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            retention.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            retention.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 16),
            restore.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            restore.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            create.trailingAnchor.constraint(equalTo: restore.leadingAnchor, constant: -8),
            create.centerYAnchor.constraint(equalTo: restore.centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            folder.centerYAnchor.constraint(equalTo: restore.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }
    func reload() {
        records = store.backups.records()
        choices.removeAllItems()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        for record in records { choices.addItem(withTitle: formatter.string(from: record.created)) }
        choices.isEnabled = !records.isEmpty
        restore.isEnabled = !records.isEmpty
        if records.isEmpty { choices.addItem(withTitle: "No checkpoints yet") }
        selected(nil)
    }
    @objc func selected(_ sender: Any?) {
        detail.stringValue =
            records.indices.contains(choices.indexOfSelectedItem)
            ? "\(records[choices.indexOfSelectedItem].boardCount) canvases · \(records[choices.indexOfSelectedItem].itemCount) items · images included"
            : "Your first checkpoint is created automatically when you save."
    }
    func busy(_ value: Bool) {
        create.isEnabled = !value
        restore.isEnabled = !value && !records.isEmpty
    }
    @objc func createBackup(_ sender: Any?) {
        busy(true)
        store.backupNow { [weak self] error in
            guard let self else { return }
            busy(false)
            reload()
            if case .failure(let error) = error { NSAlert(error: error).beginSheetModal(for: window!) }
        }
    }
    @objc func restoreSelected(_ sender: Any?) {
        guard records.indices.contains(choices.indexOfSelectedItem) else { return }
        busy(true)
        store.restoreBackup(records[choices.indexOfSelectedItem]) { [weak self] error in
            guard let self else { return }
            busy(false)
            reload()
            if case .failure(let error) = error {
                NSAlert(error: error).beginSheetModal(for: window!)
            } else {
                detail.stringValue = "Restored as new workspaces and pages. Current work was kept."
            }
        }
    }
    @objc func showFolder(_ sender: Any?) {
        if FileManager.default.fileExists(atPath: store.backups.folder.path) {
            NSWorkspace.shared.open(store.backups.folder)
        } else {
            NSWorkspace.shared.open(store.directory)
        }
    }
}

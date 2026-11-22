import AppKit

struct InstalledRelease {
    let version: String
    let build: Int
    let feedURL: URL?
    let folderURL: URL?
    let bundleURL: URL
    let identifier: String
    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        feedURL = ((bundle.object(forInfoDictionaryKey: "PasteboardUpdateFeedURL") ?? bundle.object(forInfoDictionaryKey: "GatherUpdateFeedURL")) as? String).flatMap(URL.init(string:))
        folderURL = ((bundle.object(forInfoDictionaryKey: "PasteboardReleaseURL") ?? bundle.object(forInfoDictionaryKey: "GatherUpdateFolderURL")) as? String).flatMap(URL.init(string:))
        bundleURL = bundle.bundleURL; identifier = bundle.bundleIdentifier ?? "fun.leolune.gather"
    }
}

struct LocalRelease: Codable {
    let formatVersion: Int
    let version: String
    let build: Int
    let appURL: String
    let archiveURL: String
    let releasedAt: String
    let notes: [String]
    var installURL: String?
    var sha256: String? = nil
    var archiveBytes: Int? = nil
    var architecture: String? = nil
    var isRemote: Bool { URL(string: archiveURL)?.scheme == "https" }
    enum Availability { case update, current, newerInstalled }
    func availability(installedBuild: Int) -> Availability { build > installedBuild ? .update : build == installedBuild ? .current : .newerInstalled }
    static func decode(_ data: Data) throws -> LocalRelease {
        let release = try JSONDecoder().decode(LocalRelease.self, from: data)
        guard release.formatVersion == 1, release.build > 0, !release.version.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        if release.isRemote { try GitHubUpdates.validate(release); return release }
        guard let app = URL(string: release.appURL), app.isFileURL, app.pathExtension.lowercased() == "app",
              let archive = URL(string: release.archiveURL), archive.isFileURL, archive.pathExtension.lowercased() == "zip" else { throw CocoaError(.fileReadCorruptFile) }
        if let value = release.installURL { guard let url = URL(string: value), url.isFileURL, url.pathExtension.lowercased() == "app" else { throw CocoaError(.fileReadCorruptFile) } }
        return release
    }
    static func read(at url: URL) throws -> LocalRelease {
        if url == GitHubUpdates.feedURL {
            let release = try decode(ReleaseTransport.fetch(url, maxBytes: 1_048_576))
            guard release.isRemote else { throw CocoaError(.fileReadCorruptFile) }
            return release
        }
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try decode(Data(contentsOf: url))
    }
}

final class UpdatesWindowController: NSWindowController {
    private let installed: InstalledRelease
    private let latestLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let notesLabel = NSTextField(wrappingLabelWithString: "")
    private let checkedLabel = NSTextField(labelWithString: "")
    private var checkButton: NSButton!
    private var appButton: NSButton!
    private var archiveButton: NSButton!
    private var latest: LocalRelease?
    private var checkID = UUID()
    private var timeout: Timer?
    private let stateDirectory: URL
    var prepareForRelaunch: (() -> Bool)?
    private var installButton: NSButton!
    private var installing = false
    private var remoteChannel: Bool { installed.feedURL == GitHubUpdates.feedURL }

    init(installed: InstalledRelease, stateDirectory: URL) {
        self.installed = installed; self.stateDirectory = stateDirectory
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pasteboard Updates"; window.isReleasedWhenClosed = false; window.backgroundColor = .pasteboardCanvas
        super.init(window: window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)])
        let heading = NSTextField(labelWithString: "App updates"); heading.font = .systemFont(ofSize: 24, weight: .semibold); heading.textColor = .pasteboardInk
        let current = NSTextField(labelWithString: "Installed: Pasteboard \(installed.version) · build \(installed.build)"); current.font = .systemFont(ofSize: 13); current.textColor = .pasteboardMuted
        latestLabel.font = .systemFont(ofSize: 16, weight: .semibold); latestLabel.textColor = .pasteboardInk
        for label in [messageLabel, notesLabel] { label.font = .systemFont(ofSize: 12); label.textColor = .pasteboardInk; label.preferredMaxLayoutWidth = 504 }
        checkedLabel.font = .systemFont(ofSize: 10); checkedLabel.textColor = .pasteboardMuted
        let channel = NSTextField(wrappingLabelWithString: remoteChannel ? "GitHub releases · downloads are checked before your app is replaced." : "Local release channel · checks the builds created for this Mac.")
        channel.font = .systemFont(ofSize: 11); channel.textColor = .pasteboardMuted; channel.preferredMaxLayoutWidth = 504
        checkButton = NSButton(title: "Check Again", target: self, action: #selector(check(_:)))
        appButton = NSButton(title: remoteChannel ? "Release Notes" : "Show Latest App", target: self, action: #selector(showLatestApp(_:)))
        archiveButton = NSButton(title: remoteChannel ? "Download ZIP" : "Show ZIP", target: self, action: #selector(showArchive(_:)))
        installButton = NSButton(title: "Update and Relaunch", target: self, action: #selector(installUpdate(_:))); installButton.bezelStyle = .rounded; installButton.controlSize = .large; installButton.bezelColor = .pasteboardAccent; installButton.contentTintColor = .white; installButton.isEnabled = false
        let buttons = NSStackView(views: [checkButton, appButton, archiveButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        for button in [checkButton!, appButton!, archiveButton!] { button.bezelStyle = .rounded; button.controlSize = .large }
        let folderButton = NSButton(title: remoteChannel ? "View on GitHub" : "Open update folder", target: self, action: #selector(showFolder(_:))); folderButton.isBordered = false; folderButton.contentTintColor = .pasteboardAccent
        folderButton.isEnabled = installed.folderURL != nil
        for view in [heading, current, latestLabel, messageLabel, notesLabel, installButton!, buttons, folderButton, checkedLabel, channel] { stack.addArrangedSubview(view) }
        for label in [messageLabel, notesLabel, channel] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); check(nil) }
    @objc private func check(_ sender: Any?) {
        guard !installing else { return }
        installButton.isEnabled = false
        timeout?.invalidate(); checkID = UUID(); let requestID = checkID
        checkButton.isEnabled = false; appButton.isEnabled = false; archiveButton.isEnabled = false; latest = nil
        latestLabel.stringValue = remoteChannel ? "Checking GitHub releases…" : "Checking local releases…"; messageLabel.stringValue = ""; notesLabel.stringValue = ""; checkedLabel.stringValue = ""
        guard let feed = installed.feedURL, feed.isFileURL || remoteChannel else { showUnavailable(); return }
        let cache = stateDirectory.appendingPathComponent(remoteChannel ? "LastCheckedGitHubRelease.json" : "LastCheckedRelease.json")
        let timer = Timer(timeInterval: remoteChannel ? 20 : 4, repeats: false) { [weak self] _ in
            guard let self, self.checkID == requestID else { return }
            self.checkID = UUID(); self.showUnavailable()
        }
        timeout = timer; RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(LocalRelease, Bool), Error> = Result {
                do {
                    let release = try LocalRelease.read(at: feed)
                    try? JSONEncoder().encode(release).write(to: cache, options: .atomic)
                    return (release, false)
                } catch {
                    let cached = try LocalRelease.read(at: cache)
                    guard cached.isRemote == (feed == GitHubUpdates.feedURL) else { throw CocoaError(.fileReadCorruptFile) }
                    return (cached, true)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.checkID == requestID else { return }
                self.timeout?.invalidate(); self.timeout = nil
                self.checkButton.isEnabled = true
                self.checkedLabel.stringValue = "Last checked just now"
                switch result {
                case .failure: self.showUnavailable()
                case .success(let (release, cached)):
                    self.latest = release
                    self.latestLabel.stringValue = "Latest published: Pasteboard \(release.version)"
                    switch release.availability(installedBuild: self.installed.build) {
                    case .current: self.messageLabel.stringValue = "You’re up to date. The latest release and ZIP are available below."
                    case .update: self.messageLabel.stringValue = "A newer build is available. Update and Relaunch saves your boards, installs the update, and reopens Pasteboard."
                    case .newerInstalled: self.messageLabel.stringValue = "This app is newer than the latest published release."
                    }
                    if cached { self.messageLabel.stringValue = "Couldn’t check for updates. Showing the last checked release. Check again when you’re connected before installing." }
                    self.notesLabel.stringValue = release.notes.prefix(4).map { "• " + $0 }.joined(separator: "\n")
                    self.appButton.isEnabled = true; self.archiveButton.isEnabled = true
                    self.installButton.isEnabled = !cached && release.availability(installedBuild: self.installed.build) == .update
                }
            }
        }
    }
    @objc private func installUpdate(_ sender: Any?) {
        guard !installing, let latest, latest.availability(installedBuild: installed.build) == .update else { return }
        installing = true; installButton.isEnabled = false; checkButton.isEnabled = false; messageLabel.stringValue = latest.isRemote ? "Downloading and verifying the update…" : "Preparing and verifying the update…"
        let installed = self.installed, directory = stateDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try latest.isRemote
                    ? GitHubUpdates.prepare(latest, installedAt: installed.bundleURL, identifier: installed.identifier, stateDirectory: directory)
                    : LocalUpdater.prepare(latest, installedAt: installed.bundleURL, identifier: installed.identifier, stateDirectory: directory)
            }
            DispatchQueue.main.async {
                guard let self else { if case .success(let prepared) = result { prepared.cancel() }; return }
                do {
                    let prepared = try result.get()
                    guard self.prepareForRelaunch?() == true else { prepared.cancel(); throw LocalUpdater.error("Finish importing images and make sure your boards can save, then try again.") }
                    do { _ = try prepared.launchHelper() } catch { prepared.cancel(); throw error }
                    self.messageLabel.stringValue = "Your boards are saved. Relaunching Pasteboard…"; NSApp.terminate(nil)
                } catch {
                    self.installing = false; self.checkButton.isEnabled = true; self.installButton.isEnabled = true
                    self.messageLabel.stringValue = error.localizedDescription
                }
            }
        }
    }
    private func showUnavailable() {
        checkButton.isEnabled = true; latestLabel.stringValue = "Update location unavailable"
        messageLabel.stringValue = remoteChannel ? "Couldn’t reach the GitHub release. Check your internet connection and try again, or use View on GitHub to download the app." : "The local build folder may have moved, or no release has been published yet."
    }
    private func openReleaseLocation(_ url: URL) { if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else if url.scheme == "https" { NSWorkspace.shared.open(url) } }
    @objc private func showLatestApp(_ sender: Any?) { if let url = latest.flatMap({ URL(string: $0.appURL) }) { openReleaseLocation(url) } }
    @objc private func showArchive(_ sender: Any?) { if let url = latest.flatMap({ URL(string: $0.archiveURL) }) { openReleaseLocation(url) } }
    @objc private func showFolder(_ sender: Any?) { if let url = installed.folderURL { if url.isFileURL { NSWorkspace.shared.open(url) } else { openReleaseLocation(url) } } }
}

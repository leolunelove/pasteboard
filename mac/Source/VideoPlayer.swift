import AVKit
import AppKit
import WebKit

final class VideoPlayerWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let store: BoardStore
    private let boardID: UUID
    private let card: Card
    private var player: AVPlayer?
    private var web: WKWebView?
    private var observation: NSKeyValueObservation?
    private let status = NSTextField(labelWithString: "")
    init(store: BoardStore, boardID: UUID, card: Card) {
        self.store = store
        self.boardID = boardID
        self.card = card
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 840, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = card.video?.title ?? "Video"
        window.minSize = CGSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = window.contentView!
        let open = NSButton(
            title: card.video?.youtubeID != nil ? "Open on YouTube ↗" : "Open in Default Player ↗",
            target: self, action: #selector(openOriginal(_:)))
        open.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.stringValue =
            card.video?.youtubeID != nil
            ? "YouTube · Requires internet. Some videos allow playback only on YouTube."
            : "Local video · Stored on this Mac"
        let content: NSView
        if card.video?.youtubeID != nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            web = view
            content = view
        } else {
            let view = AVPlayerView()
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = true
            if let file = card.video?.file {
                let item = AVPlayerItem(
                    url: store.directory.appendingPathComponent("Assets").appendingPathComponent(file))
                let player = AVPlayer(playerItem: item)
                self.player = player
                view.player = player
                observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .failed {
                        DispatchQueue.main.async {
                            self?.status.stringValue =
                                "This video could not play. Try Open in Default Player."
                        }
                    }
                }
            }
            content = view
        }
        for view in [content, status, open] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -12),
            open.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -12),
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let video = card.video, let request = YouTubeLink.playerRequest(video) { web?.load(request) }
        player?.play()
    }
    func refreshFromStore() {
        guard
            store.workspace.boards.first(where: { $0.id == boardID })?.cards.contains(where: {
                $0.id == card.id && $0.video == card.video
            }) == true
        else {
            close()
            return
        }
    }
    private func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        observation = nil
        web?.stopLoading()
        web?.loadHTMLString("", baseURL: nil)
    }
    override func close() {
        stop()
        super.close()
    }
    func windowWillClose(_ notification: Notification) { stop() }
    @objc private func openOriginal(_ sender: Any?) {
        guard let video = card.video else { return }
        if let url = YouTubeLink.watchURL(video) {
            NSWorkspace.shared.open(url)
        } else if let file = video.file {
            NSWorkspace.shared.open(
                store.directory.appendingPathComponent("Assets").appendingPathComponent(file))
        }
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        status.stringValue = "YouTube could not load. Check your connection, or Open on YouTube."
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, ["https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame == nil, action.navigationType == .linkActivated, url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

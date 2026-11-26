import AppKit
import ImageIO
import UniformTypeIdentifiers

struct SocialArtwork {
    let post: SocialPost
    let assets: URL
    func imagePNG() throws -> Data {
        guard post.isComplete else {
            throw BoardExport.error(
                "This frame has missing items. Move them back to this page, or unmark the post and mark a new selection."
            )
        }
        let export = BoardExport(cards: post.cards, assets: assets, padding: 0)
        let scale = min(2, 4096 / max(export.bounds.width, export.bounds.height))
        return try export.png(scale: scale, transparent: true)
    }
    static func previewPNG(imageData: Data, draft: SocialDraft) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BoardExport.error("The post image could not be rendered.")
        }
        let story = draft.platform == .story
        let original = CGFloat(image.width) / CGFloat(image.height)
        // Feed previews use the platform's visible single-image ratio range.
        let ratio: CGFloat =
            story
            ? 9 / 16
            : (draft.format.ratio
                ?? {
                    switch draft.platform {
                    case .instagram: return min(1.91, max(0.75, original))
                    case .linkedin: return min(3, max(0.8, original))
                    default: return min(2, max(0.75, original))
                    }
                }())
        let width: CGFloat = 600
        let inset: CGFloat = 24
        let mediaWidth = width - inset * 2
        let mediaHeight = mediaWidth / ratio
        let caption = draft.caption.isEmpty ? "Your caption goes here…" : draft.caption
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(hex: 0x242629),
            .paragraphStyle: paragraph,
        ]
        let captionHeight =
            ceil(
                (caption as NSString).boundingRect(
                    with: CGSize(width: mediaWidth, height: 20_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
                ).height) + 8
        let topCaption = draft.platform == .linkedin || draft.platform == .x
        let mediaY: CGFloat = topCaption ? 102 + captionHeight : 88
        let height = mediaY + mediaHeight + (topCaption ? 78 : captionHeight + 102)
        guard height <= 16_000,
            let context = CGContext(
                data: nil, width: Int(width * 2), height: Int(ceil(height) * 2),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw BoardExport.error("This preview is too large. Shorten the caption and try again.")
        }
        context.translateBy(x: 0, y: ceil(height) * 2)
        context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ value: String, _ rect: CGRect, size: CGFloat, bold: Bool = false, muted: Bool = false) {
            (value as NSString).draw(
                in: rect,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                    .foregroundColor: NSColor(hex: muted ? 0x777B80 : 0x242629),
                ])
        }
        context.setFillColor(NSColor(hex: 0xE9E5F5).cgColor)
        context.fillEllipse(in: CGRect(x: inset, y: 23, width: 42, height: 42))
        text("Y", CGRect(x: inset + 14, y: 33, width: 22, height: 24), size: 18, bold: true)
        text("Your profile", CGRect(x: 79, y: 24, width: 370, height: 23), size: 17, bold: true)
        text(
            draft.platform.title + " · Post preview", CGRect(x: 79, y: 48, width: 420, height: 20), size: 12,
            muted: true)
        let media = CGRect(x: inset, y: mediaY, width: mediaWidth, height: mediaHeight)
        context.setFillColor(NSColor(hex: 0xF1F1F3).cgColor)
        context.fill(media)
        context.saveGState()
        context.clip(to: media)
        let factor =
            draft.fill
            ? max(media.width / CGFloat(image.width), media.height / CGFloat(image.height))
            : min(media.width / CGFloat(image.width), media.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        let rect = CGRect(
            x: media.midX - drawSize.width / 2, y: media.midY - drawSize.height / 2,
            width: drawSize.width, height: drawSize.height)
        NSImage(cgImage: image, size: .zero).draw(
            in: rect, from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGState()
        let captionY = topCaption ? 88 : media.maxY + 44
        if !topCaption {
            text(
                story ? "Reply to story…" : "♡   Comment   Share",
                CGRect(x: inset, y: media.maxY + 13, width: mediaWidth, height: 24), size: 15, muted: true)
        }
        (caption as NSString).draw(
            with: CGRect(x: inset, y: captionY, width: mediaWidth, height: captionHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        if topCaption {
            text(
                draft.platform == .linkedin
                    ? "Like     Comment     Repost     Send" : "Reply     Repost     Like     Share",
                CGRect(x: inset, y: media.maxY + 18, width: mediaWidth, height: 24), size: 14, muted: true)
        }
        text(
            "Pasteboard · Illustrative preview",
            CGRect(x: inset, y: height - 28, width: mediaWidth, height: 18), size: 11, muted: true)
        guard let result = context.makeImage() else {
            throw BoardExport.error("Could not create the preview.")
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else {
            throw BoardExport.error("PNG export is unavailable.")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BoardExport.error("PNG export could not finish.")
        }
        return data as Data
    }
}

private final class SocialPreviewSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
final class SocialPreviewWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let store: BoardStore
    private var post: SocialPost
    private var savedDraft: SocialDraft
    private let platform = NSPopUpButton()
    private let format = NSPopUpButton()
    private let fit = NSPopUpButton()
    private let caption = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let imageView = NSImageView()
    private let imageScroll = NSScrollView()
    private let imageDocument = Document()
    private var timer: Timer?
    private var artwork: Data?
    private var preview: Data?
    private var exportButtons: [NSButton] = []
    private var isSaving = false
    private var unavailable = false
    init(store: BoardStore, post: SocialPost) {
        self.store = store
        self.post = post
        savedDraft = post.draft
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Ready to post — \(post.pageName)"
        window.minSize = CGSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = SocialPreviewSurface(frame: window.contentView!.bounds)
        let content = window.contentView!
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)
        imageScroll.drawsBackground = true
        imageScroll.backgroundColor = .pasteboardCanvas
        imageScroll.hasVerticalScroller = true
        imageScroll.documentView = imageDocument
        imageScroll.translatesAutoresizingMaskIntoConstraints = false
        imageDocument.addSubview(imageView)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageScroll)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            controls.widthAnchor.constraint(equalToConstant: 334),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            imageScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            imageScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            imageScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            imageScroll.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -24),
        ])
        func label(_ text: String, size: CGFloat = 13, bold: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            controls.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        label("Ready to post", size: 25, bold: true)
        label("\(post.pageName) · \(post.title)")
        for (picker, titles, name) in [
            (platform, SocialPlatform.allCases.map(\.title), "Social platform"),
            (format, SocialFormat.allCases.map(\.title), "Image proportions"),
            (fit, ["Fit whole image", "Fill frame · centre crop"], "Image fit"),
        ] {
            picker.addItems(withTitles: titles)
            picker.setAccessibilityLabel(name)
            picker.target = self
            picker.action = #selector(optionsChanged(_:))
            controls.addArrangedSubview(picker)
            picker.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        label("Caption", bold: true)
        let captionScroll = NSScrollView()
        captionScroll.borderType = .bezelBorder
        captionScroll.hasVerticalScroller = true
        captionScroll.documentView = caption
        caption.isRichText = false
        caption.font = .systemFont(ofSize: 14)
        caption.textContainerInset = CGSize(width: 10, height: 10)
        caption.isVerticallyResizable = true
        caption.isHorizontallyResizable = false
        caption.autoresizingMask = .width
        caption.textContainer?.widthTracksTextView = true
        caption.allowsUndo = true
        caption.setAccessibilityLabel("Draft caption. Write a placeholder caption for your post.")
        caption.delegate = self
        controls.addArrangedSubview(captionScroll)
        captionScroll.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        captionScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        controls.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        func row(_ entries: [(String, Selector)], exports: Bool = false) {
            let row = NSStackView()
            row.spacing = 8
            row.distribution = .fillEqually
            for (title, action) in entries {
                let button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .rounded
                row.addArrangedSubview(button)
                if exports { exportButtons.append(button) }
            }
            controls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        row([("Save Draft", #selector(saveDraft(_:))), ("Copy Caption", #selector(copyCaption(_:)))])
        row(
            [("Copy Preview", #selector(copyPreview(_:))), ("Save Preview…", #selector(savePreview(_:)))],
            exports: true)
        row(
            [("Copy Image", #selector(copyImage(_:))), ("Save Image…", #selector(saveImage(_:)))],
            exports: true)
        row([("Show on Board", #selector(showOnBoard(_:))), ("Unmark Ready", #selector(unmark(_:)))])
        label(
            "Drafts stay on this Mac. Previews are illustrative. Image exports keep your artwork and transparency, without the caption or social interface.",
            size: 11)
        loadControls()
        window.center()
    }
    var onShowBoard: ((UUID, Set<UUID>) -> Void)?
    required init?(coder: NSCoder) { fatalError() }
    private func loadControls() {
        platform.selectItem(at: SocialPlatform.allCases.firstIndex(of: post.draft.platform)!)
        format.selectItem(at: SocialFormat.allCases.firstIndex(of: post.draft.format)!)
        fit.selectItem(at: post.draft.fill ? 1 : 0)
        caption.string = post.draft.caption
        updateDraft()
    }
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        render()
    }
    func refreshFromStore() {
        guard !isSaving else { return }
        guard let current = store.socialPost(boardID: post.boardID, anchorID: post.anchorID) else {
            unavailable = true
            status.stringValue = "This post was removed or moved. Reopen it from its workspace."
            for button in exportButtons { button.isEnabled = false }
            return
        }
        unavailable = false
        if post.cards != current.cards {
            artwork = nil
            post = SocialPost(
                boardID: current.boardID, anchorID: current.anchorID, pageName: current.pageName,
                draft: post.draft, cards: current.cards)
        }
        if post.draft == savedDraft && savedDraft != current.draft {
            post.draft = current.draft
            savedDraft = current.draft
            loadControls()
        }
        window?.title = "Ready to post — \(current.pageName)"
        queuePreview()
    }
    private func updateDraft() {
        post.draft.platform = SocialPlatform.allCases[max(0, platform.indexOfSelectedItem)]
        post.draft.format = SocialFormat.allCases[max(0, format.indexOfSelectedItem)]
        post.draft.fill = fit.indexOfSelectedItem == 1
        post.draft.caption = caption.string
        format.isEnabled = post.draft.platform != .story
        status.stringValue =
            post.draft.caption.count > 10_000
            ? "Caption is too long · maximum 10,000 characters."
            : "\(post.draft.caption.count) characters · \(post.draft == savedDraft ? "Saved draft" : "Unsaved draft")"
    }
    func textDidChange(_ notification: Notification) {
        updateDraft()
        queuePreview()
    }
    @objc private func optionsChanged(_ sender: Any?) {
        updateDraft()
        queuePreview()
    }
    private func queuePreview() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.render()
        }
    }
    private func render() {
        guard !unavailable else { return }
        do {
            guard post.draft.isValid else {
                throw BoardExport.error("Shorten the caption to 10,000 characters or fewer.")
            }
            if artwork == nil {
                artwork = try SocialArtwork(
                    post: post, assets: store.directory.appendingPathComponent("Assets")
                ).imagePNG()
            }
            preview = try SocialArtwork.previewPNG(imageData: artwork!, draft: post.draft)
            imageView.image = NSImage(data: preview!)
            layoutPreview()
            for button in exportButtons { button.isEnabled = true }
            updateDraft()
        } catch {
            preview = nil
            imageView.image = nil
            for button in exportButtons { button.isEnabled = false }
            status.stringValue = error.localizedDescription
        }
    }
    private func layoutPreview() {
        guard let image = imageView.image else { return }
        let available = max(1, imageScroll.contentSize.width - 30)
        let fitted =
            max(1, imageScroll.contentSize.height - 30) * image.size.width / max(1, image.size.height)
        let width = min(available, max(280, fitted))
        let height = width * image.size.height / max(1, image.size.width)
        imageDocument.frame = CGRect(
            x: 0, y: 0, width: imageScroll.contentSize.width,
            height: max(imageScroll.contentSize.height, height + 30))
        imageView.frame = CGRect(
            x: (imageDocument.bounds.width - width) / 2, y: 15, width: width, height: height)
    }
    func windowDidResize(_ notification: Notification) { layoutPreview() }
    @discardableResult func flush() -> Bool {
        updateDraft()
        guard post.draft != savedDraft else { return true }
        guard !unavailable else {
            let alert = NSAlert()
            alert.messageText = "This post was removed."
            alert.informativeText =
                "Your unsaved caption is still in this window. Keep it open to copy the text, or discard this draft."
            alert.addButton(withTitle: "Keep Draft Open")
            alert.addButton(withTitle: "Discard Draft")
            window?.makeKeyAndOrderFront(nil)
            if alert.runModal() == .alertSecondButtonReturn {
                savedDraft = post.draft
                return true
            }
            return false
        }
        isSaving = true
        defer { isSaving = false }
        guard store.updateSocialDraft(post.draft, boardID: post.boardID, anchorID: post.anchorID) else {
            status.stringValue = "Draft could not be saved. Keep this window open and shorten the caption."
            return false
        }
        savedDraft = post.draft
        updateDraft()
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if flush() {
            timer?.invalidate()
            return true
        }
        NSSound.beep()
        return false
    }
    @objc private func saveDraft(_ sender: Any?) {
        if flush() {
            status.stringValue = store.save() ? "Draft saved on this Mac" : "Save failed · try again"
        }
    }
    @objc private func copyCaption(_ sender: Any?) {
        if !unavailable && !flush() { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(post.draft.caption, forType: .string)
        status.stringValue = "Caption copied"
    }
    private func data(preview wantsPreview: Bool) throws -> Data {
        refreshFromStore()
        guard flush(), !unavailable else { throw BoardExport.error("This draft cannot be exported yet.") }
        if wantsPreview { render() }
        guard
            let result = wantsPreview
                ? preview
                : (try SocialArtwork(post: post, assets: store.directory.appendingPathComponent("Assets"))
                    .imagePNG())
        else {
            throw BoardExport.error("The preview could not be rendered.")
        }
        return result
    }
    private func copy(preview: Bool) {
        do {
            let result = try data(preview: preview)
            let item = NSPasteboardItem()
            item.setData(result, forType: .png)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else {
                throw BoardExport.error("The image could not be copied.")
            }
            status.stringValue =
                preview ? "Preview copied · use Copy Caption for caption text" : "Image copied"
        } catch { show(error) }
    }
    private func save(preview: Bool) {
        do {
            let result = try data(preview: preview)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = preview ? "Post Preview.png" : "Post Image.png"
            panel.beginSheetModal(for: window!) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try result.write(to: url, options: .atomic)
                    self?.status.stringValue = "PNG saved"
                } catch { self?.show(error) }
            }
        } catch { show(error) }
    }
    private func show(_ error: Error) { NSAlert(error: error).beginSheetModal(for: window!) }
    @objc private func copyPreview(_ sender: Any?) { copy(preview: true) }
    @objc private func copyImage(_ sender: Any?) { copy(preview: false) }
    @objc private func savePreview(_ sender: Any?) { save(preview: true) }
    @objc private func saveImage(_ sender: Any?) { save(preview: false) }
    @objc private func showOnBoard(_ sender: Any?) {
        guard flush() else { return }
        onShowBoard?(post.boardID, Set(post.draft.memberIDs))
    }
    @objc private func unmark(_ sender: Any?) {
        post.draft.isReady = false
        if flush() { close() }
    }
}

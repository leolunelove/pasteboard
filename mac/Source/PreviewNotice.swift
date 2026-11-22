import AppKit

enum PreviewNotice {
    static let acknowledgementKey = "PasteboardPreviewAcknowledgedBuild"
    static func shouldShow(build: Int, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: acknowledgementKey) as? Int != build
    }
    static func acknowledge(build: Int, defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: acknowledgementKey)
    }
    static func alert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = PasteboardArtwork.smallIcon
        alert.messageText = "Pasteboard is a work in progress"
        alert.informativeText = "You’re trying an early preview. Some features are still being refined, and you may run into rough edges.\n\nEverything saves on this Mac. Keep a separate backup of important boards."
        alert.addButton(withTitle: "Continue to Pasteboard")
        return alert
    }
}

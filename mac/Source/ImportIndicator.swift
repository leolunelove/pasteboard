import AppKit

// Non-modal feedback: importing never takes focus or blocks the worktable.
final class ImportIndicator: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.zPosition = 10_000_001
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .pasteboardInk
        for view in [spinner, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        isHidden = true
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.pasteboardSurface.cgColor
            layer?.borderColor = NSColor.pasteboardBorder.cgColor
        }
    }
    func show(count: Int) {
        guard count > 0 else {
            isHidden = true
            spinner.stopAnimation(nil)
            return
        }
        label.stringValue = count == 1 ? "Adding image…" : "Adding \(count) images…"
        isHidden = false
        spinner.startAnimation(nil)
    }
}

import AppKit
import QuartzCore

func check(_ value: @autoclosure () -> Bool, line: Int = #line) throws {
    if !value() {
        throw NSError(
            domain: "SceneCheck", code: line,
            userInfo: [NSLocalizedDescriptionKey: "Scene check failed at line \(line)"])
    }
}
let directory = URL(fileURLWithPath: "/private/tmp/PasteboardScene-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let app = NSApplication.shared
let store = BoardStore(directory: directory)
let scene = CanvasScene()
let group = UUID()
let first = Card(x: 0, y: 0, width: 100, height: 80, text: "Visible", groupID: group)
var second = Card(x: 120, y: 0, width: 100, height: 80, text: "Offscreen", groupID: group)
store.board.cards = [first, second]
var groups = [group: CGRect(x: 0, y: 0, width: 220, height: 80)]
let selection: Set<UUID> = [first.id, second.id]
let guides = [AlignmentGuide(axis: .x, position: 10, from: 0, to: 200)]
let spacing = [SpacingGuide(axis: .x, position: 50, distance: 20, spans: [GapSpan(from: 100, to: 120)])]
func frame(zoom: CGFloat = 1, offset: CGPoint = .zero, drawGroups: Bool = true, drawGuides: Bool = true) {
    scene.update(
        cards: [first], selection: selection, groups: drawGroups ? groups : [:],
        guides: drawGuides ? guides : [], spacingGuides: drawGuides ? spacing : [], editing: nil, zoom: zoom,
        offset: offset, store: store, color: { _ in .white }, backingScale: 2)
}
do {
    frame()
    let outline = scene.root.sublayers!.first { $0.zPosition == 1_000_000 } as! CAShapeLayer
    let label = scene.root.sublayers!.first { $0.zPosition == 1_000_001 } as! CATextLayer
    let grip = scene.root.sublayers!.first { $0.zPosition == 1_000_002 }!
    let guide = scene.root.sublayers!.first { $0.zPosition == 2_000_000 } as! CAShapeLayer
    let gap = scene.root.sublayers!.first { $0.zPosition == 2_000_001 } as! CAShapeLayer
    let outlinePath = outline.path
    let guidePath = guide.path
    let gapPath = gap.path
    frame(offset: CGPoint(x: 40, y: -20))
    try check(scene.root.position == CGPoint(x: 40, y: -20))
    try check(outline.path === outlinePath && guide.path === guidePath && gap.path === gapPath)
    frame(zoom: 0.5)
    try check(abs(outline.lineWidth - 3.4) < 0.001)
    groups[group] = CGRect(x: 100, y: 0, width: 220, height: 80)
    frame()
    try check(outline.path!.boundingBox.minX == 91)
    second.locked = true
    store.board.cards = [first, second]
    frame()
    try check(grip.isHidden && (label.string as? NSAttributedString)?.string == "Locked group")
    second.locked = false
    store.board.cards = [first, second]
    frame()
    try check(!grip.isHidden && (label.string as? NSAttributedString)?.string == "Group")
    let groupedGapY = gap.path!.boundingBox.minY
    frame(drawGroups: false)
    try check(gap.path!.boundingBox.minY == groupedGapY + 24)
    frame(drawGroups: false, drawGuides: false)
    try check(guide.isHidden && gap.isHidden && guide.path == nil)
    print(
        "PASS: retained pan geometry, zoom strokes, moved group bounds, offscreen group locking/unlocking, spacing offset and cleared guides"
    )
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}

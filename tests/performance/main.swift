import AppKit
import QuartzCore

let directory = URL(fileURLWithPath: "/private/tmp/PasteboardBench-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let app = NSApplication.shared
let store = BoardStore(directory: directory)
let group = UUID()
var cards: [Card] = []
for i in 0..<800 {
    let x = Double(i % 40) * 110.0
    let y = Double(i / 40) * 90.0
    let groupID: UUID? = i < 40 ? group : nil
    cards.append(Card(x: x, y: y, width: 100, height: 80, text: "Reference \(i)", groupID: groupID))
}
store.board.cards = cards
let selection = Set(cards.prefix(40).map(\.id))
let groups = store.board.groupBounds(for: selection)
let scene = CanvasScene()
func frame(_ i: Int) {
    scene.update(
        cards: cards, selection: selection, groups: groups, guides: [], editing: nil, zoom: 1,
        offset: CGPoint(x: i, y: i), store: store, color: { _ in .white }, backingScale: 2)
}
frame(0)
var samples: [Double] = []
for run in 0..<5 {
    let start = CFAbsoluteTimeGetCurrent()
    for i in 1...1000 { frame(i + run) }
    samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
}
print(samples.sorted()[2])

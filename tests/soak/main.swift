import AppKit
import Darwin
import QuartzCore

func check(_ condition: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) throws {
    guard condition() else {
        throw NSError(
            domain: "Pasteboard.Soak", code: line,
            userInfo: [NSLocalizedDescriptionKey: "Soak assertion failed at \(file):\(line)"])
    }
}
func waitFor(_ condition: () -> Bool, timeout: Double = 60, file: String = #fileID, line: Int = #line) throws
{
    let end = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < end { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
    try check(condition(), file: file, line: line)
}
struct Generator {
    var state: UInt64 = 0xC4A9_B713
    mutating func next(_ upper: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upper))
    }
}
let app = NSApplication.shared
let activity = ProcessInfo.processInfo.beginActivity(
    options: .userInitiated, reason: "Unattended Pasteboard reliability test")
defer { ProcessInfo.processInfo.endActivity(activity) }
let duration = max(1, Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60)
let interval = max(0.001, Double(CommandLine.arguments.dropFirst(2).first ?? "0.1") ?? 0.1)
let directory = URL(fileURLWithPath: "/private/tmp/PasteboardSoak-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = BoardStore(directory: directory)
let view = BoardView(store: store)
view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
view.layout()
let scene = CanvasScene()
let light = NSAppearance(named: .aqua)!
let dark = NSAppearance(named: .darkAqua)!
var rng = Generator()
let groups = (0..<25).map { _ in UUID() }
store.board.cards = (0..<500).map { i in
    Card(
        x: Double(i % 25) * 160 - 1000, y: Double(i / 25) * 130 - 600,
        width: 140, height: 100, text: "Reference \(i)", tone: i % 4,
        groupID: i < 100 ? groups[i / 4] : nil, locked: i % 37 == 0 ? true : nil)
}
let root = store.board.id
_ = store.newPage(in: root, name: "Other page")
store.activate(root)
view.refresh()
let context = CGContext(
    data: nil, width: 416, height: 316, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: 316)
context.scaleBy(x: 2, y: -2)
print("SOAK directory=\(directory.path)")
let started = Date()
var lastReport = Date.distantPast
var lastSave = Date.distantPast
var iterations = 0
var writes = 0
var undos = 0
var renders = 0
var imports = 0
var failure: Error?
do {
    try interactionTest(directory: directory.appendingPathComponent("interactions"))
    try arrangementTest(directory: directory.appendingPathComponent("arrangement"))
    while Date().timeIntervalSince(started) < duration {
        try autoreleasepool {
            let cards = store.board.cards
            let selected = Set((0..<8).map { _ in cards[rng.next(cards.count)].id })
            view.selection = selected
            switch rng.next(9) {
            case 0, 1:
                let mode = BoardArrangement.allCases[rng.next(BoardArrangement.allCases.count)]
                let original = store.board.cards
                let arranged = mode.applying(to: store.board, selection: selected)
                store.replaceCards(arranged, name: mode.title)
                if original != arranged {
                    store.history.undo()
                    try check(store.board.cards == original)
                    store.history.redo()
                    try check(store.board.cards == arranged)
                    undos += 1
                }
            case 2:
                let card = cards[rng.next(cards.count)]
                view.selection = [card.id]
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero,
                    modifierFlags: rng.next(2) == 0 ? [.shift] : [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: UInt16(123 + rng.next(4)))!
                view.keyDown(with: event)
            case 3:
                let movable = store.board.expandedSelection(selected).subtracting(store.board.lockedIDs)
                let original = store.board.cards
                let scaled = Card.scaled(
                    original, ids: movable, around: .zero, by: rng.next(2) == 0 ? 0.99 : 1.01)
                store.replaceCards(scaled, name: "Resize Group")
            case 4:
                store.board.zoom = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4][rng.next(8)]
                store.board.offsetX = Double(rng.next(4000) - 2000)
                store.board.offsetY = Double(rng.next(4000) - 2000)
                store.scheduleSave()
            case 5:
                let board = store.board.id
                let other = store.workspace.boards.first(where: { $0.id != board })!.id
                store.activate(other)
                view.refresh()
                store.activate(board)
                view.refresh()
            case 6:
                let text = "Thought \(iterations): paste, arrange, save."
                let card = Card(x: 100, y: 100, width: 300, height: 140, text: text)
                store.replaceCards(store.board.cards + [card], name: "Add Note")
                store.history.undo()
                try check(store.board.cards == cards)
                store.history.redo()
                try check(store.board.cards.last?.text == text)
                store.history.undo()
                undos += 2
            case 7:
                // Real asynchronous transparent image import and persistence.
                let bitmap = CGContext(
                    data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                bitmap.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.5))
                bitmap.fillEllipse(in: CGRect(x: 8, y: 8, width: 16, height: 16))
                let png = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(
                    using: .png, properties: [:])!
                var prepared: PreparedImage?
                var done = false
                store.prepareImages([png]) { images, failed in
                    if images.count != 1 || failed != 0 {
                        failure = NSError(
                            domain: "Soak.ImageImport", code: failed,
                            userInfo: [
                                NSLocalizedDescriptionKey: store.lastImageImportError
                                    ?? "No prepared image returned"
                            ])
                        try? png.write(to: directory.appendingPathComponent("FailedImport.png"))
                    }
                    prepared = images.first
                    done = true
                }
                try waitFor({ done })
                if let failure { throw failure }
                try check(prepared != nil)
                let image = prepared!
                try check(store.originalImageData(image.asset) == png)
                var withImage = store.board.cards
                if withImage.filter({ $0.asset != nil }).count >= 8,
                    let index = withImage.firstIndex(where: { $0.asset != nil })
                {
                    withImage.remove(at: index)
                }
                withImage.append(store.card(for: image, at: CGPoint(x: rng.next(2000), y: rng.next(2000))))
                store.replaceCards(withImage, name: "Paste Image")
                imports += 1
            default: break
            }
            try check(store.board.cards.allSatisfy(BoardStore.valid))
            let zoom = store.board.zoom
            let offset = CGPoint(x: store.board.offsetX, y: store.board.offsetY)
            scene.update(
                cards: store.board.cards, selection: view.selection,
                groups: store.board.groupBounds(for: view.selection), guides: [], editing: nil,
                zoom: zoom, offset: offset, store: store, color: view.noteColor,
                backingScale: 2, appearance: iterations % 2 == 0 ? dark : light)
            view.minimap.render(in: context)
            renders += 1
            if Date().timeIntervalSince(lastSave) >= 10 {
                try check(store.save())
                let reloaded = BoardStore(directory: directory)
                try check(reloaded.workspace.boards == store.workspace.boards)
                try check(reloaded.workspace.active == store.workspace.active)
                writes += 1
                lastSave = Date()
            }
            iterations += 1
        }
        if Date().timeIntervalSince(lastReport) >= 60 {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print(
                "SOAK elapsed=\(Int(Date().timeIntervalSince(started)))s iterations=\(iterations) saves=\(writes) undo_checks=\(undos) renders=\(renders) imports=\(imports) max_rss_bytes=\(usage.ru_maxrss)"
            )
            fflush(stdout)
            lastReport = Date()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }
    try check(store.save())
    print(
        "PASS: \(Int(Date().timeIntervalSince(started))) second randomized soak; \(iterations) iterations, \(writes) save/reloads, \(undos) undo checks, \(renders) scene/minimap renders, \(imports) asynchronous alpha imports"
    )
} catch {
    fputs("FAIL after \(iterations) iterations: \(error.localizedDescription)\n", stderr)
    exit(1)
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum LocalRead {
    // Retry once before treating a transient file/decoder failure as corruption.
    // Normal reads take the direct path; failed reads wait only 20 milliseconds.
    static func retry<Value>(_ operation: () throws -> Value) throws -> Value {
        do { return try operation() } catch {
            Thread.sleep(forTimeInterval: 0.02)
            return try operation()
        }
    }
}

struct PreparedImage {
    let asset: String
    let preview: CGImage
    let size: CGSize
    var sourceURL: String?
}

enum GroupCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
    var opposite: GroupCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

struct Card: Codable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String?
    var asset: String?
    var tone = 0
    var groupID: UUID?
    var contentScale: Double?
    var locked: Bool?
    var sourceURL: String?
    var hex: String?
    var isLocked: Bool { locked == true }
    var socialPost: SocialDraft?
    var video: BoardVideo?
    var crop: ImageCrop?
    var imageCrop: ImageCrop { crop ?? .full }
    var fullImageRect: CGRect {
        let crop = imageCrop
        let w = width / crop.width
        let h = height / crop.height
        return CGRect(x: x - crop.x * w, y: y - crop.y * h, width: w, height: h)
    }
    var renderScale: Double { contentScale ?? 1 }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    static func scaled(_ cards: [Card], ids: Set<UUID>, around anchor: CGPoint, by requested: Double)
        -> [Card]
    {
        let members = cards.filter { ids.contains($0.id) }
        guard !members.isEmpty, requested.isFinite else { return cards }
        let minimum = members.reduce(0.0) { max($0, 40 / $1.width, 40 / $1.height, 0.02 / $1.renderScale) }
        let maximum = members.reduce(Double.infinity) {
            min($0, 99_999 / $1.fullImageRect.width, 99_999 / $1.fullImageRect.height, 64 / $1.renderScale)
        }
        let factor = min(maximum.nextDown, max(minimum.nextUp, requested))
        if abs(factor - 1) < 0.000000001 { return cards }
        return cards.map { card in
            guard ids.contains(card.id) else { return card }
            var result = card
            result.x = anchor.x + (card.x - anchor.x) * factor
            result.y = anchor.y + (card.y - anchor.y) * factor
            result.width = card.width * factor
            result.height = card.height * factor
            result.contentScale = card.renderScale * factor
            return result
        }
    }

    func textHeight(for content: String) -> Double {
        let measured = content.boundingRect(
            with: NSSize(width: max(1, width / renderScale - 40), height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 18)])
        return min(99_999, (ceil(measured.height) + 42) * renderScale)
    }

    // Cloned groups get fresh identities so moving a copy never moves its source.
    static func copies(of cards: [Card], offset: CGPoint = .zero) -> [Card] {
        var groups: [UUID: UUID] = [:]
        return cards.map { card in
            var copy = card
            copy.id = UUID()
            copy.x += offset.x
            copy.y += offset.y
            copy.locked = nil
            copy.socialPost = nil
            if let group = card.groupID {
                if groups[group] == nil { groups[group] = UUID() }
                copy.groupID = groups[group]
            }
            return copy
        }
    }
}

struct Board: Codable, Equatable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
    var zoom: Double = 1
    var offsetX: Double = 160
    var offsetY: Double = 140
    var parentID: UUID?
    var isFolder: Bool?
    var sections: [BoardSection]?

    func expandedSelection(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(cards.filter { ids.contains($0.id) }.compactMap(\.groupID))
        return Set(cards.filter { ids.contains($0.id) || $0.groupID.map(groups.contains) == true }.map(\.id))
    }
    func groupBounds(for ids: Set<UUID>) -> [UUID: CGRect] {
        var bounds: [UUID: CGRect] = [:]
        for card in cards where ids.contains(card.id) {
            if let group = card.groupID {
                bounds[group] = bounds[group].map { $0.union(card.rect) } ?? card.rect
            }
        }
        return bounds
    }
    var lockedIDs: Set<UUID> { expandedSelection(Set(cards.filter(\.isLocked).map(\.id))) }
}

struct Workspace: Codable {
    var version = 1
    var boards = [Board(name: "My first board")]
    var active: UUID?
    var roots: [Board] { boards.filter { $0.parentID == nil } }
    func ancestors(of id: UUID) -> [Board] {
        let lookup = Dictionary(boards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Board] = []
        var seen: Set<UUID> = [id]
        var parent = lookup[id]?.parentID
        while let next = parent, seen.insert(next).inserted, let board = lookup[next] {
            result.append(board)
            parent = board.parentID
        }
        return result
    }
    func rootID(for id: UUID) -> UUID? {
        guard let board = boards.first(where: { $0.id == id }) else { return nil }
        return ancestors(of: id).last?.id ?? board.id
    }
    func pages(in id: UUID) -> [Board] { boards.filter { $0.parentID == id } }
    func descendants(of id: UUID) -> [Board] {
        var included: Set<UUID> = [id]
        var frontier = [id]
        let children = Dictionary(
            grouping: boards.compactMap { board in
                board.parentID.map { ($0, board) }
            }, by: { $0.0 })
        while let parent = frontier.popLast() {
            for (_, child) in children[parent] ?? [] where included.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return boards.filter { $0.id != id && included.contains($0.id) }
    }
    func isContainer(_ id: UUID) -> Bool {
        guard let board = boards.first(where: { $0.id == id }) else { return false }
        return board.parentID == nil || board.isFolder == true || boards.contains { $0.parentID == id }
    }
    func path(for board: Board) -> String {
        (ancestors(of: board.id).reversed().map(\.name) + [board.name]).joined(separator: " / ")
    }
    static func validHierarchy(_ boards: [Board]) -> Bool {
        guard !boards.isEmpty, Set(boards.map(\.id)).count == boards.count else { return false }
        let lookup = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        var validated = Set(boards.filter { $0.parentID == nil }.map(\.id))
        guard !validated.isEmpty else { return false }
        for board in boards {
            var path = Set<UUID>()
            var current = board.id
            while !validated.contains(current) {
                guard path.insert(current).inserted, let parent = lookup[current]?.parentID,
                    lookup[parent] != nil
                else { return false }
                current = parent
            }
            validated.formUnion(path)
        }
        return true
    }
}

struct PortableBoard: Codable {
    var version = 1
    var board: Board
    var assets: [String: Data]
    var pages: [Board]?
}

final class BoardStore {
    let directory: URL
    var workspace: Workspace
    let history = UndoManager()
    var changed: (() -> Void)?
    var status: ((String) -> Void)?
    var loadWarning: String?
    private(set) var workspaceOverviewsEnabled = false
    private var saveTimer: Timer?
    private let saveQueue = DispatchQueue(label: "Gather.autosave", qos: .utility)
    private var saveRevision = 0
    lazy var backups = LocalBackups(directory: directory)
    lazy var searchIndex = ImageTextIndex(directory: directory)
    private let previews = NSCache<NSString, CGImage>()
    private var loadingImages = Set<String>()
    private var failedImages = Set<String>()
    private let imageQueue = DispatchQueue(label: "Gather.images", qos: .userInitiated)
    var imageReady: (() -> Void)?
    private(set) var lastImageImportError: String?
    private(set) var imageRevision = 0
    var index: Int { workspace.boards.firstIndex { $0.id == workspace.active } ?? 0 }
    var board: Board {
        get { workspace.boards[index] }
        set { workspace.boards[index] = newValue }
    }

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gather", isDirectory: true)
        workspace = Workspace()
        do {
            try FileManager.default.createDirectory(
                at: self.directory.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            let url = self.directory.appendingPathComponent("Workspace.json")
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    workspace = try LocalRead.retry {
                        let loaded = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
                        guard loaded.version == 1, Workspace.validHierarchy(loaded.boards),
                            loaded.boards.allSatisfy({
                                $0.zoom.isFinite && (0.1...4).contains($0.zoom) && $0.offsetX.isFinite
                                    && $0.offsetY.isFinite && $0.cards.allSatisfy(Self.valid)
                                    && $0.validSections
                                    && Set($0.cards.map(\.id)).count == $0.cards.count
                            })
                        else { throw CocoaError(.fileReadCorruptFile) }
                        return loaded
                    }
                } catch {
                    let recovery = self.directory.appendingPathComponent(
                        "Workspace-recovered-\(Int(Date().timeIntervalSince1970)).json")
                    try FileManager.default.copyItem(at: url, to: recovery)
                    loadWarning =
                        "Your previous workspace couldn’t be read. A copy is preserved at \(recovery.path)."
                }
            }
        } catch { loadWarning = "Pasteboard couldn’t open its save folder: \(error.localizedDescription)" }
        workspace.active = board.id
        history.levelsOfUndo = 100
        history.groupsByEvent = false
        previews.totalCostLimit = 160 * 1024 * 1024
    }

    // Opt in at the application boundary; native checks can still exercise legacy boards.
    // The entire previous layout is backed up before a single atomic replacement.
    func enableWorkspaceOverviews() throws {
        var next = workspace
        let containers = next.boards.filter {
            next.isContainer($0.id) && (!$0.cards.isEmpty || !($0.sections ?? []).isEmpty)
        }
        if !containers.isEmpty {
            let previous = workspace
            for root in containers {
                var page = root
                page.id = UUID()
                page.parentID = root.id
                page.isFolder = nil
                let names = Set(next.pages(in: root.id).map(\.name))
                var name = "Board"
                var number = 2
                while names.contains(name) {
                    name = "Board \(number)"
                    number += 1
                }
                page.name = name
                next.boards.append(page)
                if let index = next.boards.firstIndex(where: { $0.id == root.id }) {
                    next.boards[index].cards = []
                    next.boards[index].sections = nil
                }
            }
            try saveQueue.sync {
                try backups.capture(previous, force: true)
                try Self.write(next, to: directory.appendingPathComponent("Workspace.json"))
            }
            workspace = next
            history.removeAllActions()
        }
        workspaceOverviewsEnabled = true
    }

    static func valid(_ card: Card) -> Bool {
        [card.x, card.y, card.width, card.height, card.renderScale].allSatisfy(\.isFinite)
            && (0.02...64).contains(card.renderScale) && card.width >= 40 && card.height >= 40
            && card.width < 100_000 && card.height < 100_000
            && (card.asset == nil || URL(fileURLWithPath: card.asset!).lastPathComponent == card.asset!)
            && (card.sourceURL == nil || SourceLink.url(card.sourceURL!) != nil)
            && (card.crop == nil
                || (card.asset != nil && card.imageCrop.isValid && card.fullImageRect.width < 100_000
                    && card.fullImageRect.height < 100_000))
            && (card.video == nil
                || (card.video!.isValid && card.asset != nil && card.text == nil && card.hex == nil
                    && card.crop == nil && card.socialPost == nil))
            && (card.socialPost == nil
                || (card.socialPost!.isValid && card.socialPost!.memberIDs.contains(card.id)))
            && (card.hex == nil
                || (card.asset == nil && card.text == nil && card.crop == nil
                    && SwatchColor.normalized(card.hex!) == card.hex))
    }

    func scheduleSave() {
        saveRevision += 1
        status?("Saving…")
        if let saveTimer {
            saveTimer.fireDate = Date(timeIntervalSinceNow: 0.4)
        } else {
            let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.saveTimer = nil
                self?.saveInBackground()
            }
            saveTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func write(_ workspace: Workspace, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(workspace).write(to: url, options: .atomic)
    }
    private func saveInBackground() {
        let snapshot = workspace
        let revision = saveRevision
        let url = directory.appendingPathComponent("Workspace.json")
        let backups = self.backups
        saveQueue.async { [weak self] in
            let message: String
            do {
                var backupOK = true
                do { try backups.capture(snapshot) } catch { backupOK = false }
                try Self.write(snapshot, to: url)
                message = backupOK ? "Saved on this Mac" : "Saved · backup unavailable"
            } catch { message = "Save failed — \(error.localizedDescription)" }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.saveRevision == revision else { return }
                self.status?(message)
            }
        }
    }

    @discardableResult func save() -> Bool {
        saveTimer?.invalidate()
        saveTimer = nil
        saveRevision += 1
        let snapshot = workspace
        let url = directory.appendingPathComponent("Workspace.json")
        let backups = self.backups
        do {
            // Drain older writes before an explicit save or application shutdown.
            let backupOK = try saveQueue.sync { () throws -> Bool in
                var backupOK = true
                do { try backups.capture(snapshot) } catch { backupOK = false }
                try Self.write(snapshot, to: url)
                return backupOK
            }
            status?(backupOK ? "Saved on this Mac" : "Saved · backup unavailable")
            return true
        } catch {
            status?("Save failed — \(error.localizedDescription)")
            return false
        }
    }

    func replaceCards(
        _ cards: [Card], name: String, boardID: UUID? = nil,
        insertionPoint: CGPoint? = nil
    ) {
        let id = boardID ?? board.id
        guard let index = workspace.boards.firstIndex(where: { $0.id == id }) else { return }
        let previous = workspace.boards[index].cards
        guard previous != cards else { return }
        if name == "Delete" { backupNow() }
        let ownsGroup = !history.isUndoing && !history.isRedoing
        if ownsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) {
            $0.revertCards(from: cards, to: previous, name: name, boardID: id, insertionPoint: insertionPoint)
        }
        history.setActionName(name)
        if ownsGroup { history.endUndoGrouping() }
        workspace.boards[index].sections = workspace.boards[index].sectionsIncludingInsertedCards(
            cards, insertionPoint: insertionPoint)
        workspace.boards[index].cards = cards
        if history.isUndoing || history.isRedoing { workspace.active = id }
        scheduleSave()
        changed?()
    }
    private func revertCards(
        from after: [Card], to before: [Card], name: String, boardID: UUID,
        insertionPoint: CGPoint?
    ) {
        guard let index = workspace.boards.firstIndex(where: { $0.id == boardID }) else { return }
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(after.map(\.id))
        let added = afterIDs.subtracting(beforeIDs)
        let old = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        var cards = workspace.boards[index].cards.filter { !added.contains($0.id) }
        for (position, card) in before.enumerated() {
            if let i = cards.firstIndex(where: { $0.id == card.id }) {
                if old[card.id] != card { cards[i] = card }
            } else if !afterIDs.contains(card.id) {
                cards.insert(card, at: min(position, cards.count))
            }
        }
        let common = beforeIDs.intersection(afterIDs)
        if before.filter({ common.contains($0.id) }).map(\.id)
            != after.filter({ common.contains($0.id) }).map(\.id)
        {
            let current = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            cards = before.compactMap { current[$0.id] } + cards.filter { !beforeIDs.contains($0.id) }
        }
        replaceCards(cards, name: name, boardID: boardID, insertionPoint: insertionPoint)
    }

    // A drag previews positions in memory, then registers one undo step when released.
    func commitDrag(from original: [Card], name: String) {
        let final = board.cards
        if final == original {
            scheduleSave()
            return
        }
        board.cards = original
        replaceCards(final, name: name)
    }

    func activate(_ id: UUID) {
        guard workspace.boards.contains(where: { $0.id == id }) else { return }
        workspace.active = id
        scheduleSave()
        changed?()
    }

    func newBoard(name: String) {
        let next = Board(name: name)
        workspace.boards.append(next)
        activate(next.id)
    }
    @discardableResult func newPage(in workspaceID: UUID, name: String) -> UUID? {
        guard let current = workspace.boards.first(where: { $0.id == workspaceID }),
            let name = Self.cleanName(name)
        else { return nil }
        let parent = workspace.isContainer(workspaceID) ? workspaceID : current.parentID ?? workspaceID
        let page = Board(name: name, parentID: parent)
        workspace.boards.append(page)
        activate(page.id)
        return page.id
    }
    static func cleanName(_ name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(100))
    }
    func renameBoard(_ id: UUID, name: String) {
        guard let name = Self.cleanName(name),
            let index = workspace.boards.firstIndex(where: { $0.id == id }),
            workspace.boards[index].name != name
        else { return }
        workspace.boards[index].name = name
        scheduleSave()
        changed?()
    }
    func deletionScope(for id: UUID) -> [Board] {
        workspace.boards.filter { $0.id == id } + workspace.descendants(of: id)
    }
    func deleteBoardWithBackup(_ id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        let scope = deletionScope(for: id)
        guard scope.contains(where: { $0.id == id }) else {
            completion(
                .failure(
                    NSError(
                        domain: "Gather.Delete", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "This workspace or page no longer exists."])))
            return
        }
        backupNow { [weak self] result in
            guard let self else { return }
            if case .failure = result {
                completion(result)
                return
            }
            guard self.deletionScope(for: id) == scope else {
                completion(
                    .failure(
                        NSError(
                            domain: "Gather.Delete", code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "This workspace changed while its backup was saving. Nothing was deleted. Please try again."
                            ])))
                return
            }
            self.removeBoard(id)
            completion(.success(()))
        }
    }
    // The UI uses deleteBoardWithBackup; this mutation also serves recovery checks.
    func removeBoard(_ id: UUID) {
        guard let target = workspace.boards.first(where: { $0.id == id }) else { return }
        let removed = Set(deletionScope(for: id).map(\.id))
        workspace.boards.removeAll { removed.contains($0.id) }
        if workspace.boards.isEmpty { workspace.boards = [Board(name: "My first board")] }
        if workspace.active.map(removed.contains) == true {
            activate(target.parentID ?? workspace.boards[0].id)
        } else {
            scheduleSave()
            changed?()
        }
    }

    func backupNow(completion: ((Result<Void, Error>) -> Void)? = nil) {
        let snapshot = workspace
        let backups = self.backups
        saveQueue.async {
            let result = Result { try backups.capture(snapshot, force: true) }
            DispatchQueue.main.async { completion?(result) }
        }
    }
    func restoreBackup(_ backup: BackupRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        let manager = backups
        let directory = self.directory
        backupNow()
        saveQueue.async { [weak self] in
            let result = Result {
                try manager.restoredBoards(
                    from: backup, assetsDirectory: directory.appendingPathComponent("Assets"))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let boards):
                    let previous = self.workspace
                    self.workspace.boards.append(contentsOf: boards)
                    if self.workspaceOverviewsEnabled {
                        do { try self.enableWorkspaceOverviews() } catch {
                            self.workspace = previous
                            completion(.failure(error))
                            return
                        }
                    }
                    if let first = boards.first { self.activate(first.id) }
                    completion(.success(()))
                }
            }
        }
    }

    func image(_ name: String) -> NSImage? {
        if BoardImageIO.isSVG(name), name == URL(fileURLWithPath: name).lastPathComponent {
            return try? SVGImage(
                data: Data(
                    contentsOf: directory.appendingPathComponent("Assets").appendingPathComponent(name))
            ).image
        }
        guard name == URL(fileURLWithPath: name).lastPathComponent,
            let image = NSImage(
                contentsOf: directory.appendingPathComponent("Assets").appendingPathComponent(name))
        else { return nil }
        return image
    }
    func hasAsset(_ name: String) -> Bool {
        guard name == URL(fileURLWithPath: name).lastPathComponent else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Assets").appendingPathComponent(name).path,
            isDirectory: &isDirectory) && !isDirectory.boolValue
    }
    func originalImageData(_ name: String) -> Data? {
        guard hasAsset(name) else { return nil }
        return try? Data(
            contentsOf: directory.appendingPathComponent("Assets").appendingPathComponent(name),
            options: .mappedIfSafe)
    }

    func preview(_ name: String, pixelSize: CGFloat = 2048, crop: ImageCrop = .full) -> CGImage? {
        let vector = BoardImageIO.isSVG(name)
        let level = BoardImageIO.previewLevel(pixelSize)
        let key = vector ? BoardImageIO.vectorKey(name, level: level, crop: crop) : name
        if let cached = previews.object(forKey: key as NSString) { return cached }
        let fallback =
            vector
            ? [4096, 2048, 1024, 512].lazy.compactMap {
                self.previews.object(forKey: BoardImageIO.vectorKey(name, level: $0, crop: crop) as NSString)
            }.first : nil
        guard !loadingImages.contains(key), !failedImages.contains(key),
            name == URL(fileURLWithPath: name).lastPathComponent
        else { return fallback }
        loadingImages.insert(key)
        let url = directory.appendingPathComponent("Assets").appendingPathComponent(name)
        imageQueue.async { [weak self] in
            let thumbnail = BoardImageIO.preview(at: url, maxPixel: vector ? level : 2048, crop: crop)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingImages.remove(key)
                if let thumbnail {
                    self.cache(thumbnail, name: key)
                } else {
                    self.failedImages.insert(key)
                    self.imageRevision += 1
                }
                self.imageReady?()
            }
        }
        return fallback
    }
    func previewHasFailed(_ name: String, pixelSize: CGFloat, crop: ImageCrop) -> Bool {
        let key =
            BoardImageIO.isSVG(name)
            ? BoardImageIO.vectorKey(name, level: BoardImageIO.previewLevel(pixelSize), crop: crop) : name
        return failedImages.contains(key)
    }

    private func cache(_ image: CGImage, name: String) {
        previews.setObject(image, forKey: name as NSString, cost: image.bytesPerRow * image.height)
        imageRevision += 1
    }

    // Keep original bytes and decode a bounded preview on a serial worker queue.
    // The canvas receives no full-resolution image conversion work.
    func prepareImages(
        _ data: [Data], sourceURLs: [String?] = [], completion: @escaping ([PreparedImage], Int) -> Void
    ) {
        let assetDirectory = directory.appendingPathComponent("Assets")
        imageQueue.async { [weak self] in
            var prepared: [PreparedImage] = []
            var failed = 0
            var firstError: String?
            for (index, bytes) in data.enumerated() {
                autoreleasepool {
                    do {
                        let decoded = try BoardImageIO.decode(bytes)
                        let preview = decoded.preview
                        let ext = decoded.fileExtension
                        let name = UUID().uuidString + "." + ext
                        try bytes.write(to: assetDirectory.appendingPathComponent(name), options: .atomic)
                        prepared.append(
                            PreparedImage(
                                asset: name, preview: preview, size: decoded.size,
                                sourceURL: index < sourceURLs.count ? sourceURLs[index] : nil))
                    } catch {
                        failed += 1
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastImageImportError = firstError
                for image in prepared {
                    self.cache(
                        image.preview,
                        name: BoardImageIO.isSVG(image.asset) ? image.asset + "@1024" : image.asset)
                }
                completion(prepared, failed)
            }
        }
    }

    func card(for image: PreparedImage, at point: CGPoint) -> Card {
        let scale = max(
            min(440 / image.size.width, 440 / image.size.height),
            40 / min(image.size.width, image.size.height))
        return Card(
            x: point.x, y: point.y, width: max(40, image.size.width * scale),
            height: max(40, image.size.height * scale), asset: image.asset, sourceURL: image.sourceURL)
    }

    func imageCard(_ image: NSImage, at point: CGPoint) throws -> Card {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:]), bitmap.pixelsWide > 0,
            bitmap.pixelsHigh > 0
        else { throw CocoaError(.fileReadUnknown) }
        let decoded = try BoardImageIO.decode(png)
        let name = UUID().uuidString + ".png"
        try png.write(
            to: directory.appendingPathComponent("Assets").appendingPathComponent(name), options: .atomic)
        cache(decoded.preview, name: name)
        return card(for: PreparedImage(asset: name, preview: decoded.preview, size: decoded.size), at: point)
    }

    func portableData() throws -> Data {
        var exported = board
        exported.parentID = nil
        let pages = workspace.descendants(of: board.id)
        var assets: [String: Data] = [:]
        let hasVideos = ([exported] + pages).contains { $0.cards.contains(where: \.isVideo) }
        var total: Int64 = 0
        for name in Set(([exported] + pages).flatMap { $0.cards.flatMap(\.assetNames) }) {
            let url = directory.appendingPathComponent("Assets").appendingPathComponent(name)
            total += (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard !hasVideos || total <= 256 * 1024 * 1024 else {
                throw BoardExport.error(
                    "This board copy contains more than 256 MB of media. Export a smaller page instead. Your original videos and automatic local backups are preserved."
                )
            }
            assets[name] = try Data(contentsOf: url)
        }
        return try JSONEncoder().encode(
            PortableBoard(board: exported, assets: assets, pages: pages.isEmpty ? nil : pages))
    }

    func importBoard(data: Data) throws {
        let imported = try JSONDecoder().decode(PortableBoard.self, from: data)
        let pages = imported.pages ?? []
        let boards = [imported.board] + pages
        guard imported.version == 1, imported.board.parentID == nil,
            pages.allSatisfy({ $0.parentID != nil }), Workspace.validHierarchy(boards),
            boards.allSatisfy({
                $0.cards.allSatisfy(Self.valid) && $0.validSections
                    && Set($0.cards.map(\.id)).count == $0.cards.count && $0.zoom.isFinite
                    && (0.1...4).contains($0.zoom)
                    && $0.offsetX.isFinite && $0.offsetY.isFinite
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        let ids = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, UUID()) })
        var mapping: [String: String] = [:]
        let movies = Set(boards.flatMap { $0.cards.compactMap { $0.video?.file } })
        for name in Set(boards.flatMap { $0.cards.flatMap(\.assetNames) }) {
            guard let imageData = imported.assets[name] else { throw CocoaError(.fileReadCorruptFile) }
            let ext: String
            if movies.contains(name) {
                ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            } else {
                ext = try BoardImageIO.decode(imageData).fileExtension
            }
            let newName = UUID().uuidString + "." + ext
            try imageData.write(
                to: directory.appendingPathComponent("Assets").appendingPathComponent(newName),
                options: .atomic)
            if movies.contains(name) {
                _ = try VideoMedia.inspect(
                    directory.appendingPathComponent("Assets").appendingPathComponent(newName))
            }
            mapping[name] = newName
        }
        let copies = boards.map { original -> Board in
            var next = original
            next.id = ids[original.id]!
            next.parentID = original.parentID.flatMap { ids[$0] }
            for i in next.cards.indices {
                if let name = next.cards[i].asset { next.cards[i].asset = mapping[name] }
                if let name = next.cards[i].video?.file { next.cards[i].video?.file = mapping[name] }
            }
            return next
        }
        let previous = workspace
        workspace.boards.append(contentsOf: copies)
        do {
            if workspaceOverviewsEnabled { try enableWorkspaceOverviews() }
        } catch {
            workspace = previous
            throw error
        }
        activate(copies[0].id)
    }
}

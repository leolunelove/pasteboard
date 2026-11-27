import CryptoKit
import Foundation

struct BackupRecord: Codable {
    let id: UUID
    let created: Date
    let boardCount: Int
    let itemCount: Int
    var folderName: String { id.uuidString }
}

final class LocalBackups {
    let directory: URL
    let assets: URL
    let folder: URL
    private var lastDate = Date.distantPast
    private var lastFingerprint: String?
    private var loadedPreviousState = false
    init(directory: URL) {
        self.directory = directory
        assets = directory.appendingPathComponent("Assets")
        folder = directory.appendingPathComponent("Backups")
    }
    private struct Content: Codable {
        struct Entry: Codable {
            let id: UUID
            let name: String
            let cards: [Card]
            let parentID: UUID?
        }
        let boards: [Entry]
    }
    private func fingerprint(_ workspace: Workspace) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(
            Content(
                boards: workspace.boards.map {
                    Content.Entry(id: $0.id, name: $0.name, cards: $0.cards, parentID: $0.parentID)
                }))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    // Called only on BoardStore's serial save queue. Assets are immutable, so
    // hard links make each checkpoint independently restorable without duplicating bytes.
    func capture(_ workspace: Workspace, force: Bool = false, now: Date = Date()) throws {
        if !loadedPreviousState {
            loadedPreviousState = true
            if let latest = records().first,
                let data = try? Data(
                    contentsOf: folder.appendingPathComponent(latest.folderName).appendingPathComponent(
                        "Workspace.json")),
                let previous = try? JSONDecoder().decode(Workspace.self, from: data),
                let hash = try? fingerprint(previous)
            {
                lastDate = latest.created
                lastFingerprint = hash
            }
        }
        let hash = try fingerprint(workspace)
        guard hash != lastFingerprint else { return }
        guard force || now.timeIntervalSince(lastDate) >= 300 else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = BackupRecord(
            id: UUID(), created: now, boardCount: workspace.boards.count,
            itemCount: workspace.boards.reduce(0) { $0 + $1.cards.count })
        let staging = folder.appendingPathComponent(".pending-" + record.folderName)
        let destination = folder.appendingPathComponent(record.folderName)
        do {
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            for asset in Set(workspace.boards.flatMap { $0.cards.flatMap(\.assetNames) }) {
                guard asset == URL(fileURLWithPath: asset).lastPathComponent else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let source = assets.appendingPathComponent(asset)
                let target = staging.appendingPathComponent("Assets").appendingPathComponent(asset)
                do { try FileManager.default.linkItem(at: source, to: target) } catch {
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
            try JSONEncoder().encode(workspace).write(
                to: staging.appendingPathComponent("Workspace.json"), options: .atomic)
            try JSONEncoder().encode(record).write(
                to: staging.appendingPathComponent("Record.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
            lastDate = now
            lastFingerprint = hash
            try prune(now: now)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
    func records() -> [BackupRecord] {
        let paths =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return paths.compactMap { url -> BackupRecord? in
            guard let id = UUID(uuidString: url.lastPathComponent),
                let data = try? Data(contentsOf: url.appendingPathComponent("Record.json")),
                let record = try? JSONDecoder().decode(BackupRecord.self, from: data), record.id == id
            else { return nil }
            return record
        }.sorted { $0.created > $1.created }
    }
    private func prune(now: Date) throws {
        let all = records()
        var keep = Set(all.prefix(40).map(\.id))
        var days = Set<String>()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        for record in all where now.timeIntervalSince(record.created) < 14 * 24 * 3600 {
            if days.insert(formatter.string(from: record.created)).inserted { keep.insert(record.id) }
        }
        for record in all where !keep.contains(record.id) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(record.folderName))
        }
    }
    func restoredBoards(from record: BackupRecord, assetsDirectory: URL) throws -> [Board] {
        let source = folder.appendingPathComponent(record.folderName)
        let workspace = try JSONDecoder().decode(
            Workspace.self, from: Data(contentsOf: source.appendingPathComponent("Workspace.json")))
        guard workspace.version == 1, Workspace.validHierarchy(workspace.boards),
            workspace.boards.allSatisfy({
                Set($0.cards.map(\.id)).count == $0.cards.count && $0.cards.allSatisfy(BoardStore.valid)
                    && $0.zoom.isFinite && (0.1...4).contains($0.zoom)
                    && $0.offsetX.isFinite && $0.offsetY.isFinite
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        for name in Set(workspace.boards.flatMap { $0.cards.flatMap(\.assetNames) }) {
            let new = UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension
            try FileManager.default.copyItem(
                at: source.appendingPathComponent("Assets").appendingPathComponent(name),
                to: assetsDirectory.appendingPathComponent(new))
            names[name] = new
        }
        let ids = Dictionary(uniqueKeysWithValues: workspace.boards.map { ($0.id, UUID()) })
        return workspace.boards.map { original in
            var board = original
            board.id = ids[original.id]!
            board.parentID = original.parentID.flatMap { ids[$0] }
            board.name += " (restored)"
            var groups: [UUID: UUID] = [:]
            let cardIDs = Dictionary(uniqueKeysWithValues: board.cards.map { ($0.id, UUID()) })
            for i in board.cards.indices {
                board.cards[i].id = cardIDs[board.cards[i].id]!
                if var draft = board.cards[i].socialPost {
                    draft.memberIDs = draft.memberIDs.map { cardIDs[$0] ?? $0 }
                    board.cards[i].socialPost = draft
                }
                if let asset = board.cards[i].asset { board.cards[i].asset = names[asset] }
                if let file = board.cards[i].video?.file { board.cards[i].video?.file = names[file] }
                if let group = board.cards[i].groupID {
                    if groups[group] == nil { groups[group] = UUID() }
                    board.cards[i].groupID = groups[group]
                }
            }
            return board
        }
    }
}

import AppKit
import Vision

enum SourceLink {
    static func url(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
            ["http", "https", "file"].contains(scheme)
        else { return nil }
        guard scheme == "file" || url.host?.isEmpty == false else { return nil }
        return url
    }
    static func normalized(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") { return URL(fileURLWithPath: text).absoluteString }
        if let url = url(text) { return url.absoluteString }
        if !text.contains("://"), !text.contains(" "), text.contains("."), let url = url("https://" + text) {
            return url.absoluteString
        }
        return nil
    }
    static func clipboard(_ pasteboard: NSPasteboard) -> String? {
        if let value = pasteboard.string(forType: .URL), let url = url(value) { return url.absoluteString }
        if let html = pasteboard.string(forType: .html),
            let pattern = try? NSRegularExpression(
                pattern: "(?i)(?:src|href)\\s*=\\s*[\"'](https?://[^\"']+)[\"']"),
            let match = pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html),
            let url = url(String(html[range]).replacingOccurrences(of: "&amp;", with: "&"))
        {
            return url.absoluteString
        }
        return nil
    }
}

final class ImageTextIndex {
    private let directory: URL
    private let queue = DispatchQueue(label: "Gather.text-recognition", qos: .utility)
    private let writes = DispatchQueue(label: "Gather.search-index", qos: .utility)
    private var writeTask: DispatchWorkItem?
    private(set) var text: [String: String] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()
    private(set) var failures = 0
    var onChanged: (() -> Void)?
    var pendingCount: Int { pending.count }
    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("SearchIndex.json")),
            let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            text = saved
        }
    }
    static func recognize(at url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
            separator: "\n")
    }
    func index(_ workspace: Workspace) {
        for name in Set(workspace.boards.flatMap { $0.cards.compactMap(\.asset) })
        where text[name] == nil && !pending.contains(name) && !failed.contains(name) {
            guard name == URL(fileURLWithPath: name).lastPathComponent else { continue }
            pending.insert(name)
            let url = directory.appendingPathComponent("Assets").appendingPathComponent(name)
            queue.async { [weak self] in
                let result = Result { try Self.recognize(at: url) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(name)
                    switch result {
                    case .success(let value): self.text[name] = value
                    case .failure:
                        self.failures += 1
                        self.failed.insert(name)
                    }
                    self.scheduleWrite()
                    self.onChanged?()
                }
            }
        }
    }
    private func scheduleWrite() {
        writeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.text
            let url = self.directory.appendingPathComponent("SearchIndex.json")
            self.writes.async { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
        }
        writeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
}

struct BoardSearchResult {
    let boardID: UUID
    let cardID: UUID?
    let title: String
    let detail: String
}
enum BoardSearch {
    static func results(in workspace: Workspace, imageText: [String: String], query: String)
        -> [BoardSearchResult]
    {
        func normalize(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let words = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func matches(_ value: String) -> Bool {
            let value = normalize(value)
            return words.allSatisfy(value.contains)
        }
        var results: [BoardSearchResult] = []
        for board in workspace.boards {
            let path = workspace.path(for: board)
            if matches(path) {
                results.append(
                    BoardSearchResult(
                        boardID: board.id, cardID: nil, title: board.name,
                        detail: (board.parentID == nil ? "Workspace" : path) + " · \(board.cards.count) items"
                    ))
            }
            for card in board.cards {
                let recognized = card.asset.flatMap { imageText[$0] } ?? ""
                let content = [card.hex ?? "", card.text ?? "", recognized, card.sourceURL ?? ""].joined(
                    separator: " ")
                if matches(path + " " + content) {
                    let excerpt =
                        (card.hex ?? card.text
                        ?? (recognized.isEmpty ? card.sourceURL ?? "Image" : recognized))
                        .replacingOccurrences(of: "\n", with: " ")
                    results.append(
                        BoardSearchResult(
                            boardID: board.id, cardID: card.id, title: String(excerpt.prefix(130)),
                            detail: path + " · "
                                + (card.hex != nil ? "Colour swatch" : card.asset == nil ? "Note" : "Image")
                                + (card.isLocked ? " · Locked" : "")))
                }
            }
        }
        return Array(results.prefix(200))
    }
}

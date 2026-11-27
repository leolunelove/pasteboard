import AppKit

// Optional card metadata keeps older boards and portable board files compatible.
enum SocialPlatform: String, Codable, CaseIterable {
    case instagram, story, linkedin, x
    var title: String {
        switch self {
        case .instagram: return "Instagram Feed"
        case .story: return "Instagram Story"
        case .linkedin: return "LinkedIn"
        case .x: return "X"
        }
    }
}
enum SocialFormat: String, Codable, CaseIterable {
    case original, square, portrait, photo, landscape
    var title: String {
        switch self {
        case .original: return "Original proportions"
        case .square: return "Square · 1:1"
        case .portrait: return "Portrait · 4:5"
        case .photo: return "Photo · 3:4"
        case .landscape: return "Landscape · 1.91:1"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .portrait: return 0.8
        case .photo: return 0.75
        case .landscape: return 1.91
        }
    }
}
struct SocialDraft: Codable, Equatable {
    var isReady = true
    var caption = ""
    var platform: SocialPlatform = .instagram
    var format: SocialFormat = .original
    var fill = false
    var memberIDs: [UUID]
    var isValid: Bool {
        caption.count <= 10_000 && !memberIDs.isEmpty && memberIDs.count <= 10_000
            && Set(memberIDs).count == memberIDs.count
    }
}
struct SocialPost: Equatable {
    let boardID: UUID
    let anchorID: UUID
    let pageName: String
    var draft: SocialDraft
    let cards: [Card]
    var isComplete: Bool {
        Set(cards.map(\.id)) == Set(draft.memberIDs) && !cards.contains(where: \.isVideo)
            && cards.contains { $0.asset != nil }
    }
    var title: String { cards.count == 1 ? "Image" : "Frame · \(draft.memberIDs.count) items" }
}
extension BoardStore {
    func socialPost(boardID: UUID, anchorID: UUID) -> SocialPost? {
        guard let page = workspace.boards.first(where: { $0.id == boardID }),
            let anchor = page.cards.first(where: { $0.id == anchorID }), let draft = anchor.socialPost
        else { return nil }
        let ids = Set(draft.memberIDs)
        return SocialPost(
            boardID: boardID, anchorID: anchorID, pageName: page.name, draft: draft,
            cards: page.cards.filter { ids.contains($0.id) })
    }
    var allReadyPosts: [SocialPost] { readyPosts(in: nil) }
    func readyPosts(in rootID: UUID?) -> [SocialPost] {
        let scoped = rootID.map { id in
            Set([id] + workspace.descendants(of: id).map(\.id))
        }
        return workspace.boards.filter { scoped?.contains($0.id) ?? true }.flatMap {
            page -> [SocialPost] in
            let anchors = page.cards.filter { $0.socialPost?.isReady == true }
            guard !anchors.isEmpty else { return [] }
            var lookup: [UUID: (Card, Int)] = [:]
            for (index, card) in page.cards.enumerated() { lookup[card.id] = (card, index) }
            return anchors.compactMap { anchor -> SocialPost? in
                let draft = anchor.socialPost!
                let members = draft.memberIDs.compactMap { lookup[$0] }.sorted { $0.1 < $1.1 }.map { $0.0 }
                guard !members.contains(where: \.isVideo) else { return nil }
                return SocialPost(
                    boardID: page.id, anchorID: anchor.id, pageName: page.name, draft: draft, cards: members)
            }
        }
    }
    func selectedPost(_ ids: Set<UUID>) -> SocialPost? {
        guard !ids.isEmpty else { return nil }
        let matches = board.cards.compactMap { card -> SocialPost? in
            guard let draft = card.socialPost, ids.isSubset(of: Set(draft.memberIDs)) else { return nil }
            return socialPost(boardID: board.id, anchorID: card.id)
        }
        return matches.sorted {
            if $0.draft.isReady != $1.draft.isReady { return $0.draft.isReady }
            return $0.draft.memberIDs.count < $1.draft.memberIDs.count
        }.first
    }
    @discardableResult func markReady(_ ids: Set<UUID>) throws -> SocialPost {
        guard !board.cards.contains(where: { ids.contains($0.id) && $0.isVideo }) else {
            throw BoardExport.error(
                "Videos and YouTube cards cannot be marked ready to post. Select images and notes only.")
        }
        if var existing = selectedPost(ids), existing.isComplete {
            existing.draft.isReady = true
            guard updateSocialDraft(existing.draft, boardID: existing.boardID, anchorID: existing.anchorID)
            else {
                throw BoardExport.error(
                    "This frame overlaps another ready post. Unmark that post before marking this frame.")
            }
            return existing
        }
        let members = board.cards.filter { ids.contains($0.id) }
        guard !members.isEmpty, members.contains(where: { $0.asset != nil }) else {
            throw BoardExport.error("Select an image, or select images and notes together as a frame.")
        }
        guard
            !board.cards.contains(where: { card in
                card.socialPost.map { $0.isReady && !ids.isDisjoint(with: $0.memberIDs) } ?? false
            })
        else {
            throw BoardExport.error(
                "Some selected items are already in a ready post. Unmark that post before making a new frame."
            )
        }
        let anchor = members.first(where: { $0.asset != nil })!
        let draft = SocialDraft(memberIDs: members.map(\.id))
        updateSocialDraft(draft, boardID: board.id, anchorID: anchor.id)
        return socialPost(boardID: board.id, anchorID: anchor.id)!
    }
    @discardableResult func updateSocialDraft(_ draft: SocialDraft, boardID: UUID, anchorID: UUID) -> Bool {
        guard draft.isValid, draft.memberIDs.contains(anchorID),
            let page = workspace.boards.first(where: { $0.id == boardID }),
            let index = page.cards.firstIndex(where: { $0.id == anchorID })
        else { return false }
        if draft.isReady {
            let ids = Set(draft.memberIDs)
            guard !page.cards.contains(where: { ids.contains($0.id) && $0.isVideo }) else { return false }
            guard
                !page.cards.contains(where: { card in
                    card.id != anchorID
                        && (card.socialPost.map { $0.isReady && !ids.isDisjoint(with: $0.memberIDs) } ?? false)
                })
            else { return false }
        }
        var cards = page.cards
        cards[index].socialPost = draft
        replaceCards(cards, name: "Update Post Draft", boardID: boardID)
        return true
    }
}
extension BoardView {
    @objc func markReadyToPost(_ sender: Any?) {
        finishEditing()
        do {
            let post = try store.markReady(selection)
            onOpenSocialPost?(post.boardID, post.anchorID)
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }
    @objc func previewSocialPost(_ sender: Any?) {
        finishEditing()
        if let post = store.selectedPost(selection) { onOpenSocialPost?(post.boardID, post.anchorID) }
    }
    @objc func unmarkReadyToPost(_ sender: Any?) {
        if var post = store.selectedPost(selection) {
            post.draft.isReady = false
            store.updateSocialDraft(post.draft, boardID: post.boardID, anchorID: post.anchorID)
        }
    }
}

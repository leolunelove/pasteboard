import AppKit

extension SVGImage {
    func recoloured(hex: String) throws -> Data {
        guard let colour = SwatchColor(hex) else { throw Self.error("Enter a valid HEX colour.") }
        let document = try XMLDocument(data: renderingData, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement() else { throw Self.error("This SVG cannot be recoloured.") }
        let paints = Set(["fill", "stroke", "stop-color", "color"])
        func repaint(_ input: String) -> String {
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            if ["none", "transparent", "inherit", "initial", "unset"].contains(lower)
                || lower.hasPrefix("url(")
            {
                return input
            }
            // Keep alpha encoded in a paint rather than making it opaque.
            var alpha: String?
            if lower.hasPrefix("#"), value.count == 5, let a = value.last,
                let byte = Int(String(repeating: a, count: 2), radix: 16)
            {
                alpha = String(Double(byte) / 255)
            }
            if lower.hasPrefix("#"), value.count == 9, let byte = Int(value.suffix(2), radix: 16) {
                alpha = String(Double(byte) / 255)
            }
            if lower.hasPrefix("rgba("), let last = value.split(separator: ",").last {
                alpha = last.replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
            }
            if let alpha {
                return
                    "rgba(\(Int((colour.red * 255).rounded())),\(Int((colour.green * 255).rounded())),\(Int((colour.blue * 255).rounded())),\(alpha))"
            }
            return colour.hex
        }
        let declarations = try NSRegularExpression(
            pattern: #"(?i)(?<![\w-])(fill|stroke|stop-color|color)\s*:\s*([^;}{]+)"#)
        func recolourStyle(_ text: String) -> String {
            var result = text
            for match in declarations.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .reversed()
            {
                guard let range = Range(match.range(at: 2), in: text) else { continue }
                let old = String(text[range])
                let important = old.lowercased().contains("!important")
                let paint = old.replacingOccurrences(
                    of: #"(?i)\s*!important\s*"#, with: "", options: .regularExpression)
                result.replaceSubrange(range, with: repaint(paint) + (important ? " !important" : ""))
            }
            return result
        }
        var stack: [(XMLElement, [String: String])] = [
            (root, ["fill": "black", "stroke": "none", "color": "black", "stop-color": "black"])
        ]
        while let (element, inherited) = stack.popLast() {
            var originalPaints = inherited
            for attribute in element.attributes ?? [] {
                let key = (attribute.localName ?? attribute.name ?? "").lowercased()
                if paints.contains(key) { originalPaints[key] = attribute.stringValue ?? inherited[key] }
                if key == "style", let text = attribute.stringValue {
                    for match in declarations.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    {
                        if let keyRange = Range(match.range(at: 1), in: text),
                            let valueRange = Range(match.range(at: 2), in: text)
                        {
                            originalPaints[String(text[keyRange]).lowercased()] = String(text[valueRange])
                        }
                    }
                }
            }
            let name = (element.localName ?? element.name ?? "").lowercased()
            // Mask luminance and clip geometry determine transparency, not artwork colour.
            if ["mask", "clippath", "filter"].contains(name) {
                // Freeze inherited paints before the artwork's root colour changes.
                for key in ["fill", "stroke", "color"] where element.attribute(forName: key) == nil {
                    element.addAttribute(
                        XMLNode.attribute(withName: key, stringValue: originalPaints[key] ?? "black")
                            as! XMLNode)
                }
                continue
            }
            for attribute in element.attributes ?? [] {
                let key = (attribute.localName ?? attribute.name ?? "").lowercased()
                if paints.contains(key) { attribute.stringValue = repaint(attribute.stringValue ?? "") }
                if key == "style" { attribute.stringValue = recolourStyle(attribute.stringValue ?? "") }
            }
            if name == "style" { element.stringValue = recolourStyle(element.stringValue ?? "") }
            stack += (element.children ?? []).compactMap { $0 as? XMLElement }.map { ($0, originalPaints) }
        }
        if root.attribute(forName: "fill") == nil {
            root.addAttribute(XMLNode.attribute(withName: "fill", stringValue: colour.hex) as! XMLNode)
        }
        root.removeAttribute(forName: "color")
        root.addAttribute(XMLNode.attribute(withName: "color", stringValue: colour.hex) as! XMLNode)
        let data = Data(root.xmlString.utf8)
        _ = try SVGImage(data: data)
        return data
    }
}

extension BoardStore {
    func recolourSVG(
        _ id: UUID, hex: String, boardID: UUID, completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let index = workspace.boards.firstIndex(where: { $0.id == boardID }),
            let card = workspace.boards[index].cards.first(where: { $0.id == id }),
            !workspace.boards[index].lockedIDs.contains(id), let asset = card.asset,
            BoardImageIO.isSVG(asset),
            let original = originalImageData(asset)
        else {
            completion(.failure(SVGImage.error("Select an unlocked SVG image.")))
            return
        }
        // Recolouring creates a new asset: shared copies and undo retain their originals.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SVGImage(data: original).recoloured(hex: hex) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let data):
                    self.prepareImages([data]) { images, _ in
                        guard let image = images.first else {
                            completion(.failure(SVGImage.error("This SVG could not be recoloured.")))
                            return
                        }
                        guard let board = self.workspace.boards.first(where: { $0.id == boardID }),
                            let position = board.cards.firstIndex(where: { $0.id == id && $0.asset == asset }
                            ),
                            !board.lockedIDs.contains(id)
                        else {
                            completion(
                                .failure(SVGImage.error("The selected SVG changed. Please try again.")))
                            return
                        }
                        var cards = board.cards
                        cards[position].asset = image.asset
                        self.replaceCards(cards, name: "Recolour SVG", boardID: boardID)
                        completion(.success(()))
                    }
                }
            }
        }
    }
}

extension BoardView {
    var svgColourCandidate: Card? {
        let cards = store.board.cards.filter {
            selection.contains($0.id) && $0.asset.map(BoardImageIO.isSVG) == true
        }
        return cards.count == 1 && selection.count == 1 ? cards[0] : nil
    }
    @objc func recolourSVG(_ sender: Any?) {
        guard let card = svgColourCandidate, !store.board.lockedIDs.contains(card.id), let window else {
            return
        }
        finishEditing()
        cancelCropping(nil)
        let boardID = store.board.id
        let alert = NSAlert()
        alert.messageText = "Recolour SVG"
        alert.informativeText =
            "Change fills and strokes to one colour. Transparent areas, masks and empty strokes are kept. Undo restores the original."
        let apply = alert.addButton(withTitle: "Apply Colour")
        alert.addButton(withTitle: "Cancel")
        let editor = SwatchEditor(hex: "#3456C8")
        editor.validityChanged = { [weak apply] in apply?.isEnabled = $0 }
        alert.accessoryView = editor
        alert.window.initialFirstResponder = editor.field
        alert.beginSheetModal(for: window) { [weak self] result in
            editor.well.deactivate()
            guard let self, result == .alertFirstButtonReturn, let hex = editor.hex else { return }
            self.store.status?("Recolouring SVG…")
            self.store.recolourSVG(card.id, hex: hex, boardID: boardID) { result in
                switch result {
                case .failure(let error): self.showError(error)
                case .success: self.store.status?("SVG colour updated")
                }
            }
        }
    }
}

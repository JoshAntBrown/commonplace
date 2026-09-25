import Foundation
import CryptoKit

/// The library is a plain folder: one sub-folder per board, each holding
/// `board.json` (layout + connections), `cards/*.md` and `assets/`.
@Observable
final class Library {
    let root: URL
    private(set) var boards: [String] = []

    init() {
        if let custom = UserDefaults.standard.string(forKey: "libraryPath"), !custom.isEmpty {
            root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Commonplace", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
        if boards.isEmpty { Seed.startHere(in: self) }
    }

    func refresh() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        boards = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func folder(for name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    @discardableResult
    func createBoard(named base: String = "Untitled") -> String {
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(for: name).path) {
            name = "\(base) \(n)"
            n += 1
        }
        try? FileManager.default.createDirectory(
            at: folder(for: name).appendingPathComponent("cards"), withIntermediateDirectories: true)
        refresh()
        return name
    }

    /// Returns the new name on success.
    func rename(_ old: String, to proposed: String) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != old, !FileManager.default.fileExists(atPath: folder(for: name).path) else { return nil }
        do {
            try FileManager.default.moveItem(at: folder(for: old), to: folder(for: name))
            refresh()
            return name
        } catch {
            return nil
        }
    }

    func delete(_ name: String) {
        try? FileManager.default.trashItem(at: folder(for: name), resultingItemURL: nil)
        refresh()
    }

    func load(_ name: String) -> Board {
        let fm = FileManager.default
        let dir = folder(for: name)
        var board = Board(name: name, folder: dir)

        var byID: [UUID: Card] = [:]
        let cardsDir = dir.appendingPathComponent("cards")
        for file in (try? fm.contentsOfDirectory(at: cardsDir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let card = CardFile.decode(text, fileName: file.lastPathComponent)
            byID[card.id] = card
        }

        if let data = try? Data(contentsOf: dir.appendingPathComponent("board.json")),
           let file = try? JSONDecoder().decode(BoardFile.self, from: data) {
            board.viewport = file.viewport
            for p in file.cards {
                guard var card = byID.removeValue(forKey: p.id) else { continue }
                card.frame = CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
                board.cards.append(card)
            }
            let ids = Set(board.cards.map(\.id))
            board.connections = file.connections.filter { ids.contains($0.from) && ids.contains($0.to) }
        }

        // Markdown files with no placement yet (e.g. added by hand) go in a grid below.
        let bottom = board.cards.map(\.frame.maxY).max() ?? 0
        for (i, var card) in byID.values.sorted(by: { $0.created < $1.created }).enumerated() {
            let size = card.kind.defaultSize
            card.frame = CGRect(x: Double(i % 4) * 360, y: bottom + 80 + Double(i / 4) * 300,
                                width: size.width, height: size.height)
            board.cards.append(card)
        }
        return board
    }

    func save(_ board: Board, viewport: Viewport, dirty: Set<UUID>, removed: [String]) {
        let fm = FileManager.default
        let cardsDir = board.folder.appendingPathComponent("cards")
        try? fm.createDirectory(at: cardsDir, withIntermediateDirectories: true)

        for card in board.cards where dirty.contains(card.id) {
            try? CardFile.encode(card).write(to: cardsDir.appendingPathComponent(card.fileName),
                                             atomically: true, encoding: .utf8)
        }
        for name in removed {
            try? fm.trashItem(at: cardsDir.appendingPathComponent(name), resultingItemURL: nil)
        }

        let file = BoardFile(
            cards: board.cards.map { .init(id: $0.id, x: $0.frame.minX, y: $0.frame.minY, w: $0.frame.width, h: $0.frame.height) },
            connections: board.connections,
            viewport: viewport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(file).write(to: board.folder.appendingPathComponent("board.json"), options: .atomic)
    }
}

/// Markdown with a small YAML front-matter block, readable in Obsidian or any editor.
enum CardFile {
    private static let dates = ISO8601DateFormatter()

    static func encode(_ card: Card) -> String {
        var lines = ["---", "id: \(card.id.uuidString.lowercased())", "kind: \(card.kind.rawValue)"]
        if card.color != .none { lines.append("color: \(card.color.rawValue)") }
        if !card.title.isEmpty { lines.append("title: \(quote(card.title))") }
        if let url = card.url { lines.append("url: \(quote(url))") }
        if let image = card.image { lines.append("image: \(quote(image))") }
        if let summary = card.summary, !summary.isEmpty { lines.append("summary: \(quote(summary))") }
        if let media = card.media { lines.append("media: \(quote(media))") }
        if let source = card.source { lines.append("source: \(quote(source))") }
        if card.speed != 1 { lines.append("speed: \(card.speed)") }
        if card.position > 0 { lines.append("position: \(Int(card.position))") }
        if let origin = card.thoughtOf { lines.append("thought-of: \(origin.uuidString.lowercased())") }
        lines.append("created: \(dates.string(from: card.created))")
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + "\n" + card.body + (card.body.hasSuffix("\n") ? "" : "\n")
    }

    static func decode(_ text: String, fileName: String) -> Card {
        var fields: [String: String] = [:]
        var body = text

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("---\n") {
            let rest = normalized.dropFirst(4)
            if let end = rest.range(of: "\n---\n") ?? rest.range(of: "\n---", options: .anchored) {
                for line in rest[..<end.lowerBound].split(separator: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    fields[key] = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
                body = String(rest[end.upperBound...])
                if body.hasPrefix("\n") { body.removeFirst() }
            }
        }
        if body.hasSuffix("\n") { body.removeLast() }

        let stem = (fileName as NSString).deletingPathExtension
        let id = fields["id"].flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: stem) ?? stableID(fileName)
        var card = Card(id: id, kind: fields["kind"].flatMap(CardKind.init(rawValue:)) ?? .note)
        card.color = fields["color"].flatMap(CardColor.init(rawValue:)) ?? .none
        card.title = fields["title"] ?? (fields.isEmpty ? stem : "")
        card.url = fields["url"]
        card.image = fields["image"]
        card.summary = fields["summary"]
        card.media = fields["media"]
        card.source = fields["source"]
        card.thoughtOf = (fields["thought-of"] ?? fields["moment-of"]).flatMap(UUID.init(uuidString:))
        card.speed = fields["speed"].flatMap(Double.init) ?? 1
        card.position = fields["position"].flatMap(Double.init) ?? 0
        card.created = fields["created"].flatMap(dates.date(from:)) ?? Date()
        card.body = body
        card.file = fileName
        return card
    }

    private static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), let data = s.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return s }
        return value
    }

    /// Hand-written files without an id get a stable one derived from their name.
    private static func stableID(_ name: String) -> UUID {
        let d = Array(Insecure.MD5.hash(data: Data(name.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}

enum Seed {
    static func startHere(in library: Library) {
        let name = library.createBoard(named: "Start Here")
        var board = Board(name: name, folder: library.folder(for: name))

        var welcome = Card(kind: .note)
        welcome.title = "Welcome to Commonplace"
        welcome.color = .blue
        welcome.body = """
        A canvas for collecting references, snippets and notes, and connecting them.

        - Paste a **YouTube** or **X** link to get a playable video card
        - Press **T** on a selected video to note the current moment
        - Everything is saved as Markdown in `~/Commonplace`
        """
        welcome.frame = CGRect(x: 0, y: 0, width: 340, height: 260)

        var keys = Card(kind: .sticky)
        keys.color = .yellow
        keys.body = """
        # Shortcuts
        - **S** sticky · **N** note
        - **L** link or video · **I** image
        - **⌘V** paste a URL, image or text
        - **C** connect, then click a card
        - **T** timestamp on a video
        - **1–6** colour · **7** clear
        - **Return** edit · **Esc** done
        - **F** fit · **0** 100% · **?** help
        """
        keys.frame = CGRect(x: 420, y: -10, width: 280, height: 290)

        board.cards = [welcome, keys]
        board.connections = [Connection(from: welcome.id, to: keys.id, label: "start here")]
        library.save(board, viewport: Viewport(x: 80, y: 80, scale: 1),
                     dirty: Set(board.cards.map(\.id)), removed: [])
        library.refresh()
    }
}

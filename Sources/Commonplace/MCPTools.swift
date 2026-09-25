import Foundation
import CoreGraphics

struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// The tools agents get over MCP. Calls run on the main thread against the
/// same live board stores as the canvas, so changes appear immediately and
/// can be undone with ⌘Z. Agent edits never take over the user's selection
/// or keyboard focus.
final class MCPTools {
    let library: Library

    init(library: Library) {
        self.library = library
    }

    static let instructions = """
    Commonplace is the user's thinking canvas: boards of cards (sticky, note, link, video, image, \
    place). It's a space for exploring ideas, not a document to tidy.
    Two kinds of link: a card's `parent` is its sequence link, the card it follows from or forms part \
    of (one parent each, so the board has a tree that can be tidied and read in order); connections \
    are references, "this relates to that", anywhere on the board. Use parent for elaboration and \
    continuation, connect for everything else.
    - Add rather than rewrite. Draw a thought out of a card with add_thought; on a video it becomes \
    a timestamped moment. Leave the user's own words alone unless they ask you to change them.
    - Don't delete the user's cards unless they ask.
    - Bring sources in with clip_url so where things came from is kept.
    - Keep the board calm: put new cards beside what they relate to (near=<card id>), connect only \
    the strongest relationships (one or two per card), keep labels to a few words, and prefer one \
    note with a list over many stickies.
    - Omit `board` to use the board on screen. Card ids can be given as a unique prefix.
    - Every change can be undone in the app with ⌘Z.
    """

    // MARK: Definitions

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                             required: [String] = [], readOnly: Bool, destructive: Bool = false) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false],
        ]
    }

    private static let boardArg: [String: Any] = ["type": "string", "description": "Board name; defaults to the board on screen."]
    private static let cardArg: [String: Any] = ["type": "string", "description": "Card id (or a unique prefix of it)."]
    private static let colors = ["none", "yellow", "orange", "pink", "purple", "blue", "green"]

    static let definitions: [[String: Any]] = [
        tool("list_boards", "List the boards in the library, with card counts and which one is on screen.",
             readOnly: true),
        tool("get_board", "Everything on a board: cards (bodies truncated) and connections.",
             ["board": boardArg], readOnly: true),
        tool("get_card", "One card in full, with the connections touching it.",
             ["card_id": cardArg, "board": boardArg], required: ["card_id"], readOnly: true),
        tool("search", "Find cards by words in their title, text, summary or URL, across all boards or one.",
             ["query": ["type": "string"], "board": ["type": "string", "description": "Limit to one board."],
              "limit": ["type": "integer", "description": "Max results (default 30)."]],
             required: ["query"], readOnly: true),
        tool("get_selection", "The cards the user has selected on screen right now: what they're looking at.",
             readOnly: true),
        tool("get_video_moments",
             "A video card's moments (timestamped stickies) in time order, and the current playback position.",
             ["card_id": cardArg, "board": boardArg], required: ["card_id"], readOnly: true),
        tool("add_card", "Add a sticky, note or breadboard place. Use clip_url for links, videos and images. Give `parent` when the card follows from or elaborates another.",
             ["kind": ["type": "string", "enum": ["sticky", "note", "place"]],
              "title": ["type": "string", "description": "Note title or place name."],
              "body": ["type": "string", "description": "Markdown text. For a place: one affordance per line."],
              "color": ["type": "string", "enum": colors],
              "parent": ["type": "string", "description": "Card id this follows from (sequence link); it's placed in that card's column."],
              "near": ["type": "string", "description": "Card id to place this beside, without a sequence link."],
              "connect_from": ["type": "string", "description": "Card id to draw a reference from to the new card."],
              "x": ["type": "number"], "y": ["type": "number"], "board": boardArg],
             required: ["kind"], readOnly: false),
        tool("add_thought",
             "Draw a thought out of a card: a sticky that follows from it (its parent), placed beside it. On a video (or one of its moments) it's a moment; the timestamp defaults to the current playback position.",
             ["card_id": cardArg, "body": ["type": "string"],
              "timestamp": ["type": "number", "description": "Seconds into the video, for moments."],
              "board": boardArg],
             required: ["card_id", "body"], readOnly: false),
        tool("update_card", "Change a card's text, colour, position or size. Prefer `append` to keep the user's words.",
             ["card_id": cardArg, "title": ["type": "string"], "body": ["type": "string", "description": "Replaces the text."],
              "append": ["type": "string", "description": "Added as a new line after the existing text."],
              "color": ["type": "string", "enum": colors],
              "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
              "board": boardArg],
             required: ["card_id"], readOnly: false),
        tool("connect", "Add a reference between two cards (this relates to that), optionally labelled with why. For 'follows from / part of', use set_parent instead.",
             ["from": cardArg, "to": cardArg, "label": ["type": "string"],
              "from_affordance": ["type": "string", "description": "For a place card: the affordance line the arrow starts from."],
              "board": boardArg],
             required: ["from", "to"], readOnly: false),
        tool("clip_url",
             "Bring something from the web onto the board. YouTube and X posts become playable video cards; image URLs become image cards; anything else a link card with a preview.",
             ["url": ["type": "string"], "near": ["type": "string", "description": "Card id to place this beside."],
              "board": boardArg],
             required: ["url"], readOnly: false),
        tool("set_parent",
             "Set a card's sequence link: the card it follows from or forms part of. Replaces any reference between the two; an old parent is kept as a reference. Pass parent_id null to detach.",
             ["card_id": cardArg, "parent_id": ["type": ["string", "null"], "description": "Card id, or null to detach."],
              "board": boardArg],
             required: ["card_id", "parent_id"], readOnly: false),
        tool("tidy",
             "Lay out one branch neatly: the card's children in a column to its right, in order, and theirs beside them. Only use it on branches you've just built or when asked; the user's own arrangement means something. Undoable.",
             ["card_id": ["type": "string", "description": "The card whose branch to tidy."], "board": boardArg],
             required: ["card_id"], readOnly: false),
        tool("delete_card", "Remove a card and its connections. Only when the user asks; it can be undone with ⌘Z.",
             ["card_id": cardArg, "board": boardArg], required: ["card_id"], readOnly: false, destructive: true),
        tool("create_board", "Create a new, empty board.",
             ["name": ["type": "string"]], required: ["name"], readOnly: false),
        tool("focus_card", "Show the user a card: switch to its board, select it and centre the view on it.",
             ["card_id": cardArg, "board": boardArg], required: ["card_id"], readOnly: false),
    ]

    // MARK: Calls

    typealias Reply = (Result<Any, ToolError>) -> Void

    func call(_ name: String, arguments a: [String: Any], done: @escaping Reply) {
        do {
            switch name {
            case "list_boards": done(.success(listBoards()))
            case "get_board": done(.success(try getBoard(a)))
            case "get_card": done(.success(try getCard(a)))
            case "search": done(.success(try search(a)))
            case "get_selection": done(.success(getSelection()))
            case "get_video_moments": try getVideoMoments(a, done: done)
            case "add_card": done(.success(try addCard(a)))
            case "add_thought": try addThought(a, done: done)
            case "update_card": done(.success(try updateCard(a)))
            case "connect": done(.success(try connect(a)))
            case "clip_url": done(.success(try clipURL(a)))
            case "set_parent": done(.success(try setParent(a)))
            case "tidy": done(.success(try tidy(a)))
            case "delete_card": done(.success(try deleteCard(a)))
            case "create_board": done(.success(try createBoard(a)))
            case "focus_card": done(.success(try focusCard(a)))
            default: throw ToolError("Unknown tool: \(name)")
            }
        } catch let error as ToolError {
            done(.failure(error))
        } catch {
            done(.failure(ToolError("\(error)")))
        }
    }

    private func listBoards() -> Any {
        ["boards": library.boards.map { name -> [String: Any] in
            ["name": name, "cards": library.snapshot(name).cards.count, "on_screen": name == library.current]
        }]
    }

    private func getBoard(_ a: [String: Any]) throws -> Any {
        let name = try boardName(a)
        let board = library.snapshot(name)
        return ["board": name,
                "cards": board.cards.map { Self.json($0, full: false) },
                "connections": board.connections.map(Self.json)]
    }

    private func getCard(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        guard let card = store.card(id) else { throw ToolError("Card not found.") }
        return ["board": store.board.name,
                "card": Self.json(card, full: true),
                "connections": store.board.connections.filter { $0.from == id || $0.to == id }.map(Self.json)]
    }

    private func search(_ a: [String: Any]) throws -> Any {
        guard let query = (a["query"] as? String)?.lowercased(), !query.isEmpty else { throw ToolError("`query` is required.") }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let limit = max(1, a["limit"] as? Int ?? 30)
        let names = try (a["board"] as? String).map { [try boardName(["board": $0])] } ?? library.boards
        var results: [[String: Any]] = []
        for name in names {
            for card in library.snapshot(name).cards {
                let haystack = [card.title, card.body, card.summary ?? "", card.url ?? ""].joined(separator: "\n").lowercased()
                guard terms.allSatisfy(haystack.contains) else { continue }
                var hit: [String: Any] = ["board": name, "id": card.id.uuidString.lowercased(), "kind": card.kind.rawValue]
                if !card.title.isEmpty { hit["title"] = card.title }
                hit["snippet"] = Self.snippet(card.body.isEmpty ? (card.summary ?? "") : card.body, around: terms[0])
                results.append(hit)
                if results.count >= limit { return ["results": results, "truncated": true] }
            }
        }
        return ["results": results]
    }

    private func getSelection() -> Any {
        guard let name = library.current, let store = library.liveStore(name) else {
            return ["board": NSNull(), "selected": []]
        }
        let selected = store.board.cards.filter { store.selection.contains($0.id) }
        let size = store.viewSize
        let a = store.toWorld(.zero), b = store.toWorld(CGPoint(x: size.width, y: size.height))
        return ["board": name, "selected": selected.map { Self.json($0, full: true) },
                "visible_area": ["x": Int(a.x), "y": Int(a.y), "width": Int(b.x - a.x), "height": Int(b.y - a.y)]]
    }

    private func getVideoMoments(_ a: [String: Any], done: @escaping Reply) throws {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        guard let videoID = store.videoID(for: id), let video = store.card(videoID) else {
            throw ToolError("That card isn't a video or one of its moments.")
        }
        let moments = store.board.cards
            .filter { $0.parent == videoID }
            .map { card -> (Double, [String: Any]) in
                let seconds = MarkdownText.timestamp(card.body.components(separatedBy: "\n").first ?? "")?.seconds
                return (seconds ?? .infinity, Self.json(card, full: true))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        store.video(videoID).currentTime { t in
            done(.success(["video": Self.json(video, full: true), "moments": moments, "current_time": t]))
        }
    }

    private func addCard(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        guard let kind = (a["kind"] as? String).flatMap(CardKind.init(rawValue:)),
              [.sticky, .note, .place].contains(kind) else {
            throw ToolError("`kind` must be sticky, note or place (use clip_url for links, videos and images).")
        }
        let size = kind.defaultSize
        var frame: CGRect?
        let parent = try a["parent"].map { try cardID($0, in: store) }
        if let parent, a["x"] == nil {
            frame = store.columnSpot(beside: parent, size: size)
        } else if let near = a["near"] {
            frame = store.columnSpot(beside: try cardID(near, in: store), size: size)
        } else if let x = Self.number(a["x"]), let y = Self.number(a["y"]) {
            frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        let from = try a["connect_from"].map { try cardID($0, in: store) }
        let center = frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? store.freeSpot()
        let id = store.add(kind, at: center, select: false) { card in
            if let frame { card.frame = frame }
            if let title = a["title"] as? String { card.title = title }
            if let body = a["body"] as? String { card.body = body }
            if let color = (a["color"] as? String).flatMap(CardColor.init(rawValue:)) { card.color = color }
            card.parent = parent
        }
        store.fitPlace(id)
        if let from { store.connect(from, id, select: false) }
        return try cardResult(id, in: store)
    }

    private func addThought(_ a: [String: Any], done: @escaping Reply) throws {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        guard let body = a["body"] as? String, !body.isEmpty else { throw ToolError("`body` is required.") }
        let place = { (prefix: String, origin: UUID) in
            guard let thought = store.placeThought(from: origin, body: prefix + body, interactive: false) else {
                return done(.failure(ToolError("Couldn't place the thought.")))
            }
            do { done(.success(try self.cardResult(thought, in: store))) } catch { done(.failure(ToolError("\(error)"))) }
        }
        guard let videoID = store.videoID(for: id) else { return place("", id) }
        if let t = Self.number(a["timestamp"]) {
            place("[\(Timestamp.format(t))] ", videoID)
        } else {
            store.video(videoID).currentTime { t in place("[\(Timestamp.format(t))] ", videoID) }
        }
    }

    private func updateCard(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        store.checkpoint()
        store.update(id) { card in
            if let title = a["title"] as? String { card.title = title }
            if let body = a["body"] as? String { card.body = body }
            if let more = a["append"] as? String, !more.isEmpty {
                card.body += (card.body.isEmpty || card.body.hasSuffix("\n") ? "" : "\n") + more
            }
            if let color = (a["color"] as? String).flatMap(CardColor.init(rawValue:)) { card.color = color }
            if let x = Self.number(a["x"]) { card.frame.origin.x = x }
            if let y = Self.number(a["y"]) { card.frame.origin.y = y }
            if let w = Self.number(a["width"]) { card.frame.size.width = max(120, w) }
            if let h = Self.number(a["height"]) { card.frame.size.height = max(80, h) }
        }
        return try cardResult(id, in: store)
    }

    private func connect(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        let from = try cardID(a["from"], in: store)
        let to = try cardID(a["to"], in: store)
        let item = a["from_affordance"] as? String
        if let item, let card = store.card(from), !Place.affordances(card.body).contains(item) {
            throw ToolError("“\(item)” isn't an affordance on that card. It has: \(Place.affordances(card.body).joined(separator: ", ")).")
        }
        guard let connection = store.connect(from, to, item: item, select: false) else {
            throw ToolError("Those cards are already connected (or are the same card).")
        }
        if let label = a["label"] as? String, !label.isEmpty { store.setLabel(connection, label) }
        guard let result = store.board.connections.first(where: { $0.id == connection }) else { throw ToolError("Connection vanished.") }
        return ["board": store.board.name, "connection": Self.json(result)]
    }

    private func clipURL(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        guard let raw = a["url"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw ToolError("`url` must be an http(s) address.")
        }
        var point = store.freeSpot()
        if let near = a["near"], let spot = store.columnSpot(beside: try cardID(near, in: store), size: CardKind.link.defaultSize) {
            point = CGPoint(x: spot.midX, y: spot.midY)
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased()) {
            store.addRemoteImage(url, page: nil, title: "", at: point, select: false)
            return ["board": store.board.name, "status": "Downloading the image; it will appear on the board shortly."]
        }
        guard let id = store.addURL(url.absoluteString, at: point, select: false) else { throw ToolError("Couldn't add that URL.") }
        var result = try cardResult(id, in: store) as? [String: Any] ?? [:]
        result["note"] = "Title and preview fill in over the next few seconds."
        return result
    }

    private func setParent(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        let parent: UUID? = (a["parent_id"] is NSNull || a["parent_id"] == nil) ? nil : try cardID(a["parent_id"], in: store)
        guard store.setParent(id, parent) else {
            throw ToolError("That would make a card follow from itself or one of its own descendants.")
        }
        return try cardResult(id, in: store)
    }

    private func tidy(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        guard store.tidy([id]) else { throw ToolError("That card has nothing following from it to tidy.") }
        return ["board": store.board.name, "tidied": id.uuidString.lowercased()]
    }

    private func deleteCard(_ a: [String: Any]) throws -> Any {
        let store = try self.store(a)
        let id = try cardID(a["card_id"], in: store)
        store.deleteCards([id])
        return ["board": store.board.name, "deleted": id.uuidString.lowercased(),
                "note": "The user can restore it with ⌘Z."]
    }

    private func createBoard(_ a: [String: Any]) throws -> Any {
        guard let name = (a["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ToolError("`name` is required.")
        }
        return ["board": library.createBoard(named: name.replacingOccurrences(of: "/", with: "-"))]
    }

    private func focusCard(_ a: [String: Any]) throws -> Any {
        let name = try boardName(a)
        let store = library.store(name)
        let id = try cardID(a["card_id"], in: store)
        if name != library.current { UserDefaults.standard.set(name, forKey: "board") }
        store.reveal(id)
        return ["board": name, "focused": id.uuidString.lowercased()]
    }

    // MARK: Helpers

    private func boardName(_ a: [String: Any]) throws -> String {
        if let name = a["board"] as? String, !name.isEmpty {
            guard library.boards.contains(name) else {
                throw ToolError("No board named “\(name)”. Boards: \(library.boards.joined(separator: ", ")).")
            }
            return name
        }
        if let current = library.current, library.boards.contains(current) { return current }
        if let first = library.boards.first { return first }
        throw ToolError("There are no boards yet; create one with create_board.")
    }

    private func store(_ a: [String: Any]) throws -> BoardStore {
        library.store(try boardName(a))
    }

    private func cardID(_ raw: Any?, in store: BoardStore) throws -> UUID {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else {
            throw ToolError("A card id is required.")
        }
        if let id = UUID(uuidString: s), store.card(id) != nil { return id }
        let matches = store.board.cards.filter { $0.id.uuidString.lowercased().hasPrefix(s) }
        guard matches.count == 1 else {
            throw ToolError(matches.isEmpty ? "No card “\(s)” on “\(store.board.name)”."
                                            : "“\(s)” matches \(matches.count) cards; use more of the id.")
        }
        return matches[0].id
    }

    private func cardResult(_ id: UUID, in store: BoardStore) throws -> Any {
        guard let card = store.card(id) else { throw ToolError("Card not found.") }
        return ["board": store.board.name, "card": Self.json(card, full: true)]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private static func snippet(_ text: String, around term: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.lowercased().range(of: term) else { return String(flat.prefix(160)) }
        let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 100, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    static func json(_ card: Card, full: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "id": card.id.uuidString.lowercased(), "kind": card.kind.rawValue,
            "x": Int(card.frame.minX), "y": Int(card.frame.minY),
            "width": Int(card.frame.width), "height": Int(card.frame.height),
        ]
        if !card.title.isEmpty { d["title"] = card.title }
        if !card.body.isEmpty {
            d["body"] = full || card.body.count <= 600 ? card.body : String(card.body.prefix(600)) + "…"
        }
        if let url = card.url { d["url"] = url }
        if let source = card.source { d["source"] = source }
        if let summary = card.summary, !summary.isEmpty { d["summary"] = summary }
        if card.color != .none { d["color"] = card.color.rawValue }
        if let parent = card.parent { d["parent"] = parent.uuidString.lowercased() }
        if let ts = MarkdownText.timestamp(card.body.components(separatedBy: "\n").first ?? "") { d["timestamp"] = ts.seconds }
        if card.kind == .place { d["affordances"] = Place.affordances(card.body) }
        if card.kind == .video {
            if card.speed != 1 { d["speed"] = card.speed }
            if card.position > 0 { d["resume_at"] = Int(card.position) }
        }
        return d
    }

    static func json(_ c: Connection) -> [String: Any] {
        var d: [String: Any] = ["id": c.id.uuidString.lowercased(),
                                "from": c.from.uuidString.lowercased(), "to": c.to.uuidString.lowercased()]
        if !c.label.isEmpty { d["label"] = c.label }
        if let item = c.fromItem { d["from_affordance"] = item }
        return d
    }
}

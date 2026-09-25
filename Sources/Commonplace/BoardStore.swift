import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// State and editing operations for the open board.
@Observable
final class BoardStore {
    let library: Library
    var board: Board
    /// Screen position of the world origin.
    var offset: CGPoint
    var scale: CGFloat
    var selection: Set<UUID> = []
    var selectedConnection: UUID?
    var editing: UUID?
    var editingConnection: UUID?
    var connectingFrom: UUID?
    /// Affordance the pending connection starts from, when connecting from a place.
    var connectingItem: String?
    /// The pending link is a sequence link: the card clicked next follows from `connectingFrom`.
    var connectingSequence = false
    /// Pointer location in canvas coordinates.
    var hover: CGPoint?
    var showHelp = false
    var showLinkPrompt = false
    /// Cards whose underlying video file is being looked up.
    var resolving: Set<UUID> = []

    @ObservationIgnored var canvasSize: CGSize = .zero
    /// The canvas's real size, from AppKit when it's on screen.
    var viewSize: CGSize { anchorView.map(\.bounds.size) ?? canvasSize }
    /// An AppKit view covering the canvas, for routing scroll and pinch events.
    @ObservationIgnored weak var anchorView: NSView?
    @ObservationIgnored private var dirty = Set<UUID>()
    @ObservationIgnored private var removedFiles: [String] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var dragOrigins: [UUID: CGPoint]?
    @ObservationIgnored private var dragStart: CGPoint?
    @ObservationIgnored private var didMove = false
    @ObservationIgnored private var resizeOrigin: CGSize?
    @ObservationIgnored private var resizeStart: CGPoint?
    @ObservationIgnored private var videos: [UUID: VideoController] = [:]
    @ObservationIgnored private var terminateObserver: Any?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var clipCount = 0

    // Undo history: whole-board snapshots taken before each user change.
    private struct Snapshot {
        var cards: [Card]
        var connections: [Connection]
    }
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    /// Consecutive checkpoints with the same key (typing in one editing
    /// session) collapse into one undo step.
    @ObservationIgnored private var lastCheckpointKey: String?
    /// Several changes in one run-loop turn (e.g. a moment's sticky and its
    /// arrow) are one undo step.
    @ObservationIgnored private var checkpointedThisTurn = false
    @ObservationIgnored private var editSession = 0
    /// Keys typed after a card entered editing but before its editor had
    /// focus; the editor inserts them once it's ready.
    @ObservationIgnored var pendingTyping = ""

    func takePendingTyping() -> String {
        defer { pendingTyping = "" }
        return pendingTyping
    }

    init(library: Library, name: String) {
        self.library = library
        let board = library.load(name)
        self.board = board
        offset = CGPoint(x: board.viewport.x, y: board.viewport.y)
        scale = board.viewport.scale
        for i in self.board.cards.indices { fitHeight(&self.board.cards[i]) }
        migrateSequenceLinks()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveNow() }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    // MARK: Geometry

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    func toScreen(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale + offset.x, y: r.minY * scale + offset.y,
               width: r.width * scale, height: r.height * scale)
    }

    /// The card under the pointer, if any (topmost).
    var hoveredCard: UUID? {
        guard let hover else { return nil }
        let p = toWorld(hover)
        return board.cards.last { $0.frame.contains(p) }?.id
    }

    /// Cards whose connections are brought forward: the selection plus the
    /// card under the pointer. Everything else recedes.
    var focusedCards: Set<UUID> {
        var focus = selection
        if let hovered = hoveredCard { focus.insert(hovered) }
        return focus
    }

    /// Below this zoom, labels and connection dots only show for focused cards,
    /// and cards switch to their overview rendering.
    static let detailZoom: CGFloat = 0.6
    static let overviewZoom: CGFloat = 0.45

    /// Where new cards go: under the pointer, or the middle of the view.
    var insertionPoint: CGPoint {
        toWorld(hover ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    func pan(_ dx: CGFloat, _ dy: CGFloat) {
        offset.x += dx
        offset.y += dy
        scheduleSave()
    }

    func zoom(by factor: CGFloat, around point: CGPoint? = nil) {
        let anchor = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let world = toWorld(anchor)
        scale = min(4, max(0.1, scale * factor))
        offset = CGPoint(x: anchor.x - world.x * scale, y: anchor.y - world.y * scale)
        scheduleSave()
    }

    func resetZoom() { zoom(by: 1 / scale) }

    func zoomToFit() {
        guard let first = board.cards.first, viewSize.width > 0 else { return }
        let r = board.cards.reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -60, dy: -60)
        scale = min(1.5, max(0.1, min(viewSize.width / r.width, viewSize.height / r.height)))
        offset = CGPoint(x: (viewSize.width - r.width * scale) / 2 - r.minX * scale,
                         y: (viewSize.height - r.height * scale) / 2 - r.minY * scale)
        scheduleSave()
    }

    // MARK: Cards

    func card(_ id: UUID) -> Card? { board.cards.first { $0.id == id } }

    func update(_ id: UUID, content: Bool = true, _ change: (inout Card) -> Void) {
        guard let i = board.cards.firstIndex(where: { $0.id == id }) else { return }
        change(&board.cards[i])
        fitHeight(&board.cards[i])
        if content { dirty.insert(id) }
        scheduleSave()
    }

    /// Adds a card centred on `point` (world coordinates).
    @discardableResult
    func add(_ kind: CardKind, at point: CGPoint, edit: Bool = false, select: Bool = true,
             configure: (inout Card) -> Void = { _ in }) -> UUID {
        checkpoint()
        var card = Card(kind: kind)
        let size = kind.defaultSize
        card.frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height)
        if kind == .sticky { card.color = .yellow }
        configure(&card)
        board.cards.append(card)
        dirty.insert(card.id)
        if select {
            selection = [card.id]
            selectedConnection = nil
            editing = edit ? card.id : nil
        }
        scheduleSave()
        return card.id
    }

    @discardableResult
    func addURL(_ raw: String, at point: CGPoint, select: Bool = true) -> UUID? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            addText(s, at: point)
            return nil
        }
        let kind: CardKind = VideoSource.detect(url) != nil ? .video : .link
        let id = add(kind, at: point, select: select) {
            $0.url = url.absoluteString
            $0.title = url.host ?? s
        }
        if VideoSource.isXPost(url) { resolveMedia(id) }
        Task { @MainActor in
            let meta = await LinkMetadata.fetch(url)
            self.update(id) { card in
                if let t = meta.title, !t.isEmpty { card.title = t }
                if let d = meta.summary, !d.isEmpty { card.summary = d }
                // Links get a preview image; videos keep it as a poster for zoomed-out views.
                if card.image == nil || card.kind == .link, let image = meta.image { card.image = image }
            }
        }
        return id
    }

    /// Looks up the video file behind an X post so it plays natively. Posts
    /// without a video become link cards.
    func resolveMedia(_ id: UUID) {
        guard !resolving.contains(id), let card = card(id), card.media == nil,
              let url = card.url.flatMap(URL.init(string:)), VideoSource.isXPost(url) else { return }
        resolving.insert(id)
        Task { @MainActor in
            let result = await XVideo.resolve(url)
            self.resolving.remove(id)
            guard let result else { return }
            self.update(id) { card in
                if let media = result.media {
                    card.media = media
                } else if card.kind == .video {
                    card.kind = .link
                    card.frame.size = CardKind.link.defaultSize
                }
                if card.image == nil, let poster = result.poster { card.image = poster }
            }
        }
    }

    func addText(_ s: String, at point: CGPoint) {
        guard !s.isEmpty else { return }
        let long = s.count > 280 || s.contains("\n#")
        add(long ? .note : .sticky, at: point) { $0.body = s }
    }

    func addFile(_ url: URL, at point: CGPoint) {
        let ext = url.pathExtension.lowercased()
        if UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            addImage(url, at: point)
        } else if ["md", "markdown", "txt"].contains(ext), let text = try? String(contentsOf: url, encoding: .utf8) {
            add(.note, at: point) {
                $0.title = url.deletingPathExtension().lastPathComponent
                $0.body = text
            }
        } else {
            add(.link, at: point) {
                $0.url = url.absoluteString
                $0.title = url.lastPathComponent
            }
        }
    }

    func addImage(_ file: URL, at point: CGPoint) {
        guard let data = try? Data(contentsOf: file) else { return }
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        addImageData(data, ext: ext, title: file.deletingPathExtension().lastPathComponent, at: point)
    }

    @discardableResult
    func addImageData(_ data: Data, ext: String, title: String = "", at point: CGPoint, select: Bool = true) -> UUID? {
        var data = data
        var ext = ext.lowercased()
        // WebKit drags arrive as TIFF; store something smaller.
        if ext == "tiff" || ext == "tif", let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            data = png
            ext = "png"
        }
        let assets = board.folder.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let name = UUID().uuidString.lowercased() + "." + ext
        guard (try? data.write(to: assets.appendingPathComponent(name))) != nil else { return nil }

        var size = CardKind.image.defaultSize
        if let img = NSImage(data: data), img.size.width > 0 {
            let w = min(420, max(160, img.size.width))
            size = CGSize(width: w, height: w * img.size.height / img.size.width)
        }
        return add(.image, at: point, select: select) {
            $0.image = "assets/\(name)"
            $0.title = title
            $0.frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
        }
    }

    // MARK: Clipping from the browser

    func addClip(_ clip: BrowserClip) {
        let p = nextClipPoint()
        switch clip {
        case .page(let url, _), .link(let url):
            addURL(url.absoluteString, at: p)
        case .image(let url, let page, let title):
            addRemoteImage(url, page: page, title: title, at: p)
        case .quote(let text, let page, let title):
            let quoted = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "> " + $0 }
                .joined(separator: "\n")
            var body = quoted
            if let page {
                let name = title.isEmpty ? (page.host ?? page.absoluteString) : title
                body += "\n\n— [\(name.replacingOccurrences(of: "]", with: ")"))](\(page.absoluteString))"
            }
            add(.note, at: p) {
                $0.body = body
                $0.source = page?.absoluteString
            }
        }
    }

    /// Clips land in the middle of the view, fanned out so they don't stack.
    private func nextClipPoint() -> CGPoint {
        let c = toWorld(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        defer { clipCount += 1 }
        let step = CGFloat(clipCount % 6) * 28 / scale
        return CGPoint(x: c.x + step, y: c.y + step)
    }

    func addRemoteImage(_ url: URL, page: URL?, title: String, at point: CGPoint, select: Bool = true) {
        Task { @MainActor in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
            if let page { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  NSImage(data: data) != nil else {
                // Hotlink-protected or not really an image: keep a link instead.
                self.addURL(url.absoluteString, at: point, select: select)
                return
            }
            let ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
                ?? (url.pathExtension.isEmpty ? "png" : url.pathExtension)
            guard let id = self.addImageData(data, ext: ext, title: title, at: point, select: select) else { return }
            self.update(id) {
                $0.url = url.absoluteString
                $0.source = ClipWebView.source(page: page, image: url)?.absoluteString
            }
        }
    }

    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        let p = insertionPoint
        guard panel.runModal() == .OK else { return }
        for (i, url) in panel.urls.enumerated() {
            addImage(url, at: CGPoint(x: p.x + CGFloat(i) * 30, y: p.y + CGFloat(i) * 30))
        }
    }

    func paste() {
        let pb = NSPasteboard.general
        let p = insertionPoint
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            for (i, url) in urls.enumerated() {
                addFile(url, at: CGPoint(x: p.x + CGFloat(i) * 30, y: p.y + CGFloat(i) * 30))
            }
        } else if let png = pb.data(forType: .png) {
            addImageData(png, ext: "png", at: p)
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            addImageData(png, ext: "png", at: p)
        } else if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if s.hasPrefix("http"), !s.contains(where: \.isWhitespace) {
                addURL(s, at: p)
            } else {
                addText(s, at: p)
            }
        }
    }

    func setColor(_ color: CardColor) {
        guard !selection.isEmpty else { return }
        checkpoint()
        for id in selection { update(id) { $0.color = color } }
    }

    func deleteSelection() {
        if let cid = selectedConnection {
            checkpoint()
            board.connections.removeAll { $0.id == cid }
            selectedConnection = nil
            scheduleSave()
            return
        }
        deleteCards(selection)
    }


    // MARK: Selection & dragging

    func clearSelection() {
        selection = []
        selectedConnection = nil
        editing = nil
        editingConnection = nil
        connectingFrom = nil
        connectingItem = nil
        connectingSequence = false
    }

    /// Re-fits a place card's height, e.g. when editing starts or ends.
    func fitPlace(_ id: UUID) {
        update(id, content: false) { _ in }
    }

    /// Space is held: dragging the canvas pans rather than selects.
    @ObservationIgnored var spaceHeld = false

    /// Selects every card touching a box drawn in canvas coordinates.
    func select(in screenRect: CGRect, adding base: Set<UUID>) {
        let a = toWorld(screenRect.origin)
        let b = toWorld(CGPoint(x: screenRect.maxX, y: screenRect.maxY))
        let world = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let hit = Set(board.cards.filter { $0.frame.intersects(world) }.map(\.id))
        editing = nil
        selectedConnection = nil
        let next = base.union(hit)
        if next != selection { selection = next }
    }

    func selectAll() {
        editing = nil
        selectedConnection = nil
        selection = Set(board.cards.map(\.id))
    }

    func beginEditing(_ id: UUID) {
        editSession += 1
        pendingTyping = ""
        selection = [id]
        selectedConnection = nil
        // A plain video card has nothing to edit; its notes are moment stickies.
        if let card = card(id), card.kind == .video, card.body.isEmpty { return }
        editing = id
    }

    // Gestures can be cancelled without their end callback firing (a pinch or
    // double-click mid-drag), so each session is keyed by where it started and
    // stale state is discarded rather than trusted.

    /// Called for every change of a card drag.
    func dragChanged(_ id: UUID, start: CGPoint, translation t: CGSize, shift: Bool) {
        if dragOrigins == nil || dragStart != start {
            dragStart = start
            didMove = false
            beginDrag(id, shift: shift)
        }
        guard let origins = dragOrigins, !origins.isEmpty else { return }
        if !didMove, abs(t.width) + abs(t.height) > 1 {
            checkpoint()
            didMove = true
        }
        for i in board.cards.indices {
            guard let o = origins[board.cards[i].id] else { continue }
            board.cards[i].frame.origin = CGPoint(x: o.x + t.width / scale, y: o.y + t.height / scale)
        }
    }

    private func beginDrag(_ id: UUID, shift: Bool) {
        // Take keyboard focus back from the browser so canvas shortcuts work.
        if let window = NSApp.keyWindow, !(window.firstResponder is NSText) {
            window.makeFirstResponder(nil)
        }
        if let from = connectingFrom {
            if connectingSequence {
                if !setParent(id, from) { NSSound.beep() }
            } else {
                connect(from, id, item: connectingItem)
            }
            connectingFrom = nil
            connectingItem = nil
            connectingSequence = false
            dragOrigins = [:]
            return
        }
        if editing != id { editing = nil }
        editingConnection = nil
        selectedConnection = nil
        if shift {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        dragOrigins = Dictionary(
            board.cards.filter { selection.contains($0.id) }.map { ($0.id, $0.frame.origin) },
            uniquingKeysWith: { a, _ in a })
    }

    /// Safe to call more than once per drag.
    func endDrag() {
        guard dragOrigins != nil else { return }
        dragOrigins = nil
        dragStart = nil
        guard didMove else { return }
        didMove = false
        // Bring the moved cards to the front.
        let moving = board.cards.filter { selection.contains($0.id) }
        if !moving.isEmpty, board.cards.suffix(moving.count).map(\.id) != moving.map(\.id) {
            board.cards.removeAll { selection.contains($0.id) }
            board.cards.append(contentsOf: moving)
        }
        scheduleSave()
    }

    func resize(_ id: UUID, start: CGPoint, by t: CGSize) {
        guard let card = card(id) else { return }
        if resizeOrigin == nil || resizeStart != start {
            checkpoint()
            resizeStart = start
            resizeOrigin = card.frame.size
        }
        let o = resizeOrigin ?? card.frame.size
        // Place heights follow their affordances; only the width is free.
        update(id, content: false) {
            $0.frame.size = CGSize(width: max(140, o.width + t.width / scale),
                                   height: max(90, o.height + t.height / scale))
        }
    }

    func endResize() {
        resizeOrigin = nil
        resizeStart = nil
    }

    // MARK: Connections

    func startConnecting() {
        guard let id = selection.first else { return }
        startConnecting(from: id, item: nil)
    }

    func startConnecting(from id: UUID, item: String?) {
        editing = nil
        selection = [id]
        connectingFrom = id
        connectingItem = item
        connectingSequence = false
    }

    @discardableResult
    func connect(_ a: UUID, _ b: UUID, item: String? = nil, select: Bool = true) -> UUID? {
        guard a != b, !board.connections.contains(where: {
            $0.fromItem == item && (($0.from == a && $0.to == b) || ($0.from == b && $0.to == a))
        }) else { return nil }
        checkpoint()
        let connection = Connection(from: a, to: b, fromItem: item)
        board.connections.append(connection)
        if select { selection = [b] }
        scheduleSave()
        return connection.id
    }

    /// Screen-space anchor for an affordance row, on the side facing `target`.
    func affordanceAnchor(_ card: Card, item: String, toward target: CGPoint) -> CGPoint? {
        guard card.kind == .place, let i = Place.affordances(card.body).firstIndex(of: item) else { return nil }
        let r = toScreen(card.frame)
        return CGPoint(x: target.x >= r.midX ? r.maxX : r.minX,
                       y: (card.frame.minY + Place.rowCenter(i)) * scale + offset.y)
    }

    /// Screen-space start and end of a connection line.
    func endpoints(_ c: Connection) -> (CGPoint, CGPoint)? {
        guard let a = card(c.from), let b = card(c.to) else { return nil }
        let ra = toScreen(a.frame), rb = toScreen(b.frame)
        let pad: CGFloat = 6
        guard let item = c.fromItem,
              let start = affordanceAnchor(a, item: item, toward: CGPoint(x: rb.midX, y: rb.midY)) else {
            return Geometry.endpoints(ra, rb)
        }
        // Arrows into a place land on its name, as in a hand-drawn breadboard.
        let end: CGPoint
        if b.kind == .place {
            let titleY = rb.minY + (Place.padTop + Place.titleHeight / 2) * scale
            if start.x < rb.minX { end = CGPoint(x: rb.minX - pad, y: titleY) }
            else if start.x > rb.maxX { end = CGPoint(x: rb.maxX + pad, y: titleY) }
            else { end = CGPoint(x: rb.midX, y: start.y < rb.minY ? rb.minY - pad : rb.maxY + pad) }
        } else {
            end = Geometry.edge(rb.insetBy(dx: -pad, dy: -pad), toward: start)
        }
        return (start, end)
    }

    func setLabel(_ id: UUID, _ label: String) {
        guard let i = board.connections.firstIndex(where: { $0.id == id }) else { return }
        let label = label.trimmingCharacters(in: .whitespaces)
        guard board.connections[i].label != label else { return }
        checkpoint()
        board.connections[i].label = label
        scheduleSave()
    }

    // MARK: Video

    func video(_ id: UUID) -> VideoController {
        if let v = videos[id] { return v }
        let v = VideoController()
        if let card = card(id) {
            if card.speed != 1 { v.setRate(card.speed) }
            v.resumeAt = card.position
        }
        v.onProgress = { [weak self] t in
            guard let self, let old = self.card(id)?.position, abs(old - t) >= 2 else { return }
            self.update(id) { $0.position = t }
        }
        videos[id] = v
        return v
    }

    func setSpeed(_ id: UUID, _ speed: Double) {
        guard let videoID = videoID(for: id) else { return }
        update(videoID) { $0.speed = speed }
        video(videoID).setRate(speed)
    }

    /// Steps through `Card.speeds`, wrapping when going up.
    func stepSpeed(_ id: UUID, up: Bool) {
        guard let videoID = videoID(for: id), let current = card(videoID)?.speed else { return }
        let speeds = Card.speeds
        let i = speeds.firstIndex { $0 >= current - 0.001 } ?? 1
        let next = up ? (i + 1 < speeds.count ? speeds[i + 1] : speeds[0]) : speeds[max(0, i - 1)]
        setSpeed(videoID, next)
    }

    /// Places and plain video cards size themselves; only their width is free.
    private func fitHeight(_ card: inout Card) {
        switch card.kind {
        case .place:
            card.frame.size.height = Place.height(for: card.body, editing: editing == card.id)
        case .video where card.body.isEmpty:
            card.frame.size.height = Card.videoHeight(width: card.frame.width)
        default:
            break
        }
    }

    /// The video a card belongs to: itself, or the video a moment marks.
    func videoID(for id: UUID) -> UUID? {
        guard let card = card(id) else { return nil }
        if card.kind == .video { return id }
        guard let v = card.parent, self.card(v)?.kind == .video else { return nil }
        return v
    }

    // MARK: Sequence links

    func children(of id: UUID) -> [Card] {
        board.cards.filter { $0.parent == id }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    /// Would making `parent` the parent of `child` loop back on itself?
    func wouldCycle(child: UUID, parent: UUID) -> Bool {
        var cursor: UUID? = parent
        var seen = Set<UUID>()
        while let c = cursor, seen.insert(c).inserted {
            if c == child { return true }
            cursor = card(c)?.parent
        }
        return false
    }

    /// Makes `child` follow from `parent` (or detaches it with nil). A
    /// reference between the two becomes redundant and is removed.
    @discardableResult
    func setParent(_ child: UUID, _ parent: UUID?) -> Bool {
        guard card(child) != nil else { return false }
        if let parent {
            guard card(parent) != nil, parent != child, !wouldCycle(child: child, parent: parent) else { return false }
        }
        checkpoint()
        if let parent {
            board.connections.removeAll { ($0.from == parent && $0.to == child) || ($0.from == child && $0.to == parent) }
        }
        // Moving a card to a new parent keeps the old relationship as a reference.
        if let old = card(child)?.parent, old != parent, card(old) != nil, parent != nil {
            connect(old, child, select: false)
        }
        update(child) { $0.parent = parent }
        return true
    }

    /// ⇧C: the next card clicked will follow from the selected one.
    func startSequenceLink() {
        guard let id = selection.first else { return }
        editing = nil
        connectingFrom = id
        connectingItem = nil
        connectingSequence = true
    }

    /// A reference becomes a sequence link: its target now follows from its source.
    func makeSequence(_ connectionID: UUID) {
        guard let c = board.connections.first(where: { $0.id == connectionID }) else { return }
        if !setParent(c.to, c.from) { NSSound.beep() }
    }

    /// A sequence link becomes a reference: the card leaves the sequence but
    /// keeps an arrow from what it came from.
    func makeReference(_ child: UUID) {
        guard let parent = card(child)?.parent else { return }
        checkpoint()
        update(child) { $0.parent = nil }
        connect(parent, child, select: false)
    }

    /// Thoughts used to carry both a parent and an arrow to it; the parent is
    /// now drawn as the sequence link, so the duplicate arrow goes.
    private func migrateSequenceLinks() {
        let parents = Dictionary(board.cards.compactMap { c in c.parent.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let before = board.connections.count
        board.connections.removeAll { c in
            parents[c.to] == c.from || parents[c.from] == c.to
        }
        if board.connections.count != before { scheduleSave() }
    }

    /// ⇧T: continue the sequence — a new card after the selected one, sharing
    /// its parent. From a card with no parent it branches instead, like T.
    func continueSequence() {
        guard let id = selection.first, let current = card(id) else { return addThought() }
        guard let parent = current.parent, videoID(for: id) == nil else { return addThought() }
        let frame = CGRect(x: current.frame.minX, y: current.frame.maxY + 24, width: current.frame.width, height: 130)
        let next = add(.sticky, at: CGPoint(x: frame.midX, y: frame.midY)) {
            $0.frame = frame
            $0.parent = parent
        }
        beginEditing(next)
    }

    /// A: tidy trees. The trees containing the selection, or every tree on the
    /// board. Each card's children form a column to its right, in their
    /// current top-to-bottom order; roots stay where they are unless a tidied
    /// tree would overlap other cards, in which case it moves down to clear them.
    /// Only ever the selected branches: rearranging a whole board destroys a
    /// spatial arrangement that means something to the user.
    @discardableResult
    func tidy(_ ids: Set<UUID>? = nil) -> Bool {
        let scope = ids ?? selection
        // Tidy each selected card's branch, skipping cards inside another selected branch.
        var roots = Array(scope).filter { id in
            var cursor = card(id)?.parent
            var hops = 0
            while let c = cursor, hops < 64 {
                if scope.contains(c) { return false }
                cursor = card(c)?.parent
                hops += 1
            }
            return true
        }.filter { !children(of: $0).isEmpty }
        roots.sort { (card($0)?.frame.minY ?? 0) < (card($1)?.frame.minY ?? 0) }
        guard !roots.isEmpty else { return false }
        checkpoint()

        var frames = Dictionary(board.cards.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let childMap = Dictionary(grouping: board.cards.filter { $0.parent != nil }, by: { $0.parent! })
            .mapValues { $0.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }.map(\.id) }
        let gapX: CGFloat = 80, gapY: CGFloat = 24

        func layout(_ id: UUID, at origin: CGPoint, depth: Int) -> CGFloat {
            guard var f = frames[id] else { return origin.y }
            f.origin = origin
            frames[id] = f
            var bottom = f.maxY
            var y = origin.y
            guard depth < 64 else { return bottom }
            for child in childMap[id] ?? [] {
                let b = layout(child, at: CGPoint(x: f.maxX + gapX, y: y), depth: depth + 1)
                bottom = max(bottom, b)
                y = b + gapY
            }
            return bottom
        }
        func members(_ id: UUID) -> [UUID] { [id] + (childMap[id] ?? []).flatMap(members) }

        var tidied = Set<UUID>()
        for root in roots {
            guard let start = frames[root]?.origin else { continue }
            _ = layout(root, at: start, depth: 0)
            let tree = members(root)
            tidied.formUnion(tree)
            // Clear anything else on the board by moving this tree down.
            for _ in 0..<50 {
                let box = tree.compactMap { frames[$0] }.reduce(CGRect.null) { $0.union($1) }
                let blockers = frames.filter { !tree.contains($0.key) }.map(\.value)
                    .filter { $0.intersects(box.insetBy(dx: -12, dy: -12)) }
                guard let lowest = blockers.map(\.maxY).max() else { break }
                let dy = lowest + 40 - box.minY
                for m in tree { frames[m]?.origin.y += dy }
            }
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            for i in board.cards.indices where tidied.contains(board.cards[i].id) {
                if let f = frames[board.cards[i].id] { board.cards[i].frame = f }
            }
        }
        scheduleSave()
        return true
    }

    func root(of id: UUID) -> UUID {
        var current = id
        var seen: Set<UUID> = [id]
        while let p = card(current)?.parent, card(p) != nil, seen.insert(p).inserted { current = p }
        return current
    }

    /// T: draw a thought out of whatever is selected. From a video (or one
    /// of its moments) it's a moment at the current time; from any other card
    /// it's a connected sticky; with nothing selected, a free sticky.
    func addThought() {
        guard let id = selection.first, card(id) != nil else {
            add(.sticky, at: insertionPoint, edit: true)
            return
        }
        if videoID(for: id) != nil {
            addMoment(id)
        } else {
            placeThought(from: id, body: "")
        }
    }

    /// Adds a sticky for the video's current moment and starts editing it.
    func addMoment(_ id: UUID) {
        guard let videoID = videoID(for: id) else { return }
        video(videoID).currentTime { [weak self] t in
            self?.placeThought(from: videoID, body: "[\(Timestamp.format(t))] ")
        }
    }

    /// A sticky following from `origin`, stacked in a column to its right.
    /// Agents pass `interactive: false` so the user's selection and focus stay put.
    @discardableResult
    func placeThought(from origin: UUID, body: String, interactive: Bool = true) -> UUID? {
        guard let frame = columnSpot(beside: origin, size: CGSize(width: 220, height: 130)) else { return nil }
        let thought = add(.sticky, at: CGPoint(x: frame.midX, y: frame.midY), select: interactive) {
            $0.frame = frame
            $0.parent = origin
            $0.body = body
        }
        if interactive { beginEditing(thought) }
        return thought
    }

    /// The next free slot in the column to the right of a card.
    func columnSpot(beside id: UUID, size: CGSize) -> CGRect? {
        guard let source = card(id) else { return nil }
        let x = source.frame.maxX + 60
        let column = board.cards.filter { abs($0.frame.minX - x) < 1 && $0.frame.maxY > source.frame.minY - 1 }
        let y = column.map { $0.frame.maxY + 16 }.max() ?? source.frame.minY
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Somewhere sensible for a new card when nothing says where: the middle of
    /// the view if the board has been shown, otherwise below everything.
    func freeSpot() -> CGPoint {
        if canvasSize != .zero { return nextClipPoint() }
        let bottom = board.cards.map(\.frame.maxY).max() ?? 0
        let left = board.cards.map(\.frame.minX).min() ?? 0
        defer { clipCount += 1 }
        return CGPoint(x: left + 160 + CGFloat(clipCount % 4) * 260, y: bottom + 140)
    }

    func deleteCards(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        checkpoint()
        for card in board.cards where ids.contains(card.id) {
            removedFiles.append(card.fileName)
            dirty.remove(card.id)
            videos[card.id] = nil
        }
        // Children of a removed card move up to its nearest surviving ancestor.
        let parents = Dictionary(board.cards.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        func survivor(_ id: UUID?) -> UUID? {
            var cursor = id
            var hops = 0
            while let c = cursor, ids.contains(c), hops < 64 { cursor = parents[c] ?? nil; hops += 1 }
            return cursor
        }
        for i in board.cards.indices where board.cards[i].parent.map(ids.contains) == true {
            board.cards[i].parent = survivor(board.cards[i].parent)
            dirty.insert(board.cards[i].id)
        }
        board.cards.removeAll { ids.contains($0.id) }
        board.connections.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        selection.subtract(ids)
        if let e = editing, ids.contains(e) { editing = nil }
        scheduleSave()
    }

    /// Selects a card and centres the view on it.
    func reveal(_ id: UUID, animated: Bool = false) {
        guard let card = card(id) else { return }
        selection = [id]
        selectedConnection = nil
        editing = nil
        highlight = nil
        guard canvasSize != .zero else { pendingReveal = id; return }
        pendingReveal = nil
        let target = CGPoint(x: viewSize.width / 2 - card.frame.midX * scale,
                             y: viewSize.height / 2 - card.frame.midY * scale)
        if animated { glide(to: target) } else { offset = target }
        flash = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            if self?.flash == id { self?.flash = nil }
        }
        scheduleSave()
    }

    /// A card briefly outlined after travelling to it.
    var flash: UUID?
    /// A card outlined while its entry in the floating references is hovered.
    var highlight: UUID?

    /// Pans smoothly by stepping the offset, so lines (drawn in a Canvas)
    /// move in step with the cards.
    @ObservationIgnored private var glideTimer: Timer?

    /// True while the view is gliding to a card; floating references wait for arrival.
    var isGliding = false

    /// Which side of each card its floating references last used, so they
    /// don't jump sides as the view moves.
    @ObservationIgnored var haloSide: [UUID: Bool] = [:]

    private func glide(to target: CGPoint) {
        glideTimer?.invalidate()
        isGliding = true
        let start = offset, began = Date(), duration = 0.4
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            self.offset = CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
            if t >= 1 {
                timer.invalidate()
                withAnimation(.easeOut(duration: 0.18)) { self.isGliding = false }
                self.scheduleSave()
            }
        }
    }

    // MARK: References

    /// Draw every reference line, not just the selected card's (R).
    var showAllReferences = false

    struct Reference: Identifiable {
        let id: UUID
        let other: UUID
        let outgoing: Bool
        let label: String
    }

    /// Breadboard wiring: a connection from a place's affordance, or between
    /// two places. It's the diagram itself ("this leads there"), so it's
    /// always drawn and isn't treated as a reference.
    func isWire(_ c: Connection) -> Bool {
        if c.fromItem != nil { return true }
        return card(c.from)?.kind == .place && card(c.to)?.kind == .place
    }

    /// A card's references, both ways: what it points to, then what points to it.
    func references(of id: UUID) -> [Reference] {
        let refs = board.connections.filter { !isWire($0) }
        let out = refs.filter { $0.from == id }
            .map { Reference(id: $0.id, other: $0.to, outgoing: true, label: $0.label) }
        let into = refs.filter { $0.to == id }
            .map { Reference(id: $0.id, other: $0.from, outgoing: false, label: $0.label) }
        return out + into
    }

    /// Whether a link is drawn as a line. References live in the chip and the
    /// floating list instead; only breadboard wires are drawn, unless all
    /// references are switched on (R).
    func showsReference(_ c: Connection) -> Bool {
        isWire(c) || showAllReferences || editingConnection == c.id
    }

    func deleteConnection(_ id: UUID) {
        guard board.connections.contains(where: { $0.id == id }) else { return }
        checkpoint()
        board.connections.removeAll { $0.id == id }
        if selectedConnection == id { selectedConnection = nil }
        scheduleSave()
    }

    /// A card to reveal once the canvas has a size.
    @ObservationIgnored var pendingReveal: UUID?

    /// Re-reads the board after something outside the app changed its files.
    /// Skipped while there are unsaved edits, which will be written instead.
    func reloadFromDisk() {
        guard !isClosed, dirty.isEmpty, removedFiles.isEmpty, saveWork == nil, dragOrigins == nil,
              editing == nil else { return }
        let fresh = library.load(board.name)
        guard fresh.cards != board.cards || fresh.connections != board.connections else { return }
        checkpoint()
        board.cards = fresh.cards
        board.connections = fresh.connections
        for i in board.cards.indices { fitHeight(&board.cards[i]) }
        selection.formIntersection(Set(board.cards.map(\.id)))
    }

    /// When this store last wrote to disk, so the file watcher can ignore our own writes.
    @ObservationIgnored private(set) var lastSaved = Date.distantPast

    // MARK: Undo

    /// Typing into a card: one undo step per editing session.
    func editText(_ id: UUID, _ change: (inout Card) -> Void) {
        guard let before = card(id) else { return }
        var after = before
        change(&after)
        guard after != before else { return }
        checkpoint(coalescing: "text-\(id)-\(editSession)")
        update(id, change)
    }

    /// Records the board as it is now, before a user change.
    func checkpoint(coalescing key: String? = nil) {
        guard !checkpointedThisTurn else { return }
        if let key, key == lastCheckpointKey { return }
        lastCheckpointKey = key
        undoStack.append(Snapshot(cards: board.cards, connections: board.connections))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        checkpointedThisTurn = true
        DispatchQueue.main.async { [weak self] in self?.checkpointedThisTurn = false }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(Snapshot(cards: board.cards, connections: board.connections))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(Snapshot(cards: board.cards, connections: board.connections))
        restore(snapshot)
    }

    /// Swaps in a snapshot and reconciles the card files on disk with it.
    private func restore(_ snapshot: Snapshot) {
        let restoredIDs = Set(snapshot.cards.map(\.id))
        let current = Dictionary(board.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for card in board.cards where !restoredIDs.contains(card.id) {
            removedFiles.append(card.fileName)
            dirty.remove(card.id)
            videos[card.id] = nil
        }
        var cards = snapshot.cards
        for i in cards.indices {
            if let live = current[cards[i].id] {
                // Playback progress isn't part of history.
                cards[i].position = live.position
                if live == cards[i] { continue }
            }
            dirty.insert(cards[i].id)
            removedFiles.removeAll { $0 == cards[i].fileName }
        }
        board.cards = cards
        board.connections = snapshot.connections

        selection.formIntersection(restoredIDs)
        if let c = selectedConnection, !snapshot.connections.contains(where: { $0.id == c }) { selectedConnection = nil }
        editing = nil
        editingConnection = nil
        connectingFrom = nil
        lastCheckpointKey = nil
        for i in board.cards.indices { fitHeight(&board.cards[i]) }
        scheduleSave()
    }

    // MARK: Saving

    func scheduleSave() {
        guard !isClosed else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard !isClosed else { return }
        lastSaved = Date()
        library.save(board, viewport: Viewport(x: offset.x, y: offset.y, scale: scale),
                     dirty: dirty, removed: removedFiles)
        dirty = []
        removedFiles = []
    }

    /// Saves and stops writing, e.g. before the board folder is renamed or trashed.
    func close() {
        saveNow()
        isClosed = true
    }
}

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
    /// Pointer location in canvas coordinates.
    var hover: CGPoint?
    var showHelp = false
    var showLinkPrompt = false
    /// Cards whose underlying video file is being looked up.
    var resolving: Set<UUID> = []

    @ObservationIgnored var canvasSize: CGSize = .zero
    /// Canvas frame in window coordinates, for routing scroll events.
    @ObservationIgnored var canvasFrame: CGRect = .zero
    @ObservationIgnored private var dirty = Set<UUID>()
    @ObservationIgnored private var removedFiles: [String] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var dragOrigins: [UUID: CGPoint]?
    @ObservationIgnored private var resizeOrigin: CGSize?
    @ObservationIgnored private var videos: [UUID: VideoController] = [:]
    @ObservationIgnored private var terminateObserver: Any?
    @ObservationIgnored private var isClosed = false

    init(library: Library, name: String) {
        self.library = library
        let board = library.load(name)
        self.board = board
        offset = CGPoint(x: board.viewport.x, y: board.viewport.y)
        scale = board.viewport.scale
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

    /// Where new cards go: under the pointer, or the middle of the view.
    var insertionPoint: CGPoint {
        toWorld(hover ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    func pan(_ dx: CGFloat, _ dy: CGFloat) {
        offset.x += dx
        offset.y += dy
        scheduleSave()
    }

    func zoom(by factor: CGFloat, around point: CGPoint? = nil) {
        let anchor = point ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let world = toWorld(anchor)
        scale = min(4, max(0.1, scale * factor))
        offset = CGPoint(x: anchor.x - world.x * scale, y: anchor.y - world.y * scale)
        scheduleSave()
    }

    func resetZoom() { zoom(by: 1 / scale) }

    func zoomToFit() {
        guard let first = board.cards.first, canvasSize.width > 0 else { return }
        let r = board.cards.reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -60, dy: -60)
        scale = min(1.5, max(0.1, min(canvasSize.width / r.width, canvasSize.height / r.height)))
        offset = CGPoint(x: (canvasSize.width - r.width * scale) / 2 - r.minX * scale,
                         y: (canvasSize.height - r.height * scale) / 2 - r.minY * scale)
        scheduleSave()
    }

    // MARK: Cards

    func card(_ id: UUID) -> Card? { board.cards.first { $0.id == id } }

    func update(_ id: UUID, content: Bool = true, _ change: (inout Card) -> Void) {
        guard let i = board.cards.firstIndex(where: { $0.id == id }) else { return }
        change(&board.cards[i])
        if content { dirty.insert(id) }
        scheduleSave()
    }

    /// Adds a card centred on `point` (world coordinates).
    @discardableResult
    func add(_ kind: CardKind, at point: CGPoint, edit: Bool = false,
             configure: (inout Card) -> Void = { _ in }) -> UUID {
        var card = Card(kind: kind)
        let size = kind.defaultSize
        card.frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height)
        if kind == .sticky { card.color = .yellow }
        configure(&card)
        board.cards.append(card)
        dirty.insert(card.id)
        selection = [card.id]
        selectedConnection = nil
        editing = edit ? card.id : nil
        scheduleSave()
        return card.id
    }

    func addURL(_ raw: String, at point: CGPoint) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            addText(s, at: point)
            return
        }
        let kind: CardKind = VideoSource.detect(url) != nil ? .video : .link
        let id = add(kind, at: point) {
            $0.url = url.absoluteString
            $0.title = url.host ?? s
        }
        if VideoSource.isXPost(url) { resolveMedia(id) }
        Task { @MainActor in
            let meta = await LinkMetadata.fetch(url)
            self.update(id) { card in
                if let t = meta.title, !t.isEmpty { card.title = t }
                if let d = meta.summary, !d.isEmpty { card.summary = d }
                if card.kind == .link, let image = meta.image { card.image = image }
            }
        }
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

    func addImageData(_ data: Data, ext: String, title: String = "", at point: CGPoint) {
        let assets = board.folder.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let name = UUID().uuidString.lowercased() + "." + ext
        guard (try? data.write(to: assets.appendingPathComponent(name))) != nil else { return }

        var size = CardKind.image.defaultSize
        if let img = NSImage(data: data), img.size.width > 0 {
            let w = min(420, max(160, img.size.width))
            size = CGSize(width: w, height: w * img.size.height / img.size.width)
        }
        add(.image, at: point) {
            $0.image = "assets/\(name)"
            $0.title = title
            $0.frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
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
        for id in selection { update(id) { $0.color = color } }
    }

    func deleteSelection() {
        if let cid = selectedConnection {
            board.connections.removeAll { $0.id == cid }
            selectedConnection = nil
            scheduleSave()
            return
        }
        guard !selection.isEmpty else { return }
        for card in board.cards where selection.contains(card.id) {
            removedFiles.append(card.fileName)
            dirty.remove(card.id)
            videos[card.id] = nil
        }
        board.cards.removeAll { selection.contains($0.id) }
        board.connections.removeAll { selection.contains($0.from) || selection.contains($0.to) }
        selection = []
        editing = nil
        scheduleSave()
    }

    // MARK: Selection & dragging

    func clearSelection() {
        selection = []
        selectedConnection = nil
        editing = nil
        editingConnection = nil
        connectingFrom = nil
    }

    func beginEditing(_ id: UUID) {
        selection = [id]
        selectedConnection = nil
        editing = id
    }

    var isDragging: Bool { dragOrigins != nil }

    /// Called on mouse-down on a card.
    func beginDrag(_ id: UUID, shift: Bool) {
        if let from = connectingFrom {
            connect(from, id)
            connectingFrom = nil
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

    func drag(_ t: CGSize) {
        guard let origins = dragOrigins, !origins.isEmpty else { return }
        for i in board.cards.indices {
            guard let o = origins[board.cards[i].id] else { continue }
            board.cards[i].frame.origin = CGPoint(x: o.x + t.width / scale, y: o.y + t.height / scale)
        }
    }

    func endDrag() {
        dragOrigins = nil
        // Bring the moved cards to the front.
        let moving = board.cards.filter { selection.contains($0.id) }
        if !moving.isEmpty, board.cards.suffix(moving.count).map(\.id) != moving.map(\.id) {
            board.cards.removeAll { selection.contains($0.id) }
            board.cards.append(contentsOf: moving)
        }
        scheduleSave()
    }

    func resize(_ id: UUID, by t: CGSize) {
        guard let card = card(id) else { return }
        if resizeOrigin == nil { resizeOrigin = card.frame.size }
        let o = resizeOrigin ?? card.frame.size
        update(id, content: false) {
            $0.frame.size = CGSize(width: max(140, o.width + t.width / scale),
                                   height: max(90, o.height + t.height / scale))
        }
    }

    func endResize() { resizeOrigin = nil }

    // MARK: Connections

    func startConnecting() {
        guard let id = selection.first else { return }
        editing = nil
        connectingFrom = id
    }

    func connect(_ a: UUID, _ b: UUID) {
        guard a != b, !board.connections.contains(where: {
            ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a)
        }) else { return }
        board.connections.append(Connection(from: a, to: b))
        selection = [b]
        scheduleSave()
    }

    func setLabel(_ id: UUID, _ label: String) {
        guard let i = board.connections.firstIndex(where: { $0.id == id }) else { return }
        board.connections[i].label = label.trimmingCharacters(in: .whitespaces)
        scheduleSave()
    }

    // MARK: Video

    func video(_ id: UUID) -> VideoController {
        if let v = videos[id] { return v }
        let v = VideoController()
        videos[id] = v
        return v
    }

    /// Appends a `- [m:ss] ` line at the video's current time and starts editing.
    func addTimestamp(_ id: UUID) {
        video(id).currentTime { [weak self] t in
            guard let self else { return }
            self.update(id) { card in
                var body = card.body
                if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
                body += "- [\(Timestamp.format(t))] "
                card.body = body
            }
            self.beginEditing(id)
        }
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

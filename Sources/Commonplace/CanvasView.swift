import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

struct CanvasView: View {
    @Bindable var store: BoardStore
    @Environment(\.theme) private var theme
    /// Canvas offset and pointer position when the current pan began.
    @State private var panOrigin: (offset: CGPoint, touch: CGPoint)?
    @GestureState private var panning = false
    @State private var monitors: [Any] = []
    @State private var linkText = ""
    @AppStorage("showBrowser") private var showBrowser = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GridBackground(offset: store.offset, scale: store.scale, theme: theme)
                    .contentShape(Rectangle())
                    .gesture(backgroundGesture)
                    .onChange(of: panning) { _, active in if !active { panOrigin = nil } }
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                        store.add(.sticky, at: store.toWorld(tap.location), edit: true)
                    })

                ConnectionsLayer(store: store).allowsHitTesting(false)

                ForEach(store.board.cards) { card in
                    let r = store.toScreen(card.frame)
                    CardView(store: store, card: card)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }

                ForEach(store.board.connections) { connection in
                    ConnectionHandle(store: store, connection: connection)
                }

                StatusBar(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)

                if store.showHelp {
                    HelpOverlay()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { store.showHelp = false }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(theme.background)
            .background(CanvasAnchor(store: store))
            .clipped()
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): store.hover = p
                case .ended: store.hover = nil
                }
            }
            .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: nil) { providers, location in
                handleDrop(providers, at: store.toWorld(location))
            }
            .onAppear {
                store.canvasSize = geo.size
                installMonitors()
            }
            .onChange(of: geo.size) { _, size in store.canvasSize = size }
            .onDisappear(perform: removeMonitors)
        }
        .navigationTitle(store.board.name)
        .sheet(isPresented: $store.showLinkPrompt) {
            LinkPrompt(text: $linkText) {
                store.addURL(linkText, at: store.insertionPoint)
                linkText = ""
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.add(.sticky, at: store.insertionPoint, edit: true) } label: {
                    Label("Sticky", systemImage: CardKind.sticky.symbol)
                }.help("New sticky (S)")
                Button { store.add(.note, at: store.insertionPoint, edit: true) } label: {
                    Label("Note", systemImage: CardKind.note.symbol)
                }.help("New note (N)")
                Button { store.showLinkPrompt = true } label: {
                    Label("Link", systemImage: CardKind.link.symbol)
                }.help("Add link or video (L)")
                Button { store.add(.place, at: store.insertionPoint, edit: true) } label: {
                    Label("Place", systemImage: CardKind.place.symbol)
                }.help("New breadboard place (P)")
                Button { store.pickImages() } label: {
                    Label("Image", systemImage: CardKind.image.symbol)
                }.help("Add image (I)")
                Button { store.startConnecting() } label: {
                    Label("Connect", systemImage: "arrow.triangle.branch")
                }.help("Connect selected card (C)").disabled(store.selection.isEmpty)
                Button { showBrowser.toggle() } label: {
                    Label("Browser", systemImage: "globe")
                }.help("Find things on the web (B)")
                Button { store.zoomToFit() } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }.help("Zoom to fit (F)")
                Button { store.showHelp.toggle() } label: {
                    Label("Shortcuts", systemImage: "keyboard")
                }.help("Shortcuts (?)")
            }
        }
    }

    private var backgroundGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($panning) { _, state, _ in state = true }
            .onChanged { value in
                if panOrigin == nil || panOrigin?.touch != value.startLocation {
                    panOrigin = (store.offset, value.startLocation)
                }
                guard let origin = panOrigin?.offset else { return }
                store.offset = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
            }
            .onEnded { value in
                panOrigin = nil
                if abs(value.translation.width) < 3 && abs(value.translation.height) < 3 {
                    store.clearSelection()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                store.scheduleSave()
            }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        let store = store
        for (i, provider) in providers.enumerated() {
            let p = CGPoint(x: point.x + CGFloat(i) * 30, y: point.y + CGFloat(i) * 30)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { store.addFile(url, at: p) } }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                // Images dragged out of the browser carry their pixels, and
                // usually their address too.
                let page = ClipWebView.recentPage()
                let hasURL = provider.canLoadObject(ofClass: URL.self)
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data, NSImage(data: data) != nil else { return }
                    let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                    DispatchQueue.main.async {
                        guard let id = store.addImageData(data, ext: ext, at: p) else { return }
                        let record = { (image: URL?) in
                            guard let source = ClipWebView.source(page: page, image: image) else { return }
                            store.update(id) {
                                $0.source = source.absoluteString
                                if let image { $0.url = image.absoluteString }
                            }
                        }
                        guard hasURL else { record(nil); return }
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            DispatchQueue.main.async { record(url.map(ClipWebView.unwrap)) }
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async { store.addURL(ClipWebView.unwrap(url).absoluteString, at: p) }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let img = object as? NSImage, let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    DispatchQueue.main.async { store.addImageData(png, ext: "png", at: p) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text { DispatchQueue.main.async { store.addURL(text, at: p) } }
                }
            }
        }
        return true
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        let store = store
        let scroll = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            Self.handleScroll(event, store: store) ? nil : event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event, store: store) ? nil : event
        }
        monitors = [scroll, keys].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Scroll pans, ⌘/⌥-scroll and pinch zoom. Events over web views, text
    /// editors and the sidebar are left alone.
    private static func handleScroll(_ event: NSEvent, store: BoardStore) -> Bool {
        guard let window = event.window, window.attachedSheet == nil,
              let anchor = store.anchorView, anchor.window === window else { return false }
        // Canvas coordinates straight from AppKit, wherever the canvas sits in the layout.
        let p = anchor.convert(event.locationInWindow, from: nil)
        guard anchor.bounds.contains(p) else { return false }

        // Pinch always zooms the board, even over a video or a text editor.
        if event.type == .magnify {
            store.zoom(by: 1 + event.magnification, around: p)
            return true
        }
        // Scrolling over a web page or a text editor scrolls that instead.
        var view = window.contentView?.superview?.hitTest(event.locationInWindow)
        while let v = view {
            if v is WKWebView { return false }
            if let scroll = v as? NSScrollView, scroll.documentView is NSTextView { return false }
            view = v.superview
        }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            store.zoom(by: exp(dy * 0.01), around: p)
        } else {
            store.pan(dx, dy)
        }
        return true
    }

    private static func handleKey(_ event: NSEvent, store: BoardStore) -> Bool {
        guard let window = event.window, window.attachedSheet == nil else { return false }
        let inText = window.firstResponder is NSText
        // Typing into a web page (browser or video) belongs to the page.
        var responder = window.firstResponder as? NSView
        while let v = responder {
            if v is WKWebView { return false }
            responder = v.superview
        }
        let flags = event.modifierFlags

        if event.keyCode == 53 { // Esc
            if store.editing != nil || store.editingConnection != nil {
                store.editing = nil
                store.editingConnection = nil
                window.makeFirstResponder(nil)
                return true
            }
            if inText { return false }
            if store.showHelp { store.showHelp = false } else { store.clearSelection() }
            return true
        }
        // A card just entered editing but its editor isn't focused yet: hold
        // the keys for it rather than treating them as shortcuts.
        if store.editing != nil, !inText, !flags.contains(.command), !flags.contains(.control) {
            switch event.keyCode {
            case 51: if !store.pendingTyping.isEmpty { store.pendingTyping.removeLast() }
            case 36, 76: store.pendingTyping += "\n"
            default: store.pendingTyping += event.characters ?? ""
            }
            return true
        }
        if inText {
            if flags.contains(.command), event.keyCode == 36 { // ⌘Return finishes editing
                store.editing = nil
                window.makeFirstResponder(nil)
                return true
            }
            return false
        }
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": store.paste(); return true
            case "z":
                if flags.contains(.shift) { store.redo() } else { store.undo() }
                return true
            default: break
            }
            return false
        }
        if flags.contains(.control) { return false }

        switch event.keyCode {
        case 51, 117: store.deleteSelection(); return true
        case 36, 76:
            if let id = store.selection.first { store.beginEditing(id) }
            return true
        default: break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let p = store.insertionPoint
        switch key {
        case "s": store.add(.sticky, at: p, edit: true)
        case "n": store.add(.note, at: p, edit: true)
        case "l": store.showLinkPrompt = true
        case "i": store.pickImages()
        case "c": store.startConnecting()
        case "p": store.add(.place, at: p, edit: true)
        case "t": store.addThought()
        case "[", "]":
            guard let id = store.selection.first, store.videoID(for: id) != nil else { return false }
            store.stepSpeed(id, up: key == "]")
        case "b":
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: "showBrowser"), forKey: "showBrowser")
        case "f": store.zoomToFit()
        case "0": store.resetZoom()
        case "=", "+": store.zoom(by: 1.25)
        case "-": store.zoom(by: 1 / 1.25)
        case "?", "/": store.showHelp.toggle()
        default:
            guard let n = Int(key), (1...7).contains(n) else { return false }
            store.setColor(n == 7 ? .none : CardColor.allCases[n])
        }
        return true
    }
}

// MARK: - Layers

struct GridBackground: View {
    let offset: CGPoint
    let scale: CGFloat
    let theme: Theme

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.background))
            var step = 24 * scale
            while step < 14 { step *= 2 }
            let r = max(0.8, 1.1 * min(scale, 1.4))
            var dots = Path()
            var x = offset.x.truncatingRemainder(dividingBy: step) - step
            while x < size.width + step {
                var y = offset.y.truncatingRemainder(dividingBy: step) - step
                while y < size.height + step {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    y += step
                }
                x += step
            }
            ctx.fill(dots, with: .color(theme.grid))
        }
    }
}

enum Geometry {
    /// Where the ray from the centre of `r` towards `p` leaves the rectangle.
    static func edge(_ r: CGRect, toward p: CGPoint) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let sx = dx != 0 ? (r.width / 2) / abs(dx) : .infinity
        let sy = dy != 0 ? (r.height / 2) / abs(dy) : .infinity
        let t = min(sx, sy)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    static func endpoints(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint) {
        let pad: CGFloat = 6
        let p1 = edge(a.insetBy(dx: -pad, dy: -pad), toward: CGPoint(x: b.midX, y: b.midY))
        let p2 = edge(b.insetBy(dx: -pad, dy: -pad), toward: CGPoint(x: a.midX, y: a.midY))
        return (p1, p2)
    }

    static func arrowhead(at tip: CGPoint, from: CGPoint, size: CGFloat) -> Path {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        var path = Path()
        path.move(to: tip)
        for a in [angle + .pi * 5 / 6, angle - .pi * 5 / 6] {
            path.addLine(to: CGPoint(x: tip.x + cos(a) * size, y: tip.y + sin(a) * size))
        }
        path.closeSubpath()
        return path
    }
}

struct ConnectionsLayer: View {
    let store: BoardStore
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { ctx, _ in
            let chrome = min(store.scale, 1)
            let width = max(1, 1.6 * chrome)
            for c in store.board.connections {
                guard let (p1, p2) = store.endpoints(c) else { continue }
                let color = store.selectedConnection == c.id ? theme.accent : theme.muted
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                ctx.fill(Geometry.arrowhead(at: p2, from: p1, size: max(6, 10 * chrome)), with: .color(color))
            }
            if let from = store.connectingFrom, let a = store.card(from), let h = store.hover {
                let start = store.connectingItem.flatMap { store.affordanceAnchor(a, item: $0, toward: h) }
                    ?? Geometry.edge(store.toScreen(a.frame), toward: h)
                var path = Path()
                path.move(to: start)
                path.addLine(to: h)
                ctx.stroke(path, with: .color(theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
    }
}

/// The clickable midpoint of a connection: a dot, or its label.
struct ConnectionHandle: View {
    let store: BoardStore
    let connection: Connection
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let (p1, p2) = store.endpoints(connection) {
            let selected = store.selectedConnection == connection.id
            Group {
                if store.editingConnection == connection.id {
                    TextField("Label", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 150)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.accent))
                        .focused($focused)
                        .onAppear {
                            text = connection.label
                            DispatchQueue.main.async { focused = true }
                        }
                        .onSubmit(commit)
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                } else if !connection.label.isEmpty {
                    Text(connection.label)
                        .font(.system(size: max(9, 12 * min(store.scale, 1))))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(selected ? theme.accent : theme.border))
                } else {
                    Circle()
                        .fill(selected ? theme.accent : theme.muted)
                        .frame(width: 8, height: 8)
                        .padding(6)
                        .contentShape(Circle())
                }
            }
            .onTapGesture(count: 2) {
                store.selectedConnection = connection.id
                store.editingConnection = connection.id
            }
            .onTapGesture {
                store.selection = []
                store.editing = nil
                store.selectedConnection = connection.id
            }
            .help("Click to select · double-click to label")
            .position(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        }
    }

    private func commit() {
        guard store.editingConnection == connection.id else { return }
        store.setLabel(connection.id, text)
        store.editingConnection = nil
    }
}

struct StatusBar: View {
    let store: BoardStore
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text("\(Int((store.scale * 100).rounded()))%")
            if store.connectingFrom != nil {
                Text("Connecting — click a card · Esc to cancel").foregroundStyle(theme.accent)
            } else {
                Text("\(store.board.cards.count) cards")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.surface.opacity(0.9), in: Capsule())
        .padding(12)
    }
}

struct HelpOverlay: View {
    @Environment(\.theme) private var theme

    private let rows: [(String, String)] = [
        ("S", "New sticky"), ("N", "New note"), ("L", "Add link or video"), ("I", "Add image"),
        ("⌘V", "Paste URL, image or text"), ("Double-click", "Sticky on canvas / edit card"),
        ("C", "Connect selection → click target"), ("P", "New breadboard place"),
        ("B", "Browser: search, drag or right-click to add"),
        ("Affordance dot", "Connect that affordance → click a place"), ("T", "Thought from the selection (a moment on videos)"),
        ("[ · ]", "Video slower · faster"),
        ("1–6 · 7", "Colour · clear colour"), ("Return · Esc", "Edit · finish"),
        ("Delete", "Remove selection"), ("⌘Z · ⇧⌘Z", "Undo · redo"), ("Scroll · ⌘-scroll", "Pan · zoom"),
        ("F · 0 · = · −", "Fit · 100% · zoom in · out"), ("⌃⇧⌘Space", "Next theme"), ("?", "Toggle this"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                    .padding(.bottom, 4)
                ForEach(rows, id: \.0) { key, action in
                    HStack {
                        Text(key)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.accent)
                            .frame(width: 150, alignment: .leading)
                        Text(action).font(.system(size: 12.5)).foregroundStyle(theme.text)
                    }
                }
            }
            .padding(24)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border))
        }
    }
}

struct LinkPrompt: View {
    @Binding var text: String
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a link or video").font(.headline)
            TextField("https://…", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .onSubmit(add)
            Text("YouTube, X and Vimeo links become playable video cards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if text.isEmpty, let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") {
                text = s
            }
        }
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onAdd()
        dismiss()
    }
}

/// An invisible AppKit view the size of the canvas. Events are converted into
/// its coordinates, so scroll and pinch routing doesn't depend on where the
/// canvas sits in the window (sidebar, split view, toolbar).
struct CanvasAnchor: NSViewRepresentable {
    let store: BoardStore

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        store.anchorView = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        store.anchorView = view
    }
}

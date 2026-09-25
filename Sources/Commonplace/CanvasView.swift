import SwiftUI
import AppKit
import WebKit
import AVKit
import SwiftTerm
import UniformTypeIdentifiers

struct CanvasView: View {
    @Bindable var store: BoardStore
    @Environment(\.theme) private var theme
    /// Canvas offset and pointer position when the current pan began.
    @State private var panOrigin: (offset: CGPoint, touch: CGPoint)?
    @GestureState private var panning = false
    /// Selection box in canvas coordinates while dragging on empty canvas.
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<UUID> = []
    @State private var dragPans = false
    @State private var monitors: [Any] = []
    @State private var linkText = ""
    @AppStorage("showBrowser") private var showBrowser = false
    @AppStorage("showTerminal") private var showTerminal = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GridBackground(offset: store.offset, scale: store.scale, theme: theme)
                    .contentShape(Rectangle())
                    .gesture(backgroundGesture)
                    .onChange(of: panning) { _, active in
                        if !active {
                            panOrigin = nil
                            marquee = nil
                        }
                    }
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                        store.add(.sticky, at: store.toWorld(tap.location), edit: true)
                    })

                ConnectionsLayer(store: store).allowsHitTesting(false)

                // Labels sit under cards so they never cover card text.
                ForEach(store.board.connections) { connection in
                    ConnectionHandle(store: store, connection: connection)
                }

                ForEach(store.board.cards) { card in
                    let r = store.toScreen(card.frame)
                    CardView(store: store, card: card)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }

                ReferenceHalo(store: store)

                if let marquee {
                    Rectangle()
                        .fill(theme.accent.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(theme.accent.opacity(0.8), lineWidth: 1))
                        .frame(width: marquee.width, height: marquee.height)
                        .position(x: marquee.midX, y: marquee.midY)
                        .allowsHitTesting(false)
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
                if let id = store.pendingReveal { store.reveal(id) }
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
                Button { showTerminal.toggle() } label: {
                    Label("Terminal", systemImage: "terminal")
                }.help("Terminal for agents (⌃`)")
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
                // Drag on empty canvas draws a selection box; with Space held it pans.
                if panOrigin == nil || panOrigin?.touch != value.startLocation {
                    panOrigin = (store.offset, value.startLocation)
                    dragPans = store.spaceHeld
                    marqueeBase = NSEvent.modifierFlags.contains(.shift) ? store.selection : []
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                if dragPans {
                    guard let origin = panOrigin?.offset else { return }
                    store.offset = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                    return
                }
                guard abs(value.translation.width) >= 3 || abs(value.translation.height) >= 3 else { return }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                marquee = rect
                store.select(in: rect, adding: marqueeBase)
            }
            .onEnded { value in
                panOrigin = nil
                marquee = nil
                if abs(value.translation.width) < 3 && abs(value.translation.height) < 3,
                   !NSEvent.modifierFlags.contains(.shift) {
                    store.clearSelection()
                }
                if dragPans { store.scheduleSave() }
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
        let spaceUp = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == 49, store.spaceHeld {
                store.spaceHeld = false
                NSCursor.arrow.set()
            }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event, store: store) ? nil : event
        }
        monitors = [scroll, keys, spaceUp].compactMap { $0 }
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
        // Typing into a web page, or Space on a focused video player, belongs to it.
        var responder = window.firstResponder as? NSView
        while let v = responder {
            if v is WKWebView || v is AVPlayerView || v is TerminalView { return false }
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
            case "a": store.selectAll(); return true
            case "z":
                if flags.contains(.shift) { store.redo() } else { store.undo() }
                return true
            default: break
            }
            return false
        }
        if flags.contains(.control) { return false }

        switch event.keyCode {
        case 49: // Space: hold and drag to pan
            if !event.isARepeat, !store.spaceHeld {
                store.spaceHeld = true
                NSCursor.openHand.set()
            }
            return true
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
        case "c":
            if flags.contains(.shift) { store.startSequenceLink() } else { store.startConnecting() }
        case "a": if !store.tidy() { NSSound.beep() }
        case "r": store.showAllReferences.toggle()
        case "p": store.add(.place, at: p, edit: true)
        case "t":
            if flags.contains(.shift) { store.continueSequence() } else { store.addThought() }
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

    /// A smooth curve from a parent to a child, leaving the side that faces
    /// the child. Returns the path and where it meets the child.
    static func sequencePath(from parent: CGRect, to child: CGRect, scale: CGFloat) -> (Path, CGPoint) {
        let inset = 22 * scale
        var path = Path()
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
        if child.minX >= parent.maxX - 4 || child.maxX <= parent.minX + 4 {
            // Side by side: out of the parent's side, into the child's facing side.
            let right = child.minX >= parent.maxX - 4
            start = CGPoint(x: right ? parent.maxX : parent.minX, y: parent.minY + min(parent.height / 2, inset))
            end = CGPoint(x: right ? child.minX : child.maxX, y: child.minY + min(child.height / 2, inset))
            let mid = (end.x - start.x) / 2
            c1 = CGPoint(x: start.x + mid, y: start.y)
            c2 = CGPoint(x: end.x - mid, y: end.y)
        } else {
            // Stacked: out of the bottom (or top), into the child's facing edge.
            let below = child.midY >= parent.midY
            start = CGPoint(x: parent.midX, y: below ? parent.maxY : parent.minY)
            end = CGPoint(x: child.midX, y: below ? child.minY : child.maxY)
            let mid = (end.y - start.y) / 2
            c1 = CGPoint(x: start.x, y: start.y + mid)
            c2 = CGPoint(x: end.x, y: end.y - mid)
        }
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return (path, end)
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
            let focus = store.focusedCards

            // Sequence links: the tree that gives the board its order. Solid
            // and always shown, strongest for what you're focused on.
            for card in store.board.cards {
                guard let parentID = card.parent, let parent = store.card(parentID) else { continue }
                let related = focus.contains(card.id) || focus.contains(parentID)
                let (path, end) = Geometry.sequencePath(from: store.toScreen(parent.frame),
                                                        to: store.toScreen(card.frame), scale: store.scale)
                let color: SwiftUI.Color = related ? theme.accent : theme.muted.opacity(0.7)
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: max(1, (related ? 2.2 : 1.6) * chrome), lineCap: .round))
                let r = max(2, 3 * chrome)
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }

            // References: the web across the tree. Only the active card's are
            // drawn (or all, with R); the rest travel as chips on the cards.
            for c in store.board.connections where store.showsReference(c) {
                guard let (p1, p2) = store.endpoints(c) else { continue }
                // Focus and context: the focused cards' connections come forward,
                // the rest recede; with no focus, all lines stay quiet.
                let related = store.selection.contains(c.from) || store.selection.contains(c.to)
                    || store.selectedConnection == c.id
                let wire = store.isWire(c)
                let color: SwiftUI.Color = related ? theme.accent : theme.muted.opacity(wire ? 0.85 : 0.5)
                let width = max(1, (related ? 1.8 : wire ? 1.5 : 1.2) * chrome)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                // Breadboard wires are the diagram: solid. References: dashed.
                let dash: [CGFloat] = wire ? [] : [max(3, 6 * chrome), max(2, 4 * chrome)]
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                ctx.fill(Geometry.arrowhead(at: p2, from: p1, size: max(6, 10 * chrome)), with: .color(color))
            }
            if let from = store.connectingFrom, let a = store.card(from), let h = store.hover {
                let start = store.connectingItem.flatMap { store.affordanceAnchor(a, item: $0, toward: h) }
                    ?? Geometry.edge(store.toScreen(a.frame), toward: h)
                var path = Path()
                path.move(to: start)
                path.addLine(to: h)
                ctx.stroke(path, with: .color(theme.accent),
                           style: StrokeStyle(lineWidth: store.connectingSequence ? 2 : 1.5,
                                              dash: store.connectingSequence ? [] : [5, 4]))
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
            let focus = store.selection
            let related = selected || focus.contains(connection.from) || focus.contains(connection.to)
            let detailed = store.scale >= BoardStore.detailZoom
            let editing = store.editingConnection == connection.id
            // Only for links that are drawn, and then only when legible or active.
            if store.showsReference(connection) && (editing || related || detailed) {
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
                        .font(.system(size: related ? 11 : 12 * min(store.scale, 1)))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(related ? theme.accent : theme.border))
                        .opacity(!focus.isEmpty && !related ? 0.35 : 1)
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
            .help("Reference · click to select · double-click to label")
            .contextMenu {
                Button("Make Sequence Link") { store.makeSequence(connection.id) }
                Button("Label…") {
                    store.selectedConnection = connection.id
                    store.editingConnection = connection.id
                }
                Divider()
                Button("Delete Reference", role: .destructive) {
                    store.selectedConnection = connection.id
                    store.deleteSelection()
                }
            }
            .position(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            }
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
                Text(store.connectingSequence ? "Sequence — click the card that follows from this · Esc to cancel"
                                              : "Reference — click a card · Esc to cancel")
                    .foregroundStyle(theme.accent)
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
        ("C · ⇧C", "Reference → click target · sequence link → click what follows"), ("P", "New breadboard place"),
        ("B", "Browser: search, drag or right-click to add"),
        ("Affordance dot", "Connect that affordance → click a place"), ("T · ⇧T", "Branch a thought from the selection · continue its sequence"),
        ("A", "Tidy the selected branch"),
        ("R", "Show every reference line (or just the selection's)"),
        ("[ · ]", "Video slower · faster"),
        ("1–6 · 7", "Colour · clear colour"), ("Return · Esc", "Edit · finish"),
        ("Drag · ⇧-drag", "Select a box of cards · add to selection"),
        ("Space-drag", "Pan the board"), ("⌘A", "Select all"),
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

/// Floating references: when one card is active, all of its references (both
/// ways) float beside it as a list, so the list is always the whole story.
/// Entries for cards in view are marked, and hovering one outlines the real
/// card; entries for cards out of view point toward them. Choosing one
/// travels there, and its own references float in.
struct ReferenceHalo: View {
    let store: BoardStore
    @Environment(\.theme) private var theme

    private struct Entry: Identifiable {
        let ref: BoardStore.Reference
        let card: Card
        let frame: CGRect
        let angle: Double
        let inView: Bool
        var id: UUID { ref.id }
    }

    private struct Layout {
        var entries: [Entry] = []
        var more: Int = 0
        var moreFrame: CGRect = .zero
    }

    private static let size = CGSize(width: 220, height: 50)
    private static let gap: CGFloat = 6

    var body: some View {
        let layout = self.layout()
        if !layout.entries.isEmpty, let id = store.selection.first, let active = store.card(id) {
            let source = store.toScreen(active.frame)
            ZStack(alignment: .topLeading) {
                // Out-of-view entries get a faint leader to the card; in-view
                // ones already have the real line.
                Canvas { ctx, _ in
                    for e in layout.entries where !e.inView {
                        let mid = CGPoint(x: e.frame.midX, y: e.frame.midY)
                        let start = Geometry.edge(source.insetBy(dx: -4, dy: -4), toward: mid)
                        let end = Geometry.edge(e.frame.insetBy(dx: -3, dy: -3), toward: start)
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        ctx.stroke(path, with: .color(theme.accent.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
                    }
                }
                .allowsHitTesting(false)
                ForEach(layout.entries) { e in
                    entry(e)
                        .frame(width: e.frame.width, height: e.frame.height)
                        .position(x: e.frame.midX, y: e.frame.midY)
                }
                if layout.more > 0 {
                    moreButton(layout.more, active: id)
                        .frame(width: layout.moreFrame.width, height: layout.moreFrame.height)
                        .position(x: layout.moreFrame.midX, y: layout.moreFrame.midY)
                }
            }
            .transition(.opacity)
        }
    }

    private func entry(_ e: Entry) -> some View {
        Button { store.reveal(e.ref.other, animated: true) } label: {
            HStack(spacing: 9) {
                // Where the card is: a dot when it's in view, otherwise an arrow toward it.
                Group {
                    if e.inView {
                        Image(systemName: "eye").font(.system(size: 10))
                    } else {
                        Image(systemName: "location.north.fill").font(.system(size: 10))
                            .rotationEffect(.radians(e.angle + .pi / 2))
                    }
                }
                .foregroundStyle(theme.accent)
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text((e.ref.outgoing ? "→ " : "← ")
                         + (e.ref.label.isEmpty ? (e.ref.outgoing ? "refers to" : "referred to by") : e.ref.label)
                         + (e.inView ? " · in view" : ""))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    Text(e.card.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(theme.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.accent.opacity(store.highlight == e.ref.other ? 0.9 : 0.35)))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.15), radius: 8, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { store.highlight = e.ref.other } else if store.highlight == e.ref.other { store.highlight = nil }
        }
        .help("Go to “\(e.card.headline)”")
    }

    private func moreButton(_ count: Int, active: UUID) -> some View {
        Menu {
            ForEach(store.references(of: active)) { ref in
                let name = store.card(ref.other)?.headline ?? "Card"
                Button((ref.outgoing ? "→  " : "←  ") + name + (ref.label.isEmpty ? "" : "  ·  " + ref.label)) {
                    store.reveal(ref.other, animated: true)
                }
            }
        } label: {
            Text("+ \(count) more").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Every reference of a single active card, in a column on whichever side
    /// of it has room, capped to what fits in the view.
    private func layout() -> Layout {
        guard store.selection.count == 1, let id = store.selection.first, let active = store.card(id),
              store.viewSize != .zero, store.editing != id, !store.isGliding else { return Layout() }
        let refs = store.references(of: id).compactMap { ref -> (BoardStore.Reference, Card)? in
            store.card(ref.other).map { (ref, $0) }
        }
        guard !refs.isEmpty else { return Layout() }
        let view = CGRect(origin: .zero, size: store.viewSize)
        let source = store.toScreen(active.frame)
        let size = Self.size, gap = Self.gap, margin: CGFloat = 30
        let fits = max(1, Int((view.height - 24 + gap) / (size.height + gap)))
        let shown = refs.count > fits ? fits - 1 : refs.count
        let rows = shown + (refs.count > shown ? 1 : 0)
        let total = CGFloat(rows) * (size.height + gap) - gap
        // Keep to the side used last time for this card unless it no longer fits.
        let fitsRight = source.maxX + margin + size.width <= view.width - 12
        let fitsLeft = source.minX - margin - size.width >= 12
        let right: Bool
        if store.haloSide[id] == false {
            right = !fitsLeft && fitsRight
        } else {
            right = fitsRight || !fitsLeft
        }
        store.haloSide[id] = right
        let x = right ? source.maxX + margin : source.minX - margin - size.width
        var y = min(max(12, source.midY - total / 2), max(12, view.height - total - 12))
        var layout = Layout()
        for (ref, other) in refs.prefix(shown) {
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            y += size.height + gap
            let r = store.toScreen(other.frame)
            layout.entries.append(Entry(ref: ref, card: other, frame: frame,
                                        angle: atan2(r.midY - frame.midY, r.midX - frame.midX),
                                        inView: view.insetBy(dx: 24, dy: 24).intersects(r)))
        }
        if refs.count > shown {
            layout.more = refs.count - shown
            layout.moreFrame = CGRect(x: x, y: y, width: size.width, height: 22)
        }
        return layout
    }
}

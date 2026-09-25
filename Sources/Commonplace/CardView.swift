import SwiftUI
import AppKit

/// A card laid out at screen scale. Sizes are multiplied by the zoom rather
/// than using `scaleEffect`, so embedded web views and text editors stay crisp
/// and interactive.
struct CardView: View {
    let store: BoardStore
    let card: Card
    @Environment(\.theme) private var theme
    @GestureState private var dragging = false
    @GestureState private var resizing = false

    /// Content (text, images, video) scales with zoom.
    private var s: CGFloat { store.scale }
    /// Chrome (title bars, buttons, badges, corners) scales down with zoom but
    /// never past 100%, so zooming into a card doesn't blow up its frame.
    private var c: CGFloat { min(store.scale, 1) }
    private var isSelected: Bool { store.selection.contains(card.id) }
    private var isEditing: Bool { store.editing == card.id }
    private var radius: CGFloat { 10 * c }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill)
            .overlay(alignment: .top) {
                if card.kind == .note, card.color != .none {
                    theme.color(card.color).frame(height: 4 * c)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : theme.border.opacity(card.kind == .sticky ? 0 : 1),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 10 * c, y: 3 * c)
            .overlay(alignment: .bottomTrailing) {
                if isSelected, store.selection.count == 1 { resizeHandle }
            }
            // The arrival/hover outline is always present and fades by opacity, so it
            // moves with the card (a removed view would linger where it was) and sits
            // beneath the reference chip.
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.accent, lineWidth: 4)
                    .opacity(store.flash == card.id || store.highlight == card.id ? 1 : 0)
                    .animation(.easeOut(duration: 0.35), value: store.flash == card.id || store.highlight == card.id)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) { referenceChip }
            .contentShape(Rectangle())
            .gesture(moveGesture, including: isEditing ? .subviews : .all)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if !isEditing { store.beginEditing(card.id) }
            })
            // GestureState resets even when a gesture is cancelled.
            .onChange(of: dragging) { _, active in if !active { store.endDrag() } }
            .onChange(of: resizing) { _, active in if !active { store.endResize() } }
            .onChange(of: isEditing) { _, _ in if card.kind == .place { store.fitPlace(card.id) } }
            .contextMenu {
                Button("Add Thought") { store.selection = [card.id]; store.addThought() }
                Button("Choose What Follows This…") { store.selection = [card.id]; store.startThreadLink() }
                Button("Tidy Thread") { store.tidy([card.id]) }
                Divider()
                Button("Copy") { selectForMenu(); store.copySelection() }
                Button("Duplicate") { selectForMenu(); store.duplicateSelection() }
                if card.parent != nil {
                    Divider()
                    Button("Turn Thread into Reference") { store.makeReference(card.id) }
                    Button("Detach from Thread") { store.setParent(card.id, nil) }
                }
            }
    }

    // MARK: Chrome

    private var fill: Color {
        card.kind == .sticky ? theme.color(card.color == .none ? .yellow : card.color) : theme.surface
    }

    private var ink: Color { card.kind == .sticky ? theme.ink : theme.text }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                store.dragChanged(card.id, start: value.startLocation, translation: value.translation,
                                  shift: NSEvent.modifierFlags.contains(.shift))
            }
            .onEnded { _ in store.endDrag() }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.background)
            .frame(width: 16, height: 16)
            .background(theme.accent, in: Circle())
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resizing) { _, state, _ in state = true }
                    .onChanged { store.resize(card.id, start: $0.startLocation, by: $0.translation) }
                    .onEnded { _ in store.endResize() }
            )
            .help("Resize")
    }

    private func header() -> some View { header { EmptyView() } }

    private func header<Trailing: View>(@ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6 * c) {
            Image(systemName: card.kind.symbol)
            Text(card.title.isEmpty ? card.kind.label : card.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(theme.text)
            Spacer(minLength: 4 * c)
            trailing()
        }
        .font(.system(size: 11.5 * c))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 10 * c)
        .frame(height: Card.headerHeight * c)
        .frame(maxWidth: .infinity)
        .background(card.color == .none ? theme.raised : theme.color(card.color).opacity(0.35))
    }

    static func speedLabel(_ speed: Double) -> String {
        (speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)) + "×"
    }

    /// References travel with the card rather than as lines across the board:
    /// a small count hanging off the card's bottom edge (clear of its text).
    /// Hidden when zoomed out unless the card is selected.
    @ViewBuilder private var referenceChip: some View {
        let refs = store.references(of: card.id)
        if !refs.isEmpty, !far || isSelected {
            let k = far ? 1 : max(c, 0.8)  // small, but always legible and clickable
            // Selecting the card brings up its floating references, which move
            // with the board (a popover would linger on screen as it glides).
            Button {
                store.selection = [card.id]
                store.selectedConnection = nil
                store.editing = nil
            } label: {
                HStack(spacing: 3 * k) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 7.5 * k, weight: .bold))
                    Text("\(refs.count)")
                        .font(.system(size: 9.5 * k, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(isSelected ? theme.accent : theme.muted)
                .padding(.horizontal, 6 * k)
                .padding(.vertical, 2 * k)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? theme.accent.opacity(0.6) : theme.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(refs.count) reference\(refs.count == 1 ? "" : "s"): select to see them")
            .offset(x: 12 * k, y: 8 * k)
        }
    }

    /// Right-clicking a card outside the selection acts on that card alone.
    private func selectForMenu() {
        if !store.selection.contains(card.id) { store.selection = [card.id] }
    }

    private var openButton: some View {
        Button {
            if let url = card.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.plain)
        .help("Open in browser")
    }

    // MARK: Editing

    private var bodyBinding: Binding<String> {
        Binding(get: { store.card(card.id)?.body ?? "" },
                set: { value in store.editText(card.id) { $0.body = value } })
    }

    private var titleBinding: Binding<String> {
        Binding(get: { store.card(card.id)?.title ?? "" },
                set: { value in store.editText(card.id) { $0.title = value } })
    }

    private func bodyEditor(size: CGFloat) -> some View {
        // Editing text is always readable, whatever the zoom; the editor scrolls.
        CardTextEditor(text: bodyBinding, size: max(12, size * s), color: ink, takePending: store.takePendingTyping)
    }

    private func markdown(_ size: CGFloat, placeholder: String? = nil) -> some View {
        let empty = card.body.isEmpty
        return MarkdownText(
            text: empty ? (placeholder ?? "") : card.body,
            size: size * s,
            color: empty ? (card.kind == .sticky ? ink.opacity(0.5) : theme.muted) : ink,
            accent: card.kind == .sticky ? ink : theme.accent,
            onSeek: store.videoID(for: card.id).map { video in { store.video(video).seek($0) } })
    }

    // MARK: Kinds

    /// Zoomed out, cards trade detail for legibility: a readable headline
    /// rather than shrunken paragraphs, and a still frame rather than a player.
    private var overview: Bool {
        guard !isEditing, card.kind != .image else { return false }
        return s < (card.kind == .video ? BoardStore.overviewZoom : BoardStore.summaryZoom)
    }

    /// Zoomed far enough out that small chrome would be unreadable.
    private var far: Bool { s < BoardStore.overviewZoom }

    @ViewBuilder private var content: some View {
        if overview {
            overviewCard
        } else {
            detailContent
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch card.kind {
        case .sticky: sticky
        case .note: note
        case .link: link
        case .video: video
        case .image: image
        case .place: place
        }
    }

    /// Readable at any zoom: text stays at a legible size (13pt) through the
    /// summary range and only shrinks, to an 8pt floor, when zoomed far out.
    private var overviewFont: CGFloat { min(13, max(8, 30 * s)) }

    private var posterURL: URL? {
        if let image = card.image, image.hasPrefix("http") { return URL(string: image) }
        if case .youtube(let id, _)? = card.url.flatMap(URL.init(string:)).flatMap(VideoSource.detect) {
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        return nil
    }

    @ViewBuilder private var overviewCard: some View {
        if card.kind == .video {
            Color.black
                .overlay {
                    if let url = posterURL {
                        AsyncImage(url: url) { phase in
                            phase.image?.resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) { overviewLabel(icon: "play.fill", onImage: true) }
                .clipped()
        } else {
            VStack(alignment: .leading, spacing: overviewFont * 0.35) {
                overviewLabel(icon: card.kind == .sticky ? nil : card.kind.symbol, onImage: false)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: overviewFont * 0.92))
                        .foregroundStyle(card.kind == .sticky ? ink.opacity(0.85) : theme.muted)
                        .lineSpacing(overviewFont * 0.1)
                        .padding(.horizontal, overviewFont * 0.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    /// The rest of the card's text as plain lines, for the summary view.
    private var excerpt: String {
        var lines: [String]
        switch card.kind {
        case .link: lines = [card.summary ?? ""]
        case .place: lines = Place.affordances(card.body).map { "• " + $0 }
        default:
            lines = card.body.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // The headline already shows the first line when there's no title.
            if card.title.isEmpty, !lines.isEmpty { lines.removeFirst() }
            lines = lines.map { line in
                var text = line
                if text.hasPrefix("#") { text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
                for (prefix, bullet) in [("- [ ] ", "☐ "), ("- [x] ", "☑ "), ("- ", "• "), ("* ", "• "), ("> ", "")]
                where text.hasPrefix(prefix) {
                    text = bullet + text.dropFirst(prefix.count)
                    break
                }
                return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            }
        }
        return String(lines.joined(separator: "\n").prefix(700))
    }

    private func overviewLabel(icon: String?, onImage: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: overviewFont * 0.35) {
            if let icon { Image(systemName: icon).font(.system(size: overviewFont * 0.8)) }
            Text(card.headline)
                .font(.system(size: overviewFont, weight: .semibold))
                .lineLimit(nil)
                .underline(card.kind == .place)
        }
        .foregroundStyle(onImage ? .white : ink)
        .padding(overviewFont * 0.5)
        .background(onImage ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: overviewFont * 0.3))
        .padding(onImage ? overviewFont * 0.3 : 0)
    }

    private var sticky: some View {
        Group {
            if isEditing {
                bodyEditor(size: 15)
            } else {
                markdown(15, placeholder: "Double-click to write")
            }
        }
        .padding(14 * s)
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            if isEditing {
                TextField("Title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: max(13, 18 * s), weight: .semibold))
                    .foregroundStyle(theme.text)
                bodyEditor(size: 14)
            } else {
                if !card.title.isEmpty {
                    Text(card.title)
                        .font(.system(size: 18 * s, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                markdown(14, placeholder: card.title.isEmpty ? "Double-click to write" : nil)
            }
        }
        .padding(.horizontal, 14 * s)
        .padding(.vertical, 16 * s)
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 0) {
            header { openButton }
            if let img = card.image, img.hasPrefix("http"), let url = URL(string: img) {
                Color.clear
                    .frame(height: 130 * s)
                    .overlay {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                theme.raised
                            }
                        }
                    }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 6 * s) {
                if let host = card.url.flatMap(URL.init(string:))?.host {
                    Text(host).font(.system(size: 11 * s)).foregroundStyle(theme.accent)
                }
                if let summary = card.summary {
                    Text(summary)
                        .font(.system(size: 12.5 * s))
                        .foregroundStyle(theme.muted)
                        .lineLimit(4)
                }
                notes
            }
            .padding(12 * s)
        }
    }

    private var video: some View {
        VStack(alignment: .leading, spacing: 0) {
            header {
                // A plain button styled like its neighbours (a Menu ignores the
                // header's font and wouldn't scale with zoom).
                Button { store.stepSpeed(card.id, up: true) } label: {
                    Text(Self.speedLabel(card.speed)).monospacedDigit()
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ForEach(Card.speeds, id: \.self) { speed in
                        Button(Self.speedLabel(speed)) { store.setSpeed(card.id, speed) }
                    }
                }
                .help("Playback speed: click to speed up, right-click for all speeds ([ and ])")
                Button { store.addThoughtAtCurrentTime(card.id) } label: {
                    HStack(spacing: 3 * c) {
                        Image(systemName: "plus")
                        Text("Thought")
                    }
                }
                .buttonStyle(.plain)
                .help("Add a thought at the current time (T)")
                openButton
            }
            Group {
                if store.resolving.contains(card.id) {
                    ZStack {
                        Color.black
                        ProgressView().controlSize(.small)
                    }
                } else if case .file(let url) = VideoSource.of(card) {
                    NativeVideoView(url: url, controller: store.video(card.id))
                } else if let source = VideoSource.of(card) {
                    WebVideoView(source: source, controller: store.video(card.id))
                }
            }
            .frame(height: playerHeight)
            .onAppear { store.resolveMedia(card.id) }
            // Older boards kept timestamped notes inside the card; still show them.
            if isEditing {
                notes.padding(12 * s)
            } else if !card.body.isEmpty {
                ScrollView { notes.padding(12 * s) }
            }
        }
    }

    /// A plain video card gives the player everything below the header, so a
    /// fixed-size header leaves the player a touch taller than 16:9 when zoomed
    /// in (it letterboxes).
    private var playerHeight: CGFloat {
        if card.body.isEmpty && !isEditing {
            return max(0, card.frame.height * s - Card.headerHeight * c)
        }
        return card.frame.width * s * 9 / 16
    }

    @ViewBuilder private var notes: some View {
        if isEditing {
            bodyEditor(size: 13.5)
        } else if !card.body.isEmpty {
            markdown(13.5)
        } else if isSelected, card.kind != .video {
            Text("Double-click to add notes")
                .font(.system(size: 12 * s))
                .foregroundStyle(theme.muted)
        }
    }

    /// A breadboard place: underlined name, then one affordance per row with
    /// a dot to start a connection from it.
    private var place: some View {
        let connected = Set(store.board.connections.filter { $0.from == card.id }.compactMap(\.fromItem))
        return VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                TextField("Place name", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: max(13, 16 * s), weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(height: Place.titleHeight * s)
                CardTextEditor(text: bodyBinding, size: max(12, 13.5 * s), color: theme.text,
                               takePending: store.takePendingTyping)
            } else {
                Text(card.title.isEmpty ? "Place" : card.title)
                    .font(.system(size: 16 * s, weight: .semibold))
                    .underline()
                    .foregroundStyle(card.title.isEmpty ? theme.muted : theme.text)
                    .lineLimit(1)
                    .frame(height: Place.titleHeight * s, alignment: .leading)
                ForEach(Array(Place.affordances(card.body).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6 * s) {
                        Text(item)
                            .font(.system(size: 13.5 * s))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4 * s)
                        Button { store.startConnecting(from: card.id, item: item) } label: {
                            Circle()
                                .strokeBorder(theme.accent, lineWidth: 1.5)
                                .background(Circle().fill(connected.contains(item) ? theme.accent : .clear))
                                .frame(width: 10 * c, height: 10 * c)
                                .padding(4 * c)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Connect “\(item)” to a place")
                    }
                    .frame(height: Place.rowHeight * s)
                }
                if card.body.isEmpty {
                    Text("Double-click to add affordances")
                        .font(.system(size: 12.5 * s))
                        .foregroundStyle(theme.muted)
                        .frame(height: Place.rowHeight * s)
                }
            }
        }
        .padding(.leading, Place.padX * s)
        .padding(.trailing, 6 * s)
        .padding(.top, Place.padTop * s)
    }

    private var image: some View {
        Color.clear
            .overlay {
                if let path = card.image,
                   let img = ImageCache.shared.image(store.board.folder.appendingPathComponent(path)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.system(size: 28 * s)).foregroundStyle(theme.muted)
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if isSelected, let source = card.source.flatMap(URL.init(string:)), let host = source.host {
                    Button { NSWorkspace.shared.open(source) } label: {
                        Label(host, systemImage: "arrow.up.right")
                            .font(.system(size: 11 * c))
                            .padding(.horizontal, 7 * c)
                            .padding(.vertical, 3 * c)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8 * c)
                    .help(source.absoluteString)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isEditing {
                    TextField("Caption", text: titleBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12 * s))
                        .padding(6 * s)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6 * s))
                        .padding(8 * s)
                } else if !card.title.isEmpty {
                    Text(card.title)
                        .font(.system(size: 12 * s))
                        .padding(.horizontal, 8 * s)
                        .padding(.vertical, 4 * s)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6 * s))
                        .padding(8 * s)
                }
            }
    }
}

struct CardTextEditor: View {
    @Binding var text: String
    let size: CGFloat
    let color: Color
    /// Keys typed before this editor had focus.
    var takePending: () -> String = { "" }
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: size))
            .foregroundStyle(color)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .focused($focused)
            .onAppear {
                DispatchQueue.main.async {
                    focused = true
                    prepare(attempt: 0)
                }
            }
    }

    /// Once the text view has focus, put the cursor after any existing text
    /// (e.g. a thought's timestamp) and insert anything typed in the meantime.
    private func prepare(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.03)) {
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else {
                if attempt < 20 {
                    focused = true
                    prepare(attempt: attempt + 1)
                }
                return
            }
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            let pending = takePending()
            if !pending.isEmpty { tv.insertText(pending, replacementRange: tv.selectedRange()) }
        }
    }
}

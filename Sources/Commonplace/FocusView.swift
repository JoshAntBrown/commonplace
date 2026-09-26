import SwiftUI
import AppKit

/// One card, up close: the card large on the left; on the right what it
/// follows from, its thoughts (with a box for adding more) and its references.
/// Thoughts added here land on the board too, threaded from the card.
struct FocusView: View {
    let store: BoardStore
    let card: Card
    @Environment(\.theme) private var theme
    @State private var editing = false
    @FocusState private var bodyFocused: Bool
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView { subject.padding(28).frame(maxWidth: 980, alignment: .leading) }
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)

            Divider()
            sidebar
                .frame(width: 360)
                .background(theme.surface)
        }
        // Opaque, so the board behind never shows through.
        .background(theme.background)
        .onChange(of: store.focusSubmitRequest) { _, _ in
            if bodyFocused { editing = false }
        }
        // Don't let the thought box grab the cursor on its own: T puts you there,
        // and single-key shortcuts keep working until then.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .onChange(of: card.id) { _, _ in editing = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { store.exitFocus() } label: {
                Label("Board", systemImage: "chevron.left")
            }
            .help("Back to the board (Esc)")
            Image(systemName: card.kind.symbol).foregroundStyle(theme.muted)
            Text(card.headline).font(.headline).foregroundStyle(theme.text).lineLimit(1)
            Spacer()
            if card.kind == .video {
                Button(CardView.speedLabel(card.speed)) { store.stepSpeed(card.id, up: true) }
                    .monospacedDigit()
                    .help("Playback speed (< and >)")
            }
            if let url = card.url.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open in browser")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: The card, large

    @ViewBuilder private var subject: some View {
        switch card.kind {
        case .video: video
        case .image: image
        case .link: link
        case .place: place
        case .sticky, .note: text
        }
    }

    private var video: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if case .file(let url) = VideoSource.of(card) {
                    NativeVideoView(url: url, controller: store.video(card.id))
                } else if let source = VideoSource.of(card) {
                    WebVideoView(source: source, controller: store.video(card.id))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let summary = card.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 13)).foregroundStyle(theme.muted)
            }
        }
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = card.image, let img = ImageCache.shared.image(store.board.folder.appendingPathComponent(path)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !card.title.isEmpty { Text(card.title).font(.system(size: 14)).foregroundStyle(theme.muted) }
            sourceLink
        }
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let img = card.image, img.hasPrefix("http"), let url = URL(string: img) {
                AsyncImage(url: url) { $0.image?.resizable().aspectRatio(contentMode: .fit) }
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(card.title.isEmpty ? card.headline : card.title)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(theme.text)
            if let host = card.url.flatMap(URL.init(string:))?.host {
                Text(host).font(.system(size: 13)).foregroundStyle(theme.accent)
            }
            if let summary = card.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 15)).foregroundStyle(theme.muted)
            }
            if !card.body.isEmpty || editing { Divider(); bodyText }
        }
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title.isEmpty ? "Place" : card.title)
                .font(.system(size: 24, weight: .semibold)).underline().foregroundStyle(theme.text)
            ForEach(Place.affordances(card.body), id: \.self) { item in
                Text(item).font(.system(size: 16)).foregroundStyle(theme.text)
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !card.title.isEmpty {
                Text(card.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(theme.text)
            }
            bodyText
        }
    }

    /// The card's text at reading size; double-click to edit in place.
    @ViewBuilder private var bodyText: some View {
        if editing {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: Binding(get: { store.card(card.id)?.body ?? "" },
                                         set: { v in store.editText(card.id) { $0.body = v } }))
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .focused($bodyFocused)
                    .onAppear { DispatchQueue.main.async { bodyFocused = true } }
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                Text("Return to finish · ⇧Return for a new line").font(.caption).foregroundStyle(theme.muted)
            }
        } else {
            MarkdownText(text: card.body.isEmpty ? "Double-click to write" : card.body, size: 16,
                         color: card.body.isEmpty ? theme.muted : theme.text, accent: theme.accent,
                         onSeek: store.videoID(for: card.id).map { video in { store.video(video).seek($0) } })
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = true }
        }
    }

    @ViewBuilder private var sourceLink: some View {
        if let source = card.source.flatMap(URL.init(string:)), let host = source.host {
            Button { NSWorkspace.shared.open(source) } label: { Label(host, systemImage: "arrow.up.right") }
                .buttonStyle(.link)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        GeometryReader { viewport in ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let parentID = card.parent, let parent = store.card(parentID) {
                        section("Follows from") { row(parent, detail: nil) }
                    }
                    section("Thoughts") {
                        let thoughts = store.orderedThoughts(of: card.id)
                        if thoughts.isEmpty {
                            Text(card.kind == .video ? "Press T to add a thought at the current time."
                                                     : "Press T to add a thought.")
                                .font(.system(size: 12)).foregroundStyle(theme.muted)
                        }
                        ForEach(thoughts) { thought in
                            thoughtRow(thought)
                                // Zero-height markers at the row's edges to scroll to.
                                .overlay(alignment: .top) {
                                    Color.clear.frame(height: 0).id(Self.edge(thought.id, top: true))
                                }
                                .overlay(alignment: .bottom) {
                                    Color.clear.frame(height: 0).id(Self.edge(thought.id, top: false))
                                }
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: RowFrames.self,
                                                           value: [thought.id: g.frame(in: .named(Self.space))])
                                })
                        }
                    }
                    let refs = store.references(of: card.id)
                    if !refs.isEmpty {
                        section("References") {
                            ForEach(refs) { ref in
                                if let other = store.card(ref.other) {
                                    row(other, detail: (ref.outgoing ? "→ " : "← ") + (ref.label.isEmpty
                                        ? (ref.outgoing ? "refers to" : "referred to by") : ref.label))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
            // Scroll padding: keep the selected thought at least `margin` inside the
            // visible area — new ones from T, j/k/arrows, and as an edit grows.
            .onChange(of: store.focusSelectedThought) { _, id in
                guard let id else { return }
                reveal(id, proxy: proxy, height: viewport.size.height, animated: true)
            }
            .onChange(of: store.focusGrowth) { _, _ in
                guard let id = store.focusSelectedThought else { return }
                reveal(id, proxy: proxy, height: viewport.size.height, animated: false)
            }
        } }
    }

    private static let space = "thoughts"
    private static let scrollMargin: CGFloat = 72

    private static func edge(_ id: UUID, top: Bool) -> String { (top ? "top-" : "bottom-") + id.uuidString }

    /// Scrolls only if the thought is closer than `scrollMargin` to an edge,
    /// and then only far enough to restore the margin. Waits a beat for
    /// layout, so new and growing rows are measured at their real size.
    private func reveal(_ id: UUID, proxy: ScrollViewProxy, height: CGFloat, animated: Bool) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard height > 0, let frame = rowFrames[id] else { return }
                let m = min(Self.scrollMargin, height / 3)
                let target: (String, UnitPoint)?
                if frame.maxY > height - m {
                    target = (Self.edge(id, top: false), UnitPoint(x: 0.5, y: (height - m) / height))
                } else if frame.minY < m {
                    target = (Self.edge(id, top: true), UnitPoint(x: 0.5, y: m / height))
                } else {
                    target = nil
                }
                guard let (marker, anchor) = target else { return }
                if animated {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(marker, anchor: anchor) }
                } else {
                    proxy.scrollTo(marker, anchor: anchor)
                }
            }
        }
    }

    private struct RowFrames: PreferenceKey {
        static let defaultValue: [UUID: CGRect] = [:]
        static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.muted)
            content()
        }
    }

    /// A card in the sidebar: choosing it focuses it instead.
    private func row(_ other: Card, detail: String?) -> some View {
        Button { store.focus(other.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: other.kind.symbol).font(.system(size: 11)).foregroundStyle(theme.muted).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(theme.muted) }
                    Text(other.headline).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(theme.muted)
            }
            .padding(8)
            .background(theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func thoughtRow(_ thought: Card) -> some View {
        FocusThoughtRow(store: store, thought: thought, videoID: card.kind == .video ? card.id : nil)
    }
}

/// A thought in the focus view's list, behaving like a card on the board:
/// click selects, double-click (or Return) edits, Delete removes. While
/// editing, Return finishes and ⇧Return adds a line. A timestamp still seeks
/// the video, and the arrow focuses the thought itself.
private struct FocusThoughtRow: View {
    let store: BoardStore
    let thought: Card
    let videoID: UUID?
    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var selected: Bool { store.focusSelectedThought == thought.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if editing {
                TextField("Thought", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .focused($focused)
                    .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
                    .onChange(of: store.focusSubmitRequest) { _, _ in if focused { save() } }
                    .onChange(of: draft) { _, _ in store.focusGrowth += 1 }
            } else {
                MarkdownText(text: thought.body.isEmpty ? thought.headline : thought.body, size: 13,
                             color: theme.text, accent: theme.accent,
                             onSeek: videoID.map { id in { store.video(id).seek($0) } })
            }
            Button { store.focus(thought.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(theme.muted)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Focus this thought")
        }
        .padding(10)
        .background(theme.color(thought.color == .none ? .yellow : thought.color).opacity(editing ? 0.26 : 0.16),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(theme.accent, lineWidth: selected || editing ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEditing() }
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
            store.focusSelectedThought = thought.id
        }
        .contextMenu {
            Button("Edit") { beginEditing() }
            Button("Focus") { store.focus(thought.id) }
            Divider()
            Button("Delete", role: .destructive) {
                store.focusSelectedThought = thought.id
                store.deleteFocusSelection()
            }
        }
        .onChange(of: store.focusEditRequest) { _, id in
            if id == thought.id { store.focusEditRequest = nil; beginEditing() }
        }
        // A thought just made with T asks to be edited before its row exists.
        .onAppear {
            if store.focusEditRequest == thought.id { store.focusEditRequest = nil; beginEditing() }
        }
    }

    private func beginEditing() {
        store.focusSelectedThought = thought.id
        draft = thought.body
        editing = true
        DispatchQueue.main.async {
            focused = true
            // Type after any existing text (e.g. a timestamp), not over it.
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    private func save() {
        guard editing else { return }
        editing = false
        if draft != thought.body { store.editText(thought.id) { $0.body = draft } }
    }
}

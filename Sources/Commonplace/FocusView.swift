import SwiftUI
import AppKit

/// One card, up close: the card large on the left; on the right what it
/// follows from, its thoughts (with a box for adding more) and its references.
/// Thoughts added here land on the board too, threaded from the card.
struct FocusView: View {
    let store: BoardStore
    let card: Card
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var composerFocused: Bool

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
        .onChange(of: store.focusComposerRequest) { _, _ in composerFocused = true }
        // Don't let the thought box grab the cursor on its own: T puts you there,
        // and single-key shortcuts keep working until then.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .onChange(of: card.id) { _, _ in editing = false; draft = "" }
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
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                Button("Done") { editing = false }.keyboardShortcut(.return, modifiers: .command)
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let parentID = card.parent, let parent = store.card(parentID) {
                        section("Follows from") { row(parent, detail: nil) }
                    }
                    section("Thoughts") {
                        let thoughts = store.orderedThoughts(of: card.id)
                        if thoughts.isEmpty {
                            Text(card.kind == .video ? "Add a thought as you watch; it gets the current time."
                                                     : "Nothing yet.")
                                .font(.system(size: 12)).foregroundStyle(theme.muted)
                        }
                        ForEach(thoughts) { thought in thoughtRow(thought) }
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
            Divider()
            composer
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

    /// A thought, in full: timestamps seek the video; the arrow focuses it.
    private func thoughtRow(_ thought: Card) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MarkdownText(text: thought.body.isEmpty ? thought.headline : thought.body, size: 13,
                         color: theme.text, accent: theme.accent,
                         onSeek: card.kind == .video ? { store.video(card.id).seek($0) } : nil)
            Button { store.focus(thought.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(theme.muted)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Focus this thought")
        }
        .padding(10)
        .background(theme.color(thought.color == .none ? .yellow : thought.color).opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(card.kind == .video ? "Add a thought at the current time…" : "Add a thought…",
                      text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($composerFocused)
                .onSubmit {
                    store.addFocusThought(draft)
                    draft = ""
                    composerFocused = true
                }
            Text("T").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.border))
        }
        .padding(14)
    }
}

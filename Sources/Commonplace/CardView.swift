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

    private var s: CGFloat { store.scale }
    private var isSelected: Bool { store.selection.contains(card.id) }
    private var isEditing: Bool { store.editing == card.id }
    private var radius: CGFloat { 10 * s }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill)
            .overlay(alignment: .top) {
                if card.kind == .note, card.color != .none {
                    theme.color(card.color).frame(height: 4 * s)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : theme.border.opacity(card.kind == .sticky ? 0 : 1),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 10 * s, y: 3 * s)
            .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle } }
            .contentShape(Rectangle())
            .gesture(moveGesture, including: isEditing ? .subviews : .all)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if !isEditing { store.beginEditing(card.id) }
            })
            // GestureState resets even when a gesture is cancelled.
            .onChange(of: dragging) { _, active in if !active { store.endDrag() } }
            .onChange(of: resizing) { _, active in if !active { store.endResize() } }
            .onChange(of: isEditing) { _, _ in if card.kind == .place { store.fitPlace(card.id) } }
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
        HStack(spacing: 6 * s) {
            Image(systemName: card.kind.symbol)
            Text(card.title.isEmpty ? card.kind.label : card.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(theme.text)
            Spacer(minLength: 4 * s)
            trailing()
        }
        .font(.system(size: 11.5 * s))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 10 * s)
        .frame(height: 30 * s)
        .frame(maxWidth: .infinity)
        .background(card.color == .none ? theme.raised : theme.color(card.color).opacity(0.35))
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
                set: { value in store.update(card.id) { $0.body = value } })
    }

    private var titleBinding: Binding<String> {
        Binding(get: { store.card(card.id)?.title ?? "" },
                set: { value in store.update(card.id) { $0.title = value } })
    }

    private func bodyEditor(size: CGFloat) -> some View {
        CardTextEditor(text: bodyBinding, size: size * s, color: ink)
    }

    private func markdown(_ size: CGFloat, placeholder: String? = nil) -> some View {
        let empty = card.body.isEmpty
        return MarkdownText(
            text: empty ? (placeholder ?? "") : card.body,
            size: size * s,
            color: empty ? (card.kind == .sticky ? ink.opacity(0.5) : theme.muted) : ink,
            accent: card.kind == .sticky ? ink : theme.accent,
            onSeek: card.kind == .video ? { store.video(card.id).seek($0) } : nil)
    }

    // MARK: Kinds

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .sticky: sticky
        case .note: note
        case .link: link
        case .video: video
        case .image: image
        case .place: place
        }
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
                    .font(.system(size: 18 * s, weight: .semibold))
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
                Button { store.addTimestamp(card.id) } label: {
                    HStack(spacing: 3 * s) {
                        Image(systemName: "plus")
                        Text("Moment")
                    }
                }
                .buttonStyle(.plain)
                .help("Note the current moment (T)")
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
            .frame(height: card.frame.width * s * 9 / 16)
            .onAppear { store.resolveMedia(card.id) }
            if isEditing {
                notes.padding(12 * s)
            } else {
                ScrollView { notes.padding(12 * s) }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if isEditing {
            bodyEditor(size: 13.5)
        } else if !card.body.isEmpty {
            markdown(13.5)
        } else if isSelected {
            Text(card.kind == .video ? "Press T to note the current moment" : "Double-click to add notes")
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
                    .font(.system(size: 16 * s, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(height: Place.titleHeight * s)
                CardTextEditor(text: bodyBinding, size: 13.5 * s, color: theme.text)
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
                                .frame(width: 10 * s, height: 10 * s)
                                .padding(4 * s)
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
                            .font(.system(size: 11 * s))
                            .padding(.horizontal, 7 * s)
                            .padding(.vertical, 3 * s)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8 * s)
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
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: size))
            .foregroundStyle(color)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

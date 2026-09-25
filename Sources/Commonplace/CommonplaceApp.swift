import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CommonplaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = Library()
    @State private var browser = BrowserModel()
    @AppStorage("theme") private var themeID = Theme.all[0].id
    @AppStorage("board") private var boardName = ""

    private var theme: Theme { Theme.named(themeID) }

    var body: some Scene {
        Window("Commonplace", id: "main") {
            ContentView(library: library, browser: browser)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.isDark ? .dark : .light)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Board") { boardName = library.createBoard() }
                    .keyboardShortcut("n")
                Button("Show Library in Finder") { NSWorkspace.shared.open(library.root) }
            }
            CommandMenu("Theme") {
                Picker("Theme", selection: $themeID) {
                    ForEach(Theme.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Next Theme") {
                    let i = Theme.all.firstIndex { $0.id == themeID } ?? 0
                    themeID = Theme.all[(i + 1) % Theme.all.count].id
                }
                .keyboardShortcut(.space, modifiers: [.control, .command, .shift])
            }
        }
    }
}

struct ContentView: View {
    let library: Library
    let browser: BrowserModel
    @AppStorage("showBrowser") private var showBrowser = false
    @AppStorage("board") private var boardName = ""
    @State private var store: BoardStore?
    @State private var renameTarget: String?
    @State private var renameText = ""
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Boards") {
                    ForEach(library.boards, id: \.self) { name in
                        Label(name, systemImage: "square.on.square.dashed")
                            .tag(name)
                            .contextMenu {
                                Button("Rename…") {
                                    renameText = name
                                    renameTarget = name
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: name)])
                                }
                                Divider()
                                Button("Move to Trash", role: .destructive) { delete(name) }
                            }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // The sidebar panel runs up behind the traffic lights; fill all of it.
            .background { theme.surface.ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 170, ideal: 210)
            .toolbar {
                ToolbarItem {
                    Button { boardName = library.createBoard() } label: {
                        Label("New Board", systemImage: "plus")
                    }
                    .help("New board (⌘N)")
                }
            }
        } detail: {
            HSplitView {
                if let store {
                    CanvasView(store: store).id(ObjectIdentifier(store))
                        .frame(minWidth: 360)
                } else {
                    theme.background
                }
                if showBrowser {
                    BrowserPanel(model: browser)
                        .frame(minWidth: 340, idealWidth: 480, maxWidth: 1000)
                }
            }
            .toolbarBackground(theme.background, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .background(WindowTheme(theme: theme))
        .onAppear(perform: open)
        .onChange(of: boardName) { _, _ in open() }
        .alert("Rename board", isPresented: Binding(get: { renameTarget != nil },
                                                   set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename", action: commitRename)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { boardName.isEmpty ? nil : boardName },
                set: { if let name = $0 { boardName = name } })
    }

    private func open() {
        if !library.boards.contains(boardName) {
            boardName = library.boards.first ?? library.createBoard()
        }
        guard store?.board.name != boardName else { return }
        store?.close()
        let next = BoardStore(library: library, name: boardName)
        store = next
        browser.onClip = { [weak next] clip in next?.addClip(clip) }
    }

    private func commitRename() {
        guard let old = renameTarget else { return }
        renameTarget = nil
        let isCurrent = old == boardName
        if isCurrent {
            store?.close()
            store = nil
        }
        if let new = library.rename(old, to: renameText), isCurrent {
            boardName = new
        } else if isCurrent {
            open()
        }
    }

    private func delete(_ name: String) {
        if name == boardName {
            store?.close()
            store = nil
        }
        library.delete(name)
        if name == boardName || !library.boards.contains(boardName) {
            boardName = library.boards.first ?? library.createBoard()
        }
        open()
    }
}

/// Paints the window itself (behind the title bar and sidebar) with the theme,
/// so the chrome doesn't stay system grey.
private struct WindowTheme: NSViewRepresentable {
    let theme: Theme

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let color = NSColor(theme.background)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = color
            window.titlebarAppearsTransparent = true
        }
    }
}

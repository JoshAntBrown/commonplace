import SwiftUI
import AppKit
import SwiftTerm

/// Everything that lets agents work with Commonplace: the MCP server, the
/// file watcher, the skill, and the terminal panel for running agent tools.
final class Agents {
    let library: Library
    let server: MCPServer
    let watcher: FileWatcher
    let terminal = TerminalModel()
    private var started = false

    init(library: Library) {
        self.library = library
        server = MCPServer(library: library)
        watcher = FileWatcher(library: library)
    }

    func start() {
        guard !started else { return }
        started = true
        server.start()
        watcher.start()
        writeWorkspaceConfig()
    }

    /// The skill as shipped inside the app bundle.
    var skill: String? {
        Bundle.main.url(forResource: "SKILL", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Makes `claude` started in ~/Commonplace (as the terminal panel does)
    /// find the server and the skill with no setup: Claude Code reads a
    /// project's `.mcp.json` and `.claude/skills/`.
    private func writeWorkspaceConfig() {
        let fm = FileManager.default
        let config: [String: Any] = ["mcpServers": ["commonplace": [
            "type": "http", "url": server.url, "headers": ["Authorization": "Bearer \(server.token)"],
        ]]]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            let file = library.root.appendingPathComponent(".mcp.json")
            fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        if let skill {
            let dir = library.root.appendingPathComponent(".claude/skills/commonplace", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? skill.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Menu actions

    func copySetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.claudeCodeCommand + " --scope user", forType: .string)
    }

    /// Installs the skill for Claude Code everywhere, not just in ~/Commonplace.
    func installSkill() {
        let alert = NSAlert()
        if let skill {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/skills/commonplace", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try skill.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                alert.messageText = "Skill installed"
                alert.informativeText = "Claude Code will use the Commonplace skill in every project (~/.claude/skills/commonplace)."
            } catch {
                alert.messageText = "Couldn't install the skill"
                alert.informativeText = error.localizedDescription
            }
        } else {
            alert.messageText = "Skill not found in the app bundle"
            alert.informativeText = "Build the app with scripts/build-app.sh."
        }
        alert.runModal()
    }
}

/// A shell in the app, for running agent tools like `claude` beside the board.
/// It starts in ~/Commonplace, where the MCP config and skill are picked up.
final class TerminalModel: NSObject, LocalProcessTerminalViewDelegate {
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
    private var running = false

    override init() {
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func start(in directory: URL, server: MCPServer) {
        guard !running else { return }
        running = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["COMMONPLACE_MCP_URL"] = server.url
        env["COMMONPLACE_MCP_TOKEN"] = server.token
        view.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory.path)
    }

    func apply(_ theme: Theme) {
        view.nativeBackgroundColor = NSColor(theme.background)
        view.nativeForegroundColor = NSColor(theme.text)
        view.caretColor = NSColor(theme.accent)
        view.selectedTextBackgroundColor = NSColor(theme.accent).withAlphaComponent(0.35)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// The shell exited; start a fresh one next time the panel is shown.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        running = false
    }
}

private struct TerminalHost: NSViewRepresentable {
    let model: TerminalModel
    func makeNSView(context: Context) -> LocalProcessTerminalView { model.view }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}

struct TerminalPanel: View {
    let agents: Agents
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("Terminal").fontWeight(.medium)
                Spacer()
                Text("run `claude` to work on your boards")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.surface)
            Divider()
            TerminalHost(model: agents.terminal)
                .padding(6)
                .background(theme.background)
        }
        .onAppear {
            agents.terminal.apply(theme)
            agents.terminal.start(in: agents.library.root, server: agents.server)
            DispatchQueue.main.async { agents.terminal.view.window?.makeFirstResponder(agents.terminal.view) }
        }
        .onChange(of: theme) { _, theme in agents.terminal.apply(theme) }
    }
}

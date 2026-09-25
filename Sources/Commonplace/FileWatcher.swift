import Foundation
import CoreServices

/// Watches the library folder so edits made outside the app (another editor,
/// a script, git) show up on the canvas. The app's own saves are ignored.
final class FileWatcher {
    private let library: Library
    private var stream: FSEventStreamRef?

    init(library: Library) {
        self.library = library
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.changed(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [library.root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func changed(_ paths: [String]) {
        let root = library.root.resolvingSymlinksInPath().path
        var boards = Set<String>()
        var structural = false
        for path in paths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root) else { continue }
            let parts = resolved.dropFirst(root.count).split(separator: "/").map(String.init)
            guard let board = parts.first, !board.hasPrefix(".") else { continue }
            if parts.count == 1 { structural = true }
            boards.insert(board)
        }
        if structural { library.refresh() }
        for name in boards {
            guard let store = library.liveStore(name) else { continue }
            // Our own saves arrive here too; skip anything just after one.
            guard Date().timeIntervalSince(store.lastSaved) > 2 else { continue }
            store.reloadFromDisk()
        }
    }
}

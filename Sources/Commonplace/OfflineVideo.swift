import Foundation

/// Saving a video card's video into the board folder, so the board works
/// offline and the video plays in the standard player. X posts are plain MP4
/// files and download directly; YouTube, Vimeo and others need yt-dlp, and
/// the option only appears when it's installed.
enum OfflineVideo {
    /// Folders GUI apps don't get on their PATH, where Homebrew and pipx put tools.
    private static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] + env
    }()

    private static func tool(_ name: String) -> URL? {
        searchPaths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let ytDlp = tool("yt-dlp")

    /// Browsers yt-dlp can borrow a sign-in from, when a site (YouTube) refuses
    /// anonymous downloads. Off unless chosen in Settings.
    static let browsers = ["brave", "chrome", "chromium", "edge", "firefox", "opera", "safari", "vivaldi"]
    static let browserKey = "offlineSignInBrowser"
    static var signInBrowser: String? {
        let value = UserDefaults.standard.string(forKey: browserKey) ?? ""
        return browsers.contains(value) ? value : nil
    }
    /// Lets yt-dlp join separate video and audio streams (needed above ~360p).
    static let ffmpeg = tool("ffmpeg")

    /// Whether this card's video can be saved: a direct file always, anything
    /// else only with yt-dlp.
    static func canSave(_ card: Card) -> Bool {
        guard card.kind == .video, card.offline == nil else { return false }
        if card.media != nil { return true }
        return ytDlp != nil && card.url != nil
    }

    final class Job {
        var cancel: () -> Void = {}
    }

    /// Downloads into `folder`, reporting progress 0…1, then the saved file's
    /// name (or nil on failure or cancel).
    static func save(_ card: Card, into folder: URL, progress: @escaping (Double) -> Void,
                     done: @escaping (Result<URL, Error>) -> Void) -> Job {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = card.id.uuidString.lowercased()
        if let media = card.media.flatMap(URL.init(string:)) {
            return direct(media, to: folder.appendingPathComponent(name + ".mp4"), progress: progress, done: done)
        }
        guard let tool = ytDlp, let page = card.url else {
            done(.failure(Failure("yt-dlp isn't installed.")))
            return Job()
        }
        return ytdlp(tool, page: page, folder: folder, name: name, progress: progress, done: done)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func direct(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void,
                               done: @escaping (Result<URL, Error>) -> Void) -> Job {
        let job = Job()
        let task = URLSession.shared.downloadTask(with: url) { temp, _, error in
            DispatchQueue.main.async {
                guard let temp else { return done(.failure(error ?? Failure("Download failed."))) }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    done(.success(destination))
                } catch {
                    done(.failure(error))
                }
            }
        }
        let observation = task.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { progress(p.fractionCompleted) }
        }
        job.cancel = { observation.invalidate(); task.cancel() }
        task.resume()
        return job
    }

    private static func ytdlp(_ tool: URL, page: String, folder: URL, name: String,
                              progress: @escaping (Double) -> Void,
                              done: @escaping (Result<URL, Error>) -> Void) -> Job {
        let process = Process()
        process.executableURL = tool
        var args = [
            page, "--no-playlist", "--newline", "--progress", "--no-simulate",
            "-o", folder.appendingPathComponent(name + ".%(ext)s").path,
            "--progress-template", "download:%(progress._percent_str)s",
            "--print", "after_move:filepath",
        ]
        if let browser = signInBrowser { args += ["--cookies-from-browser", browser] }
        if let ffmpeg {
            // Up to 1080p, in codecs the macOS player plays, joined into one MP4.
            args += ["-S", "res:1080,vcodec:h264,acodec:m4a", "--merge-output-format", "mp4",
                     "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        } else {
            args += ["-f", "b[ext=mp4]/b"]
        }
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":")
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var savedPath: String?
        var errorText = ""
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            buffer += chunk
            while let newline = buffer.firstIndex(of: "\n") {
                let line = buffer[..<newline].trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(...newline)
                if line.hasSuffix("%"), let value = Double(line.dropLast().trimmingCharacters(in: .whitespaces)) {
                    DispatchQueue.main.async { progress(value / 100) }
                } else if line.hasPrefix("/") {
                    savedPath = line
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8) { errorText += text }
        }
        let job = Job()
        var cancelled = false
        job.cancel = { cancelled = true; process.terminate() }
        process.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if p.terminationStatus == 0, let path = savedPath {
                    done(.success(URL(fileURLWithPath: path)))
                } else if cancelled {
                    done(.failure(Failure("Cancelled.")))
                } else {
                    var reason = errorText.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
                        ?? "yt-dlp couldn't save this video."
                    // Refused downloads are usually fixed by a sign-in.
                    if signInBrowser == nil, reason.contains("403") || reason.lowercased().contains("sign in") {
                        reason += "\n\nThe site refused an anonymous download. In Settings (⌘,) → Offline videos, "
                            + "choose a browser you're signed in with to let yt-dlp use that sign-in."
                    }
                    done(.failure(Failure(reason)))
                }
            }
        }
        do { try process.run() } catch { done(.failure(error)) }
        return job
    }
}

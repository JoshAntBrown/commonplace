import SwiftUI
import WebKit
import AVKit
import JavaScriptCore

/// Sites serve full pages (and playable video) to Safari.
let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

enum VideoSource: Equatable {
    case youtube(id: String, start: Int)
    /// A page with a `<video>` element we can drive directly (X, Vimeo…).
    case page(URL)
    /// A video file, played natively.
    case file(URL)

    /// Cards with a resolved media file play it natively; otherwise fall back to the page.
    static func of(_ card: Card) -> VideoSource? {
        if let media = card.media, let url = URL(string: media) { return .file(url) }
        return card.url.flatMap(URL.init(string:)).flatMap(detect)
    }

    static func isXPost(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return ["x.com", "twitter.com", "www.x.com", "www.twitter.com", "mobile.twitter.com", "mobile.x.com"].contains(host)
            && url.pathComponents.contains("status")
    }

    static func detect(_ url: URL) -> VideoSource? {
        var host = (url.host ?? "").lowercased()
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let t = query.first { $0.name == "t" || $0.name == "start" }?.value
        let start = t.flatMap { Int($0.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) } ?? 0

        if host == "youtu.be", let id = parts.first { return .youtube(id: id, start: start) }
        if host == "youtube.com" || host == "music.youtube.com" {
            if let v = query.first(where: { $0.name == "v" })?.value { return .youtube(id: v, start: start) }
            if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) { return .youtube(id: parts[1], start: start) }
        }
        if (host == "x.com" || host == "twitter.com"), parts.contains("status") { return .page(url) }
        if host == "vimeo.com" || host == "player.vimeo.com" { return .page(url) }
        if ["mp4", "m4v", "mov", "webm"].contains(url.pathExtension.lowercased()) { return .file(url) }
        return nil
    }
}

/// Lets a card read and set the playback position of its embedded video.
final class VideoController {
    weak var webView: WKWebView?
    private(set) var player: AVPlayer?

    func player(for url: URL) -> AVPlayer {
        if let player, (player.currentItem?.asset as? AVURLAsset)?.url == url { return player }
        let p = AVPlayer(url: url)
        player = p
        return p
    }

    func currentTime(_ done: @escaping (Double) -> Void) {
        if let player {
            let t = player.currentTime().seconds
            done(t.isFinite ? t : 0)
            return
        }
        guard let webView else { done(0); return }
        webView.evaluateJavaScript("window.cpTime ? cpTime() : 0") { result, _ in
            done((result as? NSNumber)?.doubleValue ?? 0)
        }
    }

    func seek(_ seconds: Double) {
        if let player {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            return
        }
        webView?.evaluateJavaScript("window.cpSeek && cpSeek(\(seconds)); 0", completionHandler: nil)
    }
}

struct WebVideoView: NSViewRepresentable {
    let source: VideoSource
    let controller: VideoController

    /// Fallback helpers for pages that play a plain `<video>` element.
    private static let helperJS = """
    if (!window.cpTime) {
      window.cpTime = function () { var v = document.querySelector('video'); return v ? v.currentTime : 0; };
      window.cpSeek = function (s) { var v = document.querySelector('video'); if (v) { v.currentTime = s; v.play(); } };
    }
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(
            WKUserScript(source: Self.helperJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        controller.webView = webView

        switch source {
        case .youtube(let id, let start):
            webView.loadHTMLString(Self.youtubeHTML(id: id, start: start),
                                   baseURL: URL(string: "https://commonplace.local/"))
        case .page(let url), .file(let url):
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
    }

    private static func youtubeHTML(id: String, start: Int) -> String {
        let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('p', { videoId: '\(safeID)',
            playerVars: { playsinline: 1, rel: 0, start: \(start), origin: 'https://commonplace.local' } });
        }
        function cpTime() { return player && player.getCurrentTime ? player.getCurrentTime() : 0; }
        function cpSeek(s) { if (player && player.seekTo) { player.seekTo(s, true); player.playVideo(); } }
        </script></body></html>
        """
    }
}

struct NativeVideoView: NSViewRepresentable {
    let url: URL
    let controller: VideoController

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = controller.player(for: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let player = controller.player(for: url)
        if view.player !== player { view.player = player }
    }
}

/// Finds the MP4 behind an X post using the public embed ("syndication") API.
enum XVideo {
    struct Result {
        var media: String?
        var poster: String?
        var text: String?
    }

    static func resolve(_ url: URL) async -> Result? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "status"), i + 1 < parts.count else { return nil }
        let id = parts[i + 1].filter(\.isNumber)
        guard !id.isEmpty,
              let request = URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=\(token(id))"),
              let (data, response) = try? await URLSession.shared.data(from: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var result = Result(text: json["text"] as? String)
        let media = (json["mediaDetails"] as? [[String: Any]]) ?? []
        guard let video = media.first(where: { ["video", "animated_gif"].contains($0["type"] as? String) }) else {
            return result
        }
        result.poster = video["media_url_https"] as? String
        let variants = ((video["video_info"] as? [String: Any])?["variants"] as? [[String: Any]]) ?? []
        let mp4s = variants.compactMap { v -> (url: String, bitrate: Int, height: Int)? in
            guard v["content_type"] as? String == "video/mp4", let u = v["url"] as? String else { return nil }
            return (u, v["bitrate"] as? Int ?? 0, height(u))
        }
        // Best quality up to 1080p; 4K streams are heavy for a canvas card.
        let pick = mp4s.filter { $0.height <= 1080 }.max { $0.bitrate < $1.bitrate } ?? mp4s.max { $0.bitrate < $1.bitrate }
        result.media = pick?.url
        return result
    }

    private static func height(_ url: String) -> Int {
        guard let r = url.range(of: #"/(\d+)x(\d+)/"#, options: .regularExpression) else { return 0 }
        return Int(url[r].split(separator: "x").last?.filter(\.isNumber) ?? "") ?? 0
    }

    /// Same token X's embed script computes.
    private static func token(_ id: String) -> String {
        let js = "((Number('\(id)') / 1e15) * Math.PI).toString(36).replace(/(0+|\\.)/g, '')"
        return JSContext()?.evaluateScript(js)?.toString() ?? "a"
    }
}

// MARK: - Link previews

struct LinkMeta {
    var title: String?
    var summary: String?
    var image: String?
}

enum LinkMetadata {
    static func fetch(_ url: URL) async -> LinkMeta {
        let host = url.host?.lowercased() ?? ""
        if case .youtube = VideoSource.detect(url),
           let meta = await oembed("https://www.youtube.com/oembed?format=json&url=", url) {
            return meta
        }
        if host.hasSuffix("x.com") || host.hasSuffix("twitter.com"),
           let meta = await oembed("https://publish.twitter.com/oembed?omit_script=1&url=", url) {
            return meta
        }
        return await scrape(url)
    }

    private static func oembed(_ endpoint: String, _ url: URL) async -> LinkMeta? {
        guard let q = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let request = URL(string: endpoint + q),
              let result = try? await URLSession.shared.data(from: request),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else { return nil }
        let author = json["author_name"] as? String
        var meta = LinkMeta(title: json["title"] as? String, summary: author.map { "by \($0)" },
                            image: json["thumbnail_url"] as? String)
        // X returns the post as HTML rather than a title.
        if (meta.title ?? "").isEmpty, let html = json["html"] as? String {
            let body = firstGroup(#"<p[^>]*>(.*?)</p>"#, in: html) ?? html
            meta.title = author.map { "\($0) on X" }
            meta.summary = decode(body
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
        }
        return meta
    }

    private static func scrape(_ url: URL) async -> LinkMeta {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request) else { return LinkMeta() }
        let html = String(data: result.0, encoding: .utf8) ?? String(data: result.0, encoding: .isoLatin1) ?? ""
        let head = String(html.prefix(400_000))

        var tags: [String: String] = [:]
        for tag in matches(#"<meta\b[^>]*>"#, in: head) {
            guard let key = firstGroup(#"(?:property|name)\s*=\s*["']([^"']+)["']"#, in: tag)?.lowercased(),
                  let content = firstGroup(#"content\s*=\s*"([^"]*)""#, in: tag)
                    ?? firstGroup(#"content\s*=\s*'([^']*)'"#, in: tag) else { continue }
            if tags[key] == nil { tags[key] = decode(content) }
        }
        let title = tags["og:title"] ?? tags["twitter:title"]
            ?? firstGroup(#"<title[^>]*>([^<]*)</title>"#, in: head).map(decode)
        var image = tags["og:image"] ?? tags["twitter:image"]
        if let i = image { image = URL(string: i, relativeTo: url)?.absoluteString }
        return LinkMeta(title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary: tags["og:description"] ?? tags["twitter:description"] ?? tags["description"],
                        image: image)
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func decode(_ s: String) -> String {
        var r = s
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"),
                               ("&gt;", ">"), ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
                               ("&hellip;", "…"), ("&amp;", "&")] {
            r = r.replacingOccurrences(of: entity, with: char)
        }
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);") {
            for m in re.matches(in: r, range: NSRange(r.startIndex..., in: r)).reversed() {
                guard let whole = Range(m.range, in: r), let num = Range(m.range(at: 1), in: r),
                      let code = UInt32(r[num]), let scalar = Unicode.Scalar(code) else { continue }
                r.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return r
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

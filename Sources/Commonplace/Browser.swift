import SwiftUI
import WebKit

/// Something pulled off the web and onto the board.
enum BrowserClip {
    case page(URL, title: String)
    case link(URL)
    case image(URL, page: URL?, title: String)
    case quote(String, page: URL?, title: String)
}

/// The in-app browser beside the canvas. It outlives board switches, so its
/// history and sign-ins persist while you move between boards.
@Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Mode: String, CaseIterable {
        case web = "Web"
        case images = "Images"
    }

    var address = ""
    var mode: Mode = .web
    var canGoBack = false
    var canGoForward = false
    var isLoading = false

    @ObservationIgnored let webView: ClipWebView
    @ObservationIgnored var onClip: ((BrowserClip) -> Void)? {
        didSet { webView.onClip = onClip }
    }
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastQuery: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        webView = ClipWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.canGoBack) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
            webView.observe(\.isLoading) { [weak self] wv, _ in self?.isLoading = wv.isLoading },
            webView.observe(\.url) { [weak self] wv, _ in self?.didNavigate(to: wv.url) },
        ]
        webView.load(URLRequest(url: URL(string: "https://duckduckgo.com/")!))
    }

    /// Loads a URL, or searches for anything that doesn't look like one.
    func go(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if let url = Self.url(from: s) {
            lastQuery = nil
            webView.load(URLRequest(url: url))
        } else {
            search(s)
        }
    }

    func search(_ query: String) {
        lastQuery = query
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        if mode == .images {
            c.queryItems! += [URLQueryItem(name: "iax", value: "images"), URLQueryItem(name: "ia", value: "images")]
        }
        webView.load(URLRequest(url: c.url!))
    }

    /// Re-runs the current search when switching between web and images.
    func modeChanged() {
        if let q = lastQuery { search(q) }
    }

    func clipPage() {
        guard let url = webView.url else { return }
        onClip?(.page(url, title: webView.title ?? ""))
    }

    func clipSelection() {
        webView.clipSelection()
    }

    private func didNavigate(to url: URL?) {
        guard let url else { return }
        // Show the query rather than the search URL.
        if url.host?.hasSuffix("duckduckgo.com") == true,
           let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
            let query = q.replacingOccurrences(of: "+", with: " ")
            lastQuery = query
            address = query
        } else {
            address = url.absoluteString
        }
    }

    private static func url(from s: String) -> URL? {
        guard !s.contains(where: \.isWhitespace) else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.contains("."), !s.hasSuffix("."), s.first?.isLetter == true || s.first?.isNumber == true {
            return URL(string: "https://" + s)
        }
        return nil
    }

    // Open target=_blank links in place rather than dropping them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
}

/// A web view whose right-click menu can send images, links, text and the
/// page itself to the board.
final class ClipWebView: WKWebView {
    var onClip: ((BrowserClip) -> Void)?
    private var menuPoint: CGPoint = .zero

    /// The page last clicked in the browser, so a drag onto the board can
    /// record where it came from.
    private static var lastPress: (page: URL, at: Date)?

    static func recentPage() -> URL? {
        guard let press = lastPress, Date().timeIntervalSince(press.at) < 30 else { return nil }
        return press.page
    }

    override func mouseDown(with event: NSEvent) {
        if let url { Self.lastPress = (url, Date()) }
        super.mouseDown(with: event)
    }

    static func isSearchEngine(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return host.contains("duckduckgo.com") || host.contains("google.") || host.contains("bing.com")
    }

    /// Where a clipped image came from: the page it was on, unless that page
    /// is a search results page, in which case the image's own address.
    static func source(page: URL?, image: URL?) -> URL? {
        if let page, !isSearchEngine(page) { return page }
        return image ?? page
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        menuPoint = p

        let items: [(String, Selector)] = [
            ("Add Image to Board", #selector(addImage)),
            ("Add Link to Board", #selector(addLink)),
            ("Add Selection to Board", #selector(addSelection)),
            ("Add Page to Board", #selector(addPage)),
        ]
        menu.insertItem(.separator(), at: 0)
        for (title, action) in items.reversed() {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
        }
    }

    private struct Target: Decodable {
        var image: String?
        var alt: String?
        var link: String?
        var selection: String?
        var title: String?
        var page: String?
    }

    /// Asks the page what's under the right-click point.
    private func inspect(_ done: @escaping (Target) -> Void) {
        let js = """
        (function (x, y) {
          var el = document.elementFromPoint(x, y);
          var img = el && el.closest ? el.closest('img') : null;
          if (!img && el && el.querySelector) { img = el.querySelector('img'); }
          var a = el && el.closest ? el.closest('a') : null;
          return JSON.stringify({
            image: img ? (img.currentSrc || img.src) : null,
            alt: img ? (img.alt || null) : null,
            link: a ? a.href : null,
            selection: String(window.getSelection() || ''),
            title: document.title,
            page: location.href
          });
        })(\(menuPoint.x), \(menuPoint.y))
        """
        evaluateJavaScript(js) { result, _ in
            guard let json = (result as? String)?.data(using: .utf8),
                  let target = try? JSONDecoder().decode(Target.self, from: json) else { NSSound.beep(); return }
            done(target)
        }
    }

    @objc private func addImage() {
        inspect { [weak self] t in
            guard let src = t.image.flatMap(URL.init(string:)) else { NSSound.beep(); return }
            let title = [t.alt, t.title].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            self?.onClip?(.image(Self.unwrap(src), page: t.page.flatMap(URL.init(string:)), title: title))
        }
    }

    @objc private func addLink() {
        inspect { [weak self] t in
            guard let link = t.link.flatMap(URL.init(string:)) else { NSSound.beep(); return }
            self?.onClip?(.link(Self.unwrap(link)))
        }
    }

    @objc private func addSelection() { clipSelection() }

    @objc private func addPage() {
        guard let url else { return }
        onClip?(.page(url, title: title ?? ""))
    }

    func clipSelection() {
        evaluateJavaScript("String(window.getSelection() || '')") { [weak self] result, _ in
            guard let self, let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { NSSound.beep(); return }
            self.onClip?(.quote(text, page: self.url, title: self.title ?? ""))
        }
    }

    /// Search engines proxy images and links; recover the original URL.
    static func unwrap(_ url: URL) -> URL {
        guard isSearchEngine(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { ["u", "uddg", "imgurl", "url"].contains($0.name) })?.value,
              let real = URL(string: value), real.scheme?.hasPrefix("http") == true else { return url }
        return real
    }
}

struct BrowserWebView: NSViewRepresentable {
    let model: BrowserModel
    func makeNSView(context: Context) -> ClipWebView { model.webView }
    func updateNSView(_ view: ClipWebView, context: Context) {}
}

struct BrowserPanel: View {
    @Bindable var model: BrowserModel
    @Environment(\.theme) private var theme
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                Button {
                    if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
                } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                TextField("Search or enter address", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { model.go(model.address) }
                Picker("", selection: $model.mode) {
                    ForEach(BrowserModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.mode) { _, _ in model.modeChanged() }
            }
            .buttonStyle(.borderless)
            .padding(8)

            Divider()
            BrowserWebView(model: model)
            Divider()

            HStack(spacing: 10) {
                Text("Drag onto the board, or right-click to add")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Clip Selection") { model.clipSelection() }
                    .help("Add the selected text as a quote")
                Button("Add Page") { model.clipPage() }
                    .help("Add this page as a link card")
            }
            .controlSize(.small)
            .padding(8)
        }
        .background(theme.surface)
        .onAppear { DispatchQueue.main.async { addressFocused = true } }
    }
}

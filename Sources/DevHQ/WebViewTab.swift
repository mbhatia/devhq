import Foundation
import WebKit

/// Normalizes web command and link targets into loadable URL strings: full
/// URLs pass through, anything else becomes a `~`-expanded, percent-encoded
/// `file://` URL, and an empty target falls back to the configured home URL.
enum WebTargetNormalizer {
    static let defaultTitle = "Web Preview"

    private static let schemeExpression = try? NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9+.-]*://"#
    )

    static func isURL(_ target: String) -> Bool {
        guard let schemeExpression else { return false }
        let range = NSRange(location: 0, length: (target as NSString).length)
        return schemeExpression.firstMatch(in: target, range: range) != nil
    }

    static func url(
        forTarget target: String,
        homeURL: String,
        baseDirectory: String? = nil
    ) -> String {
        guard !target.isEmpty else { return homeURL }
        if target == "about:blank" || isURL(target) { return target }
        return fileURLString(forPath: target, baseDirectory: baseDirectory)
    }

    static func fileURLString(forPath path: String, baseDirectory: String? = nil) -> String {
        var expanded = NSString(string: path).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            let base = baseDirectory ?? FileManager.default.currentDirectoryPath
            expanded = base + "/" + expanded
        }
        return "file://" + percentEncodedPath(expanded)
    }

    /// Percent-encodes everything outside the RFC 3986 unreserved set plus `/`.
    static func percentEncodedPath(_ path: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "abcdefghijklmnopqrstuvwxyz0123456789-._~/"
        )
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// A display title derived from the last URL path segment, used until the
    /// page reports its own title.
    static func title(forURL url: String, fallback: String = defaultTitle) -> String {
        guard !url.isEmpty, url != "about:blank" else { return fallback }
        let name = url.split(separator: "/").last.map(String.init) ?? url
        let readable = name.replacingOccurrences(of: "%20", with: " ")
        return readable.isEmpty ? fallback : readable
    }
}

/// One web preview tab: a WKWebView with its title synced from the page title
/// (falling back to the last URL path segment) and URL tracking.
@MainActor
final class WebViewTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    /// Marks the single tab per worktree that `devhq:open-webview` and
    /// terminal link routing navigate and reuse.
    let isShared: Bool
    @Published private(set) var title: String
    @Published private(set) var urlString: String

    private var loadedWebView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    init(
        target: String,
        homeURL: String,
        baseDirectory: String? = nil,
        isShared: Bool = false
    ) {
        let url = WebTargetNormalizer.url(
            forTarget: target,
            homeURL: homeURL,
            baseDirectory: baseDirectory
        )
        self.isShared = isShared
        self.urlString = url
        self.title = WebTargetNormalizer.title(forURL: url)
        super.init()
    }

    /// The tab's web view, created on first display so model and logic tests
    /// never instantiate WebKit.
    var webView: WKWebView {
        if let loadedWebView { return loadedWebView }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        loadedWebView = webView
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.syncTitle(from: webView) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.syncURL(from: webView) }
            }
        ]
        load(urlString, in: webView)
        return webView
    }

    var canGoBack: Bool { loadedWebView?.canGoBack ?? false }
    var canGoForward: Bool { loadedWebView?.canGoForward ?? false }

    func navigate(to target: String, homeURL: String, baseDirectory: String? = nil) {
        let url = WebTargetNormalizer.url(
            forTarget: target,
            homeURL: homeURL,
            baseDirectory: baseDirectory
        )
        urlString = url
        title = WebTargetNormalizer.title(forURL: url)
        if let loadedWebView { load(url, in: loadedWebView) }
    }

    func reload() { loadedWebView?.reload() }
    func goBack() { loadedWebView?.goBack() }
    func goForward() { loadedWebView?.goForward() }

    private func load(_ urlString: String, in webView: WKWebView) {
        guard let url = URL(string: urlString) else { return }
        if url.isFileURL {
            // A local preview can reference sibling assets anywhere on disk,
            // matching the v1 native browser.
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    private func syncTitle(from webView: WKWebView) {
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            title = pageTitle
        } else {
            title = WebTargetNormalizer.title(forURL: urlString)
        }
    }

    private func syncURL(from webView: WKWebView) {
        guard let url = webView.url else { return }
        urlString = url.absoluteString
        if (webView.title ?? "").isEmpty {
            title = WebTargetNormalizer.title(forURL: urlString)
        }
    }
}

import Cocoa
import WebKit
import os

/// Hosts the bundled three.js viewer page.
///
/// The page and its single classic script load from the appex bundle over
/// `file://`; the model bytes and the Draco/Basis decoders are fetched over
/// `glbview://` by `GLBSchemeHandler`. The model URL is injected as a
/// document-start user script, so the page knows what to load with no
/// native/web handshake and no query string on a file URL.
final class ViewerWebView: NSView {
    private static let messageHandler = "viewer"

    private let log = Logger(subsystem: GLBPreviewLog.subsystem, category: "Viewer")
    private let messageProxy = MessageProxy()

    private var webView: WKWebView!
    /// The model currently loaded, so switching files reloads but re-rendering
    /// the same one (SwiftUI may call through repeatedly) does not.
    private var currentModelURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewerWebView is created in code only")
    }

    private func setUp() {
        wantsLayer = true

        let configuration = WKWebViewConfiguration()
        // A sandboxed app extension has no writable WebKit data directory, and
        // with the default (persistent) store WebKit never manages to start its
        // WebContent process — the load silently never begins. Everything the
        // viewer needs is local, so nothing needs to persist.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(GLBSchemeHandler(), forURLScheme: GLBSchemeHandler.scheme)
        // The proxy breaks the retain cycle WebKit would otherwise create:
        // the content controller retains the handler, which would retain this view.
        messageProxy.target = self
        configuration.userContentController.add(messageProxy, name: Self.messageHandler)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        // Private but long-standing: keeps WebKit from painting white over the
        // Quick Look panel while the page loads.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.webView = webView
    }

    /// Points the already-created (and therefore already warming) web view at
    /// `fileURL` and starts the load. Returns once loading has been kicked off;
    /// the model continues to arrive asynchronously after that.
    func load(modelAt fileURL: URL) {
        guard currentModelURL != fileURL else { return }
        guard let dist = GLBSchemeHandler.viewerDistURL,
              let base = GLBSchemeHandler.viewerPageBaseURL else {
            log.error("Viewer bundle is missing from the appex resources")
            return
        }
        guard let html = try? String(contentsOf: dist.appendingPathComponent("index.html"), encoding: .utf8) else {
            log.error("Viewer page missing from \(dist.path, privacy: .public)")
            return
        }
        guard let modelURL = GLBSchemeHandler.modelURL(for: fileURL) else {
            log.error("Could not build a glbview URL for \(fileURL.lastPathComponent, privacy: .public)")
            return
        }

        // The page, its scripts, the decoders and the model all come from the
        // glbview:// scheme handler, so they share one origin. That matters for
        // more than tidiness: DRACOLoader and KTX2Loader build Web Workers from
        // blob: URLs, and on a file:// origin WebKit lets those workers be
        // constructed but never run them, so Draco decoding hangs forever with
        // no error raised anywhere.
        //
        // The URLs are injected as a document-start user script: WebKit injects
        // those itself, so the page's strict CSP does not block them.
        let script = """
            window.__GLB_MODEL_URL = \(Self.javaScriptString(modelURL.absoluteString));
            window.__GLB_DECODER_ROOT = \(Self.javaScriptString(GLBSchemeHandler.decoderRoot));
            """
        // Replace rather than append: in the app, opening a second model must not
        // leave the previous load's script registered alongside this one.
        let userContent = webView.configuration.userContentController
        userContent.removeAllUserScripts()
        userContent.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        currentModelURL = fileURL
        pageReported = false
        log.info("Loading \(fileURL.lastPathComponent, privacy: .public)")
        webView.loadHTMLString(html, baseURL: base)

        // A Quick Look extension is out of process with no console, so when a
        // preview comes up blank there is otherwise nothing to go on. This
        // reports what WebKit thinks happened shortly after the load starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.pageReported else { return }
            let webView = self.webView!
            self.log.error("""
                no page signal after 4s — url=\(webView.url?.absoluteString ?? "nil", privacy: .public) \
                loading=\(webView.isLoading) progress=\(webView.estimatedProgress) \
                title=\(webView.title ?? "nil", privacy: .public) inWindow=\(webView.window != nil)
                """)
        }
    }

    /// Set once the page reports anything, so the diagnostic above stays quiet.
    private var pageReported = false

    /// JSON-encoding is the safe way to get an arbitrary path into JS source.
    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())   // drop the array brackets
    }

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        pageReported = true
        switch body["type"] as? String {
        case "ready":
            log.info("Viewer page ready")
        case "loaded":
            log.info("Model loaded — \(Self.describe(body), privacy: .public)")
        case "error":
            log.error("Viewer error — \(body["message"] as? String ?? "unknown", privacy: .public)")
        case "rendered":
            log.info("First frame drawn — \(body["message"] as? String ?? "unknown", privacy: .public)")
        default:
            log.debug("Viewer message — \(Self.describe(body), privacy: .public)")
        }
    }

    private static func describe(_ body: [String: Any]) -> String {
        body.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

// MARK: - WebKit delegates

private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: ViewerWebView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message)
    }
}

extension ViewerWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.info("Navigation finished — \(webView.url?.absoluteString ?? "nil", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("Page load failed — \(error.localizedDescription, privacy: .public)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        log.error("Page load failed early — \(error.localizedDescription, privacy: .public)")
    }
}

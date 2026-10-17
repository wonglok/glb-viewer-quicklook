import Cocoa
import Quartz
import os

/// Quick Look preview extension entry point. Finder's Space bar instantiates
/// this via `NSExtensionPrincipalClass`, hands it a file, and hosts the view
/// returned here.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let log = Logger(subsystem: GLBPreviewLog.subsystem, category: "Preview")
    private var viewer: ViewerWebView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true

        // Build the web view eagerly. Creating it starts the WebContent process,
        // and that warm-up is then free to overlap Quick Look's presentation.
        let viewer = ViewerWebView(frame: .zero)
        viewer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewer)
        NSLayoutConstraint.activate([
            viewer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewer.topAnchor.constraint(equalTo: view.topAnchor),
            viewer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.viewer = viewer
    }

    /// View-based preview — `QLIsDataBasedPreview` is false in Info.plist.
    /// We return as soon as loading has started; Quick Look shows the view
    /// while the model continues to stream in behind it.
    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        log.info("Preparing preview for \(url.path, privacy: .public)")
        guard let viewer else {
            completionHandler(NSError(
                domain: GLBPreviewLog.subsystem, code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Preview view was not created"]))
            return
        }
        viewer.load(modelAt: url)
        completionHandler(nil)
    }
}

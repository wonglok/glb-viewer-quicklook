import SwiftUI

/// Hosts the viewer in the app window.
///
/// This is the same `ViewerWebView` the Quick Look extension uses — the file is
/// compiled into both targets — so the two render identically by construction.
struct GLBViewerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> ViewerWebView {
        ViewerWebView(frame: .zero)
    }

    func updateNSView(_ view: ViewerWebView, context: Context) {
        // ViewerWebView ignores a repeat of the model it already has, so this is
        // safe to call on every SwiftUI update pass.
        view.load(modelAt: url)
    }
}

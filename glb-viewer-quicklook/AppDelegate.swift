import Cocoa

/// Catches the ways Finder hands us a file: a double-click, "Open With", or a
/// drop onto the Dock icon. All of them arrive here, and all of them can arrive
/// before the window exists — which is why the model is a shared singleton.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = urls.first(where: { $0.pathExtension.lowercased() == "glb" }) else { return }
        Task { @MainActor in
            ViewerModel.shared.open(model)
        }
    }

    /// A viewer has nothing useful to do with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import SwiftUI

@main struct MyApp: App {
    // Finder hands the file to the delegate before the scene exists, so the
    // delegate owns the "what is open" decision and the model is shared.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ViewerModel.shared)
        }
    }
}

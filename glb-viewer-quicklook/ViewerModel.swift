import Foundation
import Combine          // @Published; the target enables member import visibility
import CoreServices
import os

/// What the window is currently showing, shared by the SwiftUI view and the
/// app delegate. A Finder double-click arrives at the delegate before any window
/// exists, so the state has to live outside the view.
@MainActor
final class ViewerModel: ObservableObject {
    static let shared = ViewerModel()

    private static let log = Logger(subsystem: GLBPreviewLog.subsystem, category: "App")
    private static let contentType = "org.khronos.glb"

    @Published private(set) var url: URL?
    @Published private(set) var isDefaultHandler = false

    /// Held so the security scope stays open while the model is on screen.
    private var scopedURL: URL?

    var title: String { url?.lastPathComponent ?? "GLB 3D model viewer" }

    func open(_ candidate: URL) {
        guard candidate.pathExtension.lowercased() == "glb" else {
            Self.log.error("Ignoring \(candidate.lastPathComponent, privacy: .public) — not a .glb")
            return
        }
        if scopedURL != candidate {
            scopedURL?.stopAccessingSecurityScopedResource()
            // Returns false for files LaunchServices already granted us, which is
            // the normal case for a Finder double-click.
            scopedURL = candidate.startAccessingSecurityScopedResource() ? candidate : nil
        }
        Self.log.info("Opening \(candidate.path, privacy: .public)")
        url = candidate
    }

    // MARK: - Default handler

    func refreshDefaultHandlerState() {
        let handler = LSCopyDefaultRoleHandlerForContentType(Self.contentType as CFString, .viewer)?
            .takeRetainedValue() as String?
        isDefaultHandler = (handler == Bundle.main.bundleIdentifier)
    }

    /// Deliberately manual. This changes how *every* .glb on the machine opens on
    /// double-click, so it only ever happens from an explicit click, never at launch.
    func makeDefaultHandler() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let status = LSSetDefaultRoleHandlerForContentType(
            Self.contentType as CFString, .viewer, bundleID as CFString)
        if status != noErr {
            Self.log.error("Could not become the default .glb handler (OSStatus \(status))")
        }
        refreshDefaultHandlerState()
    }
}

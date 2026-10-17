import Foundation

/// os_log subsystem for the viewer code that is compiled into *both* the app and
/// the Quick Look extension.
///
/// Taken from the bundle identifier so the two hosts can be told apart:
///
///     log stream --predicate 'subsystem BEGINSWITH "com.loklok"'
///     log show --last 30s --predicate 'subsystem ENDSWITH "GLBQuickLook"'
enum GLBPreviewLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.glproduct.GLBPreviewer"
}

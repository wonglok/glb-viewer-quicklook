import Foundation
import WebKit
import os

/// Serves the whole viewer over one origin:
///
///     glbview://app/index.html?model=…                    the viewer page
///     glbview://app/viewer.js, /decoders/…                the bundle, out of the appex resources
///     glbview://app/model/<base64url(dir)>/<fileName>     the previewed .glb, streamed from disk
///
/// Everything shares the `app` host so the page, its bundle and the model are
/// same-origin — no CORS, and no `file://`. That last part is the point: WebKit
/// refuses to create a `blob:` Web Worker from a `file://` origin, and both
/// DRACOLoader and KTX2Loader build their workers exactly that way.
final class GLBSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "glbview"

    private static let host = "app"
    private static let modelPrefix = "model"
    private static let chunkSize = 512 * 1024

    private let log = Logger(subsystem: GLBPreviewLog.subsystem, category: "SchemeHandler")
    private let queue = DispatchQueue(label: "\(GLBPreviewLog.subsystem).scheme", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelledTasks = Set<ObjectIdentifier>()

    // MARK: - URL construction

    /// The URL the viewer should fetch the model from.
    ///
    /// The containing directory travels in the URL because the handler has to
    /// re-resolve the path itself; Quick Look only granted us the file, and a
    /// relative directory is what lets a GLB referencing sibling files still
    /// resolve them (within the sandbox) rather than 404.
    static func modelURL(for fileURL: URL) -> URL? {
        let directory = fileURL.deletingLastPathComponent().path
        let token = Data(directory.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let name = fileURL.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent
        return URL(string: "\(scheme)://\(host)/\(modelPrefix)/\(token)/\(name)")
    }

    /// The `dist` folder reference, copied verbatim into the appex resources.
    /// Inside an app extension `Bundle.main` is the appex, not the host app.
    static var viewerDistURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("dist", isDirectory: true)
    }

    /// Where the viewer fetches the Draco/Basis decoders. Passed to the page at
    /// document start; the page falls back to a relative path in dev.
    static var decoderRoot: String {
        "\(scheme)://\(host)/decoders/"
    }

    /// The page's base URL. The document is loaded with `loadHTMLString` rather
    /// than navigated to, because WebKit will not navigate a main frame to a
    /// custom scheme — but supplying this as the base gives the page the
    /// glbview:// origin it needs for its scripts, its decoders and the model to
    /// all be same-origin, and for blob: workers (which DRACOLoader and
    /// KTX2Loader both require) to be permitted. On a file:// origin those
    /// workers hang silently with no error.
    static var viewerPageBaseURL: URL? {
        URL(string: "\(scheme)://\(host)/index.html")
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // The serial queue keeps concurrent requests from interleaving file reads
        // and keeps the handler's own traffic off the main thread.
        queue.async { [weak self] in
            self?.route(urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        cancelledTasks.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    // MARK: - Routing

    private func route(_ task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            return fail(task, status: 400, message: "Request had no URL")
        }
        guard url.host == Self.host else {
            return fail(task, status: 404, message: "Unknown host \(url.host ?? "nil")")
        }
        let path = Self.decodePath(url)

        if path.first == Self.modelPrefix {
            guard path.count >= 3, let base = Self.decodeDirectoryToken(path[1]) else {
                return fail(task, status: 400, message: "Malformed model URL")
            }
            guard let file = Self.resolve(path[2...].joined(separator: "/"), under: base) else {
                return fail(task, status: 403, message: "Model path escapes its directory")
            }
            return stream(task, url: url, filePath: file)
        }

        guard let dist = Self.viewerDistURL?.standardizedFileURL.path else {
            return fail(task, status: 500, message: "Viewer bundle is missing from the appex")
        }
        guard let file = Self.resolve(path.joined(separator: "/"), under: dist) else {
            return fail(task, status: 403, message: "Asset path escapes the viewer bundle")
        }
        stream(task, url: url, filePath: file)
    }

    private static func decodePath(_ url: URL) -> [String] {
        url.pathComponents
            .filter { $0 != "/" }
            .map { $0.removingPercentEncoding ?? $0 }
    }

    /// base64url with the padding stripped; re-pad before decoding.
    private static func decodeDirectoryToken(_ token: String) -> String? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 { base64 += String(repeating: "=", count: 4 - padding) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Resolves `relative` beneath `base`, refusing anything that climbs out of it.
    private static func resolve(_ relative: String, under base: String) -> String? {
        guard !relative.isEmpty else { return nil }
        let base = (base as NSString).standardizingPath
        let candidate = ((base as NSString).appendingPathComponent(relative) as NSString).standardizingPath
        guard candidate == base || candidate.hasPrefix(base + "/") else { return nil }
        return candidate
    }

    // MARK: - Serving

    private func stream(_ task: WKURLSchemeTask, url: URL, filePath: String) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            return fail(task, status: 404, message: "Cannot open \(filePath)")
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return fail(task, status: 404, message: "Empty or unreadable file: \(filePath)")
        }

        var isPartial = false
        var start: UInt64 = 0
        var end = fileSize - 1

        if let header = task.request.value(forHTTPHeaderField: "Range"),
           let range = Self.parse(byteRange: header, fileSize: fileSize) {
            if case .unsatisfiable = range {
                let response = HTTPURLResponse(
                    url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Range": "bytes */\(fileSize)"])!
                if !isCancelled(task) { task.didReceive(response); task.didFinish() }
                return forget(task)
            }
            if case .satisfiable(let rangeStart, let rangeEnd) = range {
                start = rangeStart
                end = rangeEnd
                isPartial = true
            }
        }

        let length = end - start + 1
        var headers = [
            "Content-Type": Self.contentType(for: filePath),
            "Content-Length": String(length),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
        ]
        if isPartial { headers["Content-Range"] = "bytes \(start)-\(end)/\(fileSize)" }
        // Request-level logging is what makes an out-of-process extension
        // debuggable: it shows exactly which assets the page asked for and
        // whether they were served, which is otherwise invisible.
        log.info("\(isPartial ? 206 : 200, privacy: .public) \(url.path, privacy: .public) — \(length) bytes")

        let response = HTTPURLResponse(
            url: url, statusCode: isPartial ? 206 : 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        guard !isCancelled(task) else { return forget(task) }
        task.didReceive(response)

        try? handle.seek(toOffset: start)
        var remaining = length
        while remaining > 0 {
            if isCancelled(task) { return forget(task) }
            let requested = Int(min(UInt64(Self.chunkSize), remaining))
            guard let chunk = try? handle.read(upToCount: requested), !chunk.isEmpty else {
                return fail(task, status: 500, message: "Short read in \(filePath)")
            }
            remaining -= UInt64(chunk.count)
            if isCancelled(task) { return forget(task) }
            task.didReceive(chunk)
        }

        if !isCancelled(task) { task.didFinish() }
        forget(task)
    }

    private enum ByteRange {
        case satisfiable(UInt64, UInt64)
        case unsatisfiable
    }

    private static func parse(byteRange header: String, fileSize: UInt64) -> ByteRange? {
        // Only single ranges are handled. three.js always asks for one, and a
        // multi-range request is better served by sending the whole file.
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.hasPrefix("bytes="), !spec.contains(",") else { return nil }
        let parts = spec.dropFirst("bytes=".count)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {                                   // suffix form: bytes=-N
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            return .satisfiable(fileSize - min(suffix, fileSize), fileSize - 1)
        }
        guard let start = UInt64(parts[0]) else { return nil }
        guard start < fileSize else { return .unsatisfiable }
        let end = parts[1].isEmpty
            ? fileSize - 1
            : min(UInt64(parts[1]) ?? fileSize - 1, fileSize - 1)
        guard end >= start else { return nil }
        return .satisfiable(start, end)
    }

    private static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "bin": return "application/octet-stream"
        case "json": return "application/json"
        case "js", "mjs": return "text/javascript"
        case "wasm": return "application/wasm"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ktx2": return "image/ktx2"
        case "basis": return "image/basis"
        case "hdr": return "image/vnd.radiance"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Cancellation

    private func fail(_ task: WKURLSchemeTask, status: Int, message: String) {
        log.error("glbview:// \(status): \(message, privacy: .public)")
        guard !isCancelled(task) else { return forget(task) }
        let url = task.request.url ?? URL(string: "\(Self.scheme)://error")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
        task.didReceive(response)
        task.didFailWithError(NSError(
            domain: Self.scheme, code: status,
            userInfo: [NSLocalizedDescriptionKey: message]))
        forget(task)
    }

    private func isCancelled(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledTasks.contains(ObjectIdentifier(task))
    }

    private func forget(_ task: WKURLSchemeTask) {
        lock.lock()
        cancelledTasks.remove(ObjectIdentifier(task))
        lock.unlock()
    }
}

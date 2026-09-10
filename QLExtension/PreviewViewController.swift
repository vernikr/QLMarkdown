//
//  PreviewViewController.swift
//  QLExtension
//
//  Created by Sbarex on 16/12/20.
//

import Cocoa
import Quartz
@preconcurrency import WebKit
import OSLog
import external_launcher

class MyWKWebView: WKWebView {
    override var canBecomeKeyView: Bool {
        return false
    }

    override func becomeFirstResponder() -> Bool {
        // Quick Look window do not allow first responder child.
        return false
    }
}

/**
 * Cache of the documents already rendered, so that showing a document again does not parse and
 * highlight the Markdown from scratch.
 *
 * Quick Look asks for the same document more than once (moving back and forth inside a panel) and
 * starts a new extension process for every panel, so the cache has two levels: the in-memory
 * entries of the current process and one small file per document inside the app group container,
 * which is what makes a preview fast again after the extension has been restarted.
 *
 * An entry is reused only while everything its body was built from is unchanged: the source file
 * (modification date and size), the settings (fingerprinted) and, in `Render as code` mode, the
 * system appearance. Documents with local images embedded in the body are never cached.
 */
final class RenderedDocumentCache {
    static let shared = RenderedDocumentCache()
    
    /// Number of documents kept in memory.
    private let memoryCapacity = 8
    /// Biggest body worth caching (a few MB of HTML is already an unusually large document).
    private let maxBodyLength = 4 << 20
    /// A cached document is dropped after this long without being previewed again.
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// The cleanup keeps the cache folder below this size...
    private let maxDiskSize = 64 << 20
    /// ...and below this number of documents.
    private let maxDiskEntries = 200
    
    /// Everything the rendered body depends on.
    struct Key: Equatable, Codable {
        let path: String
        /// Modification date of the source file, in milliseconds since 1970 (an integer, so that
        /// it survives the encoding on disk exactly).
        let modified: Int?
        let size: Int
        /// Fingerprint of the settings used for the rendering.
        let settings: String
        /// The system appearance, but only when the rendering depends on it (`renderAsCode`).
        let lightAppearance: Bool?
    }
    
    private struct Entry: Codable {
        let key: Key
        let body: String
    }
    
    /// Entries ordered from the most to the least recently used.
    private var memory: [Entry] = []
    
    /// Used to keep the cleanup (file deletions) out of the preview path.
    private let cleanupQueue = DispatchQueue(label: "org.sbarex.QLMarkdown.preview-cache", qos: .utility)
    private var isCleaningUp = false
    
    // MARK: - Cache key
    
    /**
     * Key of the document: it changes as soon as one of the inputs of the rendering changes.
     */
    func key(for url: URL, settings: Settings) -> Key {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Key(
            path: url.path,
            modified: values?.contentModificationDate.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) },
            size: values?.fileSize ?? -1,
            settings: Self.fingerprint(of: settings),
            lightAppearance: settings.renderAsCode ? Settings.isLightAppearance : nil
        )
    }
    
    /**
     * Fingerprint of every setting a rendering depends on.
     *
     * The settings are encoded with sorted keys so that the fingerprint is the same in every
     * process (the cache on disk is shared with the next runs of the extension).
     */
    private static func fingerprint(of settings: Settings) -> String {
        var text = ""
        if let data = try? Self.encoder.encode(settings) {
            text = Self.fnv1a(data)
        }
        let info = Settings.getResourceBundle().infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?").\(info?["CFBundleVersion"] as? String ?? "?")"
        return "\(text)-\(version)"
    }
    
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    
    /// Stable hash (FNV-1a, 64 bit) of the given bytes; unlike `Hasher` it is the same in every
    /// process, which is required for the cache file names.
    private static func fnv1a<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x00000100000001b3
        }
        return String(hash, radix: 16)
    }
    
    // MARK: - Lookup and store
    
    /**
     * Body of the last rendering of the document, or `nil` if it must be rendered again.
     */
    func body(for key: Key) -> String? {
        if let index = memory.firstIndex(where: { $0.key == key }) {
            let entry = memory.remove(at: index)
            memory.insert(entry, at: 0)
            return entry.body
        }
        
        guard let entry = self.entry(onDisk: key) else {
            return nil
        }
        keepInMemory(entry)
        return entry.body
    }
    
    /**
     * Store the body rendered for the document, unless it is not worth (or not safe) to cache.
     */
    func store(body: String, for key: Key) {
        // A body with local images embedded in it is not cached: the images are not part of the
        // cache key, so editing one of them would keep showing the old picture.
        guard !body.contains("data:image/") else {
            return
        }
        guard body.utf8.count <= maxBodyLength else {
            return
        }
        
        let entry = Entry(key: key, body: body)
        keepInMemory(entry)
        store(entry, onDisk: key)
        scheduleCleanup()
    }
    
    private func keepInMemory(_ entry: Entry) {
        memory.removeAll { $0.key == entry.key }
        memory.insert(entry, at: 0)
        if memory.count > memoryCapacity {
            memory.removeLast(memory.count - memoryCapacity)
        }
    }
    
    // MARK: - Disk level
    
    /**
     * Folder with the cached documents, inside the container of the extension.
     *
     * The container of the extension is used instead of the app group container because the
     * sandbox allows the extension to read the shared container but not to write in it (the group
     * container belongs to the main application), and because nothing else than the extension has
     * to read this cache.
     */
    private static let folderURL: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = caches.appendingPathComponent("preview-cache", isDirectory: true)
        os_log("Preview cache folder: %{public}s", log: OSLog.quickLookExtension, type: .info, folder.path)
        return folder
    }()
    
    /// File of the given document. One file per document, so that an entry is overwritten instead
    /// of piling up every time the document changes.
    private func fileURL(for key: Key) -> URL? {
        return Self.folderURL?.appendingPathComponent("preview-\(Self.fnv1a(key.path.utf8)).json")
    }
    
    private func entry(onDisk key: Key) -> Entry? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            // Unreadable (or older format) entry: drop it and render the document again.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard entry.key == key, entry.body.utf8.count <= maxBodyLength else {
            return nil
        }
        return entry
    }
    
    private func store(_ entry: Entry, onDisk key: Key) {
        guard let url = fileURL(for: key), let folder = Self.folderURL else {
            return
        }
        guard let data = try? JSONEncoder().encode(entry) else {
            return
        }
        
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        }
        try? data.write(to: url, options: .atomic)
    }
    
    /// Drop the entries that were not used for a long time and keep the folder within its budget.
    /// Runs off the preview path, and never blocks it.
    private func scheduleCleanup() {
        cleanupQueue.async { [weak self] in
            guard let self, !self.isCleaningUp else {
                return
            }
            self.isCleaningUp = true
            defer { self.isCleaningUp = false }
            self.cleanup()
        }
    }
    
    private func cleanup() {
        guard let folder = Self.folderURL else {
            return
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        let now = Date()
        var stored: [(url: URL, modified: Date, size: Int)] = []
        var totalSize = 0
        
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: keys) else {
                continue
            }
            let modified = values.contentModificationDate ?? now
            let size = values.fileSize ?? 0
            if now.timeIntervalSince(modified) > maxAge {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            totalSize += size
            stored.append((file, modified, size))
        }
        
        // Remove the least recently used entries until the folder fits its budget again.
        var count = stored.count
        for entry in stored.sorted(by: { $0.modified < $1.modified }) {
            guard count > maxDiskEntries || totalSize > maxDiskSize else {
                break
            }
            try? FileManager.default.removeItem(at: entry.url)
            totalSize -= entry.size
            count -= 1
        }
    }
}

class PreviewViewController: NSViewController, QLPreviewingController {
    var webView: MyWKWebView?

    var handler: ((Error?) -> Void)? = nil

    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    var launcherService: ExternalLauncherProtocol?

    /// Size suggested to Quick Look. Reduced to fit the screen.
    static var previewContentSize: CGSize {
        let size = Settings.shared.qlWindowSize
        guard let screen = NSScreen.main else {
            return size
        }
        let available = screen.visibleFrame.size
        return CGSize(
            width: min(size.width, available.width * 0.9),
            height: min(size.height, available.height * 0.9)
        )
    }

    override func viewDidDisappear() {
        self.launcherService = nil
    }

    override func loadView() {
        super.loadView()

        // Paint the loading sheet with the current system appearance (dark in dark
        // mode) instead of the default white, so the preview does not flash a white
        // rectangle while the HTML is being generated and rendered.
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        Settings.shared.startMonitorChange()

        if #available(macOS 11, *) {
            let connection = NSXPCConnection(serviceName: "org.sbarex.qlmarkdown.external-launcher")

            connection.remoteObjectInterface = NSXPCInterface(with: ExternalLauncherProtocol.self)
            connection.resume()

            self.launcherService = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as? ExternalLauncherProtocol
        }

        let settings = Settings.shared

        self.preferredContentSize = Self.previewContentSize

        let previewRect: CGRect
        if #available(macOS 11, *) {
            previewRect = self.view.bounds
        } else {
            previewRect = self.view.bounds.insetBy(dx: 2, dy: 2)
        }

        // Create a configuration for the preferences
        let configuration = WKWebViewConfiguration()
        // Enable JavaScript for unsafe HTML with inline images, or when Mermaid/Math extensions are active
        configuration.preferences.javaScriptEnabled = (settings.unsafeHTMLOption && settings.inlineImageExtension) || !settings.mermaidExtension.isDisabled || !settings.mathExtension.isDisabled
        configuration.allowsAirPlayForMediaPlayback = false

        self.webView = MyWKWebView(frame: previewRect, configuration: configuration)
        self.webView!.autoresizingMask = [.height, .width]

        self.webView!.wantsLayer = true
        if #available(macOS 11, *) {
            self.webView!.layer?.borderWidth = 0
        } else {
            // Draw a border around the web view
            self.webView!.layer?.borderColor = NSColor.gridColor.cgColor
            self.webView!.layer?.borderWidth = 1
        }

        self.webView!.navigationDelegate = self

        if #available(macOS 12.0, *) {
            // Keep the themed background also around (and before) the rendered page.
            self.webView?.underPageBackgroundColor = NSColor.windowBackgroundColor
        }
        // Do not draw a white webview background before the page paints: the HTML
        // itself declares its own (theme-aware) background color.
        if self.webView?.responds(to: Selector(("drawsBackground"))) == true {
            self.webView?.setValue(false, forKey: "drawsBackground")
        }

        self.view.addSubview(self.webView!)
    }

    internal func getBundleContents(forResource: String, ofType: String) -> String?
    {
        if let p = Bundle.main.path(forResource: forResource, ofType: ofType), let data = FileManager.default.contents(atPath: p), let s = String(data: data, encoding: .utf8) {
            return s
        } else {
            return nil
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // View-based preview. This is the active path since QLIsDataBasedPreview is disabled
        // (the extension paints the loading sheet itself).

        // Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.

        // Call the completion handler so Quick Look knows that the preview is fully loaded.
        // Quick Look will display a loading spinner while the completion handler is not called.

        do {
            self.handler = handler

            let html = try renderMD(url: url)
            self.webView?.isHidden = true // hide the webview until complete rendering
            self.webView?.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        } catch {
            handler(error)
        }
    }

    /// Provides HTML preview data for Quick Look.
    /// Entry point used on macOS 12+ only when QLIsDataBasedPreview is set to true
    /// (currently disabled, see Info.plist).
    @available(macOSApplicationExtension 12.0, *)
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        Settings.shared.startMonitorChange()

        let html = try renderMD(url: request.fileURL)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: Self.previewContentSize) { (replyToUpdate: QLPreviewReply) in
            replyToUpdate.stringEncoding = .utf8
            return html.data(using: .utf8)!
        }

        return reply
    }

    func renderMD(url: URL) throws -> String {
        os_log(
            "Generating preview for file %{public}s",
            log: OSLog.quickLookExtension,
            type: .info,
            url.path
        )

        let settings = Settings.shared
        Settings.renderStats += 1

        let start = CFAbsoluteTimeGetCurrent()
        let markdown_url = Settings.getMarkdownFile(from: url)
        let cacheKey = RenderedDocumentCache.shared.key(for: markdown_url, settings: settings)
        var text: String
        var isCached = 0
        if let cached = RenderedDocumentCache.shared.body(for: cacheKey) {
            isCached = 1
            os_log(
                "Reusing the cached rendering of file %{public}s",
                log: OSLog.quickLookExtension,
                type: .info,
                markdown_url.path
            )
            text = cached
        } else {
            text = try settings.render(file: markdown_url, baseDir: markdown_url.deletingLastPathComponent().path)
            RenderedDocumentCache.shared.store(body: text, for: cacheKey)
        }
        
        if Settings.renderStats > 0 && Settings.renderStats % 100 == 0 {
            let icon: String
            if let url = Bundle.main.url(forResource: "icon", withExtension: "png"), let data = try? Data(contentsOf: url) {
                icon = data.base64EncodedString()
            } else {
                icon = ""
            }
            
            let msg =
                """
                        <div id="container" style="font-size: 1.5rem">
                            <h1><img src="data:image/png;base64,\(icon)" width="75" height="75" alt="logo" id="logo" /> QLMarkdown</h1>
                            <p>Thanks to this application you have viewed over <b>\(Settings.renderStats) files</b>.</p>
                            <p>If you find it useful and you have the possibility, consider <a href="https://buymeacoffee.com/sbarex"><b>buying me a coffee!</b></a></p>
                            <br />
                            <hr size="1" />
                            <p class="small">Developed by SBAREX with ❤️ | <a href="https://github.com/sbarex/QLMarkdown">https://github.com/sbarex/QLMarkdown</a></p>
                            </p>
                        </div>
                """

            text += msg
        }

        let html = settings.getCompleteHTML(title: url.lastPathComponent, body: text)

        os_log(
            "Preview of %{public}s ready in %{public}.1f ms (cached: %{public}d)",
            log: OSLog.quickLookExtension,
            type: .info,
            url.lastPathComponent,
            (CFAbsoluteTimeGetCurrent() - start) * 1000,
            isCached
        )

        return html
    }
}

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let handler = self.handler {
            handler(nil)
            self.handler = nil
        }
        // Show the Quick Look preview only after the complete rendering (preventing a flickering glitch).
        // Wait to show the webview to prevent a resize glitch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.webView?.isHidden = false
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let handler = self.handler {
            handler(error)
            self.handler = nil
            self.webView?.isHidden = false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !Settings.shared.openInlineLink, navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, url.scheme != "file" {
            if #available(macOS 11, *) {
                // On Big Sur NSWorkspace.shared.open fail with this error on Console:
                // Launch Services generated an error at +[_LSRemoteOpenCall(PrivateCSUIAInterface) invokeWithXPCConnection:object:]:455, converting to OSStatus -54: Error Domain=NSOSStatusErrorDomain Code=-54 "The sandbox profile of this process is missing "(allow lsopen)", so it cannot invoke Launch Services' open API." UserInfo={NSDebugDescription=The sandbox profile of this process is missing "(allow lsopen)", so it cannot invoke Launch Services' open API., _LSLine=455, _LSFunction=+[_LSRemoteOpenCall(PrivateCSUIAInterface) invokeWithXPCConnection:object:]}
                // Using a XPC service is a valid workaround.
                launcherService?.open(url, withReply: { r in
                    // print("open result: \(r)")
                })
                decisionHandler(.cancel)
                return
            } else {
                let r = NSWorkspace.shared.open(url)
                if r {
                    decisionHandler(.cancel)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }
}

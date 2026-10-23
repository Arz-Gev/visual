// ASCII Wallpaper: plays an ascii-magic-art piece behind the desktop icons on every screen,
// with a menu bar menu to pick the piece, look, speed and so on.
import Cocoa
import WebKit

let bundleID = Bundle.main.bundleIdentifier ?? "com.arzgev.asciiwallpaper"
let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web")
let defaultPiece = "moonlit-sea"
let looks = ["", "dots", "ascii", "dense", "numbers", "binary", "letters", "blocks", "squares", "lines", "dither"]

struct Piece { let slug: String, name: String, category: String }

/// Reads slug, name and category from each piece's `export const meta = {...}`.
func loadPieces() -> [Piece] {
    let dir = webRoot.appendingPathComponent("ascii-magic-art/pieces")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var out: [Piece] = []
    for f in files where f.pathExtension == "js" {
        guard let src = try? String(contentsOf: f, encoding: .utf8),
              let start = src.range(of: "export const meta") else { continue }
        let meta = String(src[start.lowerBound...].prefix(1500))
        func field(_ key: String) -> String? {
            let rx = try! NSRegularExpression(pattern: "\"?\(key)\"?\\s*:\\s*\"([^\"]*)\"")
            guard let m = rx.firstMatch(in: meta, range: NSRange(meta.startIndex..., in: meta)),
                  let r = Range(m.range(at: 1), in: meta) else { return nil }
            return String(meta[r])
        }
        let slug = f.deletingPathExtension().lastPathComponent
        out.append(Piece(slug: slug, name: field("name") ?? slug, category: field("category") ?? "other"))
    }
    return out
}

func loadCategories() -> [(id: String, name: String)] {
    struct C: Decodable { let id: String, name: String }
    let url = webRoot.appendingPathComponent("ascii-magic-art/categories.json")
    guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([C].self, from: data) else { return [] }
    return list.map { ($0.id, $0.name) }
}

/// Serves the bundled web files on ascii://app/ so ES modules load (file:// blocks them).
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = webRoot.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(webRoot.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["html": "text/html", "js": "text/javascript", "json": "application/json", "css": "text/css"]
        let mime = types[file.pathExtension] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let d = UserDefaults.standard
    let handler = SchemeHandler()
    var windows: [NSWindow] = []
    var status: NSStatusItem!
    var pieces: [Piece] = []
    var categories: [(id: String, name: String)] = []
    var shuffleTimer: Timer?

    var piece: String {
        get { d.string(forKey: "piece") ?? defaultPiece }
        set { d.set(newValue, forKey: "piece") }
    }
    var look: String { d.string(forKey: "look") ?? "" }
    var speed: Double { d.object(forKey: "speed") as? Double ?? 1 }
    var fit: String { d.string(forKey: "fit") ?? "cover" }
    var sharp: Bool { d.bool(forKey: "sharp") }
    var paused: Bool { d.bool(forKey: "paused") }
    var shuffleMinutes: Int { d.integer(forKey: "shuffle") }

    let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    var startsAtLogin: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        categories = loadCategories()
        let order = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        pieces = loadPieces().sorted {
            (order[$0.category] ?? 999, $0.name) < (order[$1.category] ?? 999, $1.name)
        }
        if !pieces.contains(where: { $0.slug == piece }) { piece = pieces.first?.slug ?? defaultPiece }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ASCII Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        buildWindows()
        resetShuffle()
        NotificationCenter.default.addObserver(self, selector: #selector(buildWindows),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // --snapshot <file.png>: save what the main screen shows after 3 s (for checking a build).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                (self.windows.first?.contentView as? WKWebView)?.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    }
                }
            }
        }
    }

    // MARK: wallpaper windows

    func pageURL() -> URL {
        var c = URLComponents()
        c.scheme = "ascii"; c.host = "app"; c.path = "/wallpaper.html"
        var q = [URLQueryItem(name: "piece", value: piece), URLQueryItem(name: "speed", value: String(speed)),
                 URLQueryItem(name: "fit", value: fit), URLQueryItem(name: "dpr", value: sharp ? "2" : "1")]
        if !look.isEmpty { q.append(URLQueryItem(name: "look", value: look)) }
        if paused { q.append(URLQueryItem(name: "still", value: "1")) }
        c.queryItems = q
        return c.url!
    }

    @objc func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "ascii")
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
            web.autoresizingMask = [.width, .height]
            web.setValue(false, forKey: "drawsBackground")
            w.contentView = web
            w.setFrame(screen.frame, display: false)
            w.orderFront(nil)
            web.load(URLRequest(url: pageURL()))
            windows.append(w)
        }
    }

    func reload() {
        let url = pageURL()
        for w in windows { (w.contentView as? WKWebView)?.load(URLRequest(url: url)) }
    }

    func show(_ slug: String) { piece = slug; reload() }

    func resetShuffle() {
        shuffleTimer?.invalidate()
        shuffleTimer = nil
        guard shuffleMinutes > 0 else { return }
        shuffleTimer = Timer.scheduledTimer(withTimeInterval: Double(shuffleMinutes) * 60, repeats: true) { [weak self] _ in
            self?.randomPiece()
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = pieces.first { $0.slug == piece }
        let now = NSMenuItem(title: current?.name ?? piece, action: nil, keyEquivalent: "")
        now.isEnabled = false
        menu.addItem(now)
        menu.addItem(item("Next", #selector(nextPiece)))
        menu.addItem(item("Previous", #selector(previousPiece)))
        menu.addItem(item("Random", #selector(randomPiece)))
        menu.addItem(.separator())

        let all = NSMenuItem(title: "Pieces", action: nil, keyEquivalent: "")
        let allMenu = NSMenu()
        var groups = categories
        if pieces.contains(where: { p in !categories.contains { $0.id == p.category } }) { groups.append(("other", "Other")) }
        for c in groups {
            let list = pieces.filter { p in c.id == "other" ? !categories.contains { $0.id == p.category } : p.category == c.id }
            guard !list.isEmpty else { continue }
            let ci = NSMenuItem(title: "\(c.name) (\(list.count))", action: nil, keyEquivalent: "")
            let cm = NSMenu()
            for p in list {
                let i = item(p.name, #selector(pickPiece(_:)))
                i.representedObject = p.slug
                i.state = p.slug == piece ? .on : .off
                cm.addItem(i)
            }
            ci.submenu = cm
            ci.state = list.contains { $0.slug == piece } ? .on : .off
            allMenu.addItem(ci)
        }
        all.submenu = allMenu
        menu.addItem(all)

        menu.addItem(options("Look", key: "look", current: look,
                             looks.map { ($0.isEmpty ? "Original" : $0.capitalized, $0) }))
        menu.addItem(options("Speed", key: "speed", current: speed,
                             [0.25, 0.5, 1, 1.5, 2, 3].map { ("\($0)×".replacingOccurrences(of: ".0×", with: "×"), $0) }))
        menu.addItem(options("Fit", key: "fit", current: fit,
                             [("Fill screen", "cover"), ("Show whole piece", "contain")]))
        menu.addItem(options("Shuffle", key: "shuffle", current: shuffleMinutes,
                             [("Off", 0), ("Every 5 minutes", 5), ("Every 15 minutes", 15),
                              ("Every 30 minutes", 30), ("Every hour", 60)]))
        menu.addItem(.separator())
        menu.addItem(toggle("Pause", paused, #selector(togglePause)))
        menu.addItem(toggle("Retina sharpness (more CPU)", sharp, #selector(toggleSharp)))
        menu.addItem(toggle("Start at login", startsAtLogin, #selector(toggleLogin)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ASCII Wallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    func options<T: Equatable>(_ title: String, key: String, current: T, _ choices: [(String, T)]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in choices {
            let i = item(label, #selector(setOption(_:)))
            i.representedObject = [key, value]
            i.state = value == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc func setOption(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let key = pair[0] as? String else { return }
        d.set(pair[1], forKey: key)
        if key == "shuffle" { resetShuffle() } else { reload() }
    }

    @objc func pickPiece(_ sender: NSMenuItem) {
        if let slug = sender.representedObject as? String { show(slug) }
    }

    func step(_ by: Int) {
        guard !pieces.isEmpty else { return }
        let i = pieces.firstIndex { $0.slug == piece } ?? 0
        show(pieces[(i + by + pieces.count) % pieces.count].slug)
    }

    @objc func nextPiece() { step(1) }
    @objc func previousPiece() { step(-1) }
    @objc func randomPiece() {
        if let p = pieces.filter({ $0.slug != piece }).randomElement() { show(p.slug) }
    }

    @objc func togglePause() { d.set(!paused, forKey: "paused"); reload() }
    @objc func toggleSharp() { d.set(!sharp, forKey: "sharp"); reload() }

    @objc func toggleLogin() {
        if startsAtLogin {
            try? FileManager.default.removeItem(at: agentURL)
        } else {
            let plist: NSDictionary = ["Label": bundleID, "RunAtLoad": true,
                                       "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath]]
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            plist.write(to: agentURL, atomically: true)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

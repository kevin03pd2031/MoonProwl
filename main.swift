import Cocoa
import WebKit

let HOMEPAGE = "https://html.duckduckgo.com/"

// Lightweight startup tracer so a crash on another machine is diagnosable from the
// last line written here: ~/Library/Application Support/MoonProwl Browser/launch.log
func LaunchLog(_ step: String) {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MoonProwl Browser", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("launch.log")
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts)  \(step)\n"
    if let fh = try? FileHandle(forWritingTo: f) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(to: f, atomically: true, encoding: .utf8)
    }
}

// Install a last-ditch trap so even a hard crash (signal / uncaught exception) writes
// its reason to launch.log before the process dies. Lets a non-technical user just
// send us the log file instead of a crash report.
func InstallCrashTrap() {
    NSSetUncaughtExceptionHandler { exc in
        LaunchLog("UNCAUGHT EXCEPTION: \(exc.name.rawValue) — \(exc.reason ?? "no reason")")
    }
    signal(SIGILL) { _ in LaunchLog("CRASH: SIGILL (illegal instruction — usually JIT/hardened-runtime)") }
    signal(SIGSEGV) { _ in LaunchLog("CRASH: SIGSEGV (bad memory access)") }
    signal(SIGABRT) { _ in LaunchLog("CRASH: SIGABRT") }
    signal(SIGBUS) { _ in LaunchLog("CRASH: SIGBUS (misaligned/bad access)") }
}

// MARK: - Material Design theme (Material 3 "baseline" palette)
// Theme-aware: a light set and a dark set. `Material.current` is updated on toggle
// so every view reads the right colors for the active mode.
enum Material {
    struct Palette {
        let primary, primaryLt, surface, surfaceVar, onSurface, outline, ripple: NSColor
    }
    // The light Material baseline — recolored to BLUE (primary #1565C0).
    static let light = Palette(
        primary:    NSColor(srgbRed: 0.08, green: 0.40, blue: 0.75, alpha: 1),   // #1565C0
        primaryLt:  NSColor(srgbRed: 0.85, green: 0.92, blue: 1.00, alpha: 1),   // light blue container
        surface:    NSColor(srgbRed: 0.99, green: 0.99, blue: 1.00, alpha: 1),
        surfaceVar: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 1),
        onSurface:  NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        outline:    NSColor(srgbRed: 0.45, green: 0.52, blue: 0.60, alpha: 1),
        ripple:     NSColor(srgbRed: 0.08, green: 0.40, blue: 0.75, alpha: 0.12)
    )
    // The dark Material baseline — blue primary on dark surfaces.
    static let dark = Palette(
        primary:    NSColor(srgbRed: 0.40, green: 0.70, blue: 1.00, alpha: 1),   // brighter blue for contrast
        primaryLt:  NSColor(srgbRed: 0.10, green: 0.28, blue: 0.50, alpha: 1),
        surface:    NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1),
        surfaceVar: NSColor(srgbRed: 0.19, green: 0.22, blue: 0.26, alpha: 1),
        onSurface:  NSColor(srgbRed: 0.90, green: 0.93, blue: 0.97, alpha: 1),
        outline:    NSColor(srgbRed: 0.58, green: 0.64, blue: 0.72, alpha: 1),
        ripple:     NSColor(srgbRed: 0.40, green: 0.70, blue: 1.00, alpha: 0.15)
    )
    static var mode: Bool = false   // false = light, true = dark
    static var current: Palette { mode ? dark : light }
    static var primary:    NSColor { current.primary }
    static var primaryLt:  NSColor { current.primaryLt }
    static var surface:    NSColor { current.surface }
    static var surfaceVar: NSColor { current.surfaceVar }
    static var onSurface:  NSColor { current.onSurface }
    static var outline:    NSColor { current.outline }
    static var ripple:     NSColor { current.ripple }
}

// MARK: - Privacy configuration (defaults maximize privacy)
struct PrivacyConfig {
    static var blockTrackers: Bool = true              // WKContentRuleList from blocklist.json
    static var thirdPartyCookies: Bool = false          // deny storage of cross-site cookies
    static var blockJS: Bool = true                      // GLOBAL: JavaScript OFF everywhere by default
    static var spoofUserAgent: Bool = true              // generic Chrome UA, not Safari/this app
    static var youtubePrivacy: Bool = true              // break YouTube watch-history -> ad profiling
    static var blockPopups: Bool = true                 // deny window.open / target=_blank
    static var resetOnRefresh: Bool = false             // wipe cookies/cache/localStorage on every page reload
    static var forgetOnClose: Bool = true               // wipe ephemeral store + cache on quit
}

// MARK: - SettingsBinder: bridges AppKit controls (NSSwitch / NSButton) to
// PrivacyConfig get/set closures. Each settings control stores its getter/setter
// here; the shared action (settingsToggle) reads the control's new state and calls
// the matching setter, then persists.
final class SettingsBinder {
    static let shared = SettingsBinder()
    private var bindings: [ObjectIdentifier: (get: () -> Bool, set: (Bool) -> Void)] = [:]
    private var lock = NSLock()

    func bind(_ ctrl: NSControl, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        bindings[ObjectIdentifier(ctrl)] = (get, set)
    }

    func handle(_ ctrl: NSControl) {
        lock.lock(); defer { lock.unlock() }
        if let b = bindings[ObjectIdentifier(ctrl)] {
            let st: NSControl.StateValue
            if let sw = ctrl as? NSSwitch { st = sw.state }
            else if let btn = ctrl as? NSButton { st = btn.state }
            else { st = .off }
            b.set(st == .on)
            // In-session only: toggles apply live but are NOT persisted across launches.
        }
    }
}

// WKContentRuleList. Rules are compiled ONCE (async) and attached to every web
// view configuration at init. This is what actually blocks trackers.
final class Blocklist {
    static let shared = Blocklist()
    private(set) var rulesList: WKContentRuleList?

    private init() { compile() }

    private func compile() {
        let blockDomains: [String]
        if let url = Bundle.main.url(forResource: "blocklist", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            blockDomains = arr
        } else {
            blockDomains = ["doubleclick.net","googleadservices.com","googlesyndication.com",
                            "google-analytics.com","googletagmanager.com","facebook.com",
                            "connect.facebook.net","analytics.tiktok.com"]
        }
        let rules: [[String: Any]] = blockDomains.map { domain in
            ["trigger": ["url-filter": ".*", "if-domain": [domain, "*." + domain]],
             "action": ["type": "block"]]
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: payload, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "quoin.blocktrackers",
                                                                encodedContentRuleList: json) { [weak self] list, error in
            if let list = list { self?.rulesList = list }
            else { NSLog("[privacy] blocklist compile failed: %@", String(describing: error)) }
        }
    }
}

// MARK: - Material circular icon button with hover state elevation
final class MaterialIconButton: NSButton {
    var adDomain: String?   // ad-block: domain this delete button removes
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 18
        (cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        // Symbol images tint from the button's native contentTintColor — do NOT
        // override that property, or AppKit's tint pipeline breaks.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = (isEnabled ? Material.ripple : NSColor.clear).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - Progress bar painted in the Material primary (purple)
final class MaterialProgress: NSProgressIndicator {
    override func draw(_ dirtyRect: NSRect) {
        // Track (unfilled portion) then filled portion in primary purple.
        let track = NSBezierPath(rect: bounds)
        (Material.surfaceVar).setFill(); track.fill()
        let frac = CGFloat(doubleValue - minValue) / CGFloat(maxValue - minValue)
        if frac > 0 {
            let w = max(0, bounds.width * frac)
            let fillPath = NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: bounds.height))
            (Material.primary).setFill(); fillPath.fill()
        }
    }
}

// MARK: - Flat container view with a solid background + optional bottom hairline
final class MaterialBar: NSView {
    // Which Material surface to paint from. Drawn LIVE from Material.current so the
    // bar follows light/dark theme changes (a stored color would stay stale).
    var fillVar: Bool = false   // false -> Material.surface, true -> Material.surfaceVar
    var shadowLine = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (fillVar ? Material.surfaceVar : Material.surface).setFill(); bounds.fill()
        if shadowLine {
            Material.surfaceVar.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

// MARK: - Rounded "pill" container for the address field (Material search bar)
final class MaterialPill: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds, xRadius: bounds.height/2, yRadius: bounds.height/2)
        Material.surfaceVar.setFill(); r.fill()
    }
}

// MARK: - Material context menu (image actions)
// A real NSView panel — NOT a native NSMenu — so it reads as Material: rounded
// surface card, purple SF-symbol glyphs, hover-highlighted rows. Drawn live from
// Material.current so it follows the light/dark theme. Used for both right-click
// and double-click on an image (macOS 26 never routes mouseDown to WKWebView, so
// the app-level NSEvent monitor drives it).
final class MaterialContextMenu: NSPanel {
    private var rows: [MaterialMenuRow] = []
    private var outsideMonitor: Any?

    init(items: [(title: String, icon: NSImage?, action: () -> Void)]) {
        let rowH: CGFloat = 38
        let w: CGFloat = 220
        let h = CGFloat(items.count) * rowH + 8
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.backgroundColor = Material.surface.cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Material.outline.withAlphaComponent(0.25).cgColor
        self.contentView = content

        // Layer is NOT flipped, so y grows downward from the top.
        var y: CGFloat = h - rowH - 4
        for (title, icon, action) in items {
            let row = MaterialMenuRow(frame: NSRect(x: 6, y: y, width: w - 12, height: rowH),
                                      title: title, icon: icon)
            row.onSelect = action
            row.onHover = { [weak self] _ in
                self?.rows.forEach { $0.setHovered($0 === row) }
            }
            content.addSubview(row)
            rows.append(row)
            y -= rowH
        }
        // Click anywhere outside the card closes it. Removed on orderOut so we
        // don't leak a global monitor per menu.
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
            if let self = self, self.isVisible,
               let cv = self.contentView {
                let loc = cv.convert(ev.locationInWindow, from: nil)
                if !cv.bounds.contains(loc) { self.close() }
            }
            return ev
        }
    }

    override var canBecomeKey: Bool { false }

    override func orderOut(_ sender: Any?) {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        super.orderOut(sender)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class MaterialMenuRow: NSView {
    var onSelect: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private let iconView: NSImageView
    private let label: NSTextField

    init(frame frameRect: NSRect, title: String, icon: NSImage?) {
        iconView = NSImageView(frame: NSRect(x: 12, y: (frameRect.height - 18)/2, width: 18, height: 18))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Material.primary

        label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = Material.onSurface
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.frame = NSRect(x: 40, y: (frameRect.height - 16)/2, width: frameRect.width - 50, height: 16)

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        addSubview(iconView)
        addSubview(label)
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setHovered(_ h: Bool) {
        layer?.backgroundColor = h ? Material.primaryLt.cgColor : NSColor.clear.cgColor
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        (window as? MaterialContextMenu)?.close()
    }
}


// MARK: - Password store (browser-owned JSON file; user can delete entries)
// Stored at ~/Library/Application Support/MoonProwl Browser/passwords.json
struct Credential: Codable, Equatable {
    var host: String
    var user: String
    var pass: String
}

final class PasswordStore {
    static let shared = PasswordStore()
    private(set) var items: [Credential] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoonProwl Browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("passwords.json")
    }

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Credential].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // Save or update a credential (unique per host+user).
    func save(host: String, user: String, pass: String) {
        if let idx = items.firstIndex(where: { $0.host == host && $0.user == user }) {
            items[idx].pass = pass
        } else {
            items.append(Credential(host: host, user: user, pass: pass))
        }
        persist()
    }

    // Does an identical credential already exist? (used to avoid re-prompting)
    func exists(host: String, user: String, pass: String) -> Bool {
        items.contains { $0.host == host && $0.user == user && $0.pass == pass }
    }

    // Same host + password already stored (any username)? Means it's the same
    // account — used so a missed/empty username detection doesn't re-prompt.
    func exists(host: String, pass: String) -> Bool {
        items.contains { $0.host == host && $0.pass == pass }
    }

    func credentials(forHost host: String) -> [Credential] {
        let norm: (String) -> String = { h in
            h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        let h = norm(host)
        return items.filter { norm($0.host) == h }
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        persist()
    }

    func removeAll() { items.removeAll(); persist() }
}


// MARK: - Bookmarks (persisted to a JSON file the browser owns)
// Stored at ~/Library/Application Support/MoonProwl Browser/bookmarks.json
final class BookmarkStore {
    static let shared = BookmarkStore()
    private struct Entry: Codable { var title: String; var url: String }
    private(set) var items: [(title: String, url: String)] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoonProwl Browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("bookmarks.json")
    }

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        items = decoded.map { ($0.title, $0.url) }
    }

    private func persist() {
        let entries = items.map { Entry(title: $0.title, url: $0.url) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(title: String, url: String) {
        if items.contains(where: { $0.url == url }) { return }
        items.append((title.isEmpty ? url : title, url))
        persist()
    }
    func remove(at i: Int) { if items.indices.contains(i) { items.remove(at: i); persist() } }
    func remove(url: String) { items.removeAll { $0.url == url }; persist() }
    func contains(url: String) -> Bool { items.contains { $0.url == url } }
}
// MARK: - Internal pages (served over the browser:// scheme)
enum BrowserPages {
    /// About page. `dark` is passed explicitly from the current theme so the
    /// page is correct even when served over the custom browser:// scheme (where
    /// prefers-color-scheme can be unreliable). No media queries — deterministic.
    static func aboutHTML(dark: Bool) -> String {
        let c = dark
            ? (bg: "#1C1B1F", surface: "#322F37", text: "#E6E1E5", sub: "#CAC4D0",
               dim: "#D0BCFF", body: "#CAC4D0", rule: "#6750A4", border: "#322F37",
               key: "#7C6BB0", asis: "#938F99")
            : (bg: "#FFFFFF", surface: "#FFFFFF", text: "#1D1B20", sub: "#49454F",
               dim: "#6750A4", body: "#333333", rule: "#6750A4", border: "#ECE6F0",
               key: "#7C6BB0", asis: "#79747E")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>About</title>
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); --purple: #6750A4; --purple-dim: #7c6bb0; }
          * { box-sizing: border-box; }
          html, body { height: 100%; }
          body {
            margin: 0;
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            background: \(c.bg); color: \(c.text);
            padding: 56px 64px;
            -webkit-font-smoothing: antialiased;
          }
          .wrap { width: 100%; border-left: 3px solid var(--purple); padding-left: 36px; }
          h1 {
            font-size: 44px; font-weight: 600; letter-spacing: -0.03em;
            margin: 0 0 4px; color: \(c.text);
          }
          .sub { font-size: 17px; color: \(c.sub); margin: 0 0 40px; }
          .rule { border-top: 1px solid var(--purple); margin: 0 0 28px; }
          .row { display: flex; gap: 32px; padding: 14px 0; border-bottom: 1px solid \(c.border); font-size: 15px; }
          .row .k { width: 150px; flex: none; color: var(--purple-dim); font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; padding-top: 2px; }
          .row .v { color: \(c.text); line-height: 1.5; }
          .copy { margin: 44px 0 8px; font-size: 15px; font-weight: 600; color: \(c.dim); }
          p { font-size: 15px; line-height: 1.6; margin: 0 0 12px; color: \(c.body); max-width: 720px; }
          .no { font-weight: 600; margin: 24px 0 8px; font-size: 15px; color: \(c.text); }
          ul { margin: 0; padding: 0; list-style: none; }
          li { font-size: 15px; line-height: 1.8; color: \(c.body); padding-left: 20px; position: relative; }
          li::before { content: "—"; position: absolute; left: 0; color: var(--purple); }
          .asis { color: \(c.asis); font-size: 12px; margin-top: 36px; font-family: "SF Mono", ui-monospace, Menlo, monospace; letter-spacing: 0.02em; }
        </style></head>
        <body>
          <div class="wrap">
            <h1>MoonProwl Browser</h1>
            <p class="sub">A lightweight WebKit browser for macOS.</p>
            <div class="rule"></div>
            <div class="row"><div class="k">Version</div><div class="v">1.0</div></div>
            <div class="row"><div class="k">Engine</div><div class="v">Apple WebKit (system framework)</div></div>
            <div class="row"><div class="k">Privacy</div><div class="v">Strong — no cookies or history written to disk</div></div>
            <div class="row"><div class="k">Author</div><div class="v">Kevin Chen</div></div>

            <p class="copy">Copyright (c) 2026 Kevin Chen</p>
            <p>This app is free to use for personal, non-commercial purposes only.</p>
            <p class="no">You may not:</p>
            <ul>
              <li>Sell, rent, or sublicense this app or any part of it.</li>
              <li>Use this app in any commercial product or service.</li>
              <li>Modify, reverse-engineer, or redistribute modified versions of this app.</li>
            </ul>
            <p class="asis">Provided "as is", without warranty of any kind.</p>
          </div>
        </body></html>
        """
    }

    static let notFoundHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <title>Not found</title>
    <style>body{font-family:-apple-system,sans-serif;background:#FEF7FF;color:#625B71;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}</style></head>
    <body><p>This internal page does not exist.</p></body></html>
    """
}

// MARK: - Internal "browser://" URL scheme handler (serves the About page etc.)
final class BrowserSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = BrowserSchemeHandler()
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url
        let host = url?.host ?? ""
        let body: String
        switch host {
        case "about": body = BrowserPages.aboutHTML(dark: Material.mode)
        default:      body = BrowserPages.notFoundHTML
        }
        let data = Data(body.utf8)
        let resp = HTTPURLResponse(url: url ?? URL(string: "browser://about")!,
                                   statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// WKWebView subclass.
//
// On macOS 26 WebKit's native context menu can't be customized the way we want,
// so we drive the menu from an app-level NSEvent monitor (see AppDelegate):
//   • right-click over an IMAGE  → swallow the click and show our custom
//     Save/Copy menu (the one thing we actually want to own).
//   • right-click anywhere else  → let the click through unchanged so WebKit
//     shows its real, stock context menu (text/link/selection/back/forward…).
// "Over an image" is detected synchronously from a hover probe cached by the
// mouseMoved monitor, so the click monitor can decide instantly whether to
// swallow the event or let native handle it.
final class KLBWebView: WKWebView {
    // Cached by the mouseMoved probe below: is the cursor currently over an <img>?
    var isOverImage: Bool = false
    var lastProbeX: CGFloat = -99999
    var lastProbeY: CGFloat = -99999

    // We deliberately do NOT override rightMouseDown: leaving the default lets
    // WebKit present its native menu whenever the click monitor lets the event
    // through (the non-image case).
    override func menu(for event: NSEvent) -> NSMenu? {
        // nil = use WebKit's default context menu. (An image right-click never
        // reaches here because the monitor swallows that event entirely.)
        return nil
    }

    /// Cheap hover probe: keep `isOverImage` fresh so the click monitor knows,
    /// synchronously, whether a right-click lands on an image. Throttled by the
    /// caller (only re-probes once the cursor moves a few points).
    func probeImageHover(atWindowPoint pt: NSPoint) {
        let local = convert(pt, from: nil)
        let js = """
        (function(){
            var x = \(local.x), y = \(local.y);
            var el = document.elementFromPoint(x, y), node = el, img = false;
            while(node && node !== document.body && node !== document.documentElement){
                if(node.tagName === 'IMG'){ img = true; break; }
                node = node.parentElement;
            }
            window.webkit.messageHandlers.klbHover.postMessage({ image: img });
        })();
        """
        evaluateJavaScript(js, completionHandler: { _, _ in })
    }

    /// Probe the DOM at a window-local point and post a message that the
    /// BrowserWindow turns into a contextual menu (image / selection / editable
    /// text). Used by BOTH double-click and middle-click (trackpad three-finger
    /// tap / middle mouse button) — macOS 26 WebKit swallows the DOM dblclick
    /// and there is no native middle-click menu, so we drive it from the
    /// app-level NSEvent monitor in BrowserWindow.
    func postContextMenu(atWindowPoint pt: NSPoint) {
        let local = convert(pt, from: nil)
        // `convert(_:from:)` with from:nil returns the point in this WebView's own
        // coordinate space. In AppKit that space already uses a top-left origin
        // (y increases downward) and matches the DOM's CSS pixel space for the
        // current viewport — so `local` is directly usable by
        // document.elementFromPoint(x, y). Do NOT flip Y here; that would mirror
        // the probe to the wrong half of the page (clicks on the top of an image
        // would hit empty space / <body> below it).
        let yCss = local.y
        // Bake the original click point into the payload so the context menu can
        // be popped at exactly where the user clicked. `pt` arrives in window
        // coordinates (event.locationInWindow), but the Material panel is placed
        // with setFrameOrigin, which expects GLOBAL screen coordinates — so
        // convert here. (The at-document DOM probe below still uses the
        // window-local `pt` via convert(_:from:nil), which is correct.)
        let screenPt = self.window?.convertPoint(toScreen: pt) ?? pt
        let js = """
        (function(){
            var x = \(local.x), y = \(yCss);
            var el = document.elementFromPoint(x, y);
            var img = null, node = el;
            while(node && node !== document.body && node !== document.documentElement){
                if(node.tagName === 'IMG'){ img = node; break; }
                node = node.parentElement;
            }
            var payload = { x: x, y: y, image: null, screenX: \(screenPt.x), screenY: \(screenPt.y) };
            if(img){
                var src = img.currentSrc || img.src;
                if(src){
                    payload.image = { src: src, srcAbs: new URL(src, location.href).href };
                    try {
                        var c = document.createElement('canvas');
                        c.width = img.naturalWidth || img.width;
                        c.height = img.naturalHeight || img.height;
                        c.getContext('2d').drawImage(img, 0, 0);
                        payload.image.imgData = c.toDataURL('image/png');
                    } catch(e) {}
                }
            }
            window.webkit.messageHandlers.klbCtx.postMessage(payload);
        })();
        """
        evaluateJavaScript(js, completionHandler: { _, _ in })
    }
}

// MARK: - Tab: owns one WKWebView + its navigation/UI state
final class Tab: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: KLBWebView!
    weak var owner: BrowserWindow?
    var title: String = "New Tab"
    /// True when this tab is on the home page (or hasn't loaded a URL yet).
    /// The start page can carry a trailing query (?i=1 etc.), so match on host+path.
    var isHomepage: Bool {
        guard let comps = URL(string: webView.url?.absoluteString ?? "") else { return true }
        guard let host = comps.host, let path = comps.path.isEmpty ? "/" : Optional(comps.path) else { return true }
        let homeHost = "vanilostartpage.is-best.net"
        let homePath = "/"
        return host == homeHost && path == homePath
    }
    var button: NSButton!      // the clickable tab in the tab bar
    var closeButton: NSButton!
    // Host captured at the start of a navigation. webView.url is often nil at
    // didCommit on macOS, so we remember it here and use it to drive autofill.
    var pendingHost: String?
    /// Set once we've offered to autofill for the current navigation, so we
    /// don't pop the "Fill password?" sheet twice (e.g. on redirects that
    /// fire didFinish more than once).
    var autofillOffered = false
    var chip: MaterialChip?    // the rounded chip container for this tab

    init(owner: BrowserWindow, configuration: WKWebViewConfiguration? = nil) {
        self.owner = owner
        let config: WKWebViewConfiguration
        if let provided = configuration {
            // Popup (window.open) config from WebKit: it is bound to the opener's
            // browsing context. MUTATING IT (e.g. replacing websiteDataStore)
            // makes WKWebView throw NSException and crash — use it verbatim.
            // It already inherits the opener's non-persistent store.
            config = provided
        } else {
            config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()   // no cookies/cache/history on disk
            // JS is controlled globally (PrivacyConfig.blockJS). The navigation
            // delegate re-applies it per load so it can never drift.
            config.defaultWebpagePreferences.allowsContentJavaScript = !PrivacyConfig.blockJS
            // Enable HTML5 element fullscreen (YouTube/Vimeo fullscreen button).
            config.preferences.setValue(true, forKey: "fullScreenEnabled")
            // Register the internal "browser://" scheme so pages like the About
            // page get a real URL in the address bar instead of about:blank.
            config.setURLSchemeHandler(BrowserSchemeHandler.shared, forURLScheme: "browser")
            let userScript = WKUserScript(source: Tab.pwScript,
                                          injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(userScript)
            // YouTube watch-history -> ad-profiling breaker. Always injected; gated at
            // runtime by window.__klbYoutubeOn (set by the flag script below, re-asserted
            // live when the toggle flips). Order: flag script first, then the worker.
            config.userContentController.addUserScript(Tab.youtubeFlagScript(PrivacyConfig.youtubePrivacy))
            config.userContentController.addUserScript(WKUserScript(source: Tab.youtubePrivacyScript,
                                                                     injectionTime: .atDocumentStart, forMainFrameOnly: true))
            // Tracker/content blocking via a compiled rules list (no network here).
            if PrivacyConfig.blockTrackers, let rules = Blocklist.shared.rulesList {
                config.userContentController.add(rules)
            }
        }
        super.init()
        // IMPORTANT: register the script-message handlers BEFORE the WKWebView is
        // created. WebKit snapshots the WKUserContentController (user scripts AND
        // message handlers) into the web view at creation time; handlers added
        // AFTER creation are NOT picked up by the live web view, so pwSave /
        // klbCtx messages would silently never reach Swift. removeScriptMessageHandler
        // first: a popup config can already carry a "pwSave" handler from the opener,
        // and adding a duplicate name throws NSException.
        config.userContentController.removeScriptMessageHandler(forName: "pwSave")
        config.userContentController.add(self, name: "pwSave")
        config.userContentController.removeScriptMessageHandler(forName: "klbCtx")
        config.userContentController.add(self, name: "klbCtx")
        config.userContentController.removeScriptMessageHandler(forName: "klbHover")
        config.userContentController.add(self, name: "klbHover")
        webView = KLBWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        // Opaque by default (no transparency toggling — avoids the macOS 26
        // render-loop flash). The in-page load tint in pwScript prevents white flash.
        webView.appearance = NSAppearance(named: Material.mode ? .darkAqua : .aqua)
        // Generic Chrome UA by default — hides WebKit/Safari signature and this app,
        // so fingerprinting sees a common, unidentifiable browser.
        if PrivacyConfig.spoofUserAgent {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }
        // When a video enters HTML5 fullscreen, WebKit opens a SEPARATE fullscreen
        // window over ours; macOS then marks our window "occluded" and WKWebView
        // suspends rendering to save power -> the fullscreen video (still parented
        // to the suspended content) goes black while audio keeps playing.
        // Disabling occlusion detection keeps the web content rendering. This is a
        // private selector, so guard it so a future OS change can't crash us.
        let occSel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occSel) {
            webView.perform(occSel, with: false as NSNumber)
        }
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "canGoBack", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "canGoForward", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
    }

    func loadRaw(_ s: String) { if let u = URL(string: s) { webView.load(URLRequest(url: u)) } }

    func teardown() {
        for k in ["estimatedProgress","canGoBack","canGoForward","URL","title"] {
            webView.removeObserver(self, forKeyPath: k)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pwSave")
    }

    var isActive: Bool { owner?.activeTab === self }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                              change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let owner = owner else { return }
        switch keyPath {
        case "estimatedProgress":
            if isActive {
                owner.progress.doubleValue = webView.estimatedProgress
                owner.progress.isHidden = webView.estimatedProgress >= 1.0
            }
        case "canGoBack": if isActive { owner.backBtn.isEnabled = webView.canGoBack }
        case "canGoForward": if isActive { owner.fwdBtn.isEnabled = webView.canGoForward }
        case "URL":
            if isActive {
                owner.urlField.stringValue = (self.isHomepage ? "" : (webView.url?.absoluteString ?? ""))
                owner.updateStar()
            }
        case "title":
            title = webView.title?.isEmpty == false ? webView.title! : "New Tab"
            owner.refreshTabTitles()
            if isActive { owner.window.title = "\(title) — MoonProwl Browser" }
        default: break
        }
    }

    private struct PendingMedia { var camera: ((WKPermissionDecision) -> Void)?; var mic: ((WKPermissionDecision) -> Void)?; var combined: Bool = false; var timer: Timer? }
    private var pendingMediaHandlers: [WKSecurityOrigin: PendingMedia] = [:]

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.isEmpty ? "This site" : origin.host

        // Pull or create pending state for this origin.
        var p = pendingMediaHandlers[origin] ?? PendingMedia(camera: nil, mic: nil, combined: false, timer: nil)

        // Store the incoming handler according to request type.
        switch type {
        case .camera: p.camera = decisionHandler
        case .microphone: p.mic = decisionHandler
        case .cameraAndMicrophone:
            // A single handler covers BOTH — must be called exactly once.
            p.camera = decisionHandler
            p.mic = nil
            p.combined = true
        @unknown default: p.camera = decisionHandler
        }

        let bothPending = p.combined || (p.camera != nil && p.mic != nil)

        // If both camera and mic are needed right now, fire one combined prompt.
        // Otherwise set a short timer: if the partner request arrives, the timer
        // is replaced; if not, the prompt fires for whichever arrived.
        if bothPending {
            p.timer?.invalidate()
            p.timer = nil
            pendingMediaHandlers.removeValue(forKey: origin)
            let handlers = p
            owner?.askPermission(title: "Allow camera and microphone?", msg: "\(host) wants to use your camera and microphone.") { granted in
                let d: WKPermissionDecision = granted ? .grant : .deny
                Self.answer(handlers, decision: d)
            }
        } else {
            p.timer?.invalidate()
            let t = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                guard let p2 = self.pendingMediaHandlers[origin] else { return }
                self.pendingMediaHandlers.removeValue(forKey: origin)
                let what: String
                if p2.combined || (p2.camera != nil && p2.mic != nil) { what = "camera and microphone" }
                else if p2.camera != nil { what = "camera" }
                else { what = "microphone" }
                self.owner?.askPermission(title: "Allow \(what)?", msg: "\(host) wants to use your \(what).") { granted in
                    let d: WKPermissionDecision = granted ? .grant : .deny
                    Self.answer(p2, decision: d)
                }
            }
            p.timer = t
            pendingMediaHandlers[origin] = p
        }
    }

    // Geolocation is denied by default — sharing precise location is a strong
    // privacy leak and most sites have no legitimate need for it. We never prompt.
    func webView(_ webView: WKWebView,
                 requestGeolocationPermissionFor frame: WKFrameInfo,
                 decisionHandler: @escaping (Bool) -> Void) {
        decisionHandler(false)
    }

    // Invoke each distinct decisionHandler exactly once. For a combined request
    // camera and mic share ONE handler, so calling both would throw NSException.
    private static func answer(_ p: PendingMedia, decision d: WKPermissionDecision) {
        if p.combined {
            p.camera?(d)          // single handler covers both
        } else {
            p.camera?(d)
            p.mic?(d)
        }
    }


    // Password save
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "klbCtx" {
            guard let dict = message.body as? [String: Any], let owner = owner else { return }
            // Right-click over an image: our custom Save/Copy menu. Anything that
            // isn't an image is handled by WebKit's native menu (we never reach
            // here for those — the click monitor lets the native event through).
            if let img = dict["image"] as? [String: Any] {
                var items: [(title: String, icon: NSImage?, action: () -> Void)] = []
                if let imgData = img["imgData"] as? String, imgData.hasPrefix("data:image") {
                    items.append((title: "Save Image",
                                  icon: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil),
                                  action: { [weak owner] in owner?.doSaveImageData(imgData) }))
                    items.append((title: "Copy Image",
                                  icon: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
                                  action: { [weak owner] in owner?.doCopyImageData(imgData) }))
                } else if let src = (img["srcAbs"] as? String) ?? (img["src"] as? String), let u = URL(string: src) {
                    items.append((title: "Save Image",
                                  icon: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil),
                                  action: { [weak owner] in owner?.doDownloadURL(u) }))
                    items.append((title: "Copy Image URL",
                                  icon: NSImage(systemSymbolName: "link", accessibilityDescription: nil),
                                  action: { [weak owner] in owner?.doCopyImageURL(u) }))
                }
                if !items.isEmpty {
                    let m = MaterialContextMenu(items: items)
                    let sx = (dict["screenX"] as? Double) ?? NSEvent.mouseLocation.x
                    let sy = (dict["screenY"] as? Double) ?? NSEvent.mouseLocation.y
                    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: sx, y: sy)) }) ?? NSScreen.main
                    var origin = NSPoint(x: sx, y: sy - m.frame.height)
                    if let s = screen {
                        let vf = s.visibleFrame
                        if origin.x + m.frame.width > vf.maxX { origin.x = vf.maxX - m.frame.width }
                        if origin.y < vf.minY { origin.y = vf.minY }
                        if origin.x < vf.minX { origin.x = vf.minX }
                    }
                    m.setFrameOrigin(origin)
                    m.orderFront(nil)
                }
            }
            return
        }
        if message.name == "klbHover" {
            guard let dict = message.body as? [String: Any], let owner = owner else { return }
            let over = (dict["image"] as? Bool) ?? false
            owner.activeTab?.webView.isOverImage = over
            return
        }
        guard message.name == "pwSave", let dict = message.body as? [String: Any],
              let user = dict["user"] as? String, let pass = dict["pass"] as? String,
              let host = dict["host"] as? String, !pass.isEmpty else {
            NSLog("[klb-pwsave] guard failed: name=%@ body=%@", message.name, String(describing: message.body))
            return
        }
        if PasswordStore.shared.exists(host: host, user: user, pass: pass) { NSLog("[klb-pwsave] duplicate, skip"); return }
        // Secondary check: same host + password already stored under a
        // different (or empty) username means it's the same account — don't
        // re-prompt just because username detection differed.
        if PasswordStore.shared.exists(host: host, pass: pass) { NSLog("[klb-pwsave] duplicate(host+pass), skip"); return }
        guard let owner = owner else { return }
        NSLog("[klb-pwsave] prompting for %@ on %@", user, host)
        let alert = NSAlert()
        alert.messageText = "Save password?"
        alert.informativeText = "Save the password for \(user.isEmpty ? host : user) on \(host)?\nStored in MoonProwl Browser only — view or delete it any time in the Passwords sidebar (🔑)."
        alert.addButton(withTitle: "Save Password")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: owner.window) { r in
            if r == .alertFirstButtonReturn {
                PasswordStore.shared.save(host: host, user: user, pass: pass)
                owner.rebuildPasswordList()
            }
        }
    }

    // Autofill saved credentials for this host from PasswordStore.
    // Called at BOTH didCommit (earliest possible moment) and didFinish (safety
    // net — atDocumentEnd user scripts are guaranteed present by then). The
    // injected filler dedupes, and a MutationObserver catches late SPA fields,
    // so there are no fixed delays anywhere.
    private func autofill(_ webView: WKWebView) {
        let host = webView.url?.host ?? pendingHost
        guard let host = host else { return }
        let creds = PasswordStore.shared.credentials(forHost: host)
        guard !creds.isEmpty else { return }
        // Only offer once per navigation (didFinish can fire on redirects).
        if autofillOffered { return }
        autofillOffered = true
        // Show a dialog so the user can choose whether to fill.
        // This avoids calling __klbFill too early (before the user
        // script defines it) or silently skipping because the timing
        // was wrong (e.g. webView.url still pointing at previous host).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let window = BrowserWindow.windows.first else { return }
            // Only prompt when the page actually has a password field. This
            // stops the sheet from appearing on every other page of a saved
            // host (dashboards, articles, settings) that has no login form.
            webView.evaluateJavaScript("!!document.querySelector('input[type=password]')") { has, _ in
                guard (has as? Bool) == true else {
                    // No password field here — allow a later SPA page to prompt.
                    self.autofillOffered = false
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Fill password?"
                alert.informativeText = "Saved credentials for \(host). Fill \(creds.count) credential(s)?"
                alert.addButton(withTitle: "Fill")
                alert.addButton(withTitle: "Skip")
                alert.beginSheetModal(for: window.window) { response in
                    if response == .alertFirstButtonReturn {
                        // Small delay to let WebKit settle after the modal sheet.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.performAutofill(webView: webView, host: host, creds: creds)
                        }
                    }
                }
            }
        }
    }

    private func performAutofill(webView: WKWebView, host: String, creds: [Credential]) {
        // Inject a self-contained fill script that does NOT depend on
        // __klbFill being defined. This avoids the indirection through
        // the pwScript's MutationObserver-based filler which can fail
        // silently if tryFill() finds no password fields at call time.
        let arr = creds.map { c -> String in
            let u = c.user.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let p = c.pass.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "{user:\"\(u)\",pass:\"\(p)\"}"
        }.joined(separator: ",")
        let js = """
        (function(){
          var creds = [\(arr)];
          function setVal(el, val){
            if(!el) return;
            try {
              var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
              setter.call(el, val);
              el.dispatchEvent(new Event('input',{bubbles:true}));
              el.dispatchEvent(new Event('change',{bubbles:true}));
            } catch(e){ el.value = val; }
          }
          var pws = document.querySelectorAll('input[type=password]');
          if(!pws.length) return;
          var pw = pws[0], c = creds[0];
          var allInputs = document.querySelectorAll('input[type=text],input[type=email],input[type=tel],input:not([type])');
          var uf = null;
          // Strategy 1: find the text-like input that PRECEDES the password field.
          // compareDocumentPosition returns where its argument sits relative to
          // the caller; DOCUMENT_POSITION_PRECEDING means the argument is before
          // `pw`, i.e. the username field.
          for(var i=0;i<allInputs.length;i++){
            if(pw.compareDocumentPosition(allInputs[i]) & Node.DOCUMENT_POSITION_PRECEDING){ uf = allInputs[i]; break; }
          }
          // Strategy 2: find the input immediately after the password field.
          if(!uf){
            for(var i=allInputs.length-1;i>=0;i--){
              if(pw.compareDocumentPosition(allInputs[i]) & Node.DOCUMENT_POSITION_FOLLOWING){ uf = allInputs[i]; break; }
            }
          }
          // Strategy 3: use the first empty text-like input on the page.
          if(!uf){
            for(var i=0;i<allInputs.length;i++){
              if(!allInputs[i].value){ uf = allInputs[i]; break; }
            }
          }
          // Strategy 4: use the first text-like input.
          if(!uf && allInputs.length){ uf = allInputs[0]; }
          if(uf && c.user) setVal(uf, c.user);
          setVal(pw, c.pass);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: { _, err in
            if let err = err { print("[autofill] JS error for \(host):", err.localizedDescription) }
        })
    }


    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pendingHost = webView.url?.host ?? pendingHost
        autofillOffered = false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // No transparency toggling (avoids the macOS 26 render-loop flash).
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingHost = webView.url?.host ?? pendingHost
        autofill(webView)
        // Also trigger save detection at didFinish in case
        // the user filled a form but no input/submit event fired.
        // This catches SPA navigations where the form state
        // persists but no native events are triggered.
        webView.evaluateJavaScript("if(typeof reportSave==='function') reportSave()", completionHandler: { _, _ in })
    }

    // Decide, per response, whether to render inline or download.
    // Only force a DOWNLOAD when BOTH:
    //   - it's the main-frame response (not a subresource XHR/fetch/image), and
    //   - WebKit genuinely cannot render this MIME type (zip, dmg, binary, etc.).
    // Otherwise we let WebKit do its normal thing: renderable pages show inline
    // (no white flash) and true attachment/binary responses still become downloads
    // via the didBecome-download delegate below.
    // Capture the true destination host as early as possible so autofill()
    // can look up credentials for the site the user is actually navigating to.
    // webView.url at didStart/didCommit often still holds the previous page's
    // host, so we read the request URL from the navigationAction instead.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let host = url.host ?? ""
        // GLOBAL JavaScript enforcement. WebKit reads defaultWebpagePreferences fresh
        // for each top-level navigation, so this single global switch (no per-site
        // list) applies to EVERY site, every load.
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = !PrivacyConfig.blockJS
        pendingHost = host
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.response.url?.scheme == "browser" { decisionHandler(.allow); return }
        // On macOS 26 / Safari 26 WebKit no longer renders PDFs inline (it hands them
        // to the system), so canShowMIMEType is false for PDFs — they become a download.
        // We let the navigation become a WKDownload and save the bytes to ~/Downloads.
        // Any other non-renderable main-frame type also becomes a download.
        let isPDF = (navigationResponse.response as? HTTPURLResponse)?.mimeType == "application/pdf"
                   || navigationResponse.response.mimeType == "application/pdf"
        if navigationResponse.isForMainFrame && (isPDF || !navigationResponse.canShowMIMEType) {
            decisionHandler(.download); return
        }
        decisionHandler(.allow)
    }

    // A navigation turned into a download (attachment, "Save As", binary file, etc.)
    // WebKit would normally hand us a WKDownload, but we run our own byte-accurate
    // download task instead (real progress, no size cap, carries cookies). So we
    // just grab the URL and let the window's download manager take over.
    // A navigation turned into a download — hand the REAL WKDownload to the manager
    // so cookies/auth/redirects are preserved (this is why downloads actually work).
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        owner?.startDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner?.startDownload(download)
    }

    // target=_blank / window.open -> open in a NEW TAB.
    // Return a real webView built from the provided configuration so pages that
    // open a blank window and then set its location (e.g. Bing on the startpage)
    // actually navigate, instead of appearing to revert to the homepage.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Pop-up blocking: deny window.open / target=_blank entirely. Malicious sites
        // use popups for popunders, redirect spam, and click-fraud iframes. When a user
        // explicitly wants a link in a new tab they use Cmd+Click / the new-tab button.
        if PrivacyConfig.blockPopups { return nil }
        guard let owner = owner else { return nil }
        let newWV = owner.newTabForPopup(configuration: configuration)
        // If the URL is already known (target=_blank on a real link), load it now.
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty {
            newWV.load(URLRequest(url: url))
        }
        return newWV
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let owner = owner else { completionHandler(); return }
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.beginSheetModal(for: owner.window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let owner = owner else { completionHandler(false); return }
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: owner.window) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    // File upload / picker: WebKit calls this when a site triggers <input type="file">.
    // Without it, the picker never opens and file selection silently does nothing.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    static let pwScript = """
    (function(){
      // App-controlled page styling: blue text-selection highlight, and a
      // page background color that matches the OS theme.
      // Always run fresh on each navigation (even SPA pushState/replaceState
      // navigations within the same tab can leave stale __klbPwInit).
      window.__klbPwInit = true;

      // App-controlled page styling: purple text-selection highlight, and a
      // page background color that matches the OS theme. We read the ACTUAL
      // prefers-color-scheme (the web view's appearance drives this, so it's
      // correct even on a redirect/navigation that re-runs this script) instead
      // of a fixed white default — that's what kills the white flash on the
      // second hop of a redirect like google.com -> google.com/?i=1.
      var s = document.createElement('style');
      s.id = '__klb_style';
      s.textContent = [
        '::selection, ::-moz-selection { background: rgba(103,80,164,0.35); color: inherit; }'
      ].join(String.fromCharCode(10));
      (document.head || document.documentElement).appendChild(s);

      // Loading background that matches the OS theme. This is ONLY a fallback shown
      // while the page is still painting — it is removed on window 'load' (below), so
      // once the site's own CSS is in, it takes over. We NEVER force a background onto
      // a site that defines its own; this just stops the WebView's default WHITE flash
      // (in dark mode especially) during the blank moment before first paint.
      var bg = document.createElement('style');
      bg.id = '__klb_bg';
      bg.textContent = [
        ':root { --klb-bg: #FEF7FF; }',
        '@media (prefers-color-scheme: dark) { :root { --klb-bg: #1C1B1F; } }',
        'html { background: var(--klb-bg); }'
      ].join(String.fromCharCode(10));
      (document.head || document.documentElement).appendChild(bg);
      // Remove the fallback bg once the page has actually loaded/painted, so we never
      // override a site's own colors (no forced black background on sites).
      window.addEventListener('load', function(){ var b = document.getElementById('__klb_bg'); if (b) b.remove(); });
      setTimeout(function(){ var b = document.getElementById('__klb_bg'); if (b) b.remove(); }, 4000);

      // Legacy getUserMedia shim: old sites call navigator.getUserMedia(constraints, ok, err)
      // which modern WebKit removed. Map it onto mediaDevices.getUserMedia.
      function cleanConstraints(c){
        if (!c || typeof c !== 'object') return c;
        var out = {};
        for (var k in c){
          if (k === 'audio' || k === 'video'){
            var v = c[k];
            if (v && typeof v === 'object' && (v.mandatory || v.optional)) out[k] = true;
            else out[k] = v;
          } else out[k] = c[k];
        }
        return out;
      }
      if (!navigator.getUserMedia && navigator.mediaDevices && navigator.mediaDevices.getUserMedia){
        navigator.getUserMedia = function(constraints, ok, err){
          navigator.mediaDevices.getUserMedia(cleanConstraints(constraints)).then(ok, err || function(){});
        };
        navigator.webkitGetUserMedia = navigator.getUserMedia;
        navigator.mozGetUserMedia = navigator.getUserMedia;
      }

      function findPwFields(root){
        return Array.prototype.slice.call((root||document).querySelectorAll('input[type=password]'));
      }
      function findUserField(pw){
        // 4-strategy username detection:
        // 1. Check preceding sibling (most common)
        // 2. Check following sibling
        // 3. Find first visible empty (or shortest) username field
        // 4. First visible username field on page
        var all = Array.prototype.slice.call(document.querySelectorAll(
          'input[type=text],input[type=email],input[type=tel],input:not([type])'));
        all = all.filter(function(f){ return f.offsetParent !== null; });
        
        // Strategy 1: Preceding
        for (var i=0; i<all.length; i++) {
          var f = all[i];
          if (pw.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_PRECEDING) {
            return f;
          }
        }
        // Strategy 2: Following
        for (var i=0; i<all.length; i++) {
          var f = all[i];
          if (pw.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING) {
            return f;
          }
        }
        // Strategy 3: First visible field
        if (all.length > 0) return all[0];
        // Strategy 4: Search in shadow DOM
        var shadowRoots = document.querySelectorAll('*');
        for (var i=0; i<shadowRoots.length; i++) {
          if (shadowRoots[i].shadowRoot) {
            var fields = shadowRoots[i].shadowRoot.querySelectorAll(
              'input[type=text],input[type=email],input[type=tel]');
            if (fields.length > 0) return fields[0];
          }
        }
        return null;
      }

      // ---- SAVE: cache credentials on every keystroke. Sites that clear the
      // fields or navigate instantly can no longer defeat detection, because
      // we report the CACHE, not the live DOM.
      var cache = {user:'', pass:''};
      var reported = '';
      var submitted = false;
      document.addEventListener('input', function(e){
        var t = e.target; if(!t || t.tagName !== 'INPUT') return;
        if (t.type === 'password') { if(t.value) cache.pass = t.value; }
        else if (['text','email','tel',''].indexOf(t.type||'') >= 0) { if(t.value) cache.user = t.value; }
      }, true);
      // Also listen for change events (catches browser autofill/paste):
      document.addEventListener('change', function(e){
        var t = e.target; if(!t || t.tagName !== 'INPUT') return;
        if (t.type === 'password') { if(t.value) cache.pass = t.value; }
        else if (['text','email','tel',''].indexOf(t.type||'') >= 0) { if(t.value) cache.user = t.value; }
      }, true);

      function reportSave(){
        try {
          if (!submitted) return;   // only honor a real submit signal, never keystrokes
          // Prefer live DOM values; fall back to the keystroke cache.
          var pass = '', user = '';
          var pws = findPwFields().filter(function(p){return p.value && p.value.length;});
          if (pws.length) {
            pass = pws[0].value;
            var uf = findUserField(pws[0]);
            user = uf ? (uf.value||'') : cache.user;
          } else {
            pass = cache.pass; user = cache.user;
          }
          if (!pass) return;
          var key = user + '\\u0001' + pass;
          if (key === reported) return;   // don't spam duplicate prompts
          reported = key;
          window.webkit.messageHandlers.pwSave.postMessage({user:user, pass:pass, host:location.hostname});
        } catch(e){}
      }

      // Save detection: only fire on a genuine submit signal — never on
      // keystrokes. Prompting the moment a single password character appears
      // is wrong; we wait until the user actually submits the login form.
      document.addEventListener('submit', function(){ submitted = true; reportSave(); }, true);
      document.addEventListener('keydown', function(e){
        if(e.key === 'Enter' && e.target && e.target.type === 'password') { submitted = true; reportSave(); }
      }, true);
      document.addEventListener('blur', function(e){
        if(e.target && e.target.tagName === 'INPUT') { submitted = true; reportSave(); }
      }, true);
      document.addEventListener('change', function(e){
        if(e.target && e.target.tagName === 'INPUT') { submitted = true; reportSave(); }
      }, true);
      // Only a click on a submit-like control counts as a submit signal.
      document.addEventListener('click', function(e){
        var t = e.target; if(!t) return;
        var el = t.closest ? t.closest('button,input[type=submit],input[type=button],[role=button],a,form') : null;
        if(el) { submitted = true; reportSave(); }
      }, true);
      // pagehide/beforeunload fire on navigation (e.g. the form POSTs and the
      // page unloads) — that's the real moment a credential was submitted.
      window.addEventListener('pagehide', function(){ submitted = true; reportSave(); }, true);
      window.addEventListener('beforeunload', function(){ submitted = true; reportSave(); }, true);
      document.addEventListener('visibilitychange', function(){
        if (document.visibilityState === 'hidden') { submitted = true; reportSave(); }
      }, true);

      // ---- AUTOFILL: fill immediately if fields exist; otherwise observe the
      // DOM and fill the moment a password field appears. No fixed delays.
      var pendingCreds = null;
      var filled = false;
      function setVal(el, val){
        if(!el) return;
        try {
          var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
          setter.call(el, val);
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
        } catch(e){ el.value = val; }
      }
      function tryFill(){
        if (filled || !pendingCreds || !pendingCreds.length) return false;
        var pws = findPwFields();
        if (!pws.length) return false;
        var pw = pws[0], c = pendingCreds[0];
        var uf = findUserField(pw);
        if (uf && c.user) setVal(uf, c.user);
        setVal(pw, c.pass);
        filled = true;
        if (window.__klbObserver) { window.__klbObserver.disconnect(); window.__klbObserver = null; }
        return true;
      }
      window.__klbFill = function(creds){
        pendingCreds = creds; filled = false;
        if (tryFill()) return;
        // Field not in DOM yet (SPA still rendering) — watch for it.
        if (window.__klbObserver) window.__klbObserver.disconnect();
        window.__klbObserver = new MutationObserver(function(){ tryFill(); });
        var root = document.body || document.documentElement;
        if (root) window.__klbObserver.observe(root, {childList:true, subtree:true});
        // Hard stop after 15s so we never observe forever.
        setTimeout(function(){ if(window.__klbObserver){window.__klbObserver.disconnect(); window.__klbObserver=null;} }, 15000);
      };

      // Right-click / middle-click context menus are driven from the app-level
      // NSEvent monitor (see AppDelegate), which calls postContextMenu() and
      // pops a custom NSMenu. KLBWebView suppresses WebKit's native menu.
    })();
    """
    // YouTube ad-personalization breaker. Runs on youtube.com only. It is ALWAYS
    // injected, but acts only when window.__klbYoutubeOn is true (set by a companion
    // flag script that re-runs at the start of every navigation). Toggling the setting
    // re-asserts window.__klbYoutubeOn live, which is why the toggle takes effect on an
    // already-open tab. The work is deferred via setTimeout(0) so it runs AFTER the flag
    // script has set the value regardless of user-script injection order.
    // Pure client-side, no network: severs the watch-history -> ad-profile link by
    // (a) rotating YouTube's VISITOR_INFO1_LIVE continuity token every visit, and
    // (b) setting Google's documented ad-preference cookie (PREF f2=8000000 & f6=2) to
    // opt out of interest-based / personalized ads. Combined with the generic UA and
    // third-party-cookie block, this makes view behavior far harder to monetize.
    // NOTE: most effective when signed OUT of Google; a logged-in account still
    // personalizes via the account itself.
    static let youtubePrivacyScript = """
    (function(){
      setTimeout(function(){
        try {
          if (!window.__klbYoutubeOn) return;
          if (location.hostname.indexOf('youtube.com') === -1) return;
          function rotVisitor(){
            var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
            var v = '';
            for (var i = 0; i < 11; i++) v += chars.charAt(Math.floor(Math.random() * chars.length));
            var exp = new Date(Date.now() + 365 * 864e5).toUTCString();
            document.cookie = 'VISITOR_INFO1_LIVE=' + v + '; domain=.youtube.com; path=/; expires=' + exp;
            document.cookie = 'VISITOR_INFO1_LIVE=' + v + '; domain=youtube.com; path=/; expires=' + exp;
          }
          rotVisitor();
          var exp = new Date(Date.now() + 365 * 864e5).toUTCString();
          document.cookie = 'PREF=f2=8000000&f6=2; domain=.youtube.com; path=/; expires=' + exp;
          document.cookie = 'PREF=f2=8000000&f6=2; domain=youtube.com; path=/; expires=' + exp;
          window.addEventListener('beforeunload', rotVisitor);
        } catch (e) {}
      }, 0);
    })();
    """
    // Companion flag script: sets window.__klbYoutubeOn at the start of every
    // navigation. Re-asserted live by applyYouTubePrivacy() when the toggle flips.
    static func youtubeFlagScript(_ on: Bool) -> WKUserScript {
        return WKUserScript(source: "window.__klbYoutubeOn = \(on);",
                             injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

// MARK: - Browser window: manages tabs, toolbar, tab bar
// MARK: - Ad-block (content blocker via WKContentRuleList)
// A lightweight, toggleable blocker. A curated domain list is bundled as
// blocklist.json; the user can also add custom block/allow entries. Rules are
// compiled once into a WKContentRuleList and attached to every web view config.
final class BrowserWindow: NSObject, NSTextFieldDelegate, WKDownloadDelegate {
    let window: NSWindow
    let urlField: NSTextField
    var content: NSView!
    var toolbarView: MaterialBar!
    var tabHostView: MaterialBar!
    let progress: MaterialProgress
    var backBtn: MaterialIconButton!
    var fwdBtn: MaterialIconButton!
    var starBtn: NSButton!
    var themeBtn: NSButton!
    var newTabBtn: MaterialIconButton!
    // Every toolbar icon button, collected so applyTheme can recolor them all.
    var toolbarButtons: [MaterialIconButton] = []
    var settingsWindows: [NSWindow] = []

    var tabs: [Tab] = []
    var activeTab: Tab!
    let webContainer = NSView()      // holds the active tab's webView
    let webBackdrop = NSView()        // solid color behind the (transparent) web view — fixes white flash
    let tabBar = NSStackView()       // horizontal row of tab buttons
    let tabBarScroll = NSScrollView()

    // Sidebar (right side, collapsible) — shows Bookmarks OR Passwords
    enum SidebarMode { case bookmarks, passwords, downloads }
    let sidebar = MaterialBar()
    let sidebarStack = NSStackView()
    var sidebarWidth: NSLayoutConstraint!
    var sidebarOpen = false
    var sidebarMode: SidebarMode = .bookmarks
    // Active downloads: filename, progress object, finished flag, file URL.
    struct DownloadItem { let id: Int; var name: String; let progress: Progress; var finished: Bool; var url: URL?; var failed: Bool; var download: WKDownload?; var destURL: URL? }
    var downloads: [DownloadItem] = []
    var downloadSeq = 0
    var downloadObservers: [Int: Any] = [:]   // progress poll timer OR KVO observation per download
    // Serialized permission-prompt queue (see askPermission).
    var permQueue: [(String, String, (Bool) -> Void)] = []
    var permShowing = false
    var sidebarHeader: NSTextField!
    var sidebarClearBtn: MaterialIconButton!

    static var windows: [BrowserWindow] = []   // keep strong refs to all open windows

    override init() {
        LaunchLog("BrowserWindow.init start")
        urlField = NSTextField()
        urlField.placeholderString = "Search or enter address"
        let ph = NSAttributedString(string: "Search or enter address",
            attributes: [.foregroundColor: Material.outline])
        urlField.placeholderAttributedString = ph
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .none
        urlField.font = NSFont.systemFont(ofSize: 13)
        // Single-line: the address never wraps to a new line. Long URLs extend to
        // the right and scroll horizontally instead of pushing the field taller.
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byClipping
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false

        progress = MaterialProgress()
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MoonProwl Browser"
        // Disable macOS native window tabbing so "New Window" always opens a real
        // separate window — even in fullscreen — instead of a native tab up top.
        window.tabbingMode = .disallowed
        // Allow native macOS fullscreen (green button + View > Enter Full Screen).
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        // Needed so the app-level mouseMoved monitor (image-hover probe) gets events.
        window.acceptsMouseMovedEvents = true
        super.init()
        LaunchLog("BrowserWindow super.init done")

        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(navigateFromField)

        buildChrome()
        BrowserWindow.windows.append(self)
        LaunchLog("newTab(HOMEPAGE) start")
        newTab(url: HOMEPAGE)
        LaunchLog("newTab done")
        window.makeKeyAndOrderFront(nil)
        LaunchLog("window ordered front")
    }

    // MARK: Chrome layout: [toolbar] [tab bar] [progress] [web]
    func buildChrome() {
        let content = MaterialBar()
        content.fillVar = false
        content.shadowLine = false
        self.content = content
        content.autoresizingMask = [.width, .height]

        backBtn = makeBtn("chevron.backward", #selector(goBack))
        fwdBtn  = makeBtn("chevron.forward", #selector(goForward))
        let reload = makeBtn("arrow.clockwise", #selector(reloadPage))
        let home = makeBtn("house.fill", #selector(goHome))
        let bookmarkAdd = makeBtn("star", #selector(addBookmark))
        starBtn = bookmarkAdd
        let bookmarksList = makeBtn("book.fill", #selector(showBookmarks))
        let passwordsBtn = makeBtn("key.fill", #selector(showPasswords))
        let downloadsBtn = makeBtn("arrow.down.circle", #selector(showDownloads))
        let themeToggle = makeBtn("sun.max.fill", #selector(toggleTheme))
        themeBtn = themeToggle
        let newTabBtnLocal = makeBtn("plus", #selector(newTabAction))
        newTabBtn = newTabBtnLocal
        let newWinBtn = makeBtn("macwindow.badge.plus", #selector(newWindowAction))
        // Privacy controls: tracker-block shield + settings gear.
        let shieldBtn = makeBtn("checkerboard.shield", #selector(showPrivacyPanel))
        shieldBtn.toolTip = "Privacy status"
        // Settings: persistent toggles for the four safety shields.
        let settingsBtn = makeBtn("gearshape", #selector(showSettings))
        settingsBtn.toolTip = "Privacy settings"
        // Collect every toolbar icon button so applyTheme can recolor them.
        toolbarButtons = [backBtn, fwdBtn, reload, home, bookmarkAdd, bookmarksList,
                          passwordsBtn, downloadsBtn, themeToggle, newTabBtnLocal, newWinBtn, shieldBtn, settingsBtn]
        newTabBtn.contentTintColor = Material.primary
        backBtn.isEnabled = false; fwdBtn.isEnabled = false

        // Address bar styled as a Material rounded "pill" text field.
        urlField.wantsLayer = true
        urlField.isBordered = false
        urlField.drawsBackground = true
        urlField.backgroundColor = Material.surfaceVar
        urlField.textColor = Material.onSurface
        urlField.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address", attributes: [.foregroundColor: Material.outline])
        urlField.font = NSFont.systemFont(ofSize: 13)
        urlField.focusRingType = .none
        if let cell = urlField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
        }
        let urlHost = MaterialPill()
        urlHost.translatesAutoresizingMaskIntoConstraints = false
        urlHost.addSubview(urlField)
        urlField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            urlField.leadingAnchor.constraint(equalTo: urlHost.leadingAnchor, constant: 14),
            urlField.trailingAnchor.constraint(equalTo: urlHost.trailingAnchor, constant: -14),
            urlField.centerYAnchor.constraint(equalTo: urlHost.centerYAnchor),
            urlHost.heightAnchor.constraint(equalToConstant: 36),
        ])

        let toolbar = MaterialBar()
        toolbar.fillVar = false
        toolbar.shadowLine = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        self.toolbarView = toolbar

        let bar = NSStackView(views: [backBtn, fwdBtn, reload, home, urlHost,
                                      bookmarkAdd, bookmarksList, passwordsBtn, downloadsBtn, themeToggle, newTabBtn, newWinBtn, shieldBtn, settingsBtn])
        bar.orientation = .horizontal
        bar.spacing = 4
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        urlHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: toolbar.topAnchor),
            bar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
        ])

        // Tab strip background
        let tabHost = MaterialBar()
        tabHost.fillVar = true
        tabHost.shadowLine = true
        tabHost.translatesAutoresizingMaskIntoConstraints = false
        self.tabHostView = tabHost

        tabBar.orientation = .horizontal
        tabBar.spacing = 6
        tabBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        tabBar.alignment = .centerY
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setContentHuggingPriority(.required, for: .horizontal)
        tabBar.setContentCompressionResistancePriority(.required, for: .horizontal)
        tabBar.detachesHiddenViews = true
        tabBarScroll.documentView = tabBar
        tabBarScroll.hasHorizontalScroller = true
        tabBarScroll.hasVerticalScroller = false
        tabBarScroll.horizontalScrollElasticity = .allowed
        tabBarScroll.autohidesScrollers = true
        tabBarScroll.drawsBackground = false
        tabBarScroll.translatesAutoresizingMaskIntoConstraints = false
        tabHost.addSubview(tabBarScroll)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: tabBarScroll.contentView.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: tabBarScroll.contentView.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: tabBarScroll.contentView.leadingAnchor),
            tabBarScroll.topAnchor.constraint(equalTo: tabHost.topAnchor),
            tabBarScroll.bottomAnchor.constraint(equalTo: tabHost.bottomAnchor),
            tabBarScroll.leadingAnchor.constraint(equalTo: tabHost.leadingAnchor),
            tabBarScroll.trailingAnchor.constraint(equalTo: tabHost.trailingAnchor),
        ])

        // Solid color behind the (transparent) web view. While a page loads, the
        // web view is see-through, so THIS color is what you see — black in dark
        // mode, white in light. Prevents the white-flash on load.
        webBackdrop.wantsLayer = true
        webBackdrop.layer?.backgroundColor = NSColor.white.cgColor
        webBackdrop.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webBackdrop)
        NSLayoutConstraint.activate([
            webBackdrop.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webBackdrop.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webBackdrop.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webBackdrop.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])

        progress.translatesAutoresizingMaskIntoConstraints = false
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true      // layer-backed host so element fullscreen composites correctly

        // Bookmarks sidebar (right, collapsible). Built once, width animates 0<->300.
        buildSidebar()

        content.addSubview(toolbar)
        content.addSubview(tabHost)
        content.addSubview(progress)
        content.addSubview(webContainer)
        content.addSubview(sidebar)

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),

            tabHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tabHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabHost.heightAnchor.constraint(equalToConstant: 40),

            progress.topAnchor.constraint(equalTo: tabHost.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 3),

            // Sidebar pinned to the right, full height below the progress bar.
            sidebar.topAnchor.constraint(equalTo: progress.bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,

            // Web content fills the space to the LEFT of the sidebar.
            webContainer.topAnchor.constraint(equalTo: progress.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        content.wantsLayer = true          // layer-backed root so fullscreen video compositing works
        window.appearance = NSAppearance(named: .aqua)   // always start from light; theme applied next
        Material.mode = (theme == .dark)
        applyTheme(theme)   // honor a previously chosen dark mode; defaults to light
    }

    // MARK: Bookmarks sidebar UI
    func buildSidebar() {
        sidebar.fillVar = false
        sidebar.shadowLine = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.clipsToBounds = true
        // Left divider line to separate from web content.
        let divider = MaterialBar()
        divider.fillVar = true
        divider.shadowLine = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(divider)

        // Header row: title + clear-all
        sidebarHeader = NSTextField(labelWithString: "Bookmarks")
        let header = sidebarHeader!
        header.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        header.textColor = Material.onSurface
        header.translatesAutoresizingMaskIntoConstraints = false

        let clearBtn = makeBtn("trash", #selector(clearSidebarItems))
        clearBtn.contentTintColor = Material.outline
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        sidebarClearBtn = clearBtn

        // Scrollable list of bookmark rows.
        sidebarStack.orientation = .vertical
        sidebarStack.spacing = 6
        sidebarStack.alignment = .leading
        sidebarStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = sidebarStack

        sidebar.addSubview(header)
        sidebar.addSubview(clearBtn)
        sidebar.addSubview(scroll)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: sidebar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),

            clearBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),

            sidebarStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
    }

    func makeBtn(_ symbol: String, _ action: Selector) -> MaterialIconButton {
        let b = MaterialIconButton()
        var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            img = img?.withSymbolConfiguration(cfg)
        }
        b.image = img
        b.target = self; b.action = action
        b.contentTintColor = Material.onSurface
        return b
    }
}
// MARK: - Draggable tab button: click to select, drag horizontally to reorder freely
final class DraggableTabButton: NSButton {
    weak var owner: BrowserWindow?
    weak var tab: Tab?

    override func mouseDown(with event: NSEvent) {
        guard let owner = owner, let tab = tab else { super.mouseDown(with: event); return }
        // Select on press
        owner.selectTab(tab)

        let startX = event.locationInWindow.x
        var dragging = false
        // Own the entire drag with a tracking loop. Because we don't return to the
        // normal event path, rebuilding the tab bar mid-drag can't interrupt us —
        // the tab follows the cursor continuously across the whole strip.
        while let ev = self.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            let dx = ev.locationInWindow.x - startX
            if !dragging && abs(dx) < 5 { continue }   // click threshold
            dragging = true
            guard let strip = owner.tabBar as NSView?,
                  let clip = owner.tabBarScroll.contentView as NSView? else { continue }
            let pInStrip = strip.convert(ev.locationInWindow, from: nil)

            // Auto-scroll when the cursor nears either edge of the visible area.
            let pInClip = clip.convert(ev.locationInWindow, from: nil)
            let visW = owner.tabBarScroll.contentView.bounds.width
            var origin = owner.tabBarScroll.contentView.bounds.origin
            if pInClip.x > visW - 40 { origin.x += 18 }
            else if pInClip.x < 40 { origin.x -= 18 }
            origin.x = max(0, min(origin.x, max(0, strip.frame.width - visW)))
            owner.tabBarScroll.contentView.scroll(to: origin)
            owner.tabBarScroll.reflectScrolledClipView(owner.tabBarScroll.contentView)

            // Determine target index from cursor position over sibling groups.
            let groups = owner.tabs.compactMap { $0.button.superview }
            var target = owner.tabs.count - 1
            for (idx, g) in groups.enumerated() where pInStrip.x < g.frame.midX {
                target = idx; break
            }
            owner.moveTab(tab, to: target)
        }
    }
}
// MARK: - Material bookmark row (rounded card: click opens, ✕ removes)
final class MaterialBookmarkRow: NSView {
    let index: Int
    weak var owner: BrowserWindow?
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(index: Int, title: String, url: String, owner: BrowserWindow) {
        self.index = index
        self.owner = owner
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12

        let titleLabel = NSTextField(labelWithString: title.isEmpty ? url : title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Material.onSurface
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let host = (URL(string: url)?.host) ?? url
        let urlLabel = NSTextField(labelWithString: host)
        urlLabel.font = NSFont.systemFont(ofSize: 11)
        urlLabel.textColor = Material.outline
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = Material.primary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let del = MaterialIconButton()
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            del.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?.withSymbolConfiguration(cfg)
        }
        del.contentTintColor = Material.outline
        del.target = self
        del.action = #selector(removeSelf)
        del.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon); addSubview(titleLabel); addSubview(urlLabel); addSubview(del)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            del.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            del.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Material.primaryLt.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    override func mouseDown(with event: NSEvent) { owner?.openBookmarkAt(index) }
    @objc func removeSelf() { owner?.removeBookmarkAt(index) }
}

// MARK: - Material password row (site + user, reveal-on-hold, ✕ deletes)
final class MaterialPasswordRow: NSView {
    let index: Int
    weak var owner: BrowserWindow?
    private var trackingArea: NSTrackingArea?
    private let passLabel: NSTextField
    private let pass: String
    private var revealed = false
    private var eyeBtn: MaterialIconButton!

    init(index: Int, cred: Credential, owner: BrowserWindow) {
        self.index = index
        self.owner = owner
        self.pass = cred.pass
        self.passLabel = NSTextField(labelWithString: String(repeating: "•", count: max(6, min(cred.pass.count, 14))))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12

        let siteLabel = NSTextField(labelWithString: cred.host)
        siteLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        siteLabel.textColor = Material.onSurface
        siteLabel.lineBreakMode = .byTruncatingTail
        siteLabel.translatesAutoresizingMaskIntoConstraints = false

        let userLabel = NSTextField(labelWithString: cred.user.isEmpty ? "(no username)" : cred.user)
        userLabel.font = NSFont.systemFont(ofSize: 11)
        userLabel.textColor = Material.outline
        userLabel.lineBreakMode = .byTruncatingTail
        userLabel.translatesAutoresizingMaskIntoConstraints = false

        passLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        passLabel.textColor = Material.outline
        passLabel.lineBreakMode = .byTruncatingTail
        passLabel.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        icon.contentTintColor = Material.primary
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Reveal (eye) toggle
        let eye = MaterialIconButton()
        eyeBtn = eye
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Reveal")?.withSymbolConfiguration(cfg)
        }
        eye.contentTintColor = Material.outline
        eye.target = self
        eye.action = #selector(toggleReveal)
        eye.translatesAutoresizingMaskIntoConstraints = false

        let del = MaterialIconButton()
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            del.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete")?.withSymbolConfiguration(cfg)
        }
        del.contentTintColor = Material.outline
        del.target = self
        del.action = #selector(removeSelf)
        del.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon); addSubview(siteLabel); addSubview(userLabel); addSubview(passLabel)
        addSubview(eye); addSubview(del)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            del.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            del.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -2),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),

            siteLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            siteLabel.trailingAnchor.constraint(equalTo: eye.leadingAnchor, constant: -6),
            siteLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            userLabel.leadingAnchor.constraint(equalTo: siteLabel.leadingAnchor),
            userLabel.trailingAnchor.constraint(equalTo: siteLabel.trailingAnchor),
            userLabel.topAnchor.constraint(equalTo: siteLabel.bottomAnchor, constant: 1),

            passLabel.leadingAnchor.constraint(equalTo: siteLabel.leadingAnchor),
            passLabel.trailingAnchor.constraint(equalTo: siteLabel.trailingAnchor),
            passLabel.topAnchor.constraint(equalTo: userLabel.bottomAnchor, constant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Material.primaryLt.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    @objc func toggleReveal() {
        revealed.toggle()
        passLabel.stringValue = revealed ? pass : String(repeating: "•", count: max(6, min(pass.count, 14)))
        passLabel.textColor = revealed ? Material.onSurface : Material.outline
        // Swap the icon: open eye when hidden, slashed eye while revealed.
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let name = revealed ? "eye.slash" : "eye"
            let desc = revealed ? "Hide" : "Reveal"
            eyeBtn.image = NSImage(systemSymbolName: name, accessibilityDescription: desc)?.withSymbolConfiguration(cfg)
        }
        // Tint the slashed eye with the primary color so the "revealed" state pops.
        eyeBtn.contentTintColor = revealed ? Material.primary : Material.outline
    }
    @objc func removeSelf() { owner?.removePasswordAt(index) }
}

// MARK: - Material chip container for a tab (rounded, colored when active)
final class MaterialChip: NSStackView {
    weak var tab: Tab?
    var active = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        (active ? Material.primaryLt : Material.surface).setFill()
        r.fill()
        if active {
            Material.primary.withAlphaComponent(0.55).setStroke()
        } else {
            Material.outline.withAlphaComponent(0.35).setStroke()
        }
        r.lineWidth = active ? 1.5 : 1
        r.stroke()
        super.draw(dirtyRect)
    }
}
// MARK: - Tab management, navigation, bookmarks
extension BrowserWindow {
    func newTab(url: String) {
        let tab = Tab(owner: self)
        installTab(tab)
        selectTab(tab)
        tab.loadRaw(url)
        refreshTabTags()
    }

    // Open the About page in a new tab via the internal browser:// scheme, so the
    // address bar shows "browser://about" and it's a real navigable/reloadable URL.
final class MaterialDownloadRow: NSView {
    let index: Int
    weak var owner: BrowserWindow?
    private var nameLabel: NSTextField!
    private var subLabel: NSTextField!
    private var progress: MaterialProgress!
    private var revealBtn: MaterialIconButton!
    private var cancelBtn: MaterialIconButton!

    init(index: Int, item: BrowserWindow.DownloadItem, owner: BrowserWindow) {
        self.index = index
        self.owner = owner
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12

        nameLabel = NSTextField(labelWithString: item.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Material.onSurface
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        subLabel = NSTextField(labelWithString: "")
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = Material.outline
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.translatesAutoresizingMaskIntoConstraints = false

        progress = MaterialProgress()
        progress.minValue = 0; progress.maxValue = 1; progress.doubleValue = 0
        progress.isIndeterminate = false
        progress.style = .bar
        progress.wantsLayer = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true

        revealBtn = MaterialIconButton()
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            revealBtn.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Show in Finder")?.withSymbolConfiguration(cfg)
        }
        revealBtn.contentTintColor = Material.outline
        revealBtn.target = self; revealBtn.action = #selector(revealSelf)
        revealBtn.toolTip = "Show in Finder"

        cancelBtn = MaterialIconButton()
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            cancelBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?.withSymbolConfiguration(cfg)
        }
        cancelBtn.contentTintColor = Material.outline
        cancelBtn.target = self; cancelBtn.action = #selector(removeSelf)

        let info = NSStackView(views: [nameLabel, subLabel])
        info.orientation = .vertical
        info.spacing = 2
        info.alignment = .leading
        info.translatesAutoresizingMaskIntoConstraints = false
        info.setHuggingPriority(.defaultLow, for: .horizontal)

        let btns = NSStackView(views: [revealBtn, cancelBtn])
        btns.orientation = .horizontal
        btns.spacing = 4
        btns.alignment = .centerY
        btns.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView(views: [info, btns])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .centerY
        top.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [top, progress])
        col.orientation = .vertical
        col.spacing = 6
        col.alignment = .leading
        col.translatesAutoresizingMaskIntoConstraints = false
        col.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        update(item: item)
    }

    func update(item: BrowserWindow.DownloadItem) {
        nameLabel.stringValue = item.name
        let p = item.progress.fractionCompleted
        if item.failed {
            subLabel.stringValue = "Failed"
            progress.isIndeterminate = false
            progress.doubleValue = 1
        } else if item.finished {
            let sz = item.url == nil ? "" : ByteCountFormatter.string(fromByteCount: Int64(item.progress.completedUnitCount), countStyle: .file)
            subLabel.stringValue = "Done" + (sz.isEmpty ? "" : "  ·  " + sz)
            progress.isIndeterminate = false
            progress.doubleValue = 1
            revealBtn.isHidden = false
        } else {
            let total = item.progress.totalUnitCount
            let done = ByteCountFormatter.string(fromByteCount: Int64(item.progress.completedUnitCount), countStyle: .file)
            if total > 0 {
                // Known total: show an accurate determinate bar + percentage.
                progress.isIndeterminate = false
                progress.stopAnimation(nil)
                let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                subLabel.stringValue = "\(Int(p*100))%   \(done) / \(all)"
                progress.doubleValue = p
            } else {
                // Unknown total (server sent no Content-Length): show an animated
                // indeterminate bar so it's obvious the download is progressing, and
                // still report the bytes received. The bar itself can't show a
                // fraction without a total, but the byte count proves it's moving.
                progress.isIndeterminate = true
                progress.startAnimation(nil)
                subLabel.stringValue = done.isEmpty ? "Starting…" : "\(done) downloaded"
            }
            revealBtn.isHidden = true
        }
    }

    @objc func revealSelf() { owner?.revealDownloadAt(index) }
    @objc func removeSelf() { owner?.cancelDownloadAt(index) }

    required init?(coder: NSCoder) { fatalError() }
}

    @objc func showAbout() {
        // Reuse an existing About tab if present, then reload so it matches the
        // current theme (dark/light). Otherwise open a fresh one.
        if let existing = tabs.first(where: { $0.webView.url?.absoluteString == "browser://about" }) {
            selectTab(existing)
            existing.webView.reload()
        } else {
            newTab(url: "browser://about")
        }
    }

    // Persistent settings window for the four safety shields. Toggling a switch
    // updates PrivacyConfig immediately and applies live where possible.
    @objc func showSettings() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        panel.title = "Privacy settings"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: Material.mode ? .darkAqua : .aqua)
        panel.backgroundColor = Material.surface

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .left
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack

        // Build one labeled switch (NSSwitch) row per setting.
        func row(_ title: String, _ note: String, get: @escaping () -> Bool,
                 set: @escaping (Bool) -> Void) -> NSView {
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 420).isActive = true

            // Native macOS toggle switch. target:self guarantees the action reaches
            // BrowserWindow.settingsToggle (the settings panel's responder chain does
            // NOT include BrowserWindow, so a nil target would silently drop the event).
            let sw = NSSwitch()
            sw.state = get() ? .on : .off
            sw.target = self
            sw.action = #selector(settingsToggle(_:))
            sw.translatesAutoresizingMaskIntoConstraints = false
            SettingsBinder.shared.bind(sw, get: get, set: set)

            let titleLbl = NSTextField(labelWithString: title)
            titleLbl.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            titleLbl.textColor = Material.onSurface
            titleLbl.translatesAutoresizingMaskIntoConstraints = false
            let sub = NSTextField(labelWithString: note)
            sub.font = NSFont.systemFont(ofSize: 11)
            sub.textColor = Material.outline
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.lineBreakMode = .byWordWrapping
            sub.preferredMaxLayoutWidth = 360
            sub.setContentCompressionResistancePriority(.required, for: .vertical)
            let textCol = NSStackView(views: [titleLbl, sub])
            textCol.orientation = .vertical
            textCol.spacing = 3
            textCol.alignment = .left
            textCol.translatesAutoresizingMaskIntoConstraints = false

            let h = NSStackView(views: [sw, textCol])
            h.orientation = .horizontal
            h.spacing = 12
            h.alignment = .top
            h.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: v.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                h.topAnchor.constraint(equalTo: v.topAnchor),
                h.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                sw.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            ])
            return v
        }

        stack.addArrangedSubview(row("JavaScript", "OFF blocks scripts on every site (global). ON enables them everywhere.",
            get: { !PrivacyConfig.blockJS }, set: { on in
                PrivacyConfig.blockJS = !on
                if let web = self.activeTab?.webView {
                    web.configuration.defaultWebpagePreferences.allowsContentJavaScript = on
                    web.reload()
                }
            }))
        stack.addArrangedSubview(row("Pop-up blocking", "Deny window.open / target=_blank entirely.",
            get: { PrivacyConfig.blockPopups }, set: { PrivacyConfig.blockPopups = $0 }))
        stack.addArrangedSubview(row("YouTube ad-privacy", "Rotate watch-history cookie + opt out of personalized ads on youtube.com.",
            get: { PrivacyConfig.youtubePrivacy }, set: { PrivacyConfig.youtubePrivacy = $0; self.applyYouTubePrivacy() }))
        stack.addArrangedSubview(row("Reset memory on refresh", "Wipe cookies/cache/localStorage every time you reload a page.",
            get: { PrivacyConfig.resetOnRefresh }, set: { PrivacyConfig.resetOnRefresh = $0 }))

        let hint = NSTextField(labelWithString: "These apply for this session only. They reset to the safest defaults when you quit.")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = Material.outline
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 404
        hint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hint)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        settingsWindows.append(panel)
    }

    // Re-assert window.__klbYoutubeOn on every open tab's controller so the YouTube
    // toggle takes effect immediately on already-loaded tabs. User scripts are
    // get-only on this SDK, so we re-add the (idempotent) flag script; duplicates just
    // re-set the same value before the worker's setTimeout(0) fires. Reload youtube
    // tabs so the new state is applied to the current page load.
    func applyYouTubePrivacy() {
        let flag = Tab.youtubeFlagScript(PrivacyConfig.youtubePrivacy)
        for t in tabs {
            t.webView.configuration.userContentController.addUserScript(flag)
            if t.webView.url?.host?.contains("youtube.com") == true { t.webView.reload() }
        }
    }

    // Shared action for every settings switch; forwards to the bound closure.
    @objc func settingsToggle(_ sender: NSControl) {
        SettingsBinder.shared.handle(sender)
    }

    // Show a small privacy-status sheet for the current page.
    @objc func showPrivacyPanel() {
        let web = activeTab?.webView
        let host = web?.url?.host ?? "(no page)"
        let jsState = jsAllowed(for: web ?? activeTab?.webView ?? WKWebView()) ? "ON" : "OFF"
        let a = NSAlert()
        a.messageText = "Privacy status"
        a.informativeText = """
        Site: \(host)
        JavaScript: \(jsState) (global)
        Tracker blocking: \(PrivacyConfig.blockTrackers ? "ON" : "OFF")
        Pop-up blocking: \(PrivacyConfig.blockPopups ? "ON" : "OFF")
        YouTube ad-privacy: \(PrivacyConfig.youtubePrivacy ? "ON" : "OFF")
        Third-party cookies: \(PrivacyConfig.thirdPartyCookies ? "allowed" : "blocked")
        Geolocation: denied
        User-Agent: \(PrivacyConfig.spoofUserAgent ? "generic Chrome (spoofed)" : "default")
        Storage: ephemeral, wiped on quit
        """
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { _ in }
    }

    // Single source of truth for whether JS is currently enforced on a web view.
    // Reads the same value the navigation delegate applies (defaultWebpagePreferences),
    // driven by the single global PrivacyConfig.blockJS switch.
    func jsAllowed(for web: WKWebView) -> Bool {
        !PrivacyConfig.blockJS || web.configuration.defaultWebpagePreferences.allowsContentJavaScript
    }


    // Build the tab-bar chrome for a Tab and register it. Does NOT load or select.
    func installTab(_ tab: Tab) {
        tabs.append(tab)
        // NOTE: we deliberately do NOT force the page into dark mode — content is
        // shown as-is. We only set the web view's BACKDROP color so a loading page
        // matches the theme (black in dark mode, white in light) instead of flashing.
        applyWebTheme(to: tab.webView, dark: Material.mode)
        let titleBtn = DraggableTabButton()
        titleBtn.owner = self
        titleBtn.tab = tab
        titleBtn.title = "New Tab"
        titleBtn.isBordered = false
        titleBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleBtn.contentTintColor = Material.onSurface
        titleBtn.target = self
        titleBtn.action = #selector(tabClicked(_:))
        titleBtn.tag = tabs.count - 1
        titleBtn.alignment = .left
        titleBtn.lineBreakMode = .byTruncatingTail
        tab.button = titleBtn

        let close = MaterialIconButton()
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(cfg)
        } else {
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        }
        close.target = self
        close.action = #selector(tabCloseClicked(_:))
        close.tag = tabs.count - 1
        close.contentTintColor = Material.outline
        // Shrink the close button to chip scale
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),
        ])
        close.layer?.cornerRadius = 10
        tab.closeButton = close

        let chip = MaterialChip(views: [titleBtn, close])
        chip.orientation = .horizontal
        chip.spacing = 4
        chip.alignment = .centerY
        chip.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 6)
        chip.tab = tab
        tab.chip = chip
        NSLayoutConstraint.activate([ chip.heightAnchor.constraint(equalToConstant: 28) ])
        tabBar.addArrangedSubview(chip)
    }

    // For window.open / target=_blank: create a tab wrapping the provided config,
    // return its webView so the calling page can drive navigation into it.
    func newTabForPopup(configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = Tab(owner: self, configuration: configuration)
        installTab(tab)
        selectTab(tab)
        refreshTabTags()
        return tab.webView
    }

    @objc func newTabAction() { newTab(url: HOMEPAGE) }
    @objc func newWindowAction() { _ = BrowserWindow() }

    func selectTab(_ tab: Tab) {
        activeTab = tab
        // Swap the visible webView, but keep the solid backdrop view in place
        // (it sits behind the transparent web view to prevent the load flash).
        webContainer.subviews.forEach { if $0 !== webBackdrop { $0.removeFromSuperview() } }
        webContainer.addSubview(tab.webView)
        tab.webView.wantsLayer = true
        applyWebTheme(to: tab.webView, dark: Material.mode)
        updateBackdrop(dark: Material.mode)
        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        backBtn.isEnabled = tab.webView.canGoBack
        fwdBtn.isEnabled = tab.webView.canGoForward
        urlField.stringValue = tab.isHomepage ? "" : (tab.webView.url?.absoluteString ?? "")
        progress.isHidden = tab.webView.estimatedProgress >= 1.0
        window.title = "\(tab.title) — MoonProwl Browser"
        refreshTabTitles()
        updateStar()
    }

    @objc func tabClicked(_ sender: NSButton) {
        if tabs.indices.contains(sender.tag) { selectTab(tabs[sender.tag]) }
    }

    @objc func tabCloseClicked(_ sender: NSButton) {
        let i = sender.tag
        guard tabs.indices.contains(i) else { return }
        let tab = tabs[i]
        if tabs.count == 1 { window.performClose(nil); return }  // last tab -> close window
        tab.teardown()
        tab.webView.removeFromSuperview()
        if let group = tab.button.superview { group.removeFromSuperview() }
        tabs.remove(at: i)
        if activeTab === tab { selectTab(tabs[max(0, i - 1)]) }
        refreshTabTags()
    }

    func refreshTabTags() {
        for (idx, t) in tabs.enumerated() {
            t.button.tag = idx
            t.closeButton.tag = idx
        }
        refreshTabTitles()
    }

    // Reorder: move `tab` to position `to` in both the model and the visible tab bar.
    func moveTab(_ tab: Tab, to dest: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let clamped = max(0, min(dest, tabs.count - 1))
        if from == clamped { return }
        // Reorder model
        let t = tabs.remove(at: from)
        tabs.insert(t, at: clamped)
        // Reorder views: rebuild the tab bar arranged subviews in the new order
        let groups: [NSView] = tabs.compactMap { $0.button.superview }
        for g in tabBar.arrangedSubviews { tabBar.removeArrangedSubview(g); g.removeFromSuperview() }
        for g in groups { tabBar.addArrangedSubview(g) }
        refreshTabTags()
    }

    func refreshTabTitles() {
        for t in tabs {
            var label = t.title
            if label.count > 20 { label = String(label.prefix(20)) + "…" }
            let isActive = (t === activeTab)
            // In light mode the active tab sits on a light-purple chip, so a purple
            // title is low-contrast — use near-black (Material.onSurface) there.
            // In dark mode the lighter purple reads fine on the dark chip.
            let color = isActive ? (Material.mode ? Material.primary : Material.onSurface) : Material.onSurface
            let attr = NSAttributedString(string: label.isEmpty ? "New Tab" : label, attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .medium),
            ])
            t.button.attributedTitle = attr
            t.chip?.active = isActive
        }
    }

    // MARK: Navigation (operates on the active tab)
    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return }
        var url: URL?
        if s.contains("://") {
            // Already has a scheme (http://, https://, browser://, file://, …): use as-is.
            url = URL(string: s)
        } else if s.contains(" ") || !s.contains(".") {
            // Bare words / queries -> search.
            let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            url = URL(string: "https://searchbare.com/search?q=\(q)")
        } else {
            // Looks like a host with no scheme. Default to http:// so plaintext-only
            // sites (e.g. neverssl.com) load; we no longer force https:// (HTTPS-Only
            // mode was removed).
            if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
                s = "http://" + s
            }
            url = URL(string: s)
        }
        if let u = url { activeTab.webView.load(URLRequest(url: u)) }
    }

    @objc func navigateFromField() { load(urlField.stringValue) }
    @objc func goBack() { activeTab.webView.goBack() }
    @objc func goForward() { activeTab.webView.goForward() }
    @objc func reloadPage() {
        if PrivacyConfig.resetOnRefresh {
            // Wipe the ephemeral data store (cookies, cache, localStorage, etc.) so a
            // refresh starts the page with a clean slate — no lingering session/trackers.
            let store = activeTab.webView.configuration.websiteDataStore
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.removeData(ofTypes: types, modifiedSince: Date.distantPast) { [weak self] in
                self?.activeTab.webView.reload()
            }
        } else {
            activeTab.webView.reload()
        }
    }
    @objc func goHome() { load(HOMEPAGE) }

    // MARK: Theme (light / dark). Default is LIGHT and we deliberately ignore the
    // system appearance so the Material palette stays consistent. The user's choice
    // is persisted and applied to both the window chrome and the web content.
    private static let themeKey = "klb.theme"
    enum ThemeMode: String { case light, dark }
    var theme: ThemeMode {
        ThemeMode(rawValue: UserDefaults.standard.string(forKey: BrowserWindow.themeKey) ?? "") ?? .light
    }

    @objc func toggleTheme() {
        let next: ThemeMode = (theme == .light) ? .dark : .light
        UserDefaults.standard.set(next.rawValue, forKey: BrowserWindow.themeKey)
        applyTheme(next)
    }

    func applyTheme(_ mode: ThemeMode) {
        let dark = (mode == .dark)
        Material.mode = dark
        // Recolor the chrome. Views that read Material.* at draw time refresh via
        // needsDisplay; the few properties captured at build time are re-set here.
        urlField.backgroundColor = Material.surfaceVar
        urlField.textColor = Material.onSurface
        urlField.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address", attributes: [.foregroundColor: Material.outline])
        // Recolor every toolbar icon button purple (matching the new-tab + icon),
        // as requested — uniform Material primary tint across the whole toolbar.
        for b in toolbarButtons { b.contentTintColor = Material.primary }
        newTabBtn.contentTintColor = Material.primary
        starBtn.contentTintColor = Material.primary
        themeBtn.contentTintColor = Material.primary
        for t in tabs {
            t.button?.contentTintColor = Material.onSurface
            t.closeButton?.contentTintColor = Material.outline
        }
        refreshTabTitles()   // recolor active/inactive tab name text for the new theme
        progress.needsDisplay = true   // redraw the purple progress fill
        updateBackdrop(dark: dark)     // recolor the load backdrop (black/white)
        for t in tabs {
            applyWebTheme(to: t.webView, dark: dark)
        }
        content.needsDisplay = true
        toolbarView.needsDisplay = true
        tabHostView.needsDisplay = true
        sidebar.needsDisplay = true
        sidebarHeader?.textColor = Material.onSurface
        sidebarClearBtn?.contentTintColor = Material.outline
        if sidebarOpen { rebuildSidebarList() }
        // Redraw everything under the content view (sidebars, rows, etc.).
        func redraw(_ v: NSView) { v.needsDisplay = true; for s in v.subviews { redraw(s) } }
        redraw(content)
        updateThemeIcon(dark)
        // If the About page is open, re-serve it so it picks up the new theme
        // immediately when the dark-mode switch is toggled.
        if let u = activeTab?.webView.url?.absoluteString, u == "browser://about" {
            activeTab?.webView.reload()
        }
        // Recolor any open settings windows so they track the theme too.
        for sw in settingsWindows {
            sw.appearance = NSAppearance(named: Material.mode ? .darkAqua : .aqua)
            sw.backgroundColor = Material.surface
        }
    }

    // Solid color behind the (transparent) web view. While a page loads the web
    // view is see-through, so this is what shows: black in dark mode, white in
    // light — never WebKit's default white flash.
    func updateBackdrop(dark: Bool) {
        webBackdrop.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
    }

    // Per-tab page tweaks for the active theme.
    //  - Keep the web view transparent so the solid backdrop shows through while
    //    a page is still painting (no white flash).
    //  - Set the web view's APPEARANCE to darkAqua in dark mode. This is what tells
    //    sites the system is in dark mode: matchMedia('(prefers-color-scheme: dark)')
    //    becomes true, so sites that support it render their OWN dark theme. This is
    //    NOT a forced inversion — the site still controls its colors.
    func applyWebTheme(to webView: WKWebView, dark: Bool) {
        // Advertise the system appearance to the page (darkAqua in dark mode) so sites
        // that support dark mode switch automatically via prefers-color-scheme. Sites
        // without a dark theme stay as-is — standard browser behavior, not a forced invert.
        // The web view stays transparent so the black loading backdrop shows through.
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Reload so already-rendered content re-renders under the new color scheme.
        // Without this, the page keeps the old theme until a manual refresh.
        webView.reload()
    }

    func updateThemeIcon(_ dark: Bool) {
        // "Responsive" icon like the bookmark star: swaps to reflect current state.
        let symbol = dark ? "moon.fill" : "sun.max.fill"
        let desc = dark ? "Switch to light mode" : "Switch to dark mode"
        themeBtn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        if #available(macOS 11.0, *) {
            themeBtn.image = themeBtn.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        }
    }
    func updateStar() {
        let bookmarked = (activeTab?.webView.url?.absoluteString).map { BookmarkStore.shared.contains(url: $0) } ?? false
        let symbol = bookmarked ? "star.fill" : "star"
        starBtn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: bookmarked ? "Remove bookmark" : "Add bookmark")
    }

    @objc func addBookmark() {
        guard let u = activeTab.webView.url?.absoluteString else { return }
        if BookmarkStore.shared.contains(url: u) {
            BookmarkStore.shared.remove(url: u)   // toggle off
        } else {
            BookmarkStore.shared.add(title: activeTab.title, url: u)
        }
        if sidebarOpen { rebuildSidebarList() }
        updateStar()
    }

    // Toggle the right-hand sidebar in a given mode. Clicking the same button
    // again closes it; clicking the other button switches modes in place.
    @objc func showBookmarks() { toggleSidebar(.bookmarks) }
    @objc func showPasswords() { toggleSidebar(.passwords) }
    @objc func showDownloads() { toggleSidebar(.downloads) }

    func toggleSidebar(_ mode: SidebarMode) {
        if sidebarOpen && sidebarMode == mode {
            sidebarOpen = false
        } else if sidebarOpen {
            sidebarMode = mode          // switch content, stay open
            rebuildSidebarList()
            return
        } else {
            sidebarMode = mode
            sidebarOpen = true
            rebuildSidebarList()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = sidebarOpen ? 300 : 0
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // Trash button clears whichever list is showing.
    @objc func clearSidebarItems() {
        switch sidebarMode {
        case .bookmarks: clearBookmarks()
        case .downloads:
            // Remove finished/failed downloads from the list (keep in-progress).
            downloads.removeAll { $0.finished || $0.failed }
            rebuildSidebarList()
        case .passwords:
            let alert = NSAlert()
            alert.messageText = "Delete all saved passwords?"
            alert.informativeText = "This removes every password stored in MoonProwl Browser. This cannot be undone."
            alert.addButton(withTitle: "Delete All")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { r in
                if r == .alertFirstButtonReturn {
                    PasswordStore.shared.removeAll()
                    self.rebuildPasswordList()
                }
            }
        }
    }

    // Rebuild sidebar content for the current mode.
    func rebuildSidebarList() {
        sidebarHeader?.stringValue = sidebarMode == .bookmarks ? "Bookmarks"
                                : sidebarMode == .passwords ? "Passwords"
                                : "Downloads"
        for v in sidebarStack.arrangedSubviews { sidebarStack.removeArrangedSubview(v); v.removeFromSuperview() }
        switch sidebarMode {
        case .bookmarks: buildBookmarkRows()
        case .passwords: buildPasswordRows()
        case .downloads: buildDownloadRows()
        }
    }

    private func buildBookmarkRows() {
        let items = BookmarkStore.shared.items
        if items.isEmpty {
            addSidebarEmptyLabel("No bookmarks yet.\nClick the ☆ in the toolbar to add one.")
            return
        }
        for (idx, bm) in items.enumerated() {
            let row = MaterialBookmarkRow(index: idx, title: bm.title, url: bm.url, owner: self)
            sidebarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
    }

    private func buildPasswordRows() {
        let items = PasswordStore.shared.items
        if items.isEmpty {
            addSidebarEmptyLabel("No saved passwords.\nLog in to a site and choose Save Password.")
            return
        }
        for (idx, c) in items.enumerated() {
            let row = MaterialPasswordRow(index: idx, cred: c, owner: self)
            sidebarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
    }

    private func addSidebarEmptyLabel(_ text: String) {
        let empty = NSTextField(labelWithString: text)
        empty.font = NSFont.systemFont(ofSize: 12)
        empty.textColor = Material.outline
        empty.maximumNumberOfLines = 3
        empty.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.addArrangedSubview(empty)
    }

    // Refresh the password list if it's currently visible (called after saves/deletes).
    func rebuildPasswordList() {
        if sidebarOpen && sidebarMode == .passwords { rebuildSidebarList() }
    }

    // MARK: - Downloads

    private func buildDownloadRows() {
        if downloads.isEmpty {
            addSidebarEmptyLabel("No downloads yet.\nFiles you download will appear here and save to your Downloads folder.")
            return
        }
        // newest first
        for item in downloads.reversed() {
            let row = MaterialDownloadRow(index: item.id, item: item, owner: self)
            sidebarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
    }

    // Refresh the download list if it's currently visible (called on progress/finish).
    func rebuildDownloadList() {
        if sidebarOpen && sidebarMode == .downloads { rebuildSidebarList() }
    }

    func revealDownloadAt(_ id: Int) {
        guard let item = downloads.first(where: { $0.id == id }), let url = item.url else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    func removeDownloadAt(_ id: Int) {
        downloads.removeAll { $0.id == id }
        rebuildSidebarList()
    }

    // Open the downloads sidebar automatically when a download starts.
    func ensureDownloadsSidebarOpen() {
        if !(sidebarOpen && sidebarMode == .downloads) {
            sidebarMode = .downloads
            sidebarOpen = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                sidebarWidth.animator().constant = 300
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        rebuildSidebarList()
    }

    // MARK: - Downloads (native WKDownload + disk-size progress polling)
    // Begin a download using WebKit's own WKDownload so the navigation context
    // (cookies, auth, redirects) is preserved. Re-requesting the URL via URLSession
    // was returning HTML interstitials instead of the real file.
    func startDownload(_ download: WKDownload) {
        downloadSeq += 1
        let id = downloadSeq
        let name = (download.originalRequest?.url?.lastPathComponent).map { $0.isEmpty ? "download" : $0 } ?? "download"
        let prog = Progress()
        prog.totalUnitCount = 0
        let item = DownloadItem(id: id, name: name, progress: prog, finished: false, url: nil, failed: false, download: download, destURL: nil)
        downloads.append(item)
        download.delegate = self
        // Watch WebKit's REAL download progress (bytes received + total once the
        // server reports Content-Length) and mirror it into our row's Progress.
        let kvo = download.progress.observe(\.completedUnitCount) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDownloadRow(id) }
        }
        let kvoTotal = download.progress.observe(\.totalUnitCount) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDownloadRow(id) }
        }
        // Backup: also poll the partial file on disk every 250ms so the byte count
        // always advances even if WKDownload.progress lags behind.
        let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.refreshDownloadRow(id)
        }
        poll.tolerance = 0.1
        downloadObservers[id] = [kvo, kvoTotal, poll]   // retained until cancel/finish
        ensureDownloadsSidebarOpen()
    }

    // Re-read the live progress for one download and update its row.
    private func refreshDownloadRow(_ id: Int) {
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else {
            if let obs = downloadObservers[id] as? [Any] { for o in obs { (o as? Timer)?.invalidate() } }
            downloadObservers[id] = nil
            return
        }
        let it = downloads[idx]
        if it.finished || it.failed {
            if let obs = downloadObservers[id] as? [Any] { for o in obs { (o as? Timer)?.invalidate() } }
            downloadObservers[id] = nil
            return
        }
        // Mirror the real WKDownload progress (bytes + total) into our Progress.
        if let dl = it.download {
            let rp = dl.progress
            it.progress.totalUnitCount = rp.totalUnitCount
            it.progress.completedUnitCount = rp.completedUnitCount
        }
        if let row = sidebarStack.arrangedSubviews.compactMap({ $0 as? MaterialDownloadRow }).first(where: { $0.index == id }) {
            row.update(item: it)
        }
    }

    // Direct download for an arbitrary URL (right-click menu / link). Uses URLSession
    // with the active tab's cookies for logged-in hosts.
    func startDownload(url: URL, from webView: WKWebView?) {
        let destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let name = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let grab = { [weak self] (cookies: [HTTPCookie]) in
            guard let self = self else { return }
            var req = URLRequest(url: url, timeoutInterval: 60)
            if !cookies.isEmpty {
                let hdr = HTTPCookie.requestHeaderFields(with: cookies)
                if let c = hdr["Cookie"] { req.setValue(c, forHTTPHeaderField: "Cookie") }
            }
            let task = URLSession.shared.downloadTask(with: req) { [weak self] loc, resp, err in
                guard let self = self, let loc = loc, err == nil else { return }
                let finalName = (resp as? HTTPURLResponse)?.suggestedFilename ?? name
                let (fn, d) = self.resolveDownloadsDest(finalName)
                try? FileManager.default.moveItem(at: loc, to: d)
                let prog = Progress(); prog.totalUnitCount = 1; prog.completedUnitCount = 1
                prog.setUserInfoObject(d, forKey: .fileURLKey)
                DispatchQueue.main.async {
                    self.downloads.append(DownloadItem(id: self.downloadSeq + 1, name: fn, progress: prog, finished: true, url: d, failed: false, download: nil, destURL: d))
                    self.downloadSeq += 1
                    self.rebuildDownloadList()
                    self.ensureDownloadsSidebarOpen()
                }
            }
            task.resume()
        }
        if let wv = webView {
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { grab($0) }
        } else { grab([]) }
    }

    // Pick a non-clobbering destination name in ~/Downloads.
    func resolveDownloadsDest(_ baseName: String) -> (name: String, url: URL) {
        let destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var base = baseName.isEmpty ? "download" : baseName
        var dest = destDir.appendingPathComponent(base)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            base = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            dest = destDir.appendingPathComponent(base)
            n += 1
        }
        return (base, dest)
    }

    // Cancel a download and remove its (possibly partial) file from disk.
    func cancelDownloadAt(_ id: Int) {
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else { return }
        let item = downloads[idx]
        if let obs = downloadObservers[id] as? [Any] { for o in obs { (o as? Timer)?.invalidate() } }
        downloadObservers[id] = nil
        item.download?.cancel { _ in }
        if let dest = item.destURL, !item.finished, FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        downloads.remove(at: idx)
        rebuildSidebarList()
    }

    // Download a URL directly (used by the right-click "Download" menu).
    func downloadURLDirectly(_ url: URL) {
        startDownload(url: url, from: activeTab?.webView)
    }

    // Image action handlers (called from the Material image context menu).
    func doCopyImageData(_ dataStr: String) {
        guard let range = dataStr.range(of: ";base64,"), dataStr.hasPrefix("data:image") else { return }
        let b64 = String(dataStr[range.upperBound...])
        guard let data = Data(base64Encoded: b64) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Raw PNG bytes under the PNG UTI — an actual image, not base64 text.
        // Do NOT also call writeObjects([NSImage]): that adds a second
        // representation and causes a double paste.
        pb.setData(data, forType: .png)
    }
    func doCopyImageURL(_ u: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(u.absoluteString, forType: .string)
    }
    func doDownloadURL(_ u: URL) {
        NSLog("[klb-dl] url=%@", u.absoluteString)
        downloadURLDirectly(u)
    }
    // Save the image bytes we captured via canvas (handles blob:/data:/CORS
    // images that URLSession can't fetch). The payload is a data: URL PNG string.
    func doSaveImageData(_ dataStr: String) {
        guard let range = dataStr.range(of: ";base64,"), dataStr.hasPrefix("data:image") else { return }
        let b64 = String(dataStr[range.upperBound...])
        guard let data = Data(base64Encoded: b64) else { return }
        let base = (activeTab?.title ?? "image").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (base.isEmpty ? "image" : base).replacingOccurrences(of: "/", with: "-")
        let (fn, dest) = resolveDownloadsDest(name + ".png")
        do { try data.write(to: dest) }
        catch { return }
        downloads.append(DownloadItem(id: downloadSeq + 1, name: fn, progress: { let p = Progress(); p.totalUnitCount = 1; p.completedUnitCount = 1; p.setUserInfoObject(dest, forKey: .fileURLKey); return p }(), finished: true, url: dest, failed: false, download: nil, destURL: dest))
        downloadSeq += 1
        rebuildDownloadList()
        ensureDownloadsSidebarOpen()
    }

    // MARK: - WKDownloadDelegate (native: preserves cookies/auth/redirects)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let (name, dest) = resolveDownloadsDest(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        if let id = downloads.first(where: { $0.download === download })?.id,
           let idx = downloads.firstIndex(where: { $0.id == id }) {
            downloads[idx].name = name
            downloads[idx].destURL = dest
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = downloads.first(where: { $0.download === download })?.id else { return }
        if let idx = downloads.firstIndex(where: { $0.id == id }) {
            downloads[idx].finished = true
            let finalURL = (download.progress.userInfo[.fileURLKey] as? URL) ?? downloads[idx].destURL
            downloads[idx].url = finalURL
            downloads[idx].destURL = finalURL
            if let obs = downloadObservers[id] as? [Any] { for o in obs { (o as? Timer)?.invalidate() } }
            downloadObservers[id] = nil
        }
        rebuildDownloadList()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = downloads.first(where: { $0.download === download })?.id else { return }
        if let idx = downloads.firstIndex(where: { $0.id == id }) {
            downloads[idx].failed = true
            if let obs = downloadObservers[id] as? [Any] { for o in obs { (o as? Timer)?.invalidate() } }
            downloadObservers[id] = nil
        }
        rebuildDownloadList()
    }

    func removePasswordAt(_ idx: Int) {
        PasswordStore.shared.remove(at: idx)
        rebuildSidebarList()
    }

    func openBookmarkAt(_ idx: Int) {
        let items = BookmarkStore.shared.items
        if items.indices.contains(idx) { newTab(url: items[idx].url) }
    }

    func removeBookmarkAt(_ idx: Int) {
        BookmarkStore.shared.remove(at: idx)
        rebuildSidebarList()
        updateStar()
    }

    @objc func openBookmark(_ sender: NSMenuItem) { openBookmarkAt(sender.tag) }

    @objc func clearBookmarks() {
        while !BookmarkStore.shared.items.isEmpty { BookmarkStore.shared.remove(at: 0) }
        rebuildSidebarList()
        updateStar()
    }

    // Serialized permission prompts. Presenting two sheets on the same window at
    // once makes the second queue invisibly and swallows clicks, so we run them
    // one at a time. (State lives on the class; extensions can't store properties.)
    func askPermission(title: String, msg: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.permQueue.append((title, msg, completion))
            self.drainPermQueue()
        }
    }

    private func drainPermQueue() {
        guard !permShowing, !permQueue.isEmpty else { return }
        let (title, msg, completion) = permQueue.removeFirst()
        permShowing = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.alertStyle = .informational
        alert.beginSheetModal(for: self.window) { r in
            completion(r == .alertFirstButtonReturn)
            self.permShowing = false
            // Present the next queued prompt (if any) on the next runloop tick.
            DispatchQueue.main.async { self.drainPermQueue() }
        }
    }
}
// MARK: - Window close cleanup: drop the strong ref when a window closes
extension BrowserWindow: NSWindowDelegate {
    // Returns false to veto the close and show a confirmation; once the user
    // confirms, we set closingConfirmed and call close() again to proceed.
    private var closeKey: UnsafeRawPointer { UnsafeRawPointer(bitPattern: 1)! }
    var closingConfirmed: Bool { objc_getAssociatedObject(self, closeKey) as? Bool ?? false }
    func setClosingConfirmed(_ v: Bool) { objc_setAssociatedObject(self, closeKey, v, .OBJC_ASSOCIATION_RETAIN) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // If every tab is the home page (or a not-yet-loaded tab), just close.
        let nonHome = tabs.filter { !$0.isHomepage }
        if nonHome.isEmpty { return true }
        if closingConfirmed { return true }

        let a = NSAlert()
        a.messageText = "Close MoonProwl Browser?"
        let n = nonHome.count
        a.informativeText = "You have \(n) tab\(n == 1 ? "" : "s") open that \(n == 1 ? "isn't" : "aren't") the home page. Close anyway?"
        a.addButton(withTitle: "Close")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn {
                self.setClosingConfirmed(true)
                self.window.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        for t in tabs { t.teardown() }
        BrowserWindow.windows.removeAll { $0 === self }
    }
}

// MARK: - App delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        InstallCrashTrap()
        LaunchLog("didFinishLaunching start")
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        LaunchLog("creating BrowserWindow")
        let w = BrowserWindow()
        LaunchLog("BrowserWindow created")
        w.window.delegate = w
        setupMenu()
        LaunchLog("menu set up")
        NSApp.activate(ignoringOtherApps: true)
        LaunchLog("activated")

        // Opt into secure state restoration (silences the Tahoe warning and avoids
        // a potential hang on newer macOS when restorable state is encoded).
        LaunchLog("launch complete")

        // App-level right-click + middle-click monitor. macOS 26 WebKit swallows
        // NSView mouse events (mouseDown/otherMouseDown never reach KLBWebView),
        // so we intercept here. POLICY:
        //   • right-click over an IMAGE  → consume the event and show our custom
        //     Save/Copy menu (postContextMenu).
        //   • right-click anywhere else  → let the event through untouched so
        //     WebKit shows its real, stock context menu.
        // "Over an image" is read from the hover probe (isOverImage), kept fresh
        // by the mouseMoved monitor below.
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown, .leftMouseDown]) { event in
            let isRight = event.type == .rightMouseDown
            let isMiddle = event.type == .otherMouseDown
            let isLeft = event.type == .leftMouseDown
            let isDouble = isLeft && event.clickCount == 2
            // We only act on right-click, middle-click, or a left double-click that
            // lands on an image. Every other click passes through untouched.
            guard isRight || isMiddle || isDouble else { return event }

            // Synthetic/local events may report window == nil; fall back to the
            // front KLB window (real clicks always carry a window).
            let win = event.window
            let browser: BrowserWindow?
            if let w = win {
                browser = BrowserWindow.windows.first(where: { $0.window === w })
            } else {
                browser = BrowserWindow.windows.first
            }
            guard let browser = browser else { return event }
            guard let web = browser.activeTab?.webView else { return event }
            // Only over the web content area, not the toolbar / URL field.
            let localInWeb = browser.webContainer.convert(event.locationInWindow, from: nil)
            guard browser.webContainer.bounds.contains(localInWeb) else { return event }

            // Only image hits get our custom Material menu; everything else keeps
            // WebKit's native behaviour (right-click -> stock menu for text/links,
            // double-click -> select word / zoom).
            guard web.isOverImage else { return event }

            let pt = event.locationInWindow
            DispatchQueue.main.async { web.postContextMenu(atWindowPoint: pt) }
            // Consume the event so the native (long) context menu / text-select /
            // zoom never fires over an image.
            return nil
        }

        // Keep isOverImage fresh as the cursor moves, so the click monitor above
        // can decide synchronously. Throttled to a few points of movement.
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            // Synthetic/local events may report window == nil; fall back to the
            // front KLB window and verify the point is inside it.
            let win = event.window
            let browser: BrowserWindow?
            if let w = win {
                browser = BrowserWindow.windows.first(where: { $0.window === w })
            } else {
                browser = BrowserWindow.windows.first
            }
            if let browser = browser,
               let web = browser.activeTab?.webView {
                let localInWeb = browser.webContainer.convert(event.locationInWindow, from: nil)
                if browser.webContainer.bounds.contains(localInWeb),
                   abs(web.lastProbeX - localInWeb.x) > 4 || abs(web.lastProbeY - localInWeb.y) > 4 {
                    web.lastProbeX = localInWeb.x; web.lastProbeY = localInWeb.y
                    web.probeImageHover(atWindowPoint: event.locationInWindow)
                }
            }
            return event
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    var frontBrowser: BrowserWindow? {
        BrowserWindow.windows.first { $0.window.isKeyWindow } ?? BrowserWindow.windows.last
    }

    @objc func menuNewTab() { frontBrowser?.newTabAction() }
    @objc func menuNewWindow() {
        let w = BrowserWindow(); w.window.delegate = w
    }
    @objc func menuAddBookmark() { frontBrowser?.addBookmark() }
    @objc func menuShowBookmarks() { frontBrowser?.showBookmarks() }
    @objc func menuAbout() { frontBrowser?.showAbout() }
    @objc func menuCloseTab() {
        guard let b = frontBrowser, let a = b.activeTab else { return }
        b.tabCloseClicked(a.closeButton)
    }

    // Opt into secure-coded restorable state (required to silence the Tahoe warning
    // and avoid a startup hang on newer macOS).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func setupMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MoonProwl Browser", action: #selector(menuAbout), keyEquivalent: "").target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit MoonProwl Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(menuNewTab), keyEquivalent: "t").target = self
        file.addItem(withTitle: "New Window", action: #selector(menuNewWindow), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Close Tab", action: #selector(menuCloseTab), keyEquivalent: "w").target = self
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let bmItem = NSMenuItem(); main.addItem(bmItem)
        let bm = NSMenu(title: "Bookmarks")
        bm.addItem(withTitle: "Add Bookmark", action: #selector(menuAddBookmark), keyEquivalent: "d").target = self
        bm.addItem(withTitle: "Show Bookmarks", action: #selector(menuShowBookmarks), keyEquivalent: "b").target = self
        bmItem.submenu = bm

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "About MoonProwl Browser", action: #selector(menuAbout), keyEquivalent: "").target = self
        helpItem.submenu = help

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

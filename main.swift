import AppKit
import UserNotifications
import ServiceManagement

// Shows usage limits for Claude Code, Codex and Cursor, using each tool's own saved login.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
item.button?.image = ringIcon(session: 0, weekly: 0)
// Add to Login Items once, on first launch; after that the user's choice in Settings wins.
if !UserDefaults.standard.bool(forKey: "loginItemSet") {
    do { try SMAppService.mainApp.register(); UserDefaults.standard.set(true, forKey: "loginItemSet") }
    catch { NSLog("Login item registration failed: \(error)") }
}
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
let menu = NSMenu()
item.menu = menu
var lastUpdated: Date?

struct Limit {
    let label: String, pct: Double, resets: Date?
    let short: Bool  // session-style window (hours) vs weekly/monthly
}

enum Status {
    case limits([Limit])
    case login(String, command: String?)  // what to tell the user; command is copied on click, nil opens the app
    case error(String)
}

// MARK: - Helpers

func run(_ path: String, _ args: [String]) -> Data? {
    let p = Process(); let out = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

func jsonObject(_ data: Data?) -> [String: Any]? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

func isoDate(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

// Payload of a JWT, without verifying it: only used to read the user id.
func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    return jsonObject(Data(base64Encoded: b64))
}

func fetch(_ url: String, _ headers: [String: String], _ done: @escaping (Int?, [String: Any]?) -> Void) {
    var req = URLRequest(url: URL(string: url)!)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        done((resp as? HTTPURLResponse)?.statusCode, jsonObject(data))
    }.resume()
}

func windowLabel(seconds: Double) -> String {
    let hours = Int(seconds / 3600)
    return hours < 24 ? "Session" : hours == 168 ? "Weekly" : "\(hours / 24)-day"
}

// MARK: - Providers. Each returns nil when that tool isn't installed or logged in on this Mac.

func claude(_ done: @escaping (Status?) -> Void) {
    guard let creds = jsonObject(run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])),
          let token = (creds["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    else { return done(.login("Not signed in, click to copy “claude”", command: "claude")) }  // always shown: this is the main one
    fetch("https://api.anthropic.com/api/oauth/usage",
          ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]) { status, json in
        if status == 401 || status == 403 { return done(.login("Signed out, click to copy “claude”", command: "claude")) }
        guard let json, json["five_hour"] != nil else { return done(.error("Couldn't fetch usage")) }
        func limit(_ key: String, _ label: String, short: Bool) -> Limit {
            let w = json[key] as? [String: Any]
            return Limit(label: label, pct: w?["utilization"] as? Double ?? 0, resets: isoDate(w?["resets_at"]), short: short)
        }
        done(.limits([limit("five_hour", "Session", short: true), limit("seven_day", "Weekly", short: false)]))
    }
}

// Same endpoint the Codex CLI uses for /status when logged in with ChatGPT.
func codex(_ done: @escaping (Status?) -> Void) {
    let path = NSHomeDirectory() + "/.codex/auth.json"
    guard let tokens = jsonObject(FileManager.default.contents(atPath: path))?["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String
    else { return done(nil) }
    var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex-cli"]
    headers["ChatGPT-Account-Id"] = tokens["account_id"] as? String
    fetch("https://chatgpt.com/backend-api/wham/usage", headers) { status, json in
        if status == 401 || status == 403 { return done(.login("Signed out, click to copy “codex login”", command: "codex login")) }
        guard let rate = json?["rate_limit"] as? [String: Any] else { return done(.error("Couldn't fetch usage")) }
        let limits = ["primary_window", "secondary_window"].compactMap { key -> Limit? in
            guard let w = rate[key] as? [String: Any] else { return nil }
            let seconds = w["limit_window_seconds"] as? Double ?? 0
            return Limit(label: windowLabel(seconds: seconds), pct: w["used_percent"] as? Double ?? 0,
                         resets: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }, short: seconds < 86400)
        }
        done(limits.isEmpty ? .error("No usage limits on this plan") : .limits(limits))
    }
}

// Cursor keeps its login in its settings database; the dashboard's usage summary takes it as a cookie.
func cursor(_ done: @escaping (Status?) -> Void) {
    let db = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    guard FileManager.default.fileExists(atPath: db),
          let out = run("/usr/bin/sqlite3", [db, "select value from ItemTable where key = 'cursorAuth/accessToken'"]),
          let token = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
    else { return done(nil) }
    guard let sub = jwtPayload(token)?["sub"] as? String, let user = sub.split(separator: "|").last
    else { return done(.login("Signed out, click to open Cursor", command: nil)) }
    fetch("https://cursor.com/api/usage-summary", ["Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)"]) { status, json in
        if status == 401 || status == 403 { return done(.login("Signed out, click to open Cursor", command: nil)) }
        guard let json, let plan = (json["individualUsage"] as? [String: Any])?["plan"] as? [String: Any],
              let pct = plan["totalPercentUsed"] as? Double
        else { return done(.error("Couldn't fetch usage")) }
        done(.limits([Limit(label: "Monthly", pct: pct,
                            resets: isoDate(json["billingCycleEnd"]), short: false)]))
    }
}

let providers: [(name: String, fetch: (@escaping (Status?) -> Void) -> Void)] =
    [("Claude", claude), ("Codex", codex), ("Cursor", cursor)]

// MARK: - Drawing

func levelColor(_ pct: Double) -> NSColor {
    pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : .systemGreen
}

// Two concentric rings, Activity-style: outer = highest weekly/monthly limit, inner = highest session limit.
// Monochrome while fine, ring turns orange/red as its own limit gets close.
func ringIcon(session: Double, weekly: Double) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        let c = NSPoint(x: r.midX, y: r.midY)
        for (pct, radius) in [(weekly, 7.4), (session, 3.9)] {
            let tint = pct >= 75 ? levelColor(pct) : NSColor.labelColor
            let track = NSBezierPath(); track.lineWidth = 2.4
            track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
            tint.withAlphaComponent(0.25).setStroke(); track.stroke()
            let arc = NSBezierPath(); arc.lineWidth = 2.4; arc.lineCapStyle = .round
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(min(pct, 100), 2) / 100, clockwise: true)
            tint.setStroke(); arc.stroke()
        }
        return true
    }
    img.accessibilityDescription = String(format: "Usage: session %.0f%%, long-term %.0f%%", session, weekly)
    return img
}

// Relative within a day ("in 2 hours"), otherwise the exact moment ("Tue 9:00 AM"), since "in 4 days" is vague.
// Menu bar ring glides to new values after a refresh, so a change is noticeable without being loud.
var ringShown = (session: 0.0, weekly: 0.0)
var ringTimer: Timer?
func setRing(session: Double, weekly: Double) {
    ringTimer?.invalidate()
    let from = ringShown, start = CACurrentMediaTime(), duration = 0.6
    func step(_ e: Double) {
        ringShown = (from.session + (session - from.session) * e, from.weekly + (weekly - from.weekly) * e)
        item.button?.image = ringIcon(session: ringShown.session, weekly: ringShown.weekly)
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || (from.session == session && from.weekly == weekly) { return step(1) }
    ringTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
        let t = min((CACurrentMediaTime() - start) / duration, 1)
        step(1 - pow(1 - t, 3))  // ease-out cubic
        if t >= 1 { timer.invalidate() }
    }
    RunLoop.main.add(ringTimer!, forMode: .common)
}

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    if date.timeIntervalSinceNow < 86400 {
        return "Resets " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
    let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEjmm")
    return "Resets " + f.string(from: date)
}

// Menu row: label + % on top, flat bar, reset time below. Neutral until 75%, same rule as the menu bar ring.
class UsageRow: NSView {
    let key: String, label: String, pct: Double, reset: String
    var shown: Double  // where the bar is drawn; slides from the last-seen value to pct when the menu opens
    init(_ key: String, _ label: String, _ pct: Double, _ reset: String) {
        (self.key, self.label, self.pct, self.reset) = (key, label, pct, reset)
        shown = seen[key] ?? pct
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        autoresizingMask = .width  // stretch to the menu's width
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let x: CGFloat = 16, w = bounds.width - 32, hot = pct >= 75
        (label as NSString).draw(at: NSPoint(x: x, y: 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        let pctStr = String(format: "%.0f%%", pct) as NSString
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: hot ? .semibold : .regular),
            .foregroundColor: hot ? levelColor(pct) : NSColor.secondaryLabelColor]
        pctStr.draw(at: NSPoint(x: x + w - pctStr.size(withAttributes: pctAttrs).width, y: 6), withAttributes: pctAttrs)

        // Below 75% the bar takes the system accent color, softened; orange/red stay reserved for warnings.
        let tint = hot ? levelColor(pct) : NSColor.controlAccentColor.withAlphaComponent(0.75)
        let track = NSRect(x: x, y: 27, width: w, height: 6)
        tint.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let fillW = max(track.height, track.width * min(shown, 100) / 100) // keep a dot visible at 0%
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 27, width: fillW, height: 6), xRadius: 3, yRadius: 3).fill()

        (reset as NSString).draw(at: NSPoint(x: x, y: 37), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// Bars whose value changed since the menu was last open glide to the new value; unchanged rows stay still.
// Timer runs in .common mode so it ticks while the menu is tracking.
var seen: [String: Double] = [:]
var glide: Timer?, menuOpen = false
func glideChangedRows() {
    let rows = menu.items.compactMap { $0.view as? UsageRow }.filter { $0.shown != $0.pct }
    glide?.invalidate()
    guard !rows.isEmpty else { return }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return rows.forEach { $0.shown = $0.pct; $0.needsDisplay = true } }
    let from = rows.map(\.shown), start = CACurrentMediaTime(), duration = 0.45
    glide = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
        let t = min((CACurrentMediaTime() - start) / duration, 1), e = 1 - pow(1 - t, 3)  // ease-out cubic
        for (r, f) in zip(rows, from) { r.shown = f + (r.pct - f) * e; r.needsDisplay = true }
        if t >= 1 { timer.invalidate() }
    }
    RunLoop.main.add(glide!, forMode: .common)
}

func row(_ v: NSView) -> NSMenuItem { let i = NSMenuItem(); i.view = v; return i }

func note(_ title: String, _ symbol: String, action: Selector? = nil, tip: String? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
    i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    i.target = poller
    i.toolTip = tip
    return i
}

// Section header: brand mark + tool name. Marks are Simple Icons (CC0) in icon/marks, bundled as PDFs.
// Claude keeps its brand color; the black OpenAI and Cursor marks follow the text color so they work in dark mode.
let brandColors = ["Claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)]  // #D97757
class HeaderRow: NSView {
    let name: String
    init(_ name: String) {
        self.name = name
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        autoresizingMask = .width
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        var x: CGFloat = 16
        if let mark = Bundle.main.image(forResource: name.lowercased()) {
            let color = brandColors[name] ?? .labelColor
            NSImage(size: mark.size, flipped: false) { r in
                mark.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
            }.draw(in: NSRect(x: x, y: 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 20
        }
        (name as NSString).draw(at: NSPoint(x: x, y: 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// MARK: - Alerts

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    (c.title, c.body, c.sound) = (title, body, .default)
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: title, content: c, trigger: nil))
}

// Fire once per crossing; re-arms when usage drops back under 90% (i.e. after the limit resets).
var alerted: Set<String> = []
func checkAlert(_ name: String, _ pct: Double, _ reset: String) {
    if pct < 90 { alerted.remove(name); return }
    guard alerted.insert(name).inserted else { return }
    notify("\(name) limit at \(Int(pct))%", reset)
}

// MARK: - Menu

let updatedItem = NSMenuItem()
func updateFooter() {
    let text = lastUpdated.map { "Updated " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "Updating…"
    updatedItem.attributedTitle = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
}

func addControls() {
    menu.addItem(.separator())
    updateFooter()
    menu.addItem(updatedItem)
    menu.addItem(withTitle: "Refresh", action: #selector(Poller.refresh), keyEquivalent: "r").target = poller
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
}

func render(_ results: [(String, Status)]) {
    menu.removeAllItems()
    var session = 0.0, long = 0.0, tooltip: [String] = []
    for (name, status) in results {
        if menu.items.count > 0 { menu.addItem(.separator()) }
        menu.addItem(row(HeaderRow(name)))
        switch status {
        case .limits(let limits):
            for l in limits {
                menu.addItem(row(UsageRow("\(name) \(l.label)", l.label, l.pct, resetText(l.resets))))
                if l.short { session = max(session, l.pct) } else { long = max(long, l.pct) }
                tooltip.append(String(format: "%@ %@ %.0f%%", name, l.label.lowercased(), l.pct))
                checkAlert("\(name) \(l.label.lowercased())", l.pct, resetText(l.resets))
            }
        case .login(let title, let command):
            let fix = command == nil
                ? note(title, "arrow.up.forward.app", action: #selector(Poller.openApp(_:)), tip: "Sign in, then Refresh")
                : note(title, "doc.on.doc", action: #selector(Poller.copyCommand(_:)), tip: "Run it in Terminal, then Refresh")
            fix.representedObject = command ?? name
            menu.addItem(fix)
        case .error(let message):
            menu.addItem(note(message, "exclamationmark.triangle"))
        }
    }
    if results.isEmpty {
        menu.addItem(note("No Claude Code, Codex or Cursor login found", "exclamationmark.triangle"))
    }
    let anyLimits = results.contains { if case .limits = $0.1 { return true } else { return false } }
    if anyLimits {
        item.button?.contentTintColor = nil
        setRing(session: session, weekly: long)
        item.button?.toolTip = tooltip.joined(separator: "\n")
    } else {
        ringTimer?.invalidate(); ringShown = (0, 0)
        let img = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "No usage available")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.contentTintColor = .systemRed
        item.button?.toolTip = "No usage available"
    }
    addControls()
    if menuOpen { glideChangedRows() }  // a refresh landed while the menu is showing
}

class Poller: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; updateFooter(); glideChangedRows() }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        glide?.invalidate()
        for r in menu.items.compactMap({ $0.view as? UsageRow }) { r.shown = r.pct; seen[r.key] = r.pct }
    }

    @objc func copyCommand(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as! String, forType: .string)
    }
    @objc func openApp(_ sender: NSMenuItem) { _ = run("/usr/bin/open", ["-a", sender.representedObject as! String]) }

    @objc func refresh() {
        lastUpdated = nil
        let group = DispatchGroup()
        var results = [Status?](repeating: nil, count: providers.count)
        for (i, p) in providers.enumerated() {
            group.enter()
            p.fetch { status in DispatchQueue.main.async { results[i] = status; group.leave() } }
        }
        group.notify(queue: .main) {
            lastUpdated = Date()
            render(zip(providers, results).compactMap { p, r in r.map { (p.name, $0) } })
        }
    }
}

let poller = Poller()
menu.delegate = poller
addControls()
poller.refresh()
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in poller.refresh() } // ponytail: 5-min poll, endpoints are rate-limited
app.run()

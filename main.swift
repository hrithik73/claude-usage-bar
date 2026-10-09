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

struct Limit {
    let label: String, symbol: String, pct: Double, resets: Date?
    let short: Bool  // session-style window (hours) vs weekly/monthly
}

enum Status {
    case limits([Limit])
    case login(String)  // what to run to log in again
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
    return hours < 24 ? "Session · \(hours) hours" : hours == 168 ? "Weekly · 7 days" : "\(hours / 24) days"
}

// MARK: - Providers. Each returns nil when that tool isn't installed or logged in on this Mac.

func claude(_ done: @escaping (Status?) -> Void) {
    guard let creds = jsonObject(run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])),
          let token = (creds["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    else { return done(.login("Run `claude` in Terminal")) }  // always shown: this is the main one
    fetch("https://api.anthropic.com/api/oauth/usage",
          ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]) { status, json in
        if status == 401 || status == 403 { return done(.login("Run `claude` in Terminal")) }
        guard let json, json["five_hour"] != nil else { return done(.error("Couldn't fetch usage")) }
        func limit(_ key: String, _ label: String, _ symbol: String, short: Bool) -> Limit {
            let w = json[key] as? [String: Any]
            return Limit(label: label, symbol: symbol, pct: w?["utilization"] as? Double ?? 0, resets: isoDate(w?["resets_at"]), short: short)
        }
        done(.limits([limit("five_hour", "Session · 5 hours", "clock.fill", short: true),
                      limit("seven_day", "Weekly · 7 days", "calendar", short: false)]))
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
        if status == 401 || status == 403 { return done(.login("Run `codex login` in Terminal")) }
        guard let rate = json?["rate_limit"] as? [String: Any] else { return done(.error("Couldn't fetch usage")) }
        let limits = ["primary_window", "secondary_window"].compactMap { key -> Limit? in
            guard let w = rate[key] as? [String: Any] else { return nil }
            let seconds = w["limit_window_seconds"] as? Double ?? 0
            return Limit(label: windowLabel(seconds: seconds), symbol: seconds < 86400 ? "clock.fill" : "calendar",
                         pct: w["used_percent"] as? Double ?? 0,
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
    else { return done(.login("Open Cursor and sign in")) }
    fetch("https://cursor.com/api/usage-summary", ["Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)"]) { status, json in
        if status == 401 || status == 403 { return done(.login("Open Cursor and sign in")) }
        guard let json, let plan = (json["individualUsage"] as? [String: Any])?["plan"] as? [String: Any],
              let pct = plan["totalPercentUsed"] as? Double
        else { return done(.error("Couldn't fetch usage")) }
        done(.limits([Limit(label: "Monthly · billing cycle", symbol: "calendar", pct: pct,
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

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    return "Resets " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
}

// Menu row: icon + label + % on top, rounded capsule bar, reset time below.
class UsageRow: NSView {
    let symbol: String, label: String, pct: Double, reset: String
    init(_ symbol: String, _ label: String, _ pct: Double, _ reset: String) {
        (self.symbol, self.label, self.pct, self.reset) = (symbol, label, pct, reset)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 62))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let x: CGFloat = 16, w = bounds.width - 32, color = levelColor(pct)
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color]))
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)?
            .draw(in: NSRect(x: x, y: 9, width: 15, height: 15))
        (label as NSString).draw(at: NSPoint(x: x + 21, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let pctStr = String(format: "%.0f%%", pct) as NSString
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold), .foregroundColor: color]
        pctStr.draw(at: NSPoint(x: x + w - pctStr.size(withAttributes: pctAttrs).width, y: 8), withAttributes: pctAttrs)

        let track = NSRect(x: x, y: 30, width: w, height: 8)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        let fillW = max(track.height, track.width * min(pct, 100) / 100) // keep a dot visible at 0%
        NSGradient(starting: color.withAlphaComponent(0.7), ending: color)?
            .draw(in: NSBezierPath(roundedRect: NSRect(x: x, y: 30, width: fillW, height: 8), xRadius: 4, yRadius: 4), angle: 0)

        (reset as NSString).draw(at: NSPoint(x: x, y: 43), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

func row(_ v: NSView) -> NSMenuItem { let i = NSMenuItem(); i.view = v; return i }

func header(_ title: String) -> NSMenuItem {
    let i = NSMenuItem()
    i.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
    return i
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

func addControls() {
    menu.addItem(.separator())
    menu.addItem(withTitle: "Refresh", action: #selector(Poller.refresh), keyEquivalent: "r").target = poller
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
}

func render(_ results: [(String, Status)]) {
    menu.removeAllItems()
    var session = 0.0, long = 0.0, tooltip: [String] = []
    for (name, status) in results {
        if menu.items.count > 0 { menu.addItem(.separator()) }
        menu.addItem(header(name))
        switch status {
        case .limits(let limits):
            for l in limits {
                menu.addItem(row(UsageRow(l.symbol, l.label, l.pct, resetText(l.resets))))
                if l.short { session = max(session, l.pct) } else { long = max(long, l.pct) }
                tooltip.append(String(format: "%@ %@ %.0f%%", name, l.label.components(separatedBy: " · ")[0].lowercased(), l.pct))
                checkAlert("\(name) \(l.label.components(separatedBy: " · ")[0].lowercased())", l.pct, resetText(l.resets))
            }
        case .login(let how):
            menu.addItem(withTitle: "Not logged in", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "\(how), then click Refresh", action: nil, keyEquivalent: "")
        case .error(let message):
            menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
        }
    }
    if results.isEmpty {
        menu.addItem(withTitle: "No Claude Code, Codex or Cursor login found", action: nil, keyEquivalent: "")
    }
    let anyLimits = results.contains { if case .limits = $0.1 { return true } else { return false } }
    if anyLimits {
        item.button?.contentTintColor = nil
        item.button?.image = ringIcon(session: session, weekly: long)
        item.button?.toolTip = tooltip.joined(separator: "\n")
    } else {
        let img = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "No usage available")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.contentTintColor = .systemRed
        item.button?.toolTip = "No usage available"
    }
    addControls()
}

class Poller: NSObject {
    @objc func refresh() {
        let group = DispatchGroup()
        var results = [Status?](repeating: nil, count: providers.count)
        for (i, p) in providers.enumerated() {
            group.enter()
            p.fetch { status in DispatchQueue.main.async { results[i] = status; group.leave() } }
        }
        group.notify(queue: .main) {
            render(zip(providers, results).compactMap { p, r in r.map { (p.name, $0) } })
        }
    }
}

let poller = Poller()
addControls()
poller.refresh()
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in poller.refresh() } // ponytail: 5-min poll, endpoints are rate-limited
app.run()

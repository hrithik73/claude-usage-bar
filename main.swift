import AppKit
import UserNotifications
import ServiceManagement

// Reads the OAuth token Claude Code stores in Keychain, polls the same endpoint `/usage` uses.
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

// Error state: red SF Symbol in the menu bar, explanation in the menu.
func showError(_ symbol: String, _ message: String) {
    let img = NSImage(systemSymbolName: symbol, accessibilityDescription: message)
    img?.isTemplate = true
    item.button?.image = img
    item.button?.contentTintColor = .systemRed
    item.button?.toolTip = message
    menu.removeAllItems()
    menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
    addControls()
}

// No token, or the token expired (Claude Code renews it only while you use it).
func showLoginError() {
    showError("person.crop.circle.badge.exclamationmark", "Not logged in to Claude Code")
    menu.insertItem(withTitle: "Run `claude` in Terminal, then click Refresh", action: nil, keyEquivalent: "", at: 1)
}

func addControls() {
    menu.addItem(.separator())
    menu.addItem(withTitle: "Refresh", action: #selector(Poller.refresh), keyEquivalent: "r").target = poller
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
}

// Two concentric rings, Activity-style: outer = weekly, inner = session.
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
    img.accessibilityDescription = String(format: "Claude usage: session %.0f%%, weekly %.0f%%", session, weekly)
    return img
}

func token() -> String? {
    let p = Process(); let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    p.standardOutput = out
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
    return oauth["accessToken"] as? String
}

func resetText(_ iso: String?) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let iso, let d = f.date(from: iso) else { return "" }
    return "resets " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
}

extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

func levelColor(_ pct: Double) -> NSColor {
    pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : .systemGreen
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
    notify("Claude \(name) limit at \(Int(pct))%", reset.capitalizedFirst)
}

func render(_ json: [String: Any]) {
    let s = json["five_hour"] as? [String: Any], w = json["seven_day"] as? [String: Any]
    let sp = s?["utilization"] as? Double ?? 0, wp = w?["utilization"] as? Double ?? 0
    item.button?.contentTintColor = nil
    item.button?.image = ringIcon(session: sp, weekly: wp)
    item.button?.toolTip = String(format: "5h %.0f%% · 7d %.0f%%", sp, wp)
    checkAlert("session", sp, resetText(s?["resets_at"] as? String))
    checkAlert("weekly", wp, resetText(w?["resets_at"] as? String))
    menu.removeAllItems()
    menu.addItem(row(UsageRow("clock.fill", "Session · 5 hours", sp, resetText(s?["resets_at"] as? String).capitalizedFirst)))
    menu.addItem(row(UsageRow("calendar", "Weekly · 7 days", wp, resetText(w?["resets_at"] as? String).capitalizedFirst)))
    addControls()
}

class Poller: NSObject {
    @objc func refresh() {
        guard let t = token() else { showLoginError(); return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                if status == 401 || status == 403 { showLoginError() }
                else if let json, json["five_hour"] != nil { render(json) }
                else { showError("exclamationmark.triangle", "Couldn't fetch usage. Check your connection.") }
            }
        }.resume()
    }
}

let poller = Poller()
addControls()
poller.refresh()
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in poller.refresh() } // ponytail: 5-min poll, endpoint is rate-limited
app.run()

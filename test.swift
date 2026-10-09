// Checks the 90% alert logic: fires once per crossing, re-arms after dropping below.
// Run: ./test.sh
var sent: [String] = []
func notify(_ title: String, _ body: String) { sent.append(title) }

for (pct, expected) in [(50.0, 0), (91, 1), (95, 1), (99, 1), (10, 1), (90, 2)] {
    checkAlert("Claude session", pct, "Resets in 1 hour")
    assert(sent.count == expected, "at \(pct)% expected \(expected) alerts, got \(sent.count)")
}
checkAlert("Cursor monthly", 92, "")  // limits tracked independently
assert(sent.count == 3 && sent.last == "Cursor monthly limit at 92%")
print("ok: \(sent)")

// Checks the 90% alert logic: fires once per crossing, re-arms after dropping below.
// Run: ./test.sh
var sent: [String] = []
func notify(_ title: String, _ body: String) { sent.append(title) }
extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

for (pct, expected) in [(50.0, 0), (91, 1), (95, 1), (99, 1), (10, 1), (90, 2)] {
    checkAlert("session", pct, "resets in 1 hour")
    assert(sent.count == expected, "at \(pct)% expected \(expected) alerts, got \(sent.count)")
}
checkAlert("weekly", 92, "")  // limits tracked independently
assert(sent.count == 3 && sent.last == "Claude weekly limit at 92%")
print("ok: \(sent)")

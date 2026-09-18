// select-text <bundle-id> <needle> <occurrence>: select the nth occurrence (1-based) of needle in
// the app's focused text view, through Accessibility — the text-range dialect, as a Cocoa text
// view exposes it. Exits non-zero, saying why, if it cannot.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count == 4, let occurrence = Int(arguments[3]), occurrence >= 1 else {
    FileHandle.standardError.write(Data("usage: select-text <bundle-id> <needle> <occurrence>\n".utf8)); exit(64)
}
func fail(_ reason: String) -> Never { FileHandle.standardError.write(Data("select-text: \(reason)\n".utf8)); exit(1) }
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[1]).first else { fail("\(arguments[1]) is not running") }
guard let focused = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
      CFGetTypeID(focused) == AXUIElementGetTypeID()
else { fail("no focused element") }
let field = focused as! AXUIElement
guard let text = attribute(field, kAXValueAttribute) as? NSString else { fail("the focused element has no text") }
var found = NSRange(location: NSNotFound, length: 0)
var from = 0
for _ in 0..<occurrence {
    found = text.range(of: arguments[2], range: NSRange(location: from, length: text.length - from))
    guard found.location != NSNotFound else { fail("occurrence \(occurrence) of '\(arguments[2])' not found") }
    from = found.location + 1
}
var range = CFRange(location: found.location, length: found.length)
let status = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!)
guard status == .success else { fail("setting the selection failed: AXError \(status.rawValue)") }

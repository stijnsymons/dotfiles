// Full-screen meeting announcement, shown ~1 minute before a meeting starts.
//
//   meeting-overlay <event.json>
//
// Deliberately disruptive: it covers everything, including the menu bar and
// any fullscreen app, on the PRIMARY display (NSScreen.screens[0]) - the same
// screen `--bar display=main` puts the bar on, so the announcement and the bar
// never end up on different monitors.
//
// Dismiss: Esc, or the Cancel button. Join opens the conference link and
// closes. There is no snooze. A hard timeout closes it regardless, so a
// forgotten overlay cannot sit on top of the machine indefinitely.
//
// Run with: swift bin/meeting-overlay.swift <event.json>
import AppKit

let HARD_TIMEOUT: TimeInterval = 300   // 5 min backstop

// --- input ------------------------------------------------------------------
guard CommandLine.arguments.count > 1,
      let raw = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      let ev = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
else {
    FileHandle.standardError.write("meeting-overlay: need a readable event JSON\n".data(using: .utf8)!)
    exit(2)
}

func str(_ k: String) -> String? { ev[k] as? String }
let title = (str("summary") ?? "(no title)").trimmingCharacters(in: .whitespacesAndNewlines)
let location = str("location")
let link = str("_link")          // resolved by meeting_announce.sh
let tierName = str("_tier") ?? "internal"
let whenText = str("_when") ?? ""
let peopleText = str("_people") ?? ""

// Same palette as the bar, so the overlay reads as part of the same system.
func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff)/255.0,
                   green: CGFloat((v >> 8) & 0xff)/255.0,
                   blue: CGFloat(v & 0xff)/255.0, alpha: 1)
}
let accent: NSColor = {
    switch tierName {
    case "external": return hex("7aa2f7")   // BLUE
    case "none":     return hex("9d7cd8")   // VIOLET
    default:         return hex("9ece6a")   // GREEN
    }
}()
let fg = hex("c0caf5"), dim = hex("565f89"), bg = hex("1a1b26")

// --- window -----------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let screen = NSScreen.screens.first else { exit(3) }

let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
win.setFrame(screen.frame, display: true)
// Fully opaque on purpose. At 0.97 the desktop behind stayed legible, which
// both softens a deliberately disruptive announcement and would leak whatever
// is on screen into a screen share.
win.isOpaque = true
win.backgroundColor = bg
// .screenSaver puts it above the menu bar; the collection behaviour is what
// gets it over a fullscreen app rather than onto a space of its own.
win.level = .screenSaver
win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
win.ignoresMouseEvents = false

let root = NSView(frame: screen.frame)
win.contentView = root

func label(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = .center
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 2
    return l
}

let stack = NSStackView()
stack.orientation = .vertical
stack.alignment = .centerX
stack.spacing = 18
stack.translatesAutoresizingMaskIntoConstraints = false

stack.addArrangedSubview(label("STARTING IN 1 MINUTE", size: 18, color: accent, weight: .semibold))
stack.addArrangedSubview(label(title, size: 64, color: fg, weight: .bold))
if !whenText.isEmpty { stack.addArrangedSubview(label(whenText, size: 26, color: dim)) }
if !peopleText.isEmpty { stack.addArrangedSubview(label(peopleText, size: 20, color: dim)) }
if let loc = location, !loc.isEmpty, link == nil {
    stack.addArrangedSubview(label(loc, size: 20, color: dim))
}

// --- actions ----------------------------------------------------------------
final class Actions: NSObject {
    var link: String?
    @objc func join() {
        if let l = link, let u = URL(string: l) { NSWorkspace.shared.open(u) }
        NSApp.terminate(nil)
    }
    @objc func cancel() { NSApp.terminate(nil) }
}
let actions = Actions()
actions.link = link

let buttons = NSStackView()
buttons.orientation = .horizontal
buttons.spacing = 16

func button(_ t: String, _ sel: Selector, primary: Bool) -> NSButton {
    let b = NSButton(title: t, target: actions, action: sel)
    b.bezelStyle = .rounded
    b.font = .systemFont(ofSize: 18, weight: primary ? .semibold : .regular)
    b.contentTintColor = primary ? accent : dim
    b.setButtonType(.momentaryPushIn)
    return b
}

if link != nil { buttons.addArrangedSubview(button("Join", #selector(Actions.join), primary: true)) }
let cancelButton = button("Cancel  (esc)", #selector(Actions.cancel), primary: false)
cancelButton.keyEquivalent = "\u{1b}"          // Esc also fires the button
buttons.addArrangedSubview(cancelButton)
stack.addArrangedSubview(buttons)

if let l = link { stack.addArrangedSubview(label(l, size: 14, color: dim)) }

root.addSubview(stack)
NSLayoutConstraint.activate([
    stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
    stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    stack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.8),
])

// Esc via a monitor as well as the key equivalent: the key equivalent only
// works while the button chain has focus, and a borderless window does not
// always get that on first show.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    if e.keyCode == 53 { NSApp.terminate(nil); return nil }
    return e
}

win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + HARD_TIMEOUT) { NSApp.terminate(nil) }
app.run()

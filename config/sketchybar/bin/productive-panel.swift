// The Productive timer panel: this week's bookings, the 40h bar and the seven
// day columns, in a native window that opens right under the bar's anchor item.
//
//   productive-panel [--board <board.json>] [--top <px from screen top>] [--x <px>]
//                    [--appearance light|dark] [--screenshot <out.png>]
//
// Why a window and not a sketchybar popup: popups are text rows. They can list
// the bookings and fake a horizontal bar, but not columns that float on a clock
// axis with a dashed presence outline, hatching, hover or tooltips. This is the
// one place on the bar that draws, so it uses what macOS has natively:
// NSVisualEffectView vibrancy (light/dark follows the system on its own),
// Core Graphics for the bar and the columns, SF Symbols for the play buttons,
// NSView tooltips, a fade/slide open.
//
// It only READS productive-board.json (productive_board.sh owns that file, and
// the herdr.app mod reads the same one, so the two UIs cannot disagree) and its
// only action is productive_switch.sh <service_id>. It never talks to
// Productive itself.
//
// Dismiss: Esc, a click anywhere else (the window resigning key, plus a global
// mouse monitor for the clicks that do not take focus), or a switch. The panel
// reloads the board file while open, so a timer started from a chip shows up.
//
// Run with: swift bin/productive-panel.swift --board <fixture.json>
import AppKit

// --- args -------------------------------------------------------------------
var boardPath = ProcessInfo.processInfo.environment["PRODUCTIVE_BOARD"] ?? ""
var topInset: CGFloat = 36
var anchorX: CGFloat = 12
var forcedAppearance: NSAppearance.Name? = nil
var shotPath: String? = nil
do {
    let a = CommandLine.arguments
    var i = 1
    while i < a.count {
        let v: String? = i + 1 < a.count ? a[i + 1] : nil
        switch a[i] {
        case "--board": boardPath = v ?? boardPath
        case "--top": topInset = CGFloat(Double(v ?? "") ?? Double(topInset))
        case "--x": anchorX = CGFloat(Double(v ?? "") ?? Double(anchorX))
        case "--appearance": forcedAppearance = v == "light" ? .aqua : .darkAqua
        case "--screenshot": shotPath = v
        default: i -= 1
        }
        i += 2
    }
}
if boardPath.isEmpty {
    let env = ProcessInfo.processInfo.environment
    let cache = env["SB_CACHE_DIR"] ?? (env["XDG_CACHE_HOME"] ?? NSHomeDirectory() + "/.cache") + "/sketchybar"
    boardPath = cache + "/productive-board.json"
}
// bin/ sits next to plugins/, whichever way the binary was started.
let configDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().path

// --- palette ----------------------------------------------------------------
// Tokyo Night, as colors.sh. Booking colours come from the board verbatim; the
// state colours get a darker twin in light mode so text stays readable.
func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0; Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
func dyn(_ dark: String, _ light: String) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light) }
}
let green = dyn("9ece6a", "4f8a1e"), amber = dyn("e0af68", "9a6a1d")
let greenFill = dyn("9ece6a", "6aa83a"), onGreen = hex("1a1b26")
let dim = NSColor.secondaryLabelColor, faint = NSColor.tertiaryLabelColor

// --- data -------------------------------------------------------------------
struct Booking {
    let key, project, budget, name, code, serviceId: String
    let color: NSColor
    let tracked: Int
    let booked: Int?
    let pinned: Bool
}
struct Day { let date, dow: String; let start, end: String?; let minutes: [String: Int] }
struct Board {
    var week = "", from = "", to = "", generatedAt = "", state = "unknown"
    var runningKey: String? = nil
    var runningMin = 0
    var total = 0, target = 2400, overtime = 0
    var bookings: [Booking] = [], days: [Day] = []
    func booking(_ k: String) -> Booking? { bookings.first { $0.key == k } }
}
func loadBoard() -> Board? {
    guard let raw = FileManager.default.contents(atPath: boardPath),
          let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
    var b = Board()
    b.week = j["week"] as? String ?? ""; b.from = j["from"] as? String ?? ""; b.to = j["to"] as? String ?? ""
    b.generatedAt = j["generated_at"] as? String ?? ""; b.state = j["state"] as? String ?? "unknown"
    if let r = j["running"] as? [String: Any] {
        b.runningKey = r["key"] as? String; b.runningMin = r["elapsed_minutes"] as? Int ?? 0
    }
    b.total = j["total_minutes"] as? Int ?? 0; b.target = j["target_minutes"] as? Int ?? 2400
    b.overtime = j["overtime_minutes"] as? Int ?? 0
    for x in j["bookings"] as? [[String: Any]] ?? [] {
        b.bookings.append(Booking(
            key: x["key"] as? String ?? "", project: x["project"] as? String ?? "",
            budget: x["budget"] as? String ?? "", name: x["name"] as? String ?? "",
            code: x["code"] as? String ?? "", serviceId: "\(x["service_id"] ?? "")",
            color: hex(x["color"] as? String ?? "#7aa2f7"), tracked: x["tracked_minutes"] as? Int ?? 0,
            booked: x["booked_minutes"] as? Int, pinned: x["pinned"] as? Bool ?? false))
    }
    for x in j["days"] as? [[String: Any]] ?? [] {
        b.days.append(Day(date: x["date"] as? String ?? "", dow: x["dow"] as? String ?? "",
                          start: x["start"] as? String, end: x["end"] as? String,
                          minutes: x["minutes"] as? [String: Int] ?? [:]))
    }
    return b
}

// Same wording as the herdr mod: rows say 12H / 15M / 0M, the running row and the
// header say 1h12m.
func fmtRow(_ m: Int) -> String { m == 0 ? "0M" : m < 60 ? "\(m)M" : "\(Int((Double(m) / 60).rounded()))H" }
func fmtHM(_ m: Int) -> String { m >= 60 ? String(format: "%dh%02dm", m / 60, m % 60) : "\(m)m" }
func clock(_ s: String) -> Double {
    let p = s.split(separator: ":").compactMap { Double($0) }
    return p.count == 2 ? p[0] + p[1] / 60 : 0
}
func weekTitle(_ b: Board) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    let w = b.week.split(separator: "W").last.map(String.init) ?? "", d = DateFormatter()
    d.locale = f.locale
    guard let a = f.date(from: b.from), let z = f.date(from: b.to) else { return "Week \(w)" }
    d.dateFormat = "d"; let da = d.string(from: a), dz = d.string(from: z)
    d.dateFormat = "MMM"; let ma = d.string(from: a), mz = d.string(from: z)
    return "Week \(w) · " + (ma == mz ? "\(da)–\(dz) \(mz)" : "\(da) \(ma) – \(dz) \(mz)")
}

// --- shared drawing helpers -------------------------------------------------
// 0 -> 1 while the panel opens: the bar and the columns grow in rather than pop.
var openProgress: CGFloat = 0
func ease(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

func text(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, align: NSTextAlignment = .left, kern: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern])
        .draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}
let capsFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
let monoSmall = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

/// Overlays hatching on `rect` (clipped): the overtime.
func hatch(_ ctx: CGContext, _ rect: NSRect) {
    ctx.saveGState(); ctx.clip(to: rect)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.42).cgColor); ctx.setLineWidth(1.6)
    var x = rect.minX - rect.height
    while x < rect.maxX {
        ctx.move(to: CGPoint(x: x, y: rect.maxY)); ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)); x += 5
    }
    ctx.strokePath(); ctx.restoreGState()
}

/// A view that registers one tooltip rect per hit target and re-registers on layout.
class HoverView: NSView, NSViewToolTipOwner {
    override var isFlipped: Bool { true }
    var hits: [(rect: NSRect, tip: String)] = []
    var hover: Int? = nil { didSet { if oldValue != hover { needsDisplay = true } } }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hover = hits.firstIndex { $0.rect.contains(p) }
    }
    override func mouseExited(with e: NSEvent) { hover = nil }
    func registerTips() {
        removeAllToolTips()
        for (i, h) in hits.enumerated() { addToolTip(h.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1)) }
    }
    func view(_ v: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        let i = Int(bitPattern: userData) - 1
        return hits.indices.contains(i) ? hits[i].tip : ""
    }
}

// --- one booking row --------------------------------------------------------
final class RowView: NSView {
    override var isFlipped: Bool { true }
    let b: Booking, running: Bool, elapsed: Int, onSwitch: (Booking) -> Void
    var hovering = false { didSet { needsDisplay = true; play.alphaValue = hovering || running ? 1 : 0.55 } }
    let play = NSButton()
    init(_ b: Booking, running: Bool, elapsed: Int, frame: NSRect, onSwitch: @escaping (Booking) -> Void) {
        self.b = b; self.running = running; self.elapsed = elapsed; self.onSwitch = onSwitch
        super.init(frame: frame)
        toolTip = (running ? "Timing now, \(fmtHM(elapsed))\n" : "") + "\(b.project) · \(b.budget)\n"
            + "Tracked \(fmtHM(b.tracked))" + (b.booked.map { " of \(fmtHM($0)) booked (\($0 > 0 ? b.tracked * 100 / $0 : 0)%)" } ?? "")
        play.isBordered = false; play.imagePosition = .imageOnly; play.target = self; play.action = #selector(go)
        play.image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill", accessibilityDescription: running ? "Timing" : "Start")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        play.contentTintColor = running ? onGreen : .labelColor
        play.toolTip = running ? "Already timing" : "Start timing \(b.code)"
        play.alphaValue = running ? 1 : 0.55
        play.frame = NSRect(x: frame.width - 28, y: (frame.height - 22) / 2, width: 22, height: 22)
        addSubview(play)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func go() { onSwitch(b) }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { go() }
    override func draw(_ r: NSRect) {
        if running { green.withAlphaComponent(0.13).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        else if hovering { NSColor.labelColor.withAlphaComponent(0.07).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        b.color.setFill(); NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 4, height: bounds.height - 12), xRadius: 2, yRadius: 2).fill()
        // play button disc, drawn here so it sits under the SF Symbol
        let d = play.frame.insetBy(dx: 0, dy: 0)
        if running { greenFill.setFill(); NSBezierPath(ovalIn: d).fill() }
        else { NSColor.separatorColor.setStroke(); let p = NSBezierPath(ovalIn: d.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke() }
        // right: tracked bold, /booked dim
        let tw: CGFloat = 70, tx = d.minX - 10 - tw
        let t = NSMutableAttributedString(string: fmtRow(b.tracked), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: b.tracked == 0 ? dim : NSColor.labelColor])
        if let bk = b.booked { t.append(NSAttributedString(string: "/" + fmtRow(bk), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: dim])) }
        let ps = NSMutableParagraphStyle(); ps.alignment = .right
        t.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: t.length))
        t.draw(in: NSRect(x: tx, y: (bounds.height - 15) / 2, width: tw, height: 16))
        // left: full name, dim budget, green elapsed on the running row
        let n = NSMutableAttributedString(string: b.project, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor])
        n.append(NSAttributedString(string: " · " + b.budget, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: dim]))
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        n.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: n.length))
        n.draw(with: NSRect(x: 16, y: (bounds.height - 16) / 2, width: tx - 24 - (running ? 56 : 0), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        // the live elapsed sits beside the figures, not after the name, so a long project name never pushes it out
        if running { text(fmtHM(elapsed), NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), green,
                          in: NSRect(x: tx - 62, y: (bounds.height - 15) / 2, width: 56, height: 16), align: .right) }
    }
}

// --- the 40h week bar -------------------------------------------------------
final class WeekBar: HoverView {
    var board = Board()
    var domain: Double { max(Double(board.target), (Double(board.total) / 300).rounded(.up) * 300) }
    let barY: CGFloat = 22, barH: CGFloat = 16
    var segs: [(b: Booking, r: NSRect)] = []
    override func layout() { super.layout(); relayout() }
    func relayout() {
        let x0: CGFloat = 0, w = bounds.width, scale = w / CGFloat(domain) * openProgress
        var x = x0; segs = []; hits = []
        for b in board.bookings.sorted(by: { $0.tracked > $1.tracked }) where b.tracked > 0 {
            let r = NSRect(x: x, y: barY, width: CGFloat(b.tracked) * scale, height: barH)
            segs.append((b, r)); x = r.maxX
            hits.append((r, "\(b.project) · \(b.budget)\n\(fmtHM(b.tracked)) this week, \(board.total > 0 ? b.tracked * 100 / board.total : 0)% of the total"))
        }
        registerTips()
    }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        relayout()
        let over = board.overtime > 0
        text("THIS WEEK", capsFont, dim, in: NSRect(x: 0, y: 0, width: 120, height: 14), kern: 0.8)
        let right = NSMutableAttributedString(string: fmtHM(board.total), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        right.append(NSAttributedString(string: " / \(board.target / 60)h", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: dim]))
        if over { right.append(NSAttributedString(string: "  +\(fmtHM(board.overtime)) over", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: amber])) }
        let ps = NSMutableParagraphStyle(); ps.alignment = .right
        right.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: right.length))
        right.draw(in: NSRect(x: 120, y: 0, width: bounds.width - 120, height: 15))

        let track = NSRect(x: 0, y: barY, width: bounds.width, height: barH)
        NSColor.labelColor.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        ctx.saveGState()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).addClip()
        for (i, s) in segs.enumerated() {
            s.b.color.setFill(); s.r.fill()
            if hover == i { NSColor.white.withAlphaComponent(0.28).setFill(); s.r.fill() }
            if i > 0 { NSColor.black.withAlphaComponent(0.25).setFill(); NSRect(x: s.r.minX, y: s.r.minY, width: 1, height: s.r.height).fill() }
        }
        let markX = CGFloat(board.target) / CGFloat(domain) * bounds.width
        if over, let last = segs.last, last.r.maxX > markX { hatch(ctx, NSRect(x: markX, y: barY, width: last.r.maxX - markX, height: barH)) }
        ctx.restoreGState()
        NSColor.labelColor.setFill(); NSRect(x: markX - 1, y: barY - 4, width: 2, height: barH + 8).fill()
        text("\(board.target / 60)h", monoSmall, dim, in: NSRect(x: markX - 20, y: barY + barH + 6, width: 40, height: 12), align: .center)
    }
}

// --- seven day columns on a clock axis --------------------------------------
final class DaysView: HoverView {
    var board = Board()
    let axisW: CGFloat = 34, top: CGFloat = 32, bandH: CGFloat = 200, footH: CGFloat = 34
    var cols: [(day: Day, r: NSRect)] = []
    var h0 = 7.0, h1 = 23.0
    var segs: [(key: String, r: NSRect)] = []
    // hits also holds the untracked-gap tips, so a hit's index is not its seg's index.
    var hitSeg: [Int?] = []
    func y(_ t: Double) -> CGFloat { top + CGFloat((t - h0) / (h1 - h0)) * bandH }
    func relayout() {
        let ts = board.days.compactMap { $0.start }.map(clock), te = board.days.compactMap { $0.end }.map(clock)
        h0 = min(7, (ts.min() ?? 7).rounded(.down)); h1 = max(23, (te.max() ?? 23).rounded(.up))
        let cw = (bounds.width - axisW - 6 * 6) / 7
        cols = board.days.enumerated().map { (i, d) in (d, NSRect(x: axisW + CGFloat(i) * (cw + 6), y: 0, width: cw, height: bounds.height)) }
        hits = []; segs = []; hitSeg = []
        let pxMin = bandH / CGFloat((h1 - h0) * 60)
        for (_, c) in cols.enumerated() {
            // No activity samples but tracked time (laptop closed, entry booked later): the time
            // must not vanish, so it stacks from 09:00 with no presence outline.
            let s = c.day.start ?? (c.day.minutes.isEmpty ? nil : "09:00"), e = c.day.end ?? s
            guard let s = s, let e = e else { continue }
            var yy = y(clock(s))
            for (k, m) in c.day.minutes.sorted(by: { $0.value > $1.value }) {
                let hgt = CGFloat(m) * pxMin * openProgress
                let r = NSRect(x: c.r.minX + 6, y: yy, width: c.r.width - 12, height: hgt)
                let name = board.booking(k).map { "\($0.project) · \($0.budget)" } ?? k
                segs.append((k, r)); hitSeg.append(segs.count - 1); hits.append((r, "\(c.day.dow): \(name)\n\(fmtHM(m))")); yy += hgt
            }
            let total = c.day.minutes.values.reduce(0, +), pres = Int(((clock(e) - clock(s)) * 60).rounded())
            let gapTop = yy, gapBot = y(clock(e))
            if c.day.start != nil, gapBot > gapTop + 2 {
                hitSeg.append(nil)
                hits.append((NSRect(x: c.r.minX + 6, y: gapTop, width: c.r.width - 12, height: gapBot - gapTop),
                    "\(c.day.dow): at the machine \(s)–\(e)\n\(fmtHM(max(0, pres - total))) not tracked"))
            }
        }
        registerTips()
    }
    override func layout() { super.layout(); relayout() }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        relayout()
        text("PER DAY", capsFont, dim, in: NSRect(x: 0, y: 0, width: 100, height: 14), kern: 0.8)
        text("first → last activity", NSFont.systemFont(ofSize: 10), dim, in: NSRect(x: bounds.width - 160, y: 0, width: 160, height: 14), align: .right)
        for h in [8, 12, 16, 20] where Double(h) >= h0 && Double(h) <= h1 {
            NSColor.separatorColor.withAlphaComponent(0.5).setFill(); NSRect(x: axisW, y: y(Double(h)), width: bounds.width - axisW, height: 0.5).fill()
            text(String(format: "%02d:00", h), monoSmall, faint, in: NSRect(x: 0, y: y(Double(h)) - 6, width: axisW - 4, height: 12), align: .right)
        }
        let today = board.generatedAt.prefix(10)
        let hoverKey = hover.flatMap { hitSeg.indices.contains($0) ? hitSeg[$0] : nil }.map { segs[$0].r }
        for c in cols {
            let isToday = c.day.date == today
            if let hk = hoverKey, hk.minX >= c.r.minX, hk.maxX <= c.r.maxX {
                NSColor.labelColor.withAlphaComponent(0.05).setFill(); NSBezierPath(roundedRect: c.r.insetBy(dx: 1, dy: 0), xRadius: 6, yRadius: 6).fill()
            }
            let total = c.day.minutes.values.reduce(0, +)
            let mine = segs.filter { $0.r.minX == c.r.minX + 6 }
            // presence outline and the time labels only exist when there are activity samples
            if let s = c.day.start, let e = c.day.end {
                let top = y(clock(s)), bot = y(clock(e))
                let outline = NSBezierPath(roundedRect: NSRect(x: c.r.minX + 6, y: top, width: c.r.width - 12, height: max(2, (bot - top) * openProgress)), xRadius: 4, yRadius: 4)
                outline.setLineDash([3, 3], count: 2, phase: 0); outline.lineWidth = 1
                NSColor.tertiaryLabelColor.setStroke(); outline.stroke()
                text(s, monoSmall, NSColor.labelColor, in: NSRect(x: c.r.minX, y: top - 14, width: c.r.width, height: 12), align: .center)
                text(e, monoSmall, dim, in: NSRect(x: c.r.minX, y: bot + 3, width: c.r.width, height: 12), align: .center)
            }
            // the stack: one rounded clip, so only its outer corners round
            if let first = mine.first, let last = mine.last {
                ctx.saveGState()
                NSBezierPath(roundedRect: NSRect(x: first.r.minX, y: first.r.minY, width: first.r.width, height: last.r.maxY - first.r.minY), xRadius: 4, yRadius: 4).addClip()
                for s in mine {
                    (board.booking(s.key)?.color ?? dim).setFill(); s.r.fill()
                    if hoverKey == s.r { NSColor.white.withAlphaComponent(0.28).setFill(); s.r.fill() }
                }
                ctx.restoreGState()
            }
            let fy = top + bandH + 14
            text(total > 0 ? fmtRow(total) : "–", NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                 isToday ? green : NSColor.labelColor, in: NSRect(x: c.r.minX, y: fy, width: c.r.width, height: 14), align: .center)
            text(c.day.dow, NSFont.systemFont(ofSize: 10, weight: isToday ? .semibold : .regular),
                 isToday ? green : dim, in: NSRect(x: c.r.minX, y: fy + 14, width: c.r.width, height: 12), align: .center)
        }
    }
}

// --- the window -------------------------------------------------------------
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { (delegate as? Controller)?.dismiss() } else { super.keyDown(with: e) } }
    override func cancelOperation(_ sender: Any?) { (delegate as? Controller)?.dismiss() }
}

final class Controller: NSObject, NSWindowDelegate {
    let W: CGFloat = 468, pad: CGFloat = 16
    var panel: Panel!
    var fx: NSVisualEffectView!
    var board = Board()
    var mtime = Date.distantPast
    var closing = false, built = false
    var clickMonitor: Any?

    func start() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: W, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        if let n = forcedAppearance { panel.appearance = NSAppearance(named: n) }
        fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5; fx.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = fx
        reload(force: true)
        place()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // open: fade + 8pt slide down, and the bar and columns grow in
        var f = panel.frame; let end = f; f.origin.y += 8; panel.setFrame(f, display: false)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1; panel.animator().setFrame(end, display: true)
        }
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [self] tm in
            let t = min(1, Date().timeIntervalSince(t0) / 0.55)
            openProgress = ease(CGFloat(t)); fx.subviews.forEach { $0.needsDisplay = true }
            if t >= 1 { tm.invalidate() }
        }
        // Clicks elsewhere that do not take focus (another app's window, the bar)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
        // the board is rewritten every minute; the elapsed time and a switch made from a chip show up here
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload(force: false) }
    }

    func reload(force: Bool) {
        let m = (try? FileManager.default.attributesOfItem(atPath: boardPath)[.modificationDate] as? Date) ?? nil
        if !force, let m = m, m <= mtime { return }
        mtime = m ?? mtime
        guard let b = loadBoard() else { if !built { board = Board(); build() }; return }
        board = b; build()
    }

    func build() {
        built = true
        fx.subviews.forEach { $0.removeFromSuperview() }
        let rowH: CGFloat = 30, innerW = W - 2 * pad
        var y: CGFloat = 14
        let head = HeaderView(frame: NSRect(x: pad, y: y, width: innerW, height: 16)); head.title = weekTitle(board)
        fx.addSubview(head); y += 26
        if board.state == "unknown" || board.bookings.isEmpty {
            let l = NSTextField(labelWithString: board.state == "unknown" ? "No data from Productive yet." : "No bookings this week.")
            l.textColor = dim; l.font = .systemFont(ofSize: 12); l.frame = NSRect(x: pad, y: y, width: innerW, height: 20); fx.addSubview(l); y += 28
        }
        // A busy week can have more bookings than the screen has room for; the fixed part
        // (header, bar, columns) stays, the rows give way and the tail becomes "+N more".
        let room = (NSScreen.screens.first?.visibleFrame.height ?? 800) - 8 - CGFloat(topInset) - (14 + 26 + 14 + 80 + 16 + 276 + 16 + 40)
        let maxRows = max(3, Int(room / (rowH + 2)))
        let shown = board.bookings.count > maxRows ? Array(board.bookings.prefix(maxRows - 1)) : board.bookings
        for b in shown {
            let run = board.runningKey == b.key
            let r = RowView(b, running: run, elapsed: run ? board.runningMin : 0,
                            frame: NSRect(x: pad, y: y, width: innerW, height: rowH), onSwitch: { [weak self] in self?.switchTo($0) })
            fx.addSubview(r); y += rowH + 2
        }
        if shown.count < board.bookings.count {
            let l = NSTextField(labelWithString: "+\(board.bookings.count - shown.count) more, quieter this week")
            l.textColor = faint; l.font = .systemFont(ofSize: 11); l.frame = NSRect(x: pad + 16, y: y, width: innerW - 16, height: 18); fx.addSubview(l); y += 22
        }
        y += 14
        let wb = WeekBar(frame: NSRect(x: pad, y: y, width: innerW, height: 58)); wb.board = board; fx.addSubview(wb); y += 58 + 22
        let dv = DaysView(frame: NSRect(x: pad, y: y, width: innerW, height: 32 + 200 + 14 + 30)); dv.board = board
        fx.addSubview(dv); y += dv.frame.height + 16
        var f = panel.frame; let top = f.maxY; f.size = NSSize(width: W, height: y); f.origin.y = top - y
        panel.setFrame(f, display: true)
        fx.frame = NSRect(origin: .zero, size: f.size)
        // the views were laid out top-down in flipped coordinates; fx is not flipped, so mirror the y
        fx.subviews.forEach { $0.frame.origin.y = f.height - $0.frame.origin.y - $0.frame.height }
    }

    func place() {
        guard let s = NSScreen.screens.first else { return }
        var f = panel.frame
        f.origin.x = min(max(s.frame.minX + 8, s.frame.minX + anchorX), s.frame.maxX - W - 8)
        f.origin.y = s.frame.maxY - topInset - f.height
        panel.setFrame(f, display: true)
    }

    func switchTo(_ b: Booking) {
        // Clicking the booking already running is a no-op in the script too, so
        // there is nothing to wait for or to close on.
        if board.runningKey == b.key { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [configDir + "/plugins/productive_switch.sh", b.serviceId]
        var env = ProcessInfo.processInfo.environment; env["CONFIG_DIR"] = configDir; p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.dismiss() }
    }

    func windowDidResignKey(_ n: Notification) { dismiss() }
    func dismiss() {
        if closing || shotPath != nil { return }
        closing = true
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        // The toggle script reads this: the click that closes us by resigning key
        // must not be mistaken for a click that asks to open us again.
        let cache = ProcessInfo.processInfo.environment["SB_CACHE_DIR"] ?? NSHomeDirectory() + "/.cache/sketchybar"
        try? "\(Date().timeIntervalSince1970)".write(toFile: cache + "/productive-panel.closed", atomically: true, encoding: .utf8)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12; panel.animator().alphaValue = 0
        }, completionHandler: { exit(0) })
    }
}

final class HeaderView: NSView {
    override var isFlipped: Bool { true }
    var title = ""
    override func draw(_ r: NSRect) {
        text(title.uppercased(), capsFont, dim, in: NSRect(x: 0, y: 0, width: bounds.width - 90, height: 14), kern: 0.8)
        text("PRODUCTIVE", capsFont, faint, in: NSRect(x: bounds.width - 90, y: 0, width: 90, height: 14), align: .right, kern: 0.8)
    }
}

// --- main -------------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
if let out = shotPath {
    // Test seam: render the content to a PNG and quit, so the drawing can be
    // inspected without a screen grab permission.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let v = controller.fx!
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        exit(0)
    }
}
app.run()

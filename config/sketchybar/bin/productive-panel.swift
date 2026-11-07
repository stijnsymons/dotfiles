// The Productive timer panel: this week's bookings, the 40h bar and the seven
// day columns, in a native window that opens right under the bar's anchor item.
//
//   productive-panel [--board <board.json>] [--top <px from screen top>] [--x <px>]
//                    [--screenshot <out.png>]
//                    test seams (with --screenshot): [--hover-seg <n>] [--hover-day <n>] [--toggle-item <n>]
//
// Why a window and not a sketchybar popup: popups are text rows. They can list
// the bookings and fake a horizontal bar, but not columns that float on a clock
// axis with a dashed presence outline, hatching, pies or hover detail. This is the
// one place on the bar that draws, so it uses what macOS has natively:
// Core Graphics for the bar, the columns and the pies, SF Symbols for the play
// buttons, a fade/slide open.
//
// Always dark, in the bar's own Tokyo Night (colors.sh), whatever the system
// appearance says: the panel hangs off the bar and must read as part of it.
//
// It only READS productive-board.json (productive_board.sh owns that file, and
// the herdr.app mod reads the same one, so the two UIs cannot disagree) and its
// actions are productive_switch.sh <service_id> and focus_upcoming.sh toggle, which
// ticks a line of this week's Focus note in Obsidian. It never talks to Productive
// itself.
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
var shotPath: String? = nil
var testHoverSeg: Int? = nil, testHoverDay: Int? = nil, testToggle: Int? = nil, startOffset = 0
do {
    let a = CommandLine.arguments
    var i = 1
    while i < a.count {
        let v: String? = i + 1 < a.count ? a[i + 1] : nil
        switch a[i] {
        case "--board": boardPath = v ?? boardPath
        case "--top": topInset = CGFloat(Double(v ?? "") ?? Double(topInset))
        case "--x": anchorX = CGFloat(Double(v ?? "") ?? Double(anchorX))
        case "--hover-seg": testHoverSeg = Int(v ?? "")
        case "--hover-day": testHoverDay = Int(v ?? "")
        case "--toggle-item": testToggle = Int(v ?? "")
        case "--offset": startOffset = Int(v ?? "") ?? 0
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
// Tokyo Night Storm, copied from colors.sh (POPUP_BG, FG, FG_DIM, SEPARATOR...).
// Booking colours come from the board verbatim. dim is a step lighter than the
// bar's FG_DIM (#565f89, the comment colour): that one is fine for a glyph but
// too faint for 10pt text on a panel, so it is kept for `faint`.
func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0; Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let bg = hex("1f2335"), fg = hex("c0caf5"), dim = hex("828bb8"), faint = hex("565f89"), sep = hex("3b4261")
let green = hex("9ece6a"), amber = hex("e0af68"), onGreen = hex("1a1b26")
let greenFill = green

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
    guard let raw = FileManager.default.contents(atPath: boardPath) else { return nil }
    return parseBoard(raw)
}
// Build and parse the board for this week + offset (0 = the live cache). For other weeks this
// runs productive_board.sh --week, which refetches that week's entries, so call it OFF the main
// thread (the panel's navigate() does). Returns nil on a failed build.
func loadBoardWeek(_ offset: Int) -> Board? {
    if offset == 0 { return loadBoard() }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [configDir + "/plugins/productive_board.sh", "--week", String(offset)]
    var env = ProcessInfo.processInfo.environment; env["CONFIG_DIR"] = configDir
    if env["SB_CACHE_DIR"] == nil { env["SB_CACHE_DIR"] = NSHomeDirectory() + "/.cache/sketchybar" }
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return parseBoard(data)
}
func parseBoard(_ raw: Data) -> Board? {
    guard let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
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
// ISO-8601 week id (YYYY-Www) for this week plus `offset` weeks: the switcher's chosen week,
// used as FOCUS_WEEK so the checklist sections follow the same week as the board.
func weekId(offset: Int) -> String {
    var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
    let d = cal.date(byAdding: .weekOfYear, value: offset, to: Date()) ?? Date()
    return String(format: "%d-W%02d", cal.component(.yearForWeekOfYear, from: d), cal.component(.weekOfYear, from: d))
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

/// A view that tracks the pointer and says which hit target it is over. The
/// detail for that target is drawn by the subclass in a fixed block beneath the
/// graphic (not a native tooltip: those sit at the cursor, a beat late, and cover
/// the very thing being read).
class HoverView: NSView {
    override var isFlipped: Bool { true }
    var hits: [NSRect] = []
    var point: NSPoint? = nil { didSet { hover = point.flatMap { p in hits.firstIndex { $0.contains(p) } } } }
    var hover: Int? = nil { didSet { if oldValue != hover { needsDisplay = true } } }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { point = convert(e.locationInWindow, from: nil) }
    override func mouseExited(with e: NSEvent) { point = nil }
}

/// The fixed detail block: a faint rounded plate, up to three lines, or a hint when nothing is hovered.
func detailBlock(_ r: NSRect, _ lines: [NSAttributedString], hint: String) {
    fg.withAlphaComponent(0.05).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
    if lines.isEmpty {
        text(hint, NSFont.systemFont(ofSize: 11), faint, in: NSRect(x: r.minX + 10, y: r.midY - 7, width: r.width - 20, height: 14)); return
    }
    for (i, l) in lines.enumerated() { l.draw(with: NSRect(x: r.minX + 10, y: r.minY + 7 + CGFloat(i) * 15, width: r.width - 20, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
}
func attr(_ s: String, _ font: NSFont = .systemFont(ofSize: 11.5), _ color: NSColor = dim) -> NSMutableAttributedString {
    let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
    return NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}

/// A pie of `frac` (tracked / planned) in the booking colour. Past the target the
/// pie is full and an amber ring round it shows the excess as its own fraction:
/// 150% is a half ring, 200% or more a closed one. Polylines, not arcs: CG's arc
/// direction flips with the view, and a polyline cannot get that wrong.
func pie(_ ctx: CGContext, _ c: CGPoint, color: NSColor, frac: Double, over: Double) {
    let r: CGFloat = 5.4, ring: CGFloat = 7.6
    func pt(_ a: Double, _ rad: CGFloat) -> CGPoint { CGPoint(x: c.x + rad * CGFloat(sin(a)), y: c.y - rad * CGFloat(cos(a))) }
    fg.withAlphaComponent(0.12).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    let f = min(1, max(0, frac)) * Double(openProgress)
    if f > 0 {
        ctx.setFillColor(color.cgColor); ctx.move(to: c)
        let n = max(2, Int(f * 48)); for i in 0...n { ctx.addLine(to: pt(f * 2 * .pi * Double(i) / Double(n), r)) }
        ctx.closePath(); ctx.fillPath()
    }
    if over > 0 {
        ctx.setLineWidth(1.7); ctx.setStrokeColor(amber.withAlphaComponent(0.22).cgColor)
        ctx.addEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: 2 * ring, height: 2 * ring)); ctx.strokePath()
        let o = min(1, over) * Double(openProgress), n = max(2, Int(o * 48))
        ctx.setStrokeColor(amber.cgColor); ctx.move(to: pt(0, ring))
        for i in 1...n { ctx.addLine(to: pt(o * 2 * .pi * Double(i) / Double(n), ring)) }
        ctx.strokePath()
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
        play.contentTintColor = running ? onGreen : fg
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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if running { green.withAlphaComponent(0.13).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        else if hovering { fg.withAlphaComponent(0.07).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        b.color.setFill(); NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 4, height: bounds.height - 12), xRadius: 2, yRadius: 2).fill()
        // play button disc, drawn here so it sits under the SF Symbol
        let d = play.frame
        if running { greenFill.setFill(); NSBezierPath(ovalIn: d).fill() }
        else { sep.setStroke(); let p = NSBezierPath(ovalIn: d.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke() }
        // right to left: play, pie, planned (dim), tracked. Both number columns are
        // right-aligned so the digits line up down the list: "12H  15H". With no plan
        // (internal) the pie and the planned slot stay empty, so the rest does not shift.
        let plan = (b.booked ?? 0) > 0 ? b.booked : nil
        let pieC = CGPoint(x: d.minX - 10 - 8, y: bounds.midY)
        let px = pieC.x - 8 - 8 - 34, tx = px - 4 - 40       // planned column, tracked column
        let over = plan.map { b.tracked > $0 } ?? false
        if let p = plan {
            let f = Double(b.tracked) / Double(p)
            pie(ctx, pieC, color: b.color, frac: f, over: over ? f - 1 : 0)
            text(fmtRow(p), NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), dim,
                 in: NSRect(x: px, y: (bounds.height - 15) / 2, width: 34, height: 16), align: .right)
        }
        text(fmtRow(b.tracked), NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
             over ? amber : (b.tracked == 0 ? dim : fg), in: NSRect(x: tx, y: (bounds.height - 15) / 2, width: 40, height: 16), align: .right)
        // left: full name, dim budget
        let n = NSMutableAttributedString(string: b.project, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: fg])
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
    static let height: CGFloat = 58 + 44            // the bar itself + the detail block beneath it
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
            hits.append(r.insetBy(dx: 0, dy: -6))
        }
    }
    func detail(_ b: Booking) -> [NSAttributedString] {
        let share = board.total > 0 ? b.tracked * 100 / board.total : 0
        let head = attr("● ", .systemFont(ofSize: 11.5), b.color); head.append(attr("\(b.project) · \(b.budget)", .systemFont(ofSize: 12, weight: .semibold), fg))
        var s = "\(fmtHM(b.tracked)) tracked · \(share)% of the week · "
        s += (b.booked ?? 0) > 0 ? "\(fmtHM(b.booked!)) planned" : "no plan"
        let l2 = attr(s)
        if let p = b.booked, p > 0, b.tracked > p { l2.append(attr(" · over by \(fmtHM(b.tracked - p))", .systemFont(ofSize: 11.5, weight: .semibold), amber)) }
        return [head, l2]
    }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        relayout()
        let over = board.overtime > 0
        text("THIS WEEK", capsFont, dim, in: NSRect(x: 0, y: 0, width: 120, height: 14), kern: 0.8)
        let right = NSMutableAttributedString(string: fmtHM(board.total), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: fg])
        right.append(NSAttributedString(string: " / \(board.target / 60)h", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: dim]))
        if over { right.append(NSAttributedString(string: "  +\(fmtHM(board.overtime)) over", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: amber])) }
        let ps = NSMutableParagraphStyle(); ps.alignment = .right
        right.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: right.length))
        right.draw(in: NSRect(x: 120, y: 0, width: bounds.width - 120, height: 15))

        let track = NSRect(x: 0, y: barY, width: bounds.width, height: barH)
        fg.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
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
        fg.setFill(); NSRect(x: markX - 1, y: barY - 4, width: 2, height: barH + 8).fill()
        text("\(board.target / 60)h", monoSmall, dim, in: NSRect(x: markX - 20, y: barY + barH + 6, width: 40, height: 12), align: .center)
        detailBlock(NSRect(x: 0, y: 58, width: bounds.width, height: 38), hover.map { detail(segs[$0].b) } ?? [], hint: "Hover a segment for the booking behind it")
    }
}

// --- seven day columns on a clock axis --------------------------------------
final class DaysView: HoverView {
    static let height: CGFloat = 32 + 180 + 14 + 30 + 8 + 52   // columns + the detail block beneath
    var board = Board()
    let axisW: CGFloat = 34, top: CGFloat = 32, bandH: CGFloat = 180, footH: CGFloat = 34
    var cols: [(day: Day, r: NSRect)] = []
    var hoverCol: Int? = nil { didSet { if oldValue != hoverCol { needsDisplay = true } } }
    var h0 = 7.0, h1 = 23.0
    var segs: [(key: String, r: NSRect)] = []
    // hits also holds the untracked-gap rects, so a hit's index is not its seg's index.
    var hitSeg: [Int?] = []
    func y(_ t: Double) -> CGFloat { top + CGFloat((t - h0) / (h1 - h0)) * bandH }
    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        hoverCol = point.flatMap { p in cols.firstIndex { p.x >= $0.r.minX - 3 && p.x < $0.r.maxX + 3 && p.y < top + bandH + 44 } }
    }
    override func mouseExited(with e: NSEvent) { super.mouseExited(with: e); hoverCol = nil }
    func relayout() {
        let ts = board.days.compactMap { $0.start }.map(clock), te = board.days.compactMap { $0.end }.map(clock)
        h0 = min(7, (ts.min() ?? 7).rounded(.down)); h1 = max(23, (te.max() ?? 23).rounded(.up))
        let cw = (bounds.width - axisW - 6 * 6) / 7
        cols = board.days.enumerated().map { (i, d) in (d, NSRect(x: axisW + CGFloat(i) * (cw + 6), y: 0, width: cw, height: top + bandH + 44)) }
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
                segs.append((k, r)); hitSeg.append(segs.count - 1); hits.append(r); yy += hgt
            }
            let gapTop = yy, gapBot = y(clock(e))
            if c.day.start != nil, gapBot > gapTop + 2 {
                hitSeg.append(nil)
                hits.append(NSRect(x: c.r.minX + 6, y: gapTop, width: c.r.width - 12, height: gapBot - gapTop))
            }
        }
    }
    override func layout() { super.layout(); relayout() }
    /// date, presence, tracked vs present, the untracked gap, and the per-booking split
    func detail(_ d: Day) -> [NSAttributedString] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let o = DateFormatter(); o.locale = f.locale; o.dateFormat = "d MMM"
        let when = f.date(from: d.date).map { "\(d.dow) \(o.string(from: $0))" } ?? d.dow
        let total = d.minutes.values.reduce(0, +)
        let l1 = attr(when, .systemFont(ofSize: 12, weight: .semibold), fg)
        var l2 = attr("")
        if let s = d.start, let e = d.end {
            let pres = Int(((clock(e) - clock(s)) * 60).rounded())
            l1.append(attr("  \(s)–\(e) at the machine"))
            l2 = attr("\(fmtHM(total)) tracked of \(fmtHM(pres)) present · ")
            l2.append(attr("\(fmtHM(max(0, pres - total))) not tracked", .systemFont(ofSize: 11.5, weight: .semibold), pres - total > 60 ? amber : dim))
        } else {
            l1.append(attr(total > 0 ? "  no activity samples" : "  nothing recorded"))
            l2 = attr(total > 0 ? "\(fmtHM(total)) tracked" : "0m tracked")
        }
        let l3 = attr("")
        for (k, m) in d.minutes.sorted(by: { $0.value > $1.value }) {
            let b = board.booking(k)
            if l3.length > 0 { l3.append(attr("  ·  ")) }
            l3.append(attr("● ", .systemFont(ofSize: 11), b?.color ?? dim)); l3.append(attr("\(b?.code ?? k) \(fmtRow(m))", .systemFont(ofSize: 11.5), fg))
        }
        return [l1, l2, l3]
    }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        relayout()
        text("PER DAY", capsFont, dim, in: NSRect(x: 0, y: 0, width: 100, height: 14), kern: 0.8)
        text("first → last activity", NSFont.systemFont(ofSize: 10), dim, in: NSRect(x: bounds.width - 160, y: 0, width: 160, height: 14), align: .right)
        for h in [8, 12, 16, 20] where Double(h) >= h0 && Double(h) <= h1 {
            sep.withAlphaComponent(0.7).setFill(); NSRect(x: axisW, y: y(Double(h)), width: bounds.width - axisW, height: 0.5).fill()
            text(String(format: "%02d:00", h), monoSmall, faint, in: NSRect(x: 0, y: y(Double(h)) - 6, width: axisW - 4, height: 12), align: .right)
        }
        let today = board.generatedAt.prefix(10)
        let hoverKey = hover.flatMap { hitSeg.indices.contains($0) ? hitSeg[$0] : nil }.map { segs[$0].r }
        for (ci, c) in cols.enumerated() {
            let isToday = c.day.date == today
            if hoverCol == ci {
                fg.withAlphaComponent(0.07).setFill(); NSBezierPath(roundedRect: c.r.insetBy(dx: 1, dy: 0), xRadius: 6, yRadius: 6).fill()
            }
            let total = c.day.minutes.values.reduce(0, +)
            let mine = segs.filter { $0.r.minX == c.r.minX + 6 }
            // presence outline and the time labels only exist when there are activity samples
            if let s = c.day.start, let e = c.day.end {
                let top = y(clock(s)), bot = y(clock(e))
                let outline = NSBezierPath(roundedRect: NSRect(x: c.r.minX + 6, y: top, width: c.r.width - 12, height: max(2, (bot - top) * openProgress)), xRadius: 4, yRadius: 4)
                outline.setLineDash([3, 3], count: 2, phase: 0); outline.lineWidth = 1
                faint.setStroke(); outline.stroke()
                text(s, monoSmall, fg, in: NSRect(x: c.r.minX, y: top - 14, width: c.r.width, height: 12), align: .center)
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
                 isToday ? green : fg, in: NSRect(x: c.r.minX, y: fy, width: c.r.width, height: 14), align: .center)
            text(c.day.dow, NSFont.systemFont(ofSize: 10, weight: isToday ? .semibold : .regular),
                 isToday ? green : dim, in: NSRect(x: c.r.minX, y: fy + 14, width: c.r.width, height: 12), align: .center)
        }
        detailBlock(NSRect(x: 0, y: bounds.height - 52, width: bounds.width, height: 52),
                    hoverCol.map { detail(cols[$0].day) } ?? [], hint: "Hover a day for its hours and where they went")
    }
}

// --- the Focus note's checklist sections ------------------------------------
// One view per section (Upcoming / Actions / Past actions), stacked in the right-hand
// column. Rows are text, so hit-testing by y is simpler than a view per line. A click
// ticks the line in the note (through focus_upcoming.sh, which owns the Markdown) and
// the controller reloads. Each [heading title (matches the note), display label].
let FOCUS_SECTIONS: [(key: String, label: String)] = [("Upcoming", "UPCOMING"), ("Actions", "ACTIONS"), ("Past actions", "PAST ACTIONS")]
struct FocusItem { let line: Int; let checked: Bool; let text, raw: String }
struct Focus { var week = "", path = ""; var missing: String? = "note"; var items: [FocusItem] = [] }
func loadFocus(_ section: String = "Upcoming", week: String = "") -> Focus {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [configDir + "/plugins/focus_upcoming.sh", section, week]
    var env = ProcessInfo.processInfo.environment; env["CONFIG_DIR"] = configDir; p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return Focus() }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Focus() }
    var f = Focus(); f.week = j["week"] as? String ?? ""; f.path = j["path"] as? String ?? ""; f.missing = j["missing"] as? String
    for x in j["items"] as? [[String: Any]] ?? [] {
        f.items.append(FocusItem(line: x["line"] as? Int ?? 0, checked: x["checked"] as? Bool ?? false,
                                 text: x["text"] as? String ?? "", raw: x["raw"] as? String ?? ""))
    }
    return f
}
/// Runs the toggle and waits (it is a temp file and a rename, a few ms); the caller reloads.
func toggleFocus(_ i: FocusItem, section: String, week: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [configDir + "/plugins/focus_upcoming.sh", "toggle", String(i.line), i.raw, section, week]
    var env = ProcessInfo.processInfo.environment; env["CONFIG_DIR"] = configDir; p.environment = env
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

final class UpcomingView: NSView {
    override var isFlipped: Bool { true }
    static let font = NSFont.systemFont(ofSize: 12), textX: CGFloat = 26, headH: CGFloat = 22
    let focus: Focus, label: String, shown: [FocusItem], more: Int, onToggle: (FocusItem) -> Void
    var rows: [NSRect] = []
    var hover: Int? = nil { didSet { if oldValue != hover { needsDisplay = true } } }
    /// Height of one item: its text wraps to at most two lines.
    static func rowHeight(_ s: String, width: CGFloat) -> CGFloat {
        let h = NSAttributedString(string: s, attributes: [.font: font]).boundingRect(with: NSSize(width: width - textX, height: 1000), options: .usesLineFragmentOrigin).height
        return min(ceil(h), 32) + 10
    }
    /// What the section needs for `items`, so the controller can budget the screen before building it.
    static func height(of items: [FocusItem], width: CGFloat, more: Bool) -> CGFloat {
        headH + (items.isEmpty ? 24 : items.reduce(0) { $0 + rowHeight($1.text, width: width) }) + (more ? 20 : 0)
    }
    init(_ f: Focus, label: String, shown: [FocusItem], more: Int, frame: NSRect, onToggle: @escaping (FocusItem) -> Void) {
        focus = f; self.label = label; self.shown = shown; self.more = more; self.onToggle = onToggle
        super.init(frame: frame)
        var y = Self.headH
        for i in shown { let h = Self.rowHeight(i.text, width: frame.width); rows.append(NSRect(x: 0, y: y, width: frame.width, height: h)); y += h }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    func at(_ e: NSEvent) -> Int? { let p = convert(e.locationInWindow, from: nil); return rows.firstIndex { $0.contains(p) } }
    override func mouseMoved(with e: NSEvent) { hover = at(e) }
    override func mouseExited(with e: NSEvent) { hover = nil }
    override func mouseDown(with e: NSEvent) { if let i = at(e) { onToggle(shown[i]) } }
    override func draw(_ r: NSRect) {
        let done = focus.items.filter { $0.checked }.count
        text(label, capsFont, dim, in: NSRect(x: 0, y: 0, width: 160, height: 14), kern: 0.8)
        text(focus.missing == nil ? "\(done)/\(focus.items.count)" : "NO NOTE",
             capsFont, faint, in: NSRect(x: bounds.width - 100, y: 0, width: 100, height: 14), align: .right, kern: 0.8)
        if focus.missing != nil || focus.items.isEmpty {
            let w = focus.week.split(separator: "-").last.map(String.init) ?? focus.week
            text(focus.missing != nil ? "No Focus note for \(w)" : "Nothing in \(label.lowercased())", NSFont.systemFont(ofSize: 12), faint,
                 in: NSRect(x: 0, y: Self.headH + 2, width: bounds.width, height: 16)); return
        }
        for (n, i) in shown.enumerated() {
            let rr = rows[n]
            if hover == n { fg.withAlphaComponent(0.07).setFill(); NSBezierPath(roundedRect: rr.insetBy(dx: -4, dy: 1), xRadius: 6, yRadius: 6).fill() }
            let box = NSRect(x: 0, y: rr.minY + 6, width: 14, height: 14), bp = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            if i.checked {
                green.setFill(); bp.fill()
                onGreen.setStroke(); let t = NSBezierPath(); t.lineWidth = 1.8; t.lineCapStyle = .round; t.lineJoinStyle = .round
                t.move(to: NSPoint(x: box.minX + 3.5, y: box.midY + 0.3)); t.line(to: NSPoint(x: box.minX + 6, y: box.midY + 3)); t.line(to: NSPoint(x: box.maxX - 3.2, y: box.midY - 2.8)); t.stroke()
            } else { faint.setStroke(); bp.lineWidth = 1.2; bp.stroke() }
            let a = NSMutableAttributedString(string: i.text, attributes: [.font: Self.font, .foregroundColor: i.checked ? faint : fg])
            if i.checked { a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: a.length)) }
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping   // wraps to two lines, the last one ellipsised
            a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
            a.draw(with: NSRect(x: Self.textX, y: rr.minY + 5, width: bounds.width - Self.textX, height: rr.height - 8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if more > 0 { text("+\(more) more in the note", NSFont.systemFont(ofSize: 11), faint, in: NSRect(x: Self.textX, y: (rows.last?.maxY ?? Self.headH) + 3, width: bounds.width - Self.textX, height: 14)) }
    }
}

// --- the window -------------------------------------------------------------
/// Flipped, so everything is laid out top-down.
final class Root: NSView { override var isFlipped: Bool { true } }

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { (delegate as? Controller)?.dismiss() } else { super.keyDown(with: e) } }
    override func cancelOperation(_ sender: Any?) { (delegate as? Controller)?.dismiss() }
}

final class Controller: NSObject, NSWindowDelegate {
    let pad: CGFloat = 16, leftW: CGFloat = 436, colGap: CGFloat = 16, rightW: CGFloat = 300
    let W: CGFloat = 16 + 436 + 16 + 300 + 16   // 784: the timer column, a gap, and the Focus column
    var panel: Panel!
    var fx: Root!
    var board = Board(), focus: [String: Focus] = [:]   // section title -> listing
    var mtime = Date.distantPast, focusMtime = Date.distantPast
    var weekOffset = 0, navBusy = false                 // the < > switcher: 0 this week, -1 last, +1 next
    var notePath: String { focus["Upcoming"]?.path ?? "" }   // all sections read the same note
    var closing = false, built = false
    var clickMonitor: Any?

    func start() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: W, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)   // system controls (the play symbols) stay dark too
        fx = Root()
        fx.wantsLayer = true; fx.layer?.backgroundColor = bg.cgColor; fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1; fx.layer?.borderColor = sep.cgColor
        panel.contentView = fx
        weekOffset = startOffset
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

    func mtimeOf(_ path: String) -> Date? {
        path.isEmpty ? nil : (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }
    /// All three Focus sections for the currently shown week (offset -> FOCUS_WEEK).
    func loadFocusAll() {
        let wk = weekId(offset: weekOffset)
        var f: [String: Focus] = [:]
        for s in FOCUS_SECTIONS { f[s.key] = loadFocus(s.key, week: wk) }
        focus = f; focusMtime = mtimeOf(notePath) ?? .distantPast
    }
    /// Rebuilds when the board or the Focus note changed on disk (a chip switch, Obsidian ticking a
    /// box). On another week the board is static (loaded once, forced or still empty); only its note
    /// is watched. Skipped entirely while a week jump is mid-flight, so the 2s tick can't race it.
    func reload(force: Bool) {
        if navBusy { return }
        let fm = mtimeOf(notePath), fNew = force || (fm ?? .distantPast) != focusMtime   // != : the note appearing or vanishing counts too
        if weekOffset == 0 {
            let bm = mtimeOf(boardPath), bNew = force || (bm ?? .distantPast) > mtime
            if !bNew && !fNew { return }
            if bNew { mtime = bm ?? mtime; if let b = loadBoard() { board = b } else if !built { board = Board() } else if !fNew { return } }
        } else {
            if force || board.bookings.isEmpty { board = loadBoardWeek(weekOffset) ?? Board() }
            else if !fNew { return }
        }
        if fNew { loadFocusAll() }
        build()
    }

    /// The < > switcher. Focus is local and loads now; the board for another week is a refetch, so
    /// it runs off the main thread with a LOADING state, and a later jump supersedes an older one.
    func navigate(_ delta: Int) {
        if navBusy { return }
        weekOffset += delta
        loadFocusAll()
        if weekOffset == 0 {
            board = loadBoard() ?? Board(); build()
        } else {
            navBusy = true; board = Board(); build()
            let off = weekOffset
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let b = loadBoardWeek(off)
                DispatchQueue.main.async {
                    guard let self = self, off == self.weekOffset else { return }
                    self.board = b ?? Board(); self.navBusy = false; self.build()
                }
            }
        }
    }

    func toggle(_ i: FocusItem, section: String) { toggleFocus(i, section: section, week: weekId(offset: weekOffset)); reload(force: true) }

    func build() {
        built = true
        fx.subviews.forEach { $0.removeFromSuperview() }
        let rowH: CGFloat = 30, innerW = leftW, rightX = pad + leftW + colGap
        var y: CGFloat = 14
        let wkNo = weekId(offset: weekOffset).split(separator: "W").last.map(String.init) ?? ""
        let head = NavHeaderView(frame: NSRect(x: pad, y: y, width: innerW, height: 16),
            title: board.week.isEmpty ? "Week \(wkNo)" : weekTitle(board),
            status: navBusy ? "LOADING…" : (weekOffset == 0 ? (board.state == "unknown" ? "NO LIVE DATA" : "PRODUCTIVE") : "OTHER WEEK"),
            onPrev: { [weak self] in self?.navigate(-1) }, onNext: { [weak self] in self?.navigate(1) })
        fx.addSubview(head); y += 26

        // Two columns. The right one (the Focus checklists) is built below regardless; the left one is
        // a one-line "loading" while a week jump fetches, otherwise the timer: bookings get the screen
        // height left after the fixed week bar and day columns, a tail becoming "+N more".
        let avail = (NSScreen.screens.first?.visibleFrame.height ?? 800) - 8 - CGFloat(topInset)
        let leftBottom: CGFloat
        if navBusy {
            let l = NSTextField(labelWithString: "Loading week \(wkNo)…")
            l.textColor = dim; l.font = .systemFont(ofSize: 12); l.frame = NSRect(x: pad, y: y, width: innerW, height: 20); fx.addSubview(l)
            leftBottom = y + 24
        } else {
            if board.state == "unknown" || board.bookings.isEmpty {
                let l = NSTextField(labelWithString: weekOffset == 0 && board.state == "unknown" ? "No data from Productive yet." : "No bookings this week.")
                l.textColor = dim; l.font = .systemFont(ofSize: 12); l.frame = NSRect(x: pad, y: y, width: innerW, height: 20); fx.addSubview(l); y += 28
            }
            let fixedLeft: CGFloat = 14 + 26 + 14 + WeekBar.height + 14 + DaysView.height + 16 + 14
            let maxRows = max(3, Int((avail - fixedLeft) / (rowH + 2)))
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
            let wb = WeekBar(frame: NSRect(x: pad, y: y, width: innerW, height: WeekBar.height)); wb.board = board; fx.addSubview(wb); y += WeekBar.height + 14
            let dv = DaysView(frame: NSRect(x: pad, y: y, width: innerW, height: DaysView.height)); dv.board = board
            fx.addSubview(dv); y += dv.frame.height + 16
            wb.relayout(); dv.relayout()
            if let n = testHoverSeg, wb.segs.indices.contains(n) { wb.hits = wb.segs.map { $0.r }; wb.hover = n }
            if let n = testHoverDay, dv.cols.indices.contains(n) { dv.hoverCol = n }
            leftBottom = y
        }

        // Right column: FOCUS header, then Upcoming / Actions / Past actions.
        var yR: CGFloat = 14
        var wk = ""
        for s in FOCUS_SECTIONS where wk.isEmpty { if let f = focus[s.key], f.missing == nil { wk = f.week.split(separator: "-").last.map(String.init) ?? f.week } }
        let fh = NSTextField(labelWithString: wk.isEmpty ? "FOCUS" : "FOCUS · \(wk)")
        fh.textColor = dim; fh.font = capsFont; fh.frame = NSRect(x: rightX, y: yR, width: rightW, height: 14); fx.addSubview(fh); yR += 26
        var budget = avail - 26 - 14
        for s in FOCUS_SECTIONS {
            let key = s.key, f = focus[key] ?? Focus()
            var shownS: [FocusItem] = [], h: CGFloat = 0
            for it in f.items {
                let ih = UpcomingView.rowHeight(it.text, width: rightW)
                if UpcomingView.headH + h + ih + 20 > budget && !shownS.isEmpty { break }
                shownS.append(it); h += ih
            }
            let moreS = f.items.count - shownS.count
            let total = UpcomingView.height(of: shownS, width: rightW, more: moreS > 0)
            let sv = UpcomingView(f, label: s.label, shown: shownS, more: moreS,
                                  frame: NSRect(x: rightX, y: yR, width: rightW, height: total),
                                  onToggle: { [weak self] in self?.toggle($0, section: key) })
            fx.addSubview(sv); yR += total + 12; budget -= total + 12
        }
        let H = max(leftBottom, yR) + 4
        var f = panel.frame; let top = f.maxY; f.size = NSSize(width: W, height: H); f.origin.y = top - H
        panel.setFrame(f, display: true)
        fx.frame = NSRect(origin: .zero, size: f.size)
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

// The panel's top line: ‹ WEEK n · range › on the left (the arrows jump weeks), a status word on
// the right. Only the two chevrons are hit targets; the title between them is inert.
final class NavHeaderView: NSView {
    override var isFlipped: Bool { true }
    let title: String, status: String, onPrev: () -> Void, onNext: () -> Void
    var prevR = NSRect.zero, nextR = NSRect.zero
    var hover = 0 { didSet { if oldValue != hover { needsDisplay = true } } }   // 0 none, 1 prev, 2 next
    static let arrow = NSFont.systemFont(ofSize: 15, weight: .medium)
    init(frame: NSRect, title: String, status: String, onPrev: @escaping () -> Void, onNext: @escaping () -> Void) {
        self.title = title; self.status = status; self.onPrev = onPrev; self.onNext = onNext
        super.init(frame: frame)
        prevR = NSRect(x: 0, y: -3, width: 16, height: 20)
        nextR = NSRect(x: 18, y: -3, width: 16, height: 20)   // both chevrons on the left, before the title
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    func hit(_ e: NSEvent) -> Int { let p = convert(e.locationInWindow, from: nil); return prevR.contains(p) ? 1 : nextR.contains(p) ? 2 : 0 }
    override func mouseMoved(with e: NSEvent) { hover = hit(e) }
    override func mouseExited(with e: NSEvent) { hover = 0 }
    override func mouseDown(with e: NSEvent) { let h = hit(e); if h == 1 { onPrev() } else if h == 2 { onNext() } }
    override func draw(_ r: NSRect) {
        text("‹", Self.arrow, hover == 1 ? fg : dim, in: prevR.offsetBy(dx: 0, dy: 1), align: .center)
        text("›", Self.arrow, hover == 2 ? fg : dim, in: nextR.offsetBy(dx: 0, dy: 1), align: .center)
        text(title.uppercased(), capsFont, dim, in: NSRect(x: 40, y: 1, width: bounds.width - 160, height: 14), kern: 0.8)
        text(status, capsFont, faint, in: NSRect(x: bounds.width - 120, y: 1, width: 120, height: 14), align: .right, kern: 0.8)
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
        if let n = testToggle, let up = controller.focus["Upcoming"], up.items.indices.contains(n) { controller.toggle(up.items[n], section: "Upcoming") }
        let v = controller.fx!
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        exit(0)
    }
}
app.run()

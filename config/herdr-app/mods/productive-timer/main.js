// Productive timer: the herdr.app twin of the sketchybar timer widget. Same data
// (the board file productive_board.sh writes), same content, same interactions;
// only the surface differs. Here that means a strip along the bottom (anchor +
// four chips + a week meter) and a dialog for the full week, drawn natively.
//
//   strip    place "bottom": anchor (state), 4 chips (click = switch), week meter
//   panel    mod.open:productive-timer (the anchor, or cmd-alt-p): booking rows,
//            40h stacked bar with hatched overtime, 7 day columns on a clock axis
//
// Read-only on the data side: the sketchybar tick keeps productive-board.json
// fresh, so this mod only reads it (every 30s) and never calls Productive. The one
// action is productive_switch.sh <service_id>, exactly what a sketchybar chip runs.
//
// Colours: dark only. Everything uses the bar's Tokyo Night palette (colors.sh), never
// herdr's theme, so strip and panel look the same in any herdr theme. Booking colours
// come from the board (identical to the bar). Green/red are state only, and the board
// never hands a booking either.
//
// v2 adds: the running booking's name in the anchor (when there is room), hover detail
// blocks (popup above a chip; fixed lines beneath the week bar and the day columns),
// planned hours + a pie per row (amber ring for the excess), and the Focus "Upcoming"
// checklist (focus_upcoming.sh lists and toggles; this mod never touches the note itself).
import { View, div, PathBuilder, Background } from "gpui-kit";
import { h_flex, v_flex, Popup } from "gpui-base";
import { exec, readTextFile, home, props, run, notify } from "herdr";

const POLL_MS = 30000;          // the board is rebuilt every 60s upstream; no point reading faster
const STALE_S = 600;            // a board older than this means sketchybar stopped: show "no data", not old truth
const SKETCHY = `${home()}/.config/sketchybar`;                // CONFIG_DIR for the scripts (colors.sh repairs PATH)
const SB_CACHE = `${home()}/.cache/sketchybar`;
const SWITCH = `${home()}/dotfiles/config/sketchybar/plugins/productive_switch.sh`;
const UPCOMING = `${home()}/dotfiles/config/sketchybar/plugins/focus_upcoming.sh`;
const BOARD_SH = `${home()}/dotfiles/config/sketchybar/plugins/productive_board.sh`;
const BOARD = `${SB_CACHE}/productive-board.json`;
// ISO-8601 week id (YYYY-Www) for this week plus `offset` weeks; the switcher's week.
const weekId = (offset) => {
  const d = new Date(); d.setDate(d.getDate() + offset * 7);
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  t.setUTCDate(t.getUTCDate() - ((t.getUTCDay() + 6) % 7) + 3);   // the week's Thursday
  const firstThu = new Date(Date.UTC(t.getUTCFullYear(), 0, 4));
  const wk = 1 + Math.round(((t - firstThu) / 864e5 - 3 + ((firstThu.getUTCDay() + 6) % 7)) / 7);
  return `${t.getUTCFullYear()}-W${String(wk).padStart(2, "0")}`;
};
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
// The Focus-note checklist sections, each [heading title (matches the note), display label].
// focus_upcoming.sh lists and toggles one section at a time; the three together are the panel's
// right-hand column (always on the bar, only when wide enough in herdr).
const SECTIONS = [["Upcoming", "UPCOMING"], ["Actions", "ACTIONS"], ["Past actions", "PAST ACTIONS"]];
const TWO_COL_MIN = 640;        // panel viewport width at/above which the Focus column moves beside the timer

// colors.sh, spelled the way the theme keys are used below (chrome = bar, popover = popup).
const TN = {
  background: "#1f2335", chrome: "#1a1b26", popover: "#1f2335", surface: "#292e42", hover: "#33395b",
  border: "#3b4261", input: "#3b4261", foreground: "#c0caf5", muted: "#737aa2", dim: "#565f89",
  ansi1: "#f7768e", ansi2: "#9ece6a", ansi3: "#e0af68",
};

const pad = (n) => String(n).padStart(2, "0");
// Booking sizes read like the bar: 0M, 45M, 12H (rounded hours past the first).
const fmt = (m) => (m <= 0 ? "0M" : m < 60 ? `${Math.round(m)}M` : `${Math.round(m / 60)}H`);
const fmtElapsed = (m) => (m >= 60 ? `${Math.floor(m / 60)}h${pad(Math.floor(m % 60))}m` : `${Math.floor(m)}m`);
const fmtTotal = (m) => `${Math.floor(m / 60)}h${pad(Math.round(m % 60))}`;
const hex2 = (a) => Math.round(a * 255).toString(16).padStart(2, "0");
const tint = (hex, a) => hex.slice(0, 7) + hex2(a);
const hm = (s) => { const [h, m] = s.split(":").map(Number); return h + m / 60; };
const clip = (str, n) => (str.length <= n ? str : `${str.slice(0, Math.max(0, n - 1))}…`);
const sum = (o) => Object.values(o || {}).reduce((a, b) => a + b, 0);

const RECT = () => PathBuilder.fill().move_to("0%", "0%").line_to("100%", "0%").line_to("100%", "100%").line_to("0%", "100%").close().build();

// A point on a circle of radius r% around the centre of its box, f of the way round from 12 o'clock.
const at = (f, r) => [`${50 + r * Math.sin(2 * Math.PI * f)}%`, `${50 - r * Math.cos(2 * Math.PI * f)}%`];
// Pie wedge of fraction f (0 < f < 1), filled in the box's own percent space: size-independent.
const wedge = (f, color) => {
  const [x, y] = at(f, 50);
  return window.paint_path(PathBuilder.fill().move_to("50%", "50%").line_to("50%", "0%").arc_to("50%", "50%", 0, f > 0.5, true, x, y).close().build(), color);
};
// Outer ring arc (stroke), same idea. herdr has real arcs (PathBuilder.arc_to), so no conic fallback is needed.
const ringArc = (f, color, w) => {
  const [x, y] = at(f, 43);
  const [x0, y0] = at(0, 43);
  return window.paint_path(PathBuilder.stroke(w).move_to(x0, y0).arc_to("43%", "43%", 0, f > 0.5, true, x, y).build(), color);
};

// Week pace as the bar's chip hover does it: a plan spreads over five working days, weekend = day 5.
const paceText = (c, mins) => {
  if (!c.booked_minutes) return `${fmtTotal(mins)} tracked, no plan this week`;
  const dow = Math.min(5, ((new Date().getDay() + 6) % 7) + 1);
  const exp = Math.floor(c.booked_minutes * dow / 5);
  const base = `${fmtTotal(mins)} of ${fmtTotal(c.booked_minutes)} planned`;
  return mins > c.booked_minutes ? `${base}, over by ${fmtTotal(mins - c.booked_minutes)}` : mins >= exp ? `${base}, on pace` : `${base}, behind: ~${fmtTotal(exp)} expected by now`;
};

export default class ProductiveTimer extends View {
  init(_props, cx) {
    this.board = null;
    this.busy = null;           // service_id being switched: its chip pulses until the board says otherwise
    // props.panel: docked in the right-hand panel (layouts/stijn.json), opened by my-tabs' Timer button.
    this.panel = Boolean(props()?.overlay || props()?.panel);
    this.hovChip = null;        // chip key under the pointer: its detail popup is open
    this.hovBar = null;         // booking key under the pointer in the week bar
    this.hovDay = null;         // day date under the pointer in the day columns
    this.foc = {};              // section title -> focus_upcoming.sh listing; only the panel shows these
    this.upBusy = false;
    this.weekOffset = 0;        // 0 this week, -1 last week, +1 next; the panel's < > switcher
    this.navBusy = false;       // a week jump is fetching its board
    cx.timer.every(POLL_MS, (cx) => { this.load(cx); this.loadUp(cx); });
    cx.spawn((cx) => { this.load(cx); this.loadUp(cx); });
  }

  async load(cx) {
    try {
      if (this.weekOffset === 0) {
        const text = await readTextFile(props()?.board ?? BOARD);
        this.board = text ? JSON.parse(text) : null;
      } else {
        // Another week: build it (entries refetched from Productive, then cached per week).
        const r = await exec("env", [`CONFIG_DIR=${SKETCHY}`, `SB_CACHE_DIR=${SB_CACHE}`, "bash", BOARD_SH, "--week", String(this.weekOffset)]);
        this.board = r.code === 0 ? JSON.parse(r.stdout) : null;
      }
    } catch (_e) {
      this.board = null;      // half-written or missing: the sketchybar writer renames atomically, so this is "no data"
    }
    cx.notify();
  }

  // Jump weeks: move the offset, then refetch both the board and the Focus sections for it.
  navigate(delta, cx) {
    if (this.navBusy) return;
    this.weekOffset += delta;
    this.navBusy = true; this.board = null; this.foc = {};
    cx.notify();
    cx.spawn(async (cx) => {
      await Promise.all([this.load(cx), this.loadUp(cx)]);
      this.navBusy = false; cx.notify();
    });
  }

  // One section's listing for the current offset's week. The script always exits 0 with JSON;
  // anything else is "unknown", kept as the last listing so a transient failure does not blank it.
  async loadSection(section, cx) {
    try {
      const r = await exec("bash", [UPCOMING, section, weekId(this.weekOffset)]);
      this.foc[section] = JSON.parse(r.stdout);
    } catch (_e) { /* keep the last listing */ }
    if (cx) cx.notify();
  }

  // All three Focus sections, in parallel. Only the panel shows them.
  async loadUp(cx) {
    if (!this.panel) return;
    await Promise.all(SECTIONS.map(([s]) => this.loadSection(s, null)));
    cx.notify();
  }

  // Tick: flip optimistically, let the script decide, then re-list that section (line numbers may have shifted).
  toggleUp(section, it, cx) {
    if (this.upBusy) return;
    this.upBusy = true;
    it.checked = !it.checked;
    cx.notify();
    cx.spawn(async (cx) => {
      let r;
      try { r = await exec("bash", [UPCOMING, "toggle", String(it.line), it.raw, section, weekId(this.weekOffset)]); } catch (e) { r = { code: 1, stderr: String(e) }; }
      if (r.code !== 0) notify({ title: "Could not tick the Focus item", body: (r.stderr || "The note changed under it. Reloaded.").trim().split("\n").pop(), level: "warning" });
      await this.loadSection(section, cx);
      this.upBusy = false;
    });
  }

  // Stale or missing means unknown, same as the bar's dim state.
  state() {
    const b = this.board;
    if (!b || !b.generated_at) return "unknown";
    const age = (Date.now() - new Date(b.generated_at).getTime()) / 1000;
    if (age > STALE_S) return "unknown";
    return b.state ?? "unknown";
  }

  // Minutes since the board was written: elapsed time and the week total keep moving between rebuilds.
  ageMin() {
    const t = new Date(this.board?.generated_at ?? 0).getTime();
    return Math.max(0, Math.floor((Date.now() - t) / 60000));
  }

  switchTo(b, cx) {
    const running = this.board?.running;
    if (this.busy || (running && String(running.service_id) === String(b.service_id))) return; // clicking the running booking is a no-op
    this.busy = String(b.service_id);
    cx.notify();
    cx.spawn(async (cx) => {
      let r = null;
      try {
        r = await exec("env", [`CONFIG_DIR=${home()}/.config/sketchybar`, `SB_CACHE_DIR=${home()}/.cache/sketchybar`, "bash", SWITCH, String(b.service_id)]);
      } catch (e) {
        r = { code: 1, stderr: String(e) };
      }
      // On failure the script has already opened the Productive tab so the stop can be done by hand.
      if (r.code !== 0) notify({ title: `Could not switch to ${b.code}`, body: (r.stderr || "").trim().split("\n").pop() || "Opened Productive instead.", level: "warning" });
      // The repaint upstream rebuilds the board within seconds: look a few times, then settle.
      for (const ms of [2500, 5000, 10000]) { await cx.sleep(ms); await this.load(cx); }
      this.busy = null;
      cx.notify();
    });
  }

  render() {
    return this.panel ? this.renderPanel() : this.renderStrip();
  }

  // ---------------------------------------------------------------- strip

  renderStrip() {
    const t = TN;
    const st = this.state();
    const b = this.board;
    const open = () => run("mod.open", { name: "productive-timer" });
    const green = t.ansi2, red = t.ansi1, amber = t.ansi3;
    const live = st !== "unknown";
    const byKey = Object.fromEntries((b?.bookings ?? []).map((x) => [x.key, x]));
    const runKey = st === "running" ? b.running?.key : null;
    const add = st === "running" ? this.ageMin() : 0;
    const total = (b?.total_minutes ?? 0) + add;
    const over = Math.max(0, total - (b?.target_minutes ?? 2400));

    const glyph = st === "running"
      ? div().size(7).rounded(4).bg(green).loop("opacity", { from: 0.35, to: 1, period: 1400 })
      : st === "idle" ? div().child("⚠").text_color(red).loop("opacity", { from: 0.55, to: 1, period: 1100 })
      : div().child("◷").text_color(t.dim);
    // Room for the booking name: the window width less everything else on the strip (estimated: gpui gives
    // no measured width back). Under ~8 chars the name is dropped; truncate() is the safety net.
    const chipList = (b?.chips ?? []).map((k) => byKey[k]).filter(Boolean);
    let vw = 0;
    try { vw = window.viewport_size().width; } catch (_e) { /* no window: no name */ }
    const used = 20 + 16 + 7 + 6 + 52 + (live && over > 0 ? 34 : 0) + 6 * 3 + (live ? 190 : 0)
      + chipList.reduce((a, c) => a + 23 + 4 + c.code.length * 7.4 + (c.pinned ? 12 : 0), 0);
    const nameChars = Math.floor((vw - used) / 6.6);
    const runName = runKey ? (byKey[runKey]?.name ?? b.running?.name ?? "") : "";
    const showName = st === "running" && runName && nameChars >= 8;
    const anchor = h_flex().id("anchor").h(22).px(8).gap(6).items_center().rounded(5).cursor_pointer().text_size(12)
      .when(st === "idle", (el) => el.bg(tint(red, 0.16)))
      .hover((s) => s.bg(st === "idle" ? tint(red, 0.26) : t.hover))
      .on_click(open)
      .tooltip(live ? `Week ${(b.week || "").split("W")[1] ?? ""}: ${fmtTotal(total)} of ${fmtTotal(b.target_minutes ?? 2400)}. Click for the full week.` : "No timer data (sketchybar board missing or stale)")
      .child(glyph)
      .child(st === "running"
        ? div().text_color(green).font_semibold().child(fmtElapsed((b.running?.elapsed_minutes ?? 0) + add))
        : st === "idle" ? div().text_color(red).child("not timing") : div().text_color(t.dim).child("--"))
      .when(showName, (el) => el.child(div().min_w(0).truncate().whitespace_nowrap().text_color(t.muted).child(clip(runName, nameChars))))
      .when(live && over > 0, (el) => el.child(div().text_color(amber).font_semibold().child(`+${Math.round(over / 60)}h`)));

    const chips = chipList.map((c) => {
      const on = runKey === c.key;
      const pulsing = this.busy === String(c.service_id);
      let el = h_flex().id(`chip-${c.key}`).relative().h(22).pl(11).pr(8).gap(4).items_center().rounded(4).cursor_pointer().text_size(11.5).font_bold()
        .bg(on ? green : t.surface).text_color(on ? t.background : t.foreground)
        .hover((s) => s.bg(on ? green : t.hover))
        .on_click((_e, cx) => this.switchTo(c, cx))
        .on_hover((hov, cx) => { this.hovChip = hov ? c.key : (this.hovChip === c.key ? null : this.hovChip); cx.notify(); })
        .child(div().absolute().left(0).top(3).bottom(3).w(3).rounded(2).bg(on ? tint(t.background, 0.5) : c.color))
        .child(c.code)
        .when(c.pinned, (e) => e.child(div().text_size(8).text_color(on ? tint(t.background, 0.6) : t.dim).child("◆")));
      if (pulsing) el = el.loop("opacity", { from: 0.4, to: 1, period: 700 });
      // Detail block on hover: a Popup in the window's top layer, pinned to the chip (the strip is too thin to hold it).
      const mins = c.tracked_minutes + (on ? add : 0);
      return Popup.new(`chip-pop-${c.key}`, el).anchor("bottom_left").when(this.hovChip === c.key, (p) => p.content(
        v_flex().gap(2).px(10).py(7).rounded(6).bg(t.popover).border(1).border_color(t.border).text_size(11).text_color(t.foreground)
          .child(div().font_semibold().child(c.name + (on ? " (timing now)" : "")))
          .child(div().text_color(t.muted).child(paceText(c, mins)))));
    });

    // Week meter: the panel's stacked bar in miniature, so progress is visible without opening anything.
    const target = b?.target_minutes ?? 2400;
    const domain = Math.max(target, total);
    const meter = !live ? null : h_flex().id("meter").gap(8).items_center().cursor_pointer().on_click(open)
      .tooltip(`${fmtTotal(total)} of ${fmtTotal(target)} this week${over ? `, ${fmtTotal(over)} over` : ""}`)
      .child(div().text_size(11).text_color(over ? amber : t.muted).child(`${Math.floor(total / 60)}h / ${Math.round(target / 60)}h`))
      .child(h_flex().relative().w(120).h(6).rounded(3).bg(t.surface).overflow_hidden()
        .children((b.bookings ?? []).filter((x) => x.tracked_minutes > 0).map((x) =>
          div().h_full().w(`${(x.tracked_minutes + (x.key === runKey ? add : 0)) / domain * 100}%`).bg(x.color)))
        .child(div().absolute().top(0).bottom(0).left(`${target / domain * 100}%`).w(1).bg(t.foreground)));

    return h_flex().id("strip").size_full().overflow_hidden().px(10).gap(6).items_center().bg(t.chrome).border_t(1).border_color(t.border)
      .when(st === "idle", (el) => el.border_color(red))
      .child(anchor)
      .child(h_flex().gap(4).items_center().min_w(0).overflow_hidden().opacity(live ? 1 : 0.45).children(chips))
      .child(div().flex_1())
      .when(Boolean(meter), (el) => el.child(meter));
  }

  // ---------------------------------------------------------------- panel

  // One Focus-note checklist section (Upcoming / Actions / Past actions). Clicking a box ticks it in
  // the Markdown file. flex_none with no own scrollbar: the Focus column (renderFocus) scrolls as one.
  renderSection(t, section, label) {
    const sk = section.replace(/\s+/g, "-").toLowerCase();
    const u = this.foc[section];
    const wk = u?.week?.split("-")[1] ?? "";
    const items = u?.items ?? [];
    const done = items.filter((i) => i.checked).length;
    const empty = section === "Upcoming" ? "Nothing upcoming" : `No ${label.toLowerCase()}`;
    const list = !u ? [div().text_color(t.dim).child("Loading…")]
      : u.missing ? [div().text_color(t.dim).child(`No Focus note for ${wk}`)]
      : items.length === 0 ? [div().text_color(t.dim).child(empty)]
      : items.map((it) => h_flex().id(`${sk}-${it.line}`).gap(8).items_start().py(3).px(4).rounded(4).cursor_pointer().hover((s) => s.bg(t.hover))
        .on_click((_e, cx) => this.toggleUp(section, it, cx))
        .child(h_flex().size(14).mt(1).flex_none().rounded(3).border(1).border_color(it.checked ? t.ansi2 : t.input).bg(it.checked ? t.ansi2 : "#00000000").items_center().justify_center()
          .text_size(10).font_bold().text_color(t.background).child(it.checked ? "✓" : ""))
        .child(div().flex_1().min_w(0).text_size(11.5).text_color(it.checked ? t.dim : t.foreground).when(it.checked, (e) => e.line_through()).child(it.text)));
    return v_flex().gap(4).flex_none()
      .child(h_flex().justify_between().text_size(10.5).text_color(t.dim)
        .child(div().child(label))
        .child(div().child(items.length ? `${done}/${items.length}` : "")))
      .child(v_flex().id(`sec-${sk}`).gap(1).children(list));
  }

  // The three checklist sections under one FOCUS heading. Scrolls as a whole so a long Past-actions
  // list never pushes the rest of the panel; the caller places it below the timer or beside it.
  renderFocus(t) {
    const wk = (SECTIONS.map(([s]) => this.foc[s]).find((u) => u?.week)?.week ?? "").split("-")[1] ?? "";
    return v_flex().id("focus").gap(12).flex_1().min_h(0).overflow_y_scrollbar()
      .child(h_flex().justify_between().text_size(11).text_color(t.dim)
        .child(div().child("FOCUS"))
        .child(div().child(wk)))
      .children(SECTIONS.map(([s, l]) => this.renderSection(t, s, l)));
  }

  // The < WEEK n · range > switcher: the arrows jump weeks, the label names the shown week. Built
  // outside the board guard so it stays visible (and clickable) while a week's board is loading.
  navHeader(t) {
    const b = this.board, st = this.state();
    const no = (b?.week || weekId(this.weekOffset)).split("W")[1] ?? "";
    let range = "";
    if (b?.from && b?.to) {
      const [f, to] = [new Date(`${b.from}T00:00`), new Date(`${b.to}T00:00`)];
      range = f.getMonth() === to.getMonth() ? `${f.getDate()}–${to.getDate()} ${MONTHS[to.getMonth()]}` : `${f.getDate()} ${MONTHS[f.getMonth()]} – ${to.getDate()} ${MONTHS[to.getMonth()]}`;
    }
    const arrow = (glyph, delta) => div().id(`nav${delta}`).px(5).rounded(4).cursor_pointer().text_color(t.muted)
      .hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click((_e, cx) => this.navigate(delta, cx)).child(glyph);
    const status = this.navBusy ? "LOADING…" : this.weekOffset === 0 ? (st === "unknown" ? "NO LIVE DATA" : "PRODUCTIVE") : "OTHER WEEK";
    return h_flex().justify_between().items_center().text_size(11).text_color(t.dim)
      .child(h_flex().gap(2).items_center()
        .child(arrow("‹", -1))
        .child(arrow("›", 1))
        .child(div().ml(4).child(`WEEK ${no}${range ? ` · ${range}` : ""}`.toUpperCase())))
      .child(div().child(status));
  }

  renderPanel() {
    const t = TN;
    const b = this.board;
    const st = this.state();
    const green = t.ansi2, red = t.ansi1, amber = t.ansi3;
    const body = v_flex().id("panel").size_full().overflow_hidden().p(16).gap(12).text_size(12).bg(t.background).text_color(t.foreground);
    if (this.navBusy || !b || !b.bookings || !b.days) { // loading a week, or a board without days (days.filter below would throw)
      const msg = this.navBusy ? `Loading week ${(b?.week || weekId(this.weekOffset)).split("W")[1] ?? ""}…`
        : (b ? "No bookings this week" : "No timer data yet. The sketchybar board has not been written.");
      return body.child(this.navHeader(t))
        .child(v_flex().flex_none().py(24).items_center().text_color(t.dim).child(msg))
        .child(this.renderFocus(t));
    }
    const add = st === "running" ? this.ageMin() : 0;
    const runKey = st === "running" ? b.running?.key : null;
    const book = (x) => x.tracked_minutes + (x.key === runKey ? add : 0);
    const bookings = [...b.bookings].sort((x, y) => book(y) - book(x));
    const total = b.total_minutes + add;
    const target = b.target_minutes ?? 2400;
    const over = Math.max(0, total - target);
    const domain = Math.max(target, Math.ceil(total / 300) * 300);
    const pct = (m) => `${(m / domain * 100).toFixed(2)}%`;
    // A fixed-height block, so hovering never shifts the layout: title line + dim detail line.
    const detail = (hov) => v_flex().h(32).flex_none().justify_center().gap(1).px(10).rounded(5).bg(t.surface).text_size(10.5).overflow_hidden()
      .child(div().truncate().whitespace_nowrap().font_semibold().text_color(hov ? t.foreground : t.dim).child(hov ? hov[0] : "Hover for details"))
      .child(div().truncate().whitespace_nowrap().text_color(t.muted).child(hov ? hov[1] : " "));
    const label = (l, r) => h_flex().justify_between().text_size(10.5).text_color(t.dim).child(div().child(l)).child(r);

    // --- rows
    const rows = bookings.map((x) => {
      const on = runKey === x.key;
      const pulsing = this.busy === String(x.service_id);
      const mins = book(x);
      // Pie: tracked / planned in the booking colour. Over target the pie is full and an amber ring arc
      // shows the excess (150% = half a ring). No plan: an empty slot, so the play buttons stay aligned.
      const planned = x.booked_minutes;
      const overT = planned > 0 && mins > planned;
      const frac = planned > 0 ? Math.min(1, mins / planned) : 0;
      const pie = div().relative().size(22).flex_none();
      if (planned > 0) {
        pie.child(div().absolute().left(5).top(5).size(12).rounded(6).bg(tint(x.color, 0.22)));
        if (frac >= 1) pie.child(div().absolute().left(5).top(5).size(12).rounded(6).bg(x.color));
        else if (frac > 0.005) pie.child(wedge(frac, x.color).absolute().left(5).top(5).size(12));
        if (overT) {
          const ex = Math.min(1, (mins - planned) / planned);
          if (ex >= 1) pie.child(div().absolute().left(0).top(0).size(22).rounded(11).border(2).border_color(amber));
          else pie.child(ringArc(ex, amber, 2).absolute().left(0).top(0).size(22));
        }
      }
      let play = h_flex().size(22).rounded(11).border(1).border_color(on ? green : t.input).bg(on ? green : "#00000000")
        .flex_none().items_center().justify_center().text_size(9).text_color(on ? t.background : t.foreground).child(on ? "■" : "▶");
      if (on) play = play.loop("opacity", { from: 0.65, to: 1, period: 1400 });
      let row = h_flex().id(`row-${x.key}`).h(28).pr(4).gap(10).items_center().rounded(5).cursor_pointer()
        .bg(on ? tint(green, 0.12) : "#00000000").hover((s) => s.bg(on ? tint(green, 0.18) : t.hover))
        .on_click((_e, cx) => this.switchTo(x, cx))
        .child(div().w(4).h(18).rounded(2).flex_none().bg(x.color))
        .child(h_flex().flex_1().min_w(0).gap(5).items_center().truncate()
          .child(div().truncate().text_color(t.foreground).child(x.project))
          .child(div().text_size(11).text_color(t.dim).whitespace_nowrap().child(`· ${x.budget}`))
          .when(on, (e) => e.child(div().text_size(11).text_color(green).whitespace_nowrap().child(`· ${fmtElapsed((b.running?.elapsed_minutes ?? 0) + add)}`))))
        // Two right-aligned columns: tracked (amber past the plan), then dim planned.
        .child(div().w(38).flex_none().text_right().text_size(11.5).font_bold().text_color(overT ? amber : mins ? t.foreground : t.dim).child(fmt(mins)))
        .child(div().w(38).flex_none().text_right().text_size(11.5).text_color(t.dim).child(x.booked_minutes ? fmt(x.booked_minutes) : ""))
        .child(pie)
        .child(play);
      if (pulsing) row = row.loop("opacity", { from: 0.5, to: 1, period: 700 });
      return row;
    });

    // --- week bar
    const segs = bookings.filter((x) => book(x) > 0).map((x, i) =>
      div().id(`seg-${x.key}`).h_full().flex_none().w(pct(book(x))).bg(x.color).when(i === 0, (e) => e.rounded_l(3))
        .on_hover((hov, cx) => { this.hovBar = hov ? x.key : (this.hovBar === x.key ? null : this.hovBar); cx.notify(); }));
    const hb = bookings.find((x) => x.key === this.hovBar && book(x) > 0);
    const barDetail = detail(hb && [hb.name, `${fmtTotal(book(hb))} tracked · ${(book(hb) / Math.max(1, total) * 100).toFixed(0)}% of the week · ${hb.booked_minutes ? `${fmtTotal(hb.booked_minutes)} planned` : "no plan"}`]);
    const bar = div().relative().h(16).mb(10).rounded(3).bg(t.background)
      .child(h_flex().size_full().overflow_hidden().rounded(3).children(segs))
      .when(over > 0, (e) => e.child(div().absolute().top(0).bottom(0).left(pct(target)).right(0).rounded_r(3).overflow_hidden()
        .child(window.paint_path(RECT(), Background.pattern_slash("#00000073", 2, 5)).absolute().top(0).left(0).size_full())))
      .child(div().absolute().top(-4).bottom(-4).left(pct(target)).w(2).bg(t.foreground))
      .child(div().absolute().top(21).left(`${target / domain * 100}%`).ml(-10).text_size(9.5).text_color(t.dim).child("40h"));

    // --- day columns on a clock axis. The range grows if a day starts before 07 or runs past 23.
    const starts = b.days.filter((d) => d.start && d.end).map((d) => hm(d.start));
    const ends = b.days.filter((d) => d.end).map((d) => hm(d.end));
    const H0 = Math.min(7, Math.floor(Math.min(...starts, 7)));
    const H1 = Math.max(23, Math.ceil(Math.max(...ends, 23)));
    const COL = 170, yTop = 14, yBot = 130;
    const y = (h) => yTop + ((h - H0) / (H1 - H0)) * (yBot - yTop);
    const minPx = (yBot - yTop) / ((H1 - H0) * 60);
    const ticks = [8, 12, 16, 20].filter((h) => h > H0 && h < H1);
    const now = new Date();
    const today = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    const colorOf = Object.fromEntries(b.bookings.map((x) => [x.key, x.color]));
    const nameOf = Object.fromEntries(b.bookings.map((x) => [x.key, x.name]));

    const cols = b.days.map((d) => {
      const tracked = sum(d.minutes);
      const isToday = d.date === today;
      const foot = v_flex().absolute().bottom(0).left(0).right(0).items_center().text_size(10).text_color(isToday ? green : t.dim)
        .child(div().text_size(10.5).font_bold().text_color(isToday ? green : t.foreground).child(tracked ? fmt(tracked) : "–"))
        .child(div().child(d.dow));
      const col = div().id(`day-${d.dow}`).relative().h_full().flex_1().child(foot);
      if (!d.start || !d.end) return col; // end can be null with start set: hm(null) would throw
      const s = hm(d.start), e = hm(d.end);
      const present = Math.round((e - s) * 60);
      const stack = Object.entries(d.minutes).sort((p, q) => q[1] - p[1]);
      return col
        .on_hover((hov, cx) => { this.hovDay = hov ? d.date : (this.hovDay === d.date ? null : this.hovDay); cx.notify(); })
        .child(div().absolute().top(y(s) - 13).left(0).right(0).text_size(9.5).text_color(t.foreground).text_center().child(d.start))
        // The dashed outline is presence; the filled stack is what got tracked. The gap between them is the leak.
        .child(div().absolute().top(y(s)).h(y(e) - y(s)).left(6).right(6).rounded(3).border(1).border_dashed().border_color(t.input))
        .child(v_flex().absolute().top(y(s)).left(6).right(6).rounded(3).overflow_hidden()
          .children(stack.map(([k, m]) => div().h(m * minPx).flex_none().bg(colorOf[k] ?? t.dim))))
        .child(div().absolute().top(y(e) + 2).left(0).right(0).text_size(9.5).text_color(t.dim).text_center().child(d.end));
    });

    const hd = b.days.find((d) => d.date === this.hovDay && d.start && d.end);
    const dayDetail = detail(hd && (() => {
      const tr = sum(hd.minutes), pr = Math.round((hm(hd.end) - hm(hd.start)) * 60);
      const dt = new Date(`${hd.date}T00:00`);
      const split = Object.entries(hd.minutes).sort((p, q) => q[1] - p[1]).map(([k, m]) => `${clip(nameOf[k] ?? k, 24)} ${fmtTotal(m)}`).join(" · ");
      return [`${hd.dow} ${dt.getDate()} ${MONTHS[dt.getMonth()]} · ${hd.start}–${hd.end}`,
        `${fmtTotal(tr)} tracked of ${fmtTotal(pr)} present${pr > tr ? ` · ${fmtTotal(pr - tr)} untracked` : ""}${split ? ` · ${split}` : ""}`];
    })());
    const days = h_flex().relative().h(COL).mt(4)
      .children(ticks.map((h) => div().absolute().top(y(h)).left(40).right(0).h(1).bg(tint(t.border, 0.5))))
      .child(div().relative().w(34).h_full().mr(6).flex_none()
        .children(ticks.map((h) => div().absolute().top(y(h) - 6).right(0).text_size(9.5).text_color(t.dim).child(`${pad(h)}:00`))))
      .children(cols);

    const header = this.navHeader(t);
    const rowsBlock = v_flex().id("rows").gap(2).max_h(170).flex_none().overflow_y_scrollbar().children(rows);
    const weekBlock = v_flex().gap(8)
      .child(label("This week", h_flex().gap(4)
        .child(div().font_semibold().text_color(t.foreground).child(fmtTotal(total)))
        .child(div().child(`/ ${Math.round(target / 60)}h`))
        .when(over > 0, (e) => e.child(div().text_color(red).child(`+${Math.round(over / 60)}h over`)))))
      .child(bar)
      .child(barDetail);
    const daysBlock = v_flex().gap(4).mt(6)
      .child(label("Per day", div().child("first → last activity")))
      .child(days)
      .child(dayDetail);
    const focus = this.renderFocus(t);

    // 1 column by default; split the Focus checklists into a second column once the panel is wide enough.
    let vw = 0; try { vw = window.viewport_size().width; } catch (_e) { /* no window: assume narrow */ }
    if (vw >= TWO_COL_MIN) {
      return body.child(header).child(h_flex().flex_1().min_h(0).gap(16)
        .child(v_flex().flex_1().min_w(0).gap(12).child(rowsBlock).child(weekBlock).child(daysBlock))
        .child(v_flex().w(300).flex_none().min_h(0).child(focus)));
    }
    return body.child(header).child(rowsBlock).child(weekBlock).child(daysBlock).child(focus);
  }
}

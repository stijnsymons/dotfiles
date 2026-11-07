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
// Colours: booking colours come from the board (identical to the bar); everything
// else follows herdr's theme. Green/red are state only, taken from the theme's ANSI
// green/red, and the board never hands a booking either.
import { View, div, PathBuilder, Background } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { exec, readTextFile, home, props, run, theme, notify } from "herdr";

const POLL_MS = 30000;          // the board is rebuilt every 60s upstream; no point reading faster
const STALE_S = 600;            // a board older than this means sketchybar stopped: show "no data", not old truth
const SWITCH = `${home()}/dotfiles/config/sketchybar/plugins/productive_switch.sh`;
const BOARD = `${home()}/.cache/sketchybar/productive-board.json`;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const pad = (n) => String(n).padStart(2, "0");
// Booking sizes read like the bar: 0M, 45M, 12H (rounded hours past the first).
const fmt = (m) => (m <= 0 ? "0M" : m < 60 ? `${Math.round(m)}M` : `${Math.round(m / 60)}H`);
const fmtElapsed = (m) => (m >= 60 ? `${Math.floor(m / 60)}h${pad(Math.floor(m % 60))}m` : `${Math.floor(m)}m`);
const fmtTotal = (m) => `${Math.floor(m / 60)}h${pad(Math.round(m % 60))}`;
const hex2 = (a) => Math.round(a * 255).toString(16).padStart(2, "0");
const tint = (hex, a) => hex.slice(0, 7) + hex2(a);
const hm = (s) => { const [h, m] = s.split(":").map(Number); return h + m / 60; };
const sum = (o) => Object.values(o || {}).reduce((a, b) => a + b, 0);

const RECT = () => PathBuilder.fill().move_to("0%", "0%").line_to("100%", "0%").line_to("100%", "100%").line_to("0%", "100%").close().build();

export default class ProductiveTimer extends View {
  init(_props, cx) {
    this.board = null;
    this.busy = null;           // service_id being switched: its chip pulses until the board says otherwise
    this.panel = Boolean(props()?.overlay);
    cx.timer.every(POLL_MS, (cx) => this.load(cx));
    cx.spawn((cx) => this.load(cx));
  }

  async load(cx) {
    try {
      const text = await readTextFile(props()?.board ?? BOARD);
      this.board = text ? JSON.parse(text) : null;
    } catch (_e) {
      this.board = null;      // half-written or missing: the sketchybar writer renames atomically, so this is "no data"
    }
    cx.notify();
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
    const t = theme();
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
    const anchor = h_flex().id("anchor").h(22).px(8).gap(6).items_center().rounded(5).cursor_pointer().text_size(12)
      .when(st === "idle", (el) => el.bg(tint(red, 0.16)))
      .hover((s) => s.bg(st === "idle" ? tint(red, 0.26) : t.hover))
      .on_click(open)
      .tooltip(live ? `Week ${(b.week || "").split("W")[1] ?? ""}: ${fmtTotal(total)} of ${fmtTotal(b.target_minutes ?? 2400)}. Click for the full week.` : "No timer data (sketchybar board missing or stale)")
      .child(glyph)
      .child(st === "running"
        ? div().text_color(green).font_semibold().child(fmtElapsed((b.running?.elapsed_minutes ?? 0) + add))
        : st === "idle" ? div().text_color(red).child("not timing") : div().text_color(t.dim).child("--"))
      .when(live && over > 0, (el) => el.child(div().text_color(amber).font_semibold().child(`+${Math.round(over / 60)}h`)));

    const chips = (b?.chips ?? []).map((k) => byKey[k]).filter(Boolean).map((c) => {
      const on = runKey === c.key;
      const pulsing = this.busy === String(c.service_id);
      let el = h_flex().id(`chip-${c.key}`).relative().h(22).pl(11).pr(8).gap(4).items_center().rounded(4).cursor_pointer().text_size(11.5).font_bold()
        .bg(on ? green : t.surface).text_color(on ? t.background : t.foreground)
        .hover((s) => s.bg(on ? green : t.hover))
        .on_click((_e, cx) => this.switchTo(c, cx))
        .tooltip(`${c.name}\n${fmt(c.tracked_minutes)} this week${c.booked_minutes ? ` of ${fmt(c.booked_minutes)} booked` : ""}${on ? " (timing now)" : ". Click to switch."}`)
        .child(div().absolute().left(0).top(3).bottom(3).w(3).rounded(2).bg(on ? tint(t.background, 0.5) : c.color))
        .child(c.code)
        .when(c.pinned, (e) => e.child(div().text_size(8).text_color(on ? tint(t.background, 0.6) : t.dim).child("◆")));
      if (pulsing) el = el.loop("opacity", { from: 0.4, to: 1, period: 700 });
      return el;
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

  renderPanel() {
    const t = theme();
    const b = this.board;
    const st = this.state();
    const green = t.ansi2, red = t.ansi1, amber = t.ansi3;
    const body = v_flex().id("panel").size_full().overflow_hidden().p(16).gap(14).text_size(12);
    if (!b || !b.bookings || !b.days) { // a board without days is as unusable as none: days.filter below would throw
      return body.items_center().justify_center().text_color(t.dim).child(b ? "No bookings this week" : "No timer data yet. The sketchybar board has not been written.");
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
    const [f, to] = [new Date(`${b.from}T00:00`), new Date(`${b.to}T00:00`)];
    const range = f.getMonth() === to.getMonth() ? `${f.getDate()}–${to.getDate()} ${MONTHS[to.getMonth()]}` : `${f.getDate()} ${MONTHS[f.getMonth()]} – ${to.getDate()} ${MONTHS[to.getMonth()]}`;
    const label = (l, r) => h_flex().justify_between().text_size(10.5).text_color(t.dim).child(div().child(l)).child(r);

    // --- rows
    const rows = bookings.map((x) => {
      const on = runKey === x.key;
      const pulsing = this.busy === String(x.service_id);
      const mins = book(x);
      let play = h_flex().size(22).rounded(11).border(1).border_color(on ? green : t.input).bg(on ? green : "#00000000")
        .flex_none().items_center().justify_center().text_size(9).text_color(on ? t.background : t.foreground).child(on ? "■" : "▶");
      if (on) play = play.loop("opacity", { from: 0.65, to: 1, period: 1400 });
      let row = h_flex().id(`row-${x.key}`).h(28).pr(4).gap(10).items_center().rounded(5).cursor_pointer()
        .bg(on ? tint(green, 0.12) : "#00000000").hover((s) => s.bg(on ? tint(green, 0.18) : t.hover))
        .on_click((_e, cx) => this.switchTo(x, cx))
        .tooltip(`${x.name}${on ? " (timing now)" : ". Click to start."}`)
        .child(div().w(4).h(18).rounded(2).flex_none().bg(x.color))
        .child(h_flex().flex_1().min_w(0).gap(5).items_center().truncate()
          .child(div().truncate().text_color(t.foreground).child(x.project))
          .child(div().text_size(11).text_color(t.dim).whitespace_nowrap().child(`· ${x.budget}`))
          .when(on, (e) => e.child(div().text_size(11).text_color(green).whitespace_nowrap().child(`· ${fmtElapsed((b.running?.elapsed_minutes ?? 0) + add)}`))))
        .child(h_flex().items_center().flex_none().text_size(11.5)
          .child(div().font_bold().text_color(mins ? t.foreground : t.dim).child(fmt(mins)))
          .when(Boolean(x.booked_minutes), (e) => e.child(div().text_color(t.dim).child(`/${fmt(x.booked_minutes)}`))))
        .child(play);
      if (pulsing) row = row.loop("opacity", { from: 0.5, to: 1, period: 700 });
      return row;
    });

    // --- week bar
    const segs = bookings.filter((x) => book(x) > 0).map((x, i) =>
      div().id(`seg-${x.key}`).h_full().flex_none().w(pct(book(x))).bg(x.color).when(i === 0, (e) => e.rounded_l(3))
        .tooltip(`${x.name}: ${fmtTotal(book(x))}`));
    const bar = div().relative().h(16).rounded(3).bg(t.background)
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
    const COL = 250, yTop = 14, yBot = 216;
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
        .tooltip(`${d.dow} ${d.start}–${d.end}. ${fmtTotal(tracked)} tracked of ${fmtTotal(present)} at the machine${present > tracked ? `, ${fmtTotal(present - tracked)} untracked` : ""}.`)
        .child(div().absolute().top(y(s) - 13).left(0).right(0).text_size(9.5).text_color(t.foreground).text_center().child(d.start))
        // The dashed outline is presence; the filled stack is what got tracked. The gap between them is the leak.
        .child(div().absolute().top(y(s)).h(y(e) - y(s)).left(6).right(6).rounded(3).border(1).border_dashed().border_color(t.input))
        .child(v_flex().absolute().top(y(s)).left(6).right(6).rounded(3).overflow_hidden()
          .children(stack.map(([k, m]) => div().h(m * minPx).flex_none().bg(colorOf[k] ?? t.dim).tooltip(`${nameOf[k] ?? k}: ${fmtTotal(m)}`))))
        .child(div().absolute().top(y(e) + 2).left(0).right(0).text_size(9.5).text_color(t.dim).text_center().child(d.end));
    });

    const days = h_flex().relative().h(COL).mt(4)
      .children(ticks.map((h) => div().absolute().top(y(h)).left(40).right(0).h(1).bg(tint(t.border, 0.5))))
      .child(div().relative().w(34).h_full().mr(6).flex_none()
        .children(ticks.map((h) => div().absolute().top(y(h) - 6).right(0).text_size(9.5).text_color(t.dim).child(`${pad(h)}:00`))))
      .children(cols);

    return body
      .child(h_flex().justify_between().text_size(11).text_color(t.dim)
        .child(div().child(`WEEK ${(b.week || "").split("W")[1] ?? ""} · ${range}`.toUpperCase()))
        .child(div().child(st === "unknown" ? "NO LIVE DATA" : "PRODUCTIVE")))
      .child(v_flex().id("rows").gap(2).max_h(236).flex_none().overflow_y_scrollbar().children(rows))
      .child(v_flex().gap(8)
        .child(label("This week", h_flex().gap(4)
          .child(div().font_semibold().text_color(t.foreground).child(fmtTotal(total)))
          .child(div().child(`/ ${Math.round(target / 60)}h`))
          .when(over > 0, (e) => e.child(div().text_color(red).child(`+${Math.round(over / 60)}h over`)))))
        .child(bar))
      .child(v_flex().gap(4).mt(10)
        .child(label("Per day", div().child("first → last activity")))
        .child(days));
  }
}

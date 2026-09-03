// One persistent process that renders the bar's high-frequency items, so they
// stop costing a fork apiece.
//
// WHY THIS EXISTS
// The shell plugins are fine code; the problem is the model. sketchybar forks a
// script per item per tick, and the fork - not the work - was the cost: bash
// alone is ~11ms, each jq ~13ms, and every `sketchybar --set` is a ~4.9ms CLI
// round trip that packs argv, looks the mach port up again and waits for a
// reply. Measured on this machine, the six items below burned ~4.2s of process
// time per minute between them. From inside one long-lived process the same
// updates go over sketchybar's own mach port in ~0.004ms - a cached port, no
// argv packing, no reply awaited - which is roughly a thousandfold less per
// update, and the readings come from frameworks instead of subprocesses.
//
// WHAT IT OWNS
//   cpu, mem            host_statistics64 tick deltas, no `ps -A`
//   net_up, net_down    getifaddrs if_data, no `netstat`
//   mic                 CoreAudio, and PUSH not poll - the 3s tick is gone
//   volume              CoreAudio, replacing three ~107ms osascript calls
//   herdr + digits      one `herdr agent list`, parsed natively, no jq
//
// WHAT IT DELIBERATELY DOES NOT OWN
// meeting and productive stay in shell: they tick at 60s and their cost is API
// latency no language changes. media stays in shell because now-playing has no
// public API (nowplaying-cli talks to the private MediaRemote framework, which
// is exactly the dependency not worth compiling in). Everything with a card
// keeps its shell click_script, so plugins/card.sh and its tests are untouched.
//
// HOW IT TALKS TO THE BAR
// Send only, deliberately. bootstrap_look_up finds "git.felix.<BAR_NAME>",
// then each command is argv NUL-separated with a trailing NUL, handed over as
// an out-of-line mach descriptor. No response is awaited: nothing here reads
// bar state back, and skipping the reply is most of the speed.
//
// HOW THE BAR TALKS TO IT
// An item with `mach_helper=<bootstrap name>` gets its events delivered to that
// port instead of forking a script. Only `volume` needs it, for volume_change /
// mouse.clicked / mouse.scrolled - which is also where the win is felt, since
// every scroll notch used to wait ~107ms on osascript.
//
// TESTING
// --selftest prints every reading as `key=value` and exits, so check.sh can
// assert this file's arithmetic without a live bar. SB_HELPER_HERDR_JSON
// injects a herdr fixture, the same hook plugins/herdr.sh already honours.

import Darwin
import Dispatch
import Foundation
import CoreAudio
import SystemConfiguration

// MARK: - Palette
//
// Duplicated from colors.sh rather than parsed out of it: this process starts
// once, and shelling out to read a shell file would reintroduce the fork this
// file exists to remove. check.sh asserts the two agree.
enum C {
    static let fgDim  = "0xff565f89"
    static let aqua   = "0xff7dcfff"
    static let green  = "0xff9ece6a"
    static let yellow = "0xffe0af68"
    static let orange = "0xffff9e64"
    static let red    = "0xfff7768e"
    static let blue   = "0xff7aa2f7"
}

// MARK: - The bar

/// Fire-and-forget client for sketchybar's mach port.
final class Bar {
    private var port: mach_port_t = 0

    private struct Message {
        var header = mach_msg_header_t()
        var descriptorCount: mach_msg_size_t = 0
        var descriptor = mach_msg_ool_descriptor_t()
    }

    private func lookUp() -> mach_port_t {
        var bs = mach_port_t()
        guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bs) == KERN_SUCCESS
        else { return 0 }
        let name = ProcessInfo.processInfo.environment["BAR_NAME"] ?? "sketchybar"
        var p = mach_port_t()
        return bootstrap_look_up(bs, "git.felix.\(name)", &p) == KERN_SUCCESS ? p : 0
    }

    /// Every argument is one NUL-terminated string; the buffer ends with a
    /// second NUL. Built from the array rather than by splitting a command
    /// string on spaces the way the reference C header does - that helper
    /// strips quotes with a hand-rolled loop its own author flags as "not
    /// actually robust", and a label containing a space or a quote is routine
    /// here (meeting titles, SSIDs, track names).
    @discardableResult
    func send(_ args: [String]) -> Bool {
        guard !args.isEmpty else { return true }
        if port == 0 { port = lookUp() }
        guard port != 0 else { return false }

        var buf = [CChar]()
        for a in args { buf.append(contentsOf: a.utf8CString) }
        buf.append(0)

        var msg = Message()
        msg.header.msgh_remote_port = port
        msg.header.msgh_local_port = 0
        msg.header.msgh_id = 0
        msg.header.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND)
                             | (UInt32(MACH_MSG_TYPE_MAKE_SEND) << 8)
                             | UInt32(0x8000_0000)   // MACH_MSGH_BITS_COMPLEX
        msg.header.msgh_size = mach_msg_size_t(MemoryLayout<Message>.size)
        msg.descriptorCount = 1
        msg.descriptor.type = UInt32(MACH_MSG_OOL_DESCRIPTOR)
        msg.descriptor.copy = UInt32(MACH_MSG_VIRTUAL_COPY)
        msg.descriptor.deallocate = 0
        msg.descriptor.size = mach_msg_size_t(buf.count)

        let ok = buf.withUnsafeMutableBufferPointer { p -> Bool in
            msg.descriptor.address = UnsafeMutableRawPointer(p.baseAddress!)
            var m = msg
            let size = m.header.msgh_size
            // The pointer must address the WHOLE message, not its header field.
            // &m.header would hand mach_msg a copy-in/copy-out temporary of
            // just that field, so everything past it - the descriptor carrying
            // the payload - would be read from the wrong memory.
            return withUnsafeMutablePointer(to: &m) { mp in
                mp.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) { hp in
                    mach_msg(hp, MACH_SEND_MSG, size, 0, mach_port_t(MACH_PORT_NULL),
                             MACH_MSG_TIMEOUT_NONE, mach_port_t(MACH_PORT_NULL)) == KERN_SUCCESS
                }
            }
        }
        // A failed send usually means the bar restarted and our cached port is
        // dead. Re-look-up once; if there is still no bar, exit and let
        // sketchybarrc start a fresh helper on its next load.
        if !ok {
            port = lookUp()
            if port == 0 { exit(0) }
        }
        return ok
    }
}

let bar = Bar()

// MARK: - CPU and memory

/// System-wide CPU load from the kernel's tick counters. The shell version
/// summed `ps -A -o %cpu`, which reports each process's *decayed average* and
/// so lagged a burst by seconds; a tick delta between our own samples is the
/// instantaneous figure `top` shows, for no subprocess at all.
final class CPUSampler {
    private var previous: host_cpu_load_info?

    private func read() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    /// nil until a second sample exists, and on any counter rollback. nil means
    /// "no reading" and leaves the item showing its last good value - never a
    /// confident 0% over a machine that is actually busy, which is the same
    /// rule the shell version's `pipefail` + empty-awk pairing enforced.
    func percent() -> Int? {
        guard let now = read() else { return nil }
        defer { previous = now }
        guard let was = previous else { return nil }

        func tick(_ i: host_cpu_load_info, _ n: Int32) -> Double {
            withUnsafePointer(to: i.cpu_ticks) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(CPU_STATE_MAX)) { Double($0[Int(n)]) }
            }
        }
        let user = tick(now, CPU_STATE_USER)   - tick(was, CPU_STATE_USER)
        let sys  = tick(now, CPU_STATE_SYSTEM) - tick(was, CPU_STATE_SYSTEM)
        let nice = tick(now, CPU_STATE_NICE)   - tick(was, CPU_STATE_NICE)
        let idle = tick(now, CPU_STATE_IDLE)   - tick(was, CPU_STATE_IDLE)
        let total = user + sys + nice + idle
        guard total > 0, user >= 0, sys >= 0, idle >= 0 else { return nil }
        return min(100, max(0, Int(((user + sys + nice) / total * 100).rounded())))
    }
}

/// The number the bar has always shown: 100 - memory_pressure's "System-wide
/// memory free percentage".
///
/// This is the one reading that stayed a subprocess, on purpose. Every page-sum
/// you can compute natively disagrees with it wildly - on this machine
/// memory_pressure says 20% used while active+wired+compressed says 56% - so
/// going native here would not have been a port, it would have silently
/// redefined what the item means AND invalidated the 60%/85% colour thresholds
/// tuned against the old scale. memory_pressure costs ~14ms at a 10s tick,
/// which is a sixth of what the whole shell tick used to cost, so fidelity is
/// nearly free. memResidentPercent() below computes the Activity-Monitor-style
/// figure; --selftest reports both, so switching later is a threshold change
/// and a one-line swap rather than an investigation.
func memPercent() -> Int? {
    guard let out = run("memory_pressure", [], timeout: 5),
          let text = String(data: out, encoding: .utf8)
    else { return nil }
    for line in text.split(separator: "\n") where line.contains("free percentage") {
        let digits = line.filter(\.isNumber)
        if let free = Int(digits), (0...100).contains(free) { return 100 - free }
    }
    return nil
}

/// Resident, unreclaimable memory as a share of physical - what Activity
/// Monitor calls "Memory Used". Not displayed; see memPercent().
func memResidentPercent() -> Int? {
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    var vm = vm_statistics64()
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

    let used = Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * Double(pageSize)
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    guard total > 0 else { return nil }
    return min(100, max(0, Int((used / total * 100).rounded())))
}

func loadColor(_ pct: Int) -> String {
    if pct >= 85 { return C.red }
    if pct >= 60 { return C.yellow }
    return C.aqua
}

// MARK: - Network throughput

/// Byte counters for the primary interface, straight out of getifaddrs.
/// The interface name comes from SCDynamicStore rather than `route -n get
/// default`, so a docked/undocked change is picked up without a subprocess.
final class NetSampler {
    private var lastIface: String?
    private var lastRX: UInt64 = 0
    private var lastTX: UInt64 = 0
    private var lastAt: Double = 0

    private lazy var store: SCDynamicStore? =
        SCDynamicStoreCreate(nil, "sb-helper" as CFString, nil, nil)

    func primaryInterface() -> String? {
        guard let store,
              let d = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = d["PrimaryInterface"] as? String
        else { return nil }
        return name
    }

    private func counters(_ iface: String) -> (UInt64, UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(start) }
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == iface,
                  cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let raw = cur.pointee.ifa_data
            else { continue }
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            return (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
        }
        return nil
    }

    /// Bytes per second, (down, up). Zero on the first sample, on a route
    /// change and on a counter reset - diffing one interface's total against
    /// another's is meaningless, and when the new one has counted more it
    /// renders as a multi-gigabyte spike. Same rule the shell version had.
    func rates() -> (Int, Int)? {
        guard let iface = primaryInterface(), let (rx, tx) = counters(iface) else { return nil }
        let now = Date().timeIntervalSince1970
        defer { lastIface = iface; lastRX = rx; lastTX = tx; lastAt = now }

        let elapsed = now - lastAt
        guard lastIface == iface, elapsed > 0.5, rx >= lastRX, tx >= lastTX else { return (0, 0) }
        return (Int(Double(rx - lastRX) / elapsed), Int(Double(tx - lastTX) / elapsed))
    }
}

/// Never wider than five characters, so the measured label widths in
/// sketchybarrc still hold.
func humanRate(_ bytes: Int) -> String {
    let b = Double(bytes)
    if bytes >= 104_857_600 { return String(format: "%.0fM", b / 1_048_576) }
    if bytes >= 1_048_576   { return String(format: "%.1fM", b / 1_048_576) }
    if bytes >= 1024        { return String(format: "%.0fK", b / 1024) }
    return "\(bytes)B"
}

// MARK: - CoreAudio: mic and volume

enum Audio {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// 0-100, or nil when the default device exposes no scalar volume (some
    /// aggregate and HDMI devices do not).
    static func volume() -> Int? {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return min(100, max(0, Int((v * 100).rounded())))
    }

    static func setVolume(_ percent: Int) {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return }
        var v = Float32(min(100, max(0, percent))) / 100
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func muted() -> Bool {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr else { return false }
        return m == 1
    }

    static func setMuted(_ on: Bool) {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return }
        var m = UInt32(on ? 1 : 0)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    private static func devices() -> [AudioDeviceID] {
        var size = UInt32(0)
        var addr = address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Who is capturing right now: one entry per process, newest API first.
    ///
    /// kAudioHardwarePropertyProcessObjectList (macOS 14+) is the list the
    /// orange dot in the menu bar is derived from - an audio object per
    /// process, each of which can be asked about INPUT specifically. That is
    /// strictly better than asking a device, which can only ever say "somebody
    /// is listening" and never who.
    ///
    /// Returns (pid, app name, bundle id). The bundle id comes straight from
    /// CoreAudio and is what plugins/app_icon.sh matches on, so a consumer gets
    /// its own glyph for free. The name is derived from the executable path
    /// rather than the bundle id because the process is usually a helper:
    /// Slack captures from
    /// /Applications/Slack.app/Contents/Frameworks/Slack Helper.app/...,
    /// and the FIRST .app component - "Slack" - is the answer to "which
    /// application", not the last.
    static func micConsumers() -> [(pid: pid_t, app: String, bundle: String)] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &a, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &a, 0, nil, &size, &objs) == noErr else { return [] }

        var out: [(pid: pid_t, app: String, bundle: String)] = []
        for o in objs {
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var ra = address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(o, &ra, 0, nil, &rsize, &running) == noErr,
                  running == 1
            else { continue }

            var p: pid_t = -1
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var pa = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(o, &pa, 0, nil, &psize, &p) == noErr, p > 0
            else { continue }

            var bundle = ""
            var bref: Unmanaged<CFString>?
            var bsize = UInt32(MemoryLayout<CFString?>.size)
            var ba = address(kAudioProcessPropertyBundleID)
            if AudioObjectGetPropertyData(o, &ba, 0, nil, &bsize, &bref) == noErr,
               let s = bref?.takeRetainedValue() {
                bundle = s as String
            }
            out.append((pid: p, app: appName(forPID: p, bundle: bundle), bundle: bundle))
        }
        // Stable order, so the card does not reshuffle between opens.
        return out.sorted { $0.app.lowercased() < $1.app.lowercased() }
    }

    /// proc_pidpath rather than NSRunningApplication: this file links CoreAudio
    /// and SystemConfiguration, and pulling AppKit in for one localised name
    /// would add its dylib load to a process that starts on every login.
    private static func appName(forPID p: pid_t, bundle: String) -> String {
        // 4096 == PROC_PIDPATHINFO_MAXSIZE, which is a macro in sys/proc_info.h
        // and so invisible to Swift even with libproc.h in the bridging header.
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(p, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            for part in path.split(separator: "/") where part.hasSuffix(".app") {
                return String(part.dropLast(4))
            }
            if let last = path.split(separator: "/").last { return String(last) }
        }
        // A daemon with no bundle and an unreadable path still has to say
        // something; the bundle id beats a bare number.
        return bundle.isEmpty ? "pid \(p)" : bundle
    }

    /// True only while something actually captures.
    ///
    /// Derived from micConsumers() when that list is available, so the item and
    /// its card can never disagree about whether the mic is live. The
    /// device-scope check below is the fallback for an OS without the process
    /// list, and is itself the bug bin/mic-active.swift was fixed for:
    /// kAudioDevicePropertyDeviceIsRunningSomewhere on the GLOBAL scope is
    /// device-wide, so AirPods merely *playing* read as capturing and the red
    /// indicator burned all day. Asked on the INPUT scope it means what it says.
    static func micActive() -> Bool {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var probe: UInt32 = 0
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                          &a, 0, nil, &probe) == noErr, probe > 0 {
            return !micConsumers().isEmpty
        }
        return micActiveByDevice()
    }

    static func micActiveByDevice() -> Bool {
        for dev in devices() {
            var size = UInt32(0)
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
            guard AudioObjectGetPropertyDataSize(dev, &streams, 0, nil, &size) == noErr, size > 0
            else { continue }

            var running = UInt32(0)
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere,
                               kAudioDevicePropertyScopeInput)
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &rsize, &running) == noErr
            else { continue }
            if running == 1 { return true }
        }
        return false
    }

    /// Watch the system object so a device appearing, disappearing or starting
    /// to capture wakes us. This is what retires mic's 3-second poll: 1.2s of
    /// process time a minute for a state that changes a few times a day.
    static func watch(_ selectors: [AudioObjectPropertySelector], _ onChange: @escaping () -> Void) {
        let box = WatchBox(onChange)
        for sel in selectors {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, DispatchQueue.main) { _, _ in box.fire() }
        }
    }

    final class WatchBox {
        private let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        func fire() { f() }
    }
}

// MARK: - herdr

struct Flock {
    var blocked = 0, working = 0, done = 0, idle = 0, unknown = 0
    var total: Int { blocked + working + done + idle + unknown }

    /// The sheep wears the most urgent colour present, same order as the card's
    /// rows: blocked, working, done, then idle.
    var tint: String {
        if blocked > 0 { return C.red }
        if working > 0 { return C.blue }
        if done > 0    { return C.green }
        return C.fgDim
    }
}

/// `herdr agent list` stays a subprocess - it is somebody else's socket
/// protocol and reimplementing the client would be a dependency on their wire
/// format. Parsing it natively still drops bash and jq, which were ~95ms of the
/// 129ms this item used to cost.
func readFlock() -> Flock? {
    let json: Data
    if let fixture = ProcessInfo.processInfo.environment["SB_HELPER_HERDR_JSON"] {
        json = Data(fixture.utf8)
    } else {
        guard let out = run("herdr", ["agent", "list"], timeout: 5) else { return nil }
        json = out
    }
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
          let result = root["result"] as? [String: Any],
          let agents = result["agents"] as? [[String: Any]]
    else { return nil }

    var f = Flock()
    for a in agents {
        switch a["agent_status"] as? String {
        case "blocked": f.blocked += 1
        case "working": f.working += 1
        case "done":    f.done += 1
        case "idle":    f.idle += 1
        default:        f.unknown += 1
        }
    }
    return f
}

/// Bounded, because a wedged helper process must not wedge the bar with it.
func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [tool] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }

    let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    deadline.cancel()
    return p.terminationStatus == 0 ? data : nil
}

// MARK: - Renderers
//
// Every renderer returns its argv fragment instead of sending; the tick joins
// them into ONE mach message. Cheap as a send is, one message that repaints the
// whole cluster also means the bar never lays out a half-updated row.

let cpuSampler = CPUSampler()
let netSampler = NetSampler()

func cpuArgs() -> [String] {
    var a = [String]()
    if let c = cpuSampler.percent() { a += ["--set", "cpu", "label=\(c)%", "icon.color=\(loadColor(c))"] }
    if let m = memPercent()         { a += ["--set", "mem", "label=\(m)%", "icon.color=\(loadColor(m))"] }
    return a
}

func netArgs() -> [String] {
    guard let (down, up) = netSampler.rates() else { return [] }
    return ["--set", "net_down", "label=\(humanRate(down))",
            "--set", "net_up",   "label=\(humanRate(up))"]
}

func micArgs() -> [String] {
    Audio.micActive()
        ? ["--set", "mic", "drawing=on", "icon=󰍬", "icon.color=\(C.red)"]
        : ["--set", "mic", "drawing=off"]
}

func volumeArgs(level: Int? = nil) -> [String] {
    let v = level ?? Audio.volume() ?? 0
    let icon: String
    var color = C.yellow
    if Audio.muted() {
        icon = "󰖁"; color = C.fgDim
    } else {
        switch v {
        case 60...:  icon = "󰕾"
        case 30..<60: icon = "󰖀"
        case 1..<30:  icon = "󰕿"
        default:      icon = "󰖁"
        }
    }
    return ["--set", "volume", "icon=\(icon)", "icon.color=\(color)", "label=\(v)%"]
}

/// Digits hide at zero, and the whole cluster hides when there is no flock at
/// all - a herdr that is not running should leave no trace on the bar.
func herdrArgs(_ f: Flock?) -> [String] {
    guard let f, f.total > 0 else {
        var a = ["--set", "herdr", "drawing=off", "--set", "sep.herdr", "drawing=off"]
        for s in ["blocked", "working", "done", "idle", "unknown"] {
            a += ["--set", "herdr.\(s)", "drawing=off"]
        }
        return a
    }
    var a = ["--set", "herdr", "drawing=on", "icon.color=\(f.tint)",
             "--set", "sep.herdr", "drawing=on"]
    for (state, count, color) in [("blocked", f.blocked, C.red),
                                  ("working", f.working, C.blue),
                                  ("done",    f.done,    C.green),
                                  ("idle",    f.idle,    C.fgDim),
                                  ("unknown", f.unknown, C.orange)] {
        a += count > 0
            ? ["--set", "herdr.\(state)", "drawing=on", "label=\(count)", "label.color=\(color)"]
            : ["--set", "herdr.\(state)", "drawing=off"]
    }
    return a
}

// MARK: - Shared state for the cards
//
// cards/cpu.sh used to sum `ps` itself, which is how the item and its own card
// could disagree about the same percentage. The helper publishes what it just
// rendered and the card reads it, so they agree by construction and the card
// loses a subprocess too.
let cacheDir: String = {
    let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
        ?? (ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.cache" } ?? "/tmp")
    return base + "/sketchybar"
}()

func publish(cpu: Int?, mem: Int?, flock: Flock?) {
    var d: [String: Any] = ["at": Int(Date().timeIntervalSince1970)]
    if let cpu { d["cpu"] = cpu }
    if let mem { d["mem"] = mem }
    if let f = flock {
        d["herdr"] = ["blocked": f.blocked, "working": f.working, "done": f.done,
                      "idle": f.idle, "unknown": f.unknown]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: d) else { return }
    let path = cacheDir + "/helper-state.json"
    // Written via a temp + rename so a card never reads a half-written file.
    let tmp = path + ".new"
    if FileManager.default.createFile(atPath: tmp, contents: data) {
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    }
}

extension FileManager {
    func createFile(atPath path: String, contents: Data) -> Bool {
        createFile(atPath: path, contents: contents, attributes: [.posixPermissions: 0o600])
    }
}

// MARK: - Stuck-card watchdog
//
// plugins/card.sh stamps $SB_CACHE_DIR/card-<item>.at when a card opens and
// removes it on close, and its own tick action force-closes one left open past
// MAX_OPEN. That tick used to ride along on each item's update_freq - so
// removing those ticks would strand the watchdog. Doing it here costs a stat
// per card per tick and no fork, and it now covers every card rather than only
// the items that happened to still be polling.
let cardMaxOpen: TimeInterval = 45
let cardItems = ["meeting", "productive", "media", "cpu", "wifi", "caffeine", "herdr"]

func closeStuckCards() -> [String] {
    var a = [String]()
    for item in cardItems {
        let stamp = cacheDir + "/card-\(item).at"
        guard let text = try? String(contentsOfFile: stamp, encoding: .utf8),
              let at = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { continue }
        if Date().timeIntervalSince1970 - at >= cardMaxOpen {
            a += ["--set", item, "popup.drawing=off"]
            try? FileManager.default.removeItem(atPath: stamp)
        }
    }
    return a
}

// MARK: - Event server
//
// An item carrying `mach_helper=<name>` has its events delivered here instead
// of forking. The payload is the event's environment as NUL-separated
// key/value pairs - the same NAME/SENDER/INFO a script would have read.
/// SB_HELPER_DEBUG=1 traces the receive path to stderr. The events this process
/// handles arrive over mach and leave no trace anywhere otherwise, so without
/// this a mis-wired mach_helper looks identical to a helper that is not running.
let debugEnabled = ProcessInfo.processInfo.environment["SB_HELPER_DEBUG"] == "1"
func debugLog(_ s: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("sb-helper: \(s)\n".utf8))
}

struct Event {
    var vars: [String: String] = [:]
    var name: String { vars["NAME"] ?? "" }
    var sender: String { vars["SENDER"] ?? "" }
}

func parseEvent(_ raw: UnsafeRawPointer, _ count: Int) -> Event {
    let bytes = UnsafeRawBufferPointer(start: raw, count: count)
    let parts = bytes.split(separator: 0)
        .map { String(decoding: $0, as: UTF8.self) }
        .filter { !$0.isEmpty }
    var e = Event()
    var i = 0
    while i + 1 < parts.count { e.vars[parts[i]] = parts[i + 1]; i += 2 }
    return e
}

func handle(_ e: Event) {
    guard e.name == "volume" else { return }
    switch e.sender {
    case "mouse.clicked":
        Audio.setMuted(!Audio.muted())
    case "mouse.scrolled":
        // Zero is the momentum-end event; acting on it nudged the volume down
        // for free. sketchybar formats the delta as a float, so it is compared
        // as a string rather than parsed as an int.
        let d = e.vars["SCROLL_DELTA"] ?? "0"
        guard let delta = Double(d), delta != 0 else { return }
        let cur = Audio.volume() ?? 0
        Audio.setVolume(cur + (delta > 0 ? 6 : -6))
    default:
        break
    }
    bar.send(volumeArgs())
}

/// Registers the bootstrap name and blocks receiving. Runs on its own thread so
/// the timers on the main queue keep firing.
func serveEvents(_ bootstrapName: String) {
    struct Buffer {
        var header = mach_msg_header_t()
        var descriptorCount: mach_msg_size_t = 0
        var descriptor = mach_msg_ool_descriptor_t()
        var trailer = mach_msg_trailer_t()
    }

    var port = mach_port_t()
    var bs = mach_port_t()
    guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS,
          mach_port_insert_right(mach_task_self_, port, port,
                                 mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS,
          task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bs) == KERN_SUCCESS
    else {
        FileHandle.standardError.write(Data("sb-helper: cannot allocate a mach port\n".utf8))
        return
    }
    // 1101 is BOOTSTRAP_NAME_IN_USE: another helper still holds the name, which
    // in practice means the previous instance outlived the reload that should
    // have killed it. Reported with the code because the two failure modes need
    // opposite fixes - a stale process versus a sandbox/entitlement problem.
    let kr = sb_bootstrap_register(bs, bootstrapName, port)
    guard kr == 0 else {
        let hint = kr == 1101 ? " (name already in use - another sb-helper is running)" : ""
        let msg = "sb-helper: cannot register \(bootstrapName): bootstrap_register kr=\(kr)\(hint)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        return
    }
    debugLog("registered \(bootstrapName)")

    // The items route their events here only once the name above exists, so
    // the helper claims them itself rather than sketchybarrc naming a port that
    // may not have been registered yet. Ordering stops being a question: if
    // registration failed we never get here, and those items keep whatever
    // handler the config gave them.
    DispatchQueue.main.async {
        bar.send(["--set", "volume", "mach_helper=\(bootstrapName)"])
    }

    var buf = Buffer()
    while true {
        let size = mach_msg_size_t(MemoryLayout<Buffer>.size)
        // Whole-buffer pointer, for the same reason as the send path: handing
        // mach_msg &buf.header makes Swift copy that one field in and out, so
        // the descriptor the kernel wrote never lands back in `buf` and the
        // payload reads as absent. That failure is silent - the message
        // arrives, the address is nil, and the event is simply dropped.
        let kr = withUnsafeMutablePointer(to: &buf) { bp in
            bp.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) { hp in
                mach_msg(hp, MACH_RCV_MSG, 0, size, port, MACH_MSG_TIMEOUT_NONE,
                         mach_port_t(MACH_PORT_NULL))
            }
        }
        if kr != KERN_SUCCESS {
            debugLog("mach_msg rcv kr=\(kr)")
            continue
        }
        if let addr = buf.descriptor.address {
            let e = parseEvent(addr, Int(buf.descriptor.size))
            debugLog("event \(e.name)/\(e.sender) \(e.vars)")
            DispatchQueue.main.async { handle(e) }
        } else {
            debugLog("message with no descriptor")
        }
        withUnsafeMutablePointer(to: &buf) { bp in
            bp.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) {
                _ = mach_msg_destroy($0)
            }
        }
    }
}

// MARK: - Self test
//
// check.sh's contract: one `key=value` per line, exit 0 only if every reading
// parsed. This is what keeps the suite able to assert this file's arithmetic
// without a running bar - the property the shell plugins had for free by being
// sourceable.
/// Both samplers are delta-based, so their first call only primes and a second
/// call can still come back empty if it lands inside the same sampling window -
/// which made this suite flake roughly one run in three. Retry rather than
/// sleeping longer by default: it is faster when the reading is ready and
/// actually deterministic when it is not.
func settle<T>(tries: Int = 6, delayUs: UInt32 = 250_000, _ read: () -> T?) -> T? {
    for _ in 0..<tries {
        if let v = read() { return v }
        usleep(delayUs)
    }
    return nil
}

func selfTest() -> Never {
    var out = [String]()
    var ok = true

    _ = cpuSampler.percent()          // prime: a delta needs two samples
    if let c = settle({ cpuSampler.percent() }), (0...100).contains(c) { out.append("cpu=\(c)") }
    else { out.append("cpu=ERR"); ok = false }

    if let m = memPercent(), (0...100).contains(m) { out.append("mem=\(m)") }
    else { out.append("mem=ERR"); ok = false }

    if let r = memResidentPercent(), (0...100).contains(r) { out.append("mem_resident=\(r)") }
    else { out.append("mem_resident=ERR"); ok = false }

    if let iface = netSampler.primaryInterface() { out.append("iface=\(iface)") }
    else { out.append("iface=NONE") }   // legitimately absent when offline
    // rates() needs >0.5s between samples before it will diff two counters at
    // all, so this genuinely exercises the arithmetic rather than the zero path.
    _ = netSampler.rates()
    usleep(700_000)
    if let (d, u) = settle({ netSampler.rates() }), d >= 0, u >= 0 { out.append("net=\(d)/\(u)") }
    else { out.append("net=ERR"); ok = false }

    out.append("human=\(humanRate(0))/\(humanRate(2048))/\(humanRate(5_242_880))/\(humanRate(209_715_200))")
    out.append("mic=\(Audio.micActive() ? 1 : 0)")
    // The count must agree with the flag or the item and its card contradict
    // each other - "mic in use" over a card saying nothing is capturing.
    let consumers = Audio.micConsumers()
    out.append("mic_consumers=\(consumers.count)")
    out.append("mic_agree=\((Audio.micActive() == !consumers.isEmpty) ? 1 : 0)")
    if let v = Audio.volume(), (0...100).contains(v) { out.append("volume=\(v)") }
    else { out.append("volume=NONE") }  // aggregate devices expose no scalar
    out.append("muted=\(Audio.muted() ? 1 : 0)")

    if let f = readFlock() {
        out.append("herdr=\(f.blocked)/\(f.working)/\(f.done)/\(f.idle)/\(f.unknown)")
        out.append("tint=\(f.tint)")
    } else {
        out.append("herdr=NONE")        // no herdr server running
    }
    out.append("colors=\(C.red),\(C.blue),\(C.green),\(C.fgDim),\(C.orange),\(C.yellow),\(C.aqua)")

    print(out.joined(separator: "\n"))
    exit(ok ? 0 : 1)
}

// MARK: - Main

setvbuf(stdout, nil, _IONBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())
if argv.contains("--selftest") { selfTest() }

// cards/mic.sh asks the same binary that renders the item, so the card cannot
// name a consumer the item disagrees about. Tab-separated because that is the
// row format card.sh already parses; the app name is free text from a path, so
// the card still runs it through card_text.
if argv.contains("--mic-consumers") {
    for c in Audio.micConsumers() {
        print("\(c.pid)\t\(c.app)\t\(c.bundle)")
    }
    exit(0)
}

// Anything left starting with "--" is a typo, not a bootstrap name. Without
// this check `sb-helper --mic-consumer` (singular) registered "--mic-consumer"
// and daemonised: a second helper holding a junk name, running timers and
// fighting the real one over the same items, with nothing on stdout. Exit
// loudly instead - a daemon is what this binary does by DEFAULT, so every
// unrecognised flag has to be rejected explicitly.
if let bad = argv.first(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write(Data(
        "sb-helper: unknown option \(bad)\nusage: sb-helper [<bootstrap-name>] | --selftest | --mic-consumers\n".utf8))
    exit(2)
}

let bootstrapName = argv.first ?? "git.felix.sbhelper"

// Paint everything once before any timer fires, so a reload does not leave the
// cluster blank for a whole interval.
var flock = readFlock()
var lastFlockShape = ""
bar.send(cpuArgs() + netArgs() + micArgs() + volumeArgs() + herdrArgs(flock))

// Items are laid out in waves after a reload, and meeting/productive fit their
// labels against the x the herdr cluster pushes them to. Nudge them once the
// digits are up, then only when the cluster's width actually changes.
func flockShape(_ f: Flock?) -> String {
    guard let f else { return "off" }
    return "\(f.blocked > 0)\(f.working > 0)\(f.done > 0)\(f.idle > 0)\(f.unknown > 0)"
}
lastFlockShape = flockShape(flock)
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { bar.send(["--trigger", "herdr_flock"]) }

/// 3s: throughput is a rate, and a longer window smears a burst away.
let netTimer = DispatchSource.makeTimerSource(queue: .main)
netTimer.schedule(deadline: .now() + 3, repeating: 3)
netTimer.setEventHandler { bar.send(netArgs()) }
netTimer.resume()

/// 10s for cpu/mem and the flock. herdr used to poll at 5s and was the single
/// most expensive item on the bar; at 10s with no fork it is nearly free.
let slowTimer = DispatchSource.makeTimerSource(queue: .main)
slowTimer.schedule(deadline: .now() + 10, repeating: 10)
slowTimer.setEventHandler {
    let cpu = cpuSampler.percent()
    let mem = memPercent()
    flock = readFlock()

    var args = [String]()
    if let cpu { args += ["--set", "cpu", "label=\(cpu)%", "icon.color=\(loadColor(cpu))"] }
    if let mem { args += ["--set", "mem", "label=\(mem)%", "icon.color=\(loadColor(mem))"] }
    args += herdrArgs(flock)
    args += closeStuckCards()
    bar.send(args)

    let shape = flockShape(flock)
    if shape != lastFlockShape {
        lastFlockShape = shape
        bar.send(["--trigger", "herdr_flock"])
    }
    publish(cpu: cpu, mem: mem, flock: flock)
}
slowTimer.resume()

// Mic and volume are push, not poll: CoreAudio tells us when a device starts
// capturing or the level moves. The slow timer above is the only safety net
// they need, and it is there for device changes the listener misses (a hot-
// unplugged interface), not for routine state.
Audio.watch([kAudioHardwarePropertyDevices,
             kAudioHardwarePropertyDefaultInputDevice,
             kAudioHardwarePropertyDefaultOutputDevice]) {
    bar.send(micArgs() + volumeArgs())
}

let micTimer = DispatchSource.makeTimerSource(queue: .main)
micTimer.schedule(deadline: .now() + 15, repeating: 15)
micTimer.setEventHandler { bar.send(micArgs()) }
micTimer.resume()

Thread { serveEvents(bootstrapName) }.start()
dispatchMain()

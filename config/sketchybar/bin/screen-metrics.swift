// Prints the display metrics the bar layout depends on, so they are not
// hardcoded to one Mac:
//
//   <safeAreaTop> <notchLeft> <notchRight> <screenWidth> <displayUUID>
//
// safeAreaTop is the reserved top inset (38pt on a notched MacBook, 24pt on a
// Mac without one, 0 on a screen that reserves nothing - callers substitute
// their default height there). notchLeft/notchRight bound the region where
// items are hidden by the notch; both are 0 when the display has no notch.
// displayUUID names the chosen screen so shell can map it to sketchybar's
// arrangement id via `--query displays` ("-" when unavailable).
//
// The chosen screen is the one the bar should live on: the first EXTERNAL
// display when one is plugged in, the built-in otherwise. Not NSScreen.main
// (that is keyboard focus, so it flips as you click between screens) and not
// screens[0] (that is whatever macOS calls primary): the bar prefers the
// external screen without requiring the menu bar to be moved there.
//
// Run with: swift bin/screen-metrics.swift
import AppKit

func displayID(_ s: NSScreen) -> CGDirectDisplayID {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

let screens = NSScreen.screens
guard let s = screens.first(where: { CGDisplayIsBuiltin(displayID($0)) == 0 }) ?? screens.first else {
    print("38 0 0 0 -")
    exit(0)
}
let w = s.frame.width
let top = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : (s.frame.maxY - s.visibleFrame.maxY)
var notchLeft = 0.0, notchRight = 0.0
if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
    notchLeft = l.width
    notchRight = w - r.width
}
var uuid = "-"
if let cf = CGDisplayCreateUUIDFromDisplayID(displayID(s))?.takeRetainedValue() {
    uuid = CFUUIDCreateString(nil, cf) as String
}
print(String(format: "%.0f %.0f %.0f %.0f", top, notchLeft, notchRight, w) + " " + uuid)

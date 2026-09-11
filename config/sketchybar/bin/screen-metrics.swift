// Prints the display metrics the bar layout depends on, so they are not
// hardcoded to one Mac:
//
//   <safeAreaTop> <notchLeft> <notchRight> <screenWidth>
//
// safeAreaTop is the reserved top inset - the menu bar's height as macOS
// reports it. Measured on this Mac: 32 on the notched built-in, 30 on an
// external. These are NOT stable across macOS releases (they were 38/24 when
// this was written), which is the whole reason it is queried and not typed in.
// The bar height must equal it or a strip of desktop shows through below it.
//
// notchLeft/notchRight bound the region where items are hidden by the notch.
// Both are 0 when the display has no notch.
//
// Run with: swift bin/screen-metrics.swift
import AppKit

// screens[0], not NSScreen.main: .main is whichever screen holds keyboard
// focus, so on two displays it flips as you click between them and the bar
// gets sized from a screen it is not on. screens[0] is the primary - the one
// with the menu bar, which is exactly where `--bar display=main` draws.
guard let s = NSScreen.screens.first else {
    print("38 0 0 0")
    exit(0)
}
let w = s.frame.width
let top = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : (s.frame.maxY - s.visibleFrame.maxY)
var notchLeft = 0.0, notchRight = 0.0
if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
    notchLeft = l.width
    notchRight = w - r.width
}
print(String(format: "%.0f %.0f %.0f %.0f", top, notchLeft, notchRight, w))

// Prints the display metrics the bar layout depends on, so they are not
// hardcoded to one Mac:
//
//   <safeAreaTop> <notchLeft> <notchRight> <screenWidth>
//
// safeAreaTop is the reserved top inset (38pt on a notched MacBook, 24pt on a
// Mac without one). The bar height must equal it or a strip of desktop shows
// through below the bar.
//
// notchLeft/notchRight bound the region where items are hidden by the notch.
// Both are 0 when the display has no notch.
//
// Run with: swift bin/screen-metrics.swift
import AppKit

guard let s = NSScreen.main ?? NSScreen.screens.first else {
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

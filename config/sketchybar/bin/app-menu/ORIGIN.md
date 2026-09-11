# Vendored: sketchybar_apple_memu_via_swift

Upstream: https://github.com/aizigao/sketchybar_apple_memu_via_swift (MIT)

Renders the frontmost application's menu bar by walking its `AXMenuBar` through
the Accessibility API and `AXPress`ing the row you pick. Driven by
`plugins/app_menu.sh`, built by `bin/build.sh`.

Vendored rather than installed through upstream's own `make install`, which
copies the bundle into `~/.config/sketchybar/plugins`. This config keeps built
artefacts out of the tracked tree, so `bin/build.sh` reproduces the Makefile's
two load-bearing steps instead:

  - it builds an .app BUNDLE, not a bare binary. macOS grants Accessibility to
    bundles, which is why the generic `bin/*.swift` loop cannot own this one.
  - it ad-hoc signs with `--identifier dev.sketchybar.apple-menu` AND a matching
    designated requirement. That is the only reason the Accessibility grant
    survives a rebuild. Change the bundle id and macOS treats the result as a
    different app - silently - and the menu stops opening until it is re-granted
    by hand in System Settings.

Sources are tracked; the built `SketchyBarAppleMenu.app` is not.

Local modifications: none. Keep it that way - if upstream ever needs patching,
record the change here, because nothing else in this repo will show that the
vendored copy has diverged.

// Vertical split straight into neovim's file picker (old herdr: prefix+f).
//
// A mod rather than a keys.json entry because key values only fill a command's
// first argument, and this needs pane.split's argv too. Opened as an overlay by
// cmd-shift-f: it splits, then closes itself. The new pane follows the focused
// pane's folder, so the picker is scoped to the project you were in.
import { View, div } from "gpui-kit";
import { props, run, closeOverlay } from "herdr";

export default class NvimFind extends View {
  render() {
    const overlay = props()?.overlay;
    // `herdr-app check` renders without an overlay: don't split from there.
    if (overlay && !this.done) {
      this.done = true;
      run("pane.split", { direction: "right", argv: ["nvim", "-c", "lua vim.schedule(function() Snacks.picker.files() end)"] });
      closeOverlay(overlay);
    }
    return div();
  }
}

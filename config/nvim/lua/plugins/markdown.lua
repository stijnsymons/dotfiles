-- Markdown: inline images, inline mermaid diagrams, and prose styling.
--
-- This replaces mermaid.nvim. snacks.nvim (already loaded by LazyVim) converts
-- ```mermaid fences through mmdc itself and draws the result in the buffer over
-- the Kitty graphics protocol, so the fence extraction, the command overrides
-- and the capability patching that plugin needed are all gone. It renders
-- ![](diagram.png) the same way, which mermaid.nvim never did at all.
--
-- Requirements: mmdc for mermaid, ImageMagick for every other format (PNG is
-- the only one snacks can hand to the terminal untouched), and a terminal that
-- speaks the Kitty graphics protocol *with* unicode placeholders - Ghostty and
-- kitty do, WezTerm can display but not place inline. `:checkhealth snacks`
-- reports on all of it.

-- mmdc is spawned by nvim, so it inherits nvim's environment and not an
-- interactive shell's. zshrc exports PUPPETEER_EXECUTABLE_PATH for the same
-- reason; repeat the lookup here for a GUI- or launchd-started nvim.
--
-- Deliberately prefers chrome-headless-shell over the full Google Chrome.app:
-- Chrome.app works when spawned from a shell but gets killed by a signal when
-- nvim spawns it (puppeteer reports "Code: null" at ChildProcess.onClose with
-- an empty stderr - a spawn that succeeded and then died). The headless shell
-- skips the LaunchServices/GUI startup path entirely.
local function puppeteer_exe()
  local hits = vim.fn.glob(
    vim.fn.expand("~/.cache/puppeteer/chrome-headless-shell") .. "/*/chrome-headless-shell-*/chrome-headless-shell",
    false,
    true
  )
  table.sort(hits) -- version-ish sort; newest last
  if #hits > 0 then
    return hits[#hits]
  end
  local chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  if vim.fn.executable(chrome) == 1 then
    return chrome
  end
end

return {
  {
    "folke/snacks.nvim",
    -- Runs before snacks loads, which is what the env vars below need.
    init = function()
      if vim.env.PUPPETEER_EXECUTABLE_PATH == nil then
        vim.env.PUPPETEER_EXECUTABLE_PATH = puppeteer_exe()
      end

      -- snacks identifies the terminal by querying it (XTVERSION) rather than
      -- by reading TERM_PROGRAM, so Ghostty and kitty are found on their own.
      -- Herdr strips TERM_PROGRAM and KITTY_WINDOW_ID from its panes and may
      -- swallow the reply, so name the environment for it - Herdr renders
      -- Kitty graphics itself (experimental.kitty_graphics in its config).
      -- HERDR_PANE_ID is the marker.
      --
      -- If images land in the wrong cell or smear inside Herdr panes, its
      -- graphics support doesn't cover unicode placeholders: set
      -- `doc.inline = false` below to fall back to the floating window.
      if vim.env.HERDR_PANE_ID and vim.env.SNACKS_GHOSTTY == nil then
        vim.env.SNACKS_GHOSTTY = "true"
      end

      -- Reveal *all* of a block the cursor enters, not just the lines the
      -- image happened to cover.
      --
      -- When snacks hides an image it blanks the virtual text it drew, but
      -- leaves the conceal_lines extmark it adds when the diagram is shorter
      -- than its source (a wide, many-node `graph LR` is the usual case). The
      -- tail of the fence, closing ``` included, then stays invisible exactly
      -- when you are trying to edit it. Dropping conceal_lines while hidden
      -- costs a small layout shift, which is the trade every other editor
      -- makes for anti-conceal anyway.
      -- Deferred rather than immediate: snacks is only on the runtimepath once
      -- lazy.nvim loads it, which is after every spec's init().
      vim.schedule(function()
        local ok, placement = pcall(require, "snacks.image.placement")
        if not ok or placement._reveal_all then
          return
        end
        local render = placement._render
        placement._reveal_all = true
        placement._render = function(self, extmarks)
          if self.hidden then
            for _, e in ipairs(extmarks) do
              e.conceal_lines = nil
            end
          end
          return render(self, extmarks)
        end
      end)
    end,
    opts = {
      image = {
        enabled = true,
        doc = {
          -- Draw below the fence/link in the buffer instead of a float.
          inline = true,
          -- Fallback for terminals without unicode placeholders.
          float = true,
          max_width = 80,
          max_height = 40,
          -- Show the diagram instead of its source. snacks hides the image
          -- again for whatever block the cursor (or visual selection) is in,
          -- on every CursorMoved, so entering the fence brings the text back.
          --
          -- This needs 'conceallevel' >= 1, which render-markdown sets to 3 in
          -- rendered markdown windows - so <leader>um also unhides every
          -- source block, which is a useful escape hatch.
          conceal = true,
        },
        convert = {
          -- mmdc failing silently was the worst part of the old setup: an
          -- UnknownDiagramError just produced no image and no explanation.
          notify = true,

          -- Diagram resolution. snacks passes the terminal's device scale
          -- (~2.25 on a retina panel) to `mmdc -s`, which is barely enough
          -- pixels to fill the cells the diagram covers, so diagrams render
          -- both small and soft. Oversample instead: Chrome startup dominates
          -- the ~1s render, so the extra pixels are nearly free.
          --
          -- Raising this makes a diagram *bigger* on screen until it hits the
          -- doc.max_width/max_height box above, and sharper once it does. The
          -- cost is terminal-side memory (width x height x 4 bytes), which is
          -- why this stops at 6 rather than going higher: a full-width
          -- sequence diagram is ~4000px wide and ~35MB decoded at that scale.
          mermaid = function()
            local theme = vim.o.background == "light" and "neutral" or "dark"
            local scale = math.max(6, 2.5 * (Snacks.image.terminal.size().scale or 1))
            return { "-i", "{src}", "-o", "{file}", "-b", "transparent", "-t", theme, "-s", tostring(scale) }
          end,

          magick = {
            -- Was 1920x1080: a retina cell is ~18px, so an 80-cell wide image
            -- box is ~1440 physical pixels and 1920px source leaves nothing to
            -- downsample from. `>` only ever shrinks, never upscales.
            default = { "{src}[0]", "-scale", "3840x2160>" },
            -- Vectors and math have no native resolution, so raster them at
            -- 4x CSS density (192 -> 384 dpi) instead of 2x.
            vector = { "-density", 384, "{src}[{page}]" },
            math = { "-density", 384, "{src}[{page}]", "-trim" },
          },
        },
      },
    },
  },

  -- Headings, tables, code blocks and callouts styled in the buffer. Opts
  -- match the LazyVim markdown extra so importing that extra later changes
  -- nothing here.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown", "markdown.mdx", "norg", "rmd", "org", "codecompanion" },
    opts = {
      code = {
        sign = false,
        width = "block",
        right_pad = 1,
      },
      heading = {
        sign = false,
        icons = {},
      },
    },
    config = function(_, opts)
      require("render-markdown").setup(opts)
      Snacks.toggle({
        name = "Render Markdown",
        get = require("render-markdown").get,
        set = require("render-markdown").set,
      }):map("<leader>um")
    end,
  },
}

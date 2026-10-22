return {
  -- 1. Install and configure Catppuccin
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = {
      -- Ensure both light and dark flavours are configured correctly
      background = {
        light = "latte",
        dark = "mocha", -- scale to frappe/macchiato if preferred
      },
    },
  },

  -- 2. Tell LazyVim to use Catppuccin
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },

  -- 3. Follow the terminal's light/dark mode live. Neovim only reads the
  -- terminal background at startup, and auto-dark-mode.nvim polled macOS, which
  -- would undo a `theme` override. So poll the same answer Ghostty, leaf and the
  -- bar use: `theme status` (the override if set, else macOS).
  -- ponytail: one fork every 2s per nvim; push over nvim's RPC socket from
  -- ~/.config/ghostty/theme if that ever shows up.
  {
    "LazyVim/LazyVim",
    init = function()
      local cmd = vim.fn.expand("~/.config/ghostty/theme")
      if vim.fn.executable(cmd) == 0 then return end
      vim.uv.new_timer():start(0, 2000, function()
        vim.system({ cmd, "status" }, { text = true }, function(r)
          local mode = vim.trim(r.stdout or "")
          if mode ~= "light" and mode ~= "dark" then return end
          vim.schedule(function()
            if vim.o.background ~= mode then vim.o.background = mode end
          end)
        end)
      end)
    end,
  },
}

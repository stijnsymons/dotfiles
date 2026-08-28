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

  -- 3. Install the automatic switcher plugin
  {
    "f-person/auto-dark-mode.nvim",
    opts = {
      update_interval = 1000, -- Check for OS theme changes every 1 second
      set_dark_mode = function()
        vim.api.nvim_set_option_value("background", "dark", {})
      end,
      set_light_mode = function()
        vim.api.nvim_set_option_value("background", "light", {})
      end,
    },
  },
}

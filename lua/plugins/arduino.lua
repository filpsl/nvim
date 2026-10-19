-- Arduino: LSP (arduino-language-server + clangd), treesitter e atalhos
-- <leader>a* para compilar/enviar/monitorar. A lógica fica em lua/config/arduino.lua
-- e os atalhos são criados em after/ftplugin/arduino.lua. O que fica fora desta
-- pasta (arduino-cli e o language server com patches) é instalado por arduino/setup.sh.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "arduino" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      local arduino = require("config.arduino")
      opts.servers = opts.servers or {}
      opts.servers.arduino_language_server = {
        -- só liga se o setup.sh já rodou nesta máquina (senão o on_buffer avisa)
        enabled = vim.fn.executable(arduino.ls_bin) == 1,
        -- build própria em ~/.local/bin (com os patches), não a do Mason
        mason = false,
        cmd = arduino.lsp_cmd,
      }
    end,
  },
}

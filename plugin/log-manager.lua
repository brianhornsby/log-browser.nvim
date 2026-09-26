if vim.g.loaded_log_manager then
  return
end
vim.g.loaded_log_manager = true

require('log-manager').setup()

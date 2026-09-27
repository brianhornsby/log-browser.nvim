if vim.g.loaded_log_browser then
  return
end
vim.g.loaded_log_browser = true

require('log-browser').setup()

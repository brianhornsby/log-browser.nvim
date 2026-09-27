local M = {}

function M.check()
  vim.health.start 'log-manager.nvim'

  local ok = pcall(require, 'snacks')
  if ok then
    vim.health.ok 'Snacks is available'
  else
    vim.health.error 'Snacks is not available'
  end

  vim.health.ok 'Native libuv follow mode is available'

  local manager = require 'log-manager'
  local logs = manager.discover()
  vim.health.ok(('Discovered %d log file%s'):format(#logs, #logs == 1 and '' or 's'))

  if #manager.diagnostics == 0 then
    vim.health.ok 'No discovery problems found'
  else
    for _, message in ipairs(manager.diagnostics) do
      vim.health.warn(message)
    end
  end
end

return M

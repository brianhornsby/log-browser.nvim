vim.opt.runtimepath:prepend(vim.fn.getcwd())

local manager = require 'log-manager'
local root = vim.fn.tempname()
local scan_root = root .. '/scan'
vim.fn.mkdir(scan_root, 'p')

local function write(name, contents, modified)
  local path = scan_root .. '/' .. name
  vim.fn.writefile({ contents }, path)
  vim.uv.fs_utime(path, modified, modified)
  return path
end

local a = write('a.log', '1', 30)
local b = write('b.log', '12345', 10)
local c = write('c.log', '123', 20)
write('ignored.log', 'ignored', 40)
local explicit = root .. '/explicit.txt'
vim.fn.writefile({ 'explicit' }, explicit)

manager.setup {
  roots = { scan_root },
  files = { function()
    return explicit
  end },
  ignore = { 'ignored%.log$' },
}

assert(#manager.config.patterns == 2, 'default patterns should be intact')
assert(manager.config.names['lsp.log'] == 'Neovim LSP', 'name defaults should be merged')

local results = manager.discover()
assert(#results == 4, 'discovery should include scanned and explicit files')
assert(results[2].path == a and results[3].path == c and results[4].path == b, 'modified sort failed')

manager.config.sort = 'name'
manager.config.sort_direction = 'asc'
results = manager.discover()
assert(results[1].name == 'A' and results[2].name == 'B' and results[3].name == 'C', 'name sort failed')

manager.config.sort = 'size'
manager.config.sort_direction = 'desc'
results = manager.discover()
assert(results[1].path == explicit, 'size sort failed')

manager.config.filters.min_size = 4
results = manager.discover()
assert(#results == 3, 'size filter failed')

manager.setup { roots = { scan_root }, patterns = { 'a%.log$' } }
results = manager.discover()
assert(#manager.config.patterns == 1, 'pattern lists should replace defaults')
assert(#results == 1 and results[1].path == a, 'custom pattern failed')

local ok = pcall(manager.setup, { sort = 'invalid' })
assert(not ok, 'invalid sort modes should fail')

manager.setup { roots = { '/private/tmp/log-manager-missing-root' }, files = {} }
assert(#manager.discover() == 0 and #manager.diagnostics > 0, 'missing roots should be diagnosed')

local picker_options
package.loaded.snacks = { picker = function(options)
  picker_options = options
end }
manager.setup { roots = {}, files = {} }
manager.open()
assert(type(picker_options.actions.show_help) == 'function', 'help action should be registered')
assert(type(picker_options.actions.follow_log) == 'function', 'follow action should be registered')
assert(picker_options.win.list.keys['?'][1] == 'show_help', 'help key should be discoverable')
manager.setup { roots = { scan_root }, files = {} }
local confirmation_prompt
local select = vim.ui.select
vim.ui.select = function(_, options, callback)
  confirmation_prompt = options.prompt
  callback 'No'
end
picker_options.actions.clear_all_logs({ closed = true })
vim.ui.select = select
assert(confirmation_prompt:match('a%.log'), 'clear-all confirmation should include discovery paths')
local fake_picker = {
  closed = false,
  list = { set_target = function() end },
  selected = function()
    return {}
  end,
  current = function()
    return nil
  end,
  find = function() end,
}
vim.fn.delete(root, 'rf')
print 'log-manager tests passed'

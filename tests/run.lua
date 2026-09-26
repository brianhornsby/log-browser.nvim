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

manager.config.filters.empty = false
manager.config.filters.min_size = 4
results = manager.discover()
assert(#results == 3, 'size filter failed')

manager.setup { roots = { scan_root }, patterns = { 'a%.log$' } }
results = manager.discover()
assert(#manager.config.patterns == 1, 'pattern lists should replace defaults')
assert(#results == 1 and results[1].path == a, 'custom pattern failed')

local ok = pcall(manager.setup, { sort = 'invalid' })
assert(not ok, 'invalid sort modes should fail')

vim.fn.delete(root, 'rf')
print 'log-manager tests passed'

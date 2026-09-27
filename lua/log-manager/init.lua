local M = {}

local uv = vim.uv or vim.loop

local defaults = {
  roots = nil,
  files = {},
  max_depth = 4,
  sort = 'modified',
  sort_direction = nil,
  patterns = { '%.log$', '/log$' },
  ignore = {},
  filters = {
    min_size = 0,
    modified_after = nil,
    names = nil,
  },
  preview = {
    max_size = 1024 * 1024,
    tail_lines = 500,
  },
  cleanup_days = 30,
  names = {
    ['conform.log'] = 'Conform',
    ['fidget.nvim.log'] = 'Fidget',
    ['log'] = 'Neovim core',
    ['lsp.log'] = 'Neovim LSP',
    ['luasnip.log'] = 'LuaSnip',
    ['mason.log'] = 'Mason',
    ['noice.log'] = 'Noice',
    ['nvim.log'] = 'Neovim',
  },
}

M.config = vim.deepcopy(defaults)
M.diagnostics = {}

local sort_modes = { 'modified', 'name', 'size' }

local function diagnostic(message)
  M.diagnostics[#M.diagnostics + 1] = message
end

local function default_roots()
  return {
    vim.fn.stdpath 'state',
    vim.fn.stdpath 'cache',
    vim.fn.stdpath 'data',
  }
end

local function is_log(path)
  local lower = path:lower()
  for _, pattern in ipairs(M.config.patterns) do
    if lower:match(pattern) then
      return true
    end
  end
  return false
end

local function is_ignored(path)
  for _, pattern in ipairs(M.config.ignore) do
    if path:match(pattern) then
      return true
    end
  end
  return false
end

local function is_visible(entry)
  local filters = M.config.filters
  if entry.size < filters.min_size then
    return false
  end
  if filters.modified_after and entry.modified < filters.modified_after then
    return false
  end
  if filters.names and not vim.tbl_contains(filters.names, entry.name) then
    return false
  end
  return true
end

local function normalized_name(value)
  return value:lower():gsub('%.log.*$', ''):gsub('%.nvim$', ''):gsub('^nvim%-', ''):gsub('[^%w]', '')
end

local function display_name(value)
  local name = value:gsub('%.nvim$', ''):gsub('^nvim%-', ''):gsub('[-_]+', ' ')
  return (name:gsub('(%a)([%w]*)', function(first, rest)
    return first:upper() .. rest
  end))
end

local function producer_name(path)
  local filename = vim.fn.fnamemodify(path, ':t'):lower()
  if M.config.names[filename] then
    return M.config.names[filename]
  end

  local stem = normalized_name(filename)
  local ok, lazy = pcall(require, 'lazy.core.config')
  if ok then
    for name, plugin in pairs(lazy.plugins or {}) do
      local repository = type(plugin[1]) == 'string' and plugin[1]:match '([^/]+)$' or nil
      if normalized_name(name) == stem or (repository and normalized_name(repository) == stem) then
        return display_name(repository or name)
      end
    end
  end

  local parent = vim.fn.fnamemodify(path, ':h:t')
  if parent:match '%.nvim$' then
    return display_name(parent)
  end
  return display_name(filename:gsub('%.log.*$', ''))
end

local function scan(directory, depth, max_depth, results, seen)
  if depth > max_depth then
    return
  end

  local handle = uv.fs_scandir(directory)
  if not handle then
    diagnostic('Could not scan directory: ' .. directory)
    return
  end

  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local path = vim.fs.joinpath(directory, name)
    if is_ignored(path) then
      -- Ignore both matching files and whole directory trees.
    elseif kind == 'directory' then
      scan(path, depth + 1, max_depth, results, seen)
    elseif kind == 'file' and is_log(path) then
      local canonical = uv.fs_realpath(path) or path
      if not seen[canonical] then
        local stat = uv.fs_stat(path)
        seen[canonical] = true
        local entry = {
          path = path,
          name = producer_name(path),
          size = stat and stat.size or 0,
          modified = stat and stat.mtime and stat.mtime.sec or 0,
        }
        if not stat then
          diagnostic('Could not read file metadata: ' .. path)
        end
        if is_visible(entry) then
          results[#results + 1] = entry
        end
      end
    end
  end
end

local function add_file(path, results, seen)
  if type(path) ~= 'string' or path == '' then
    diagnostic('A configured file provider returned an invalid path')
    return
  end
  path = vim.fs.normalize(path)
  if is_ignored(path) then
    return
  end
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    diagnostic('Configured log file does not exist: ' .. path)
    return
  end
  local canonical = uv.fs_realpath(path) or path
  if seen[canonical] then
    return
  end
  seen[canonical] = true
  local entry = { path = path, name = producer_name(path), size = stat.size or 0, modified = stat.mtime.sec or 0 }
  if is_visible(entry) then
    results[#results + 1] = entry
  end
end

local function configured_files(results, seen)
  for _, value in ipairs(M.config.files) do
    if type(value) == 'function' then
      local ok, provided = pcall(value)
      if not ok then
        diagnostic('Log file provider failed: ' .. tostring(provided))
      elseif type(provided) == 'table' then
        for _, path in ipairs(provided) do
          add_file(path, results, seen)
        end
      else
        add_file(provided, results, seen)
      end
    else
      add_file(value, results, seen)
    end
  end
end

function M.discover()
  local results, seen = {}, {}
  M.diagnostics = {}
  for _, configured_root in ipairs(M.config.roots or default_roots()) do
    local root = type(configured_root) == 'table' and configured_root.path or configured_root
    local max_depth = type(configured_root) == 'table' and configured_root.max_depth or M.config.max_depth
    if type(root) ~= 'string' or type(max_depth) ~= 'number' then
      diagnostic('Invalid configured root: ' .. vim.inspect(configured_root))
      goto continue
    end
    root = vim.fs.normalize(root)
    if uv.fs_stat(root) then
      scan(root, 0, max_depth, results, seen)
    else
      diagnostic('Configured root does not exist: ' .. root)
    end
    ::continue::
  end
  configured_files(results, seen)
  table.sort(results, function(a, b)
    local left, right
    local direction = M.config.sort_direction or (M.config.sort == 'name' and 'asc' or 'desc')
    if M.config.sort == 'name' then
      left, right = a.name:lower(), b.name:lower()
    elseif M.config.sort == 'size' then
      left, right = a.size, b.size
    else
      left, right = a.modified, b.modified
    end

    if left == right then
      return a.path < b.path
    end
    if direction == 'asc' then
      return left < right
    end
    return left > right
  end)
  return results
end

local function discover_all()
  local filters = M.config.filters
  M.config.filters = vim.deepcopy(defaults.filters)
  local ok, results = pcall(M.discover)
  M.config.filters = filters
  if not ok then
    error(results)
  end
  return results
end

local function human_size(bytes)
  local units = { 'B', 'KiB', 'MiB', 'GiB' }
  local value, unit = bytes, 1
  while value >= 1024 and unit < #units do
    value = value / 1024
    unit = unit + 1
  end
  if unit == 1 then
    return string.format('%d %s', value, units[unit])
  end
  return string.format('%.1f %s', value, units[unit])
end

local function human_age(timestamp)
  if timestamp <= 0 then
    return 'unknown'
  end
  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then
    return 'now'
  elseif seconds < 3600 then
    return ('%dm ago'):format(math.floor(seconds / 60))
  elseif seconds < 86400 then
    return ('%dh ago'):format(math.floor(seconds / 3600))
  end
  return ('%dd ago'):format(math.floor(seconds / 86400))
end

local function clear_file(path)
  local file, err = io.open(path, 'w')
  if not file then
    vim.notify(('Could not clear %s: %s'):format(path, err or 'unknown error'), vim.log.levels.ERROR)
    return false
  end
  file:close()
  return true
end

local function confirm(prompt, callback)
  vim.ui.select({ 'No', 'Yes' }, { prompt = prompt }, function(choice)
    if choice == 'Yes' then
      callback()
    end
  end)
end

local function selected_items(picker, item)
  if picker then
    local items = picker:selected { fallback = true }
    if #items > 0 then
      return items
    end
  end
  return item and { item } or {}
end

local function target_summary(items)
  if #items == 1 then
    return ('%s (%s)'):format(items[1].name, items[1].file or items[1].path)
  end
  local paths = {}
  for index, selected in ipairs(items) do
    if index > 3 then
      break
    end
    paths[#paths + 1] = selected.file or selected.path
  end
  local suffix = #items > #paths and (' and %d more'):format(#items - #paths) or ''
  return ('%d selected logs:\n%s%s'):format(#items, table.concat(paths, '\n'), suffix)
end

local function sort_footer()
  local direction = M.config.sort_direction or (M.config.sort == 'name' and 'asc' or 'desc')
  return (' Sort: %s %s '):format(M.config.sort, direction == 'asc' and '↑' or '↓')
end

local function update_sort_footer(picker)
  if not picker or picker.closed or not picker.list.win or not picker.list.win.win then
    return
  end
  picker.list.win.opts.footer = sort_footer()
  vim.schedule(function()
    if not picker.closed and vim.api.nvim_win_is_valid(picker.list.win.win) then
      picker.list.win:update()
    end
  end)
end

local function refresh(picker)
  if picker and not picker.closed then
    if picker.list.win then
      picker.list.win.opts.footer = sort_footer()
    end
    local selected = {}
    for _, item in ipairs(picker:selected()) do
      selected[item.file] = true
    end
    local current = picker:current()
    local current_file = current and current.file
    picker.list:set_target()
    picker:find {
      refresh = true,
      on_done = function()
        if picker.closed then
          return
        end
        local restored, cursor = {}, nil
        for index, found in ipairs(picker.list.items) do
          if selected[found.file] then
            restored[#restored + 1] = found
          end
          if found.file == current_file then
            cursor = index
          end
        end
        picker.list:set_selected(restored)
        if cursor then
          picker.list:view(cursor)
        end
        update_sort_footer(picker)
      end,
    }
  end
end

local function clear_selected(picker, item)
  local items = selected_items(picker, item)
  if #items == 0 then
    return
  end
  local target = target_summary(items)
  confirm(('Clear %s? '):format(target), function()
    local cleared = 0
    for _, selected in ipairs(items) do
      if clear_file(selected.file) then
        cleared = cleared + 1
      end
    end
    vim.notify(('Cleared %d of %d log files'):format(cleared, #items))
    refresh(picker)
  end)
end

local function delete_selected(picker, item)
  local items = selected_items(picker, item)
  if #items == 0 then
    return
  end
  local target = target_summary(items)
  confirm(('Permanently delete %s? '):format(target), function()
    local deleted, failures = 0, {}
    for _, selected in ipairs(items) do
      local ok, err = uv.fs_unlink(selected.file)
      if ok then
        deleted = deleted + 1
      else
        failures[#failures + 1] = ('%s: %s'):format(selected.file, err or 'unknown error')
      end
    end
    local level = #failures > 0 and vim.log.levels.WARN or vim.log.levels.INFO
    local suffix = #failures > 0 and ('\n' .. table.concat(failures, '\n')) or ''
    vim.notify(('Deleted %d of %d log files%s'):format(deleted, #items, suffix), level)
    refresh(picker)
  end)
end

local function clear_all(picker)
  local entries = discover_all()
  if #entries == 0 then
    return
  end
  confirm(('Clear all logs?\n%s'):format(target_summary(entries)), function()
    local cleared = 0
    for _, entry in ipairs(entries) do
      if clear_file(entry.path) then
        cleared = cleared + 1
      end
    end
    vim.notify(('Cleared %d log files'):format(cleared))
    refresh(picker)
  end)
end

local function cycle_sort(picker)
  local current = vim.fn.index(sort_modes, M.config.sort)
  M.config.sort = sort_modes[(current + 1) % #sort_modes + 1]
  M.config.sort_direction = nil
  vim.notify('Log sorting: ' .. M.config.sort)
  refresh(picker)
end

local function show_help(picker)
  picker:close()
  vim.schedule(function()
    vim.cmd.new()
    local buffer = vim.api.nvim_get_current_buf()
    local lines = {
      'Log Manager picker',
      '',
      'Navigation',
      '  <Enter>  Open the selected log',
      '  <Tab>    Select or unselect an item',
      '  ?        Show this help',
      '',
      'Log actions',
      '  c        Clear selected log(s)',
      '  d        Delete selected log(s)',
      '  C        Clear all discovered logs',
      '  y        Copy selected paths',
      '  R        Reveal the selected log directory',
      '  G        Open the selected log at its end',
      '  F        Follow the selected log',
      '  X        Delete logs older than cleanup_days',
      '',
      'View controls',
      '  s        Cycle sorting',
      '  r        Refresh the log list',
      '  q        Close this help',
    }
    vim.bo[buffer].buftype = 'nofile'
    vim.bo[buffer].bufhidden = 'wipe'
    vim.bo[buffer].swapfile = false
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.api.nvim_buf_set_keymap(buffer, 'n', 'q', '<cmd>close<cr>', { nowait = true, silent = true })
    vim.api.nvim_buf_set_keymap(buffer, 'n', '<Esc>', '<cmd>close<cr>', { nowait = true, silent = true })
  end)
end

local function copy_paths(picker, item)
  local paths = vim.tbl_map(function(selected)
    return selected.file
  end, selected_items(picker, item))
  if #paths > 0 then
    vim.fn.setreg('+', table.concat(paths, '\n'))
    vim.fn.setreg('"', table.concat(paths, '\n'))
    vim.notify(('Copied %d log path%s'):format(#paths, #paths == 1 and '' or 's'))
  end
end

local function reveal_log(_, item)
  if item then
    vim.ui.open(vim.fn.fnamemodify(item.file, ':h'))
  end
end

local function open_at_end(picker, item)
  if not item then
    return
  end
  picker:close()
  vim.schedule(function()
    vim.cmd.edit(vim.fn.fnameescape(item.file))
    vim.cmd 'normal! G'
  end)
end

local function follow_log(picker, item)
  if not item then
    return
  end
  picker:close()
  vim.schedule(function()
    vim.cmd.edit(vim.fn.fnameescape(item.file))
    vim.cmd 'normal! G'
    local buffer = vim.api.nvim_get_current_buf()
    local timer = uv.new_timer()
    if not timer then
      return
    end
    local last_size = item.size
    local last_modified = item.modified
    timer:start(500, 500, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(buffer) then
        timer:stop()
        timer:close()
        return
      end
      local stat = uv.fs_stat(item.file)
      if stat and (stat.size ~= last_size or (stat.mtime and stat.mtime.sec ~= last_modified)) then
        last_size = stat.size
        last_modified = stat.mtime and stat.mtime.sec or last_modified
        vim.api.nvim_buf_call(buffer, function()
          vim.cmd.checktime()
          vim.cmd 'normal! G'
        end)
      end
    end))
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buffer,
      once = true,
      callback = function()
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end,
    })
  end)
end

local function preview_log(ctx)
  if ctx.item.size == 0 then
    ctx.preview:reset()
    ctx.preview:minimal()
    ctx.preview:set_title(ctx.item.title)
    ctx.preview:set_lines {}
    return
  end
  if ctx.item.size <= M.config.preview.max_size then
    return require('snacks.picker.preview').file(ctx)
  end
  ctx.preview:reset()
  ctx.preview:minimal()
  ctx.preview:set_title(('%s — last %d lines'):format(ctx.item.title, M.config.preview.tail_lines))
  local ok, lines = pcall(vim.fn.readfile, ctx.item.file, '', -M.config.preview.tail_lines)
  if not ok then
    ctx.preview:notify('Could not read log file', 'error')
    return
  end
  table.insert(lines, 1, ('[Large log: showing the last %d lines]'):format(M.config.preview.tail_lines))
  ctx.preview:set_lines(lines)
  ctx.preview:highlight { ft = 'log' }
end

local function delete_old_logs(picker)
  local cutoff = os.time() - M.config.cleanup_days * 86400
  local old = vim.tbl_filter(function(entry)
    return entry.modified > 0 and entry.modified < cutoff
  end, discover_all())
  if #old == 0 then
    vim.notify(('No logs older than %d days'):format(M.config.cleanup_days))
    return
  end
  confirm(('Permanently delete %d logs older than %d days? '):format(#old, M.config.cleanup_days), function()
    local deleted = 0
    for _, entry in ipairs(old) do
      if uv.fs_unlink(entry.path) then
        deleted = deleted + 1
      end
    end
    vim.notify(('Deleted %d of %d old logs'):format(deleted, #old))
    refresh(picker)
  end)
end

local function action_menu(picker, item)
  local actions = {
    ['Clear selected log(s)'] = clear_selected,
    ['Delete selected log(s)'] = delete_selected,
    ['Clear all discovered logs'] = clear_all,
    ['Copy selected paths'] = copy_paths,
    ['Reveal log directory'] = reveal_log,
    ['Open log at end'] = open_at_end,
    ['Follow log'] = follow_log,
    ['Delete old logs'] = delete_old_logs,
    ['Show help'] = show_help,
  }
  local labels = vim.tbl_keys(actions)
  table.sort(labels)
  vim.ui.select(labels, { prompt = 'Log action' }, function(choice)
    if choice and actions[choice] then
      actions[choice](picker, item)
    end
  end)
end

function M.open()
  local function finder(_, ctx)
    local items = {}
    for index, entry in ipairs(M.discover()) do
      items[index] = {
        file = entry.path,
        name = entry.name,
        title = entry.name,
        size = entry.size,
        modified = entry.modified,
        text = table.concat({ entry.name, entry.path, human_size(entry.size) }, ' '),
      }
    end
    return items
  end

  require('snacks').picker {
    title = 'Neovim Logs',
    finder = finder,
    preview = preview_log,
    sort = { fields = { 'score:desc', 'idx' } },
    layout = {
      layout = {
        box = 'horizontal',
        width = 0.9,
        min_width = 110,
        height = 0.8,
        {
          box = 'vertical',
          width = 35 / 110,
          border = true,
          title = '{title} {live} {flags}',
          { win = 'input', height = 1, border = 'bottom' },
          { win = 'list', border = 'bottom', footer = sort_footer() },
        },
        { win = 'preview', title = '{preview}', border = true, width = 75 / 110 },
      },
    },
    format = function(item)
      return {
        { item.name, 'SnacksPickerLabel' },
        { '  ' .. human_size(item.size), 'SnacksPickerComment' },
        { '  ' .. human_age(item.modified), 'SnacksPickerComment' },
        { '  ' .. vim.fn.fnamemodify(item.file, ':h:t'), 'SnacksPickerComment' },
      }
    end,
    actions = {
      clear_log = clear_selected,
      delete_log = delete_selected,
      clear_all_logs = function(picker)
        clear_all(picker)
      end,
      cycle_sort = cycle_sort,
      refresh_logs = refresh,
      copy_paths = copy_paths,
      reveal_log = reveal_log,
      open_at_end = open_at_end,
      follow_log = follow_log,
      delete_old_logs = delete_old_logs,
      show_help = show_help,
      action_menu = action_menu,
    },
    win = {
      input = {
        keys = {
          ['<c-c>'] = { 'clear_log', mode = { 'n', 'i' }, desc = 'Clear log' },
          ['<c-d>'] = { 'delete_log', mode = { 'n', 'i' }, desc = 'Delete log' },
          ['<c-a>'] = { 'clear_all_logs', mode = { 'n', 'i' }, desc = 'Clear all logs' },
          ['<c-s>'] = { 'cycle_sort', mode = { 'n', 'i' }, desc = 'Cycle log sorting' },
          ['<c-r>'] = { 'refresh_logs', mode = { 'n', 'i' }, desc = 'Refresh logs' },
          ['<c-?>'] = { 'show_help', mode = { 'n', 'i' }, desc = 'Show log manager help' },
          ['<c-space>'] = { 'action_menu', mode = { 'n', 'i' }, desc = 'Open log action menu' },
        },
      },
      list = {
        keys = {
          c = { 'clear_log', desc = 'Clear log' },
          d = { 'delete_log', desc = 'Delete log' },
          C = { 'clear_all_logs', desc = 'Clear all logs' },
          s = { 'cycle_sort', desc = 'Cycle log sorting' },
          r = { 'refresh_logs', desc = 'Refresh logs' },
          y = { 'copy_paths', desc = 'Copy selected log paths' },
          R = { 'reveal_log', desc = 'Reveal log directory' },
          G = { 'open_at_end', desc = 'Open log at end' },
          F = { 'follow_log', desc = 'Follow log updates' },
          X = { 'delete_old_logs', desc = 'Delete old logs' },
          ['?'] = { 'show_help', desc = 'Show log manager help' },
          ['<space>'] = { 'action_menu', desc = 'Open log action menu' },
        },
      },
    },
  }
end

function M.setup(opts)
  opts = opts or {}
  local config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  for _, key in ipairs { 'roots', 'files', 'patterns', 'ignore' } do
    if opts[key] ~= nil then
      config[key] = vim.deepcopy(opts[key])
    end
  end
  if vim.fn.index(sort_modes, config.sort) == -1 then
    error(('Invalid log-manager sort mode: %s'):format(vim.inspect(config.sort)))
  end
  if config.sort_direction ~= nil and config.sort_direction ~= 'asc' and config.sort_direction ~= 'desc' then
    error(('Invalid log-manager sort direction: %s'):format(vim.inspect(config.sort_direction)))
  end
  for _, pattern in ipairs(config.patterns) do
    local ok, err = pcall(string.match, '', pattern)
    if not ok then
      error(('Invalid log-manager pattern %q: %s'):format(pattern, err))
    end
  end
  for _, pattern in ipairs(config.ignore) do
    local ok, err = pcall(string.match, '', pattern)
    if not ok then
      error(('Invalid log-manager ignore pattern %q: %s'):format(pattern, err))
    end
  end
  M.config = config
  vim.api.nvim_create_user_command('LogManager', M.open, { desc = 'Browse and manage Neovim logs', force = true })
  vim.api.nvim_create_user_command('LogManagerCleanup', function()
    delete_old_logs()
  end, { desc = 'Delete old Neovim logs', force = true })
  vim.api.nvim_create_user_command('LogManagerHealth', function()
    vim.cmd.checkhealth 'log-manager'
  end, { desc = 'Check log-manager health', force = true })
end

return M

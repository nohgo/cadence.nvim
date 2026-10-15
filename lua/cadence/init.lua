local M = {}
local api = vim.api
local parser = require('cadence.parser')
local compiler = require('cadence.compiler')
local namespace = api.nvim_create_namespace('cadence')
local defaults = {
  enabled = true,
  on_save = true,
  filetypes = { 'verilogams' },
  command = 'xmvlog',
  args = { '-ams' },
  include_dirs = {},
  timeout_ms = 10000,
  quickfix = true,
  open_quickfix = false,
}
local config = vim.deepcopy(defaults)
local states, published, warnings, active_runs = {}, {}, {}, {}
local enabled, group, qfid = false, nil, nil
local publish

local function notify_once(key, message)
  if not warnings[key] then
    warnings[key] = true
    vim.notify('cadence.nvim: ' .. message, vim.log.levels.WARN)
  end
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function kill(run, signal)
  if run.process and not run.finished then
    -- detach=true gives the compiler its own POSIX process group, including children.
    local ok, result = pcall(vim.uv.kill, -run.process.pid, signal)
    if not ok or not result then
      pcall(run.process.kill, run.process, signal)
    end
  end
end

local function stop(run)
  if not run or run.finished then return end
  kill(run, 15)
  close_timer(run.kill_timer)
  run.kill_timer = vim.defer_fn(function() kill(run, 9) end, 200)
end

local function cancel(state)
  local run = state.run
  state.run = nil
  if run then
    stop(run)
  end
end

local function quickfix_items()
  local records, seen = {}, {}
  for _, bufnr in ipairs(vim.tbl_keys(states)) do
    for _, record in ipairs(states[bufnr].records or {}) do
      local key = table.concat({ record.filename or '', record.lnum or '', record.col or '',
        record.tool, record.level, record.code, record.message }, '\0')
      if not seen[key] then
        seen[key] = true
        records[#records + 1] = record
      end
    end
  end
  table.sort(records, function(a, b)
    local af, bf = a.filename or '', b.filename or ''
    if af ~= bf then return af < bf end
    if (a.lnum or -1) ~= (b.lnum or -1) then return (a.lnum or -1) < (b.lnum or -1) end
    if (a.col or -1) ~= (b.col or -1) then return (a.col or -1) < (b.col or -1) end
    return a.code .. a.message < b.code .. b.message
  end)
  local items = {}
  for _, record in ipairs(records) do
    local item = {
      text = record.tool .. ' [' .. record.code .. '] ' .. record.message,
      type = record.severity == vim.diagnostic.severity.ERROR and 'E'
        or record.severity == vim.diagnostic.severity.WARN and 'W' or 'I',
      valid = record.filename and 1 or 0,
    }
    if record.filename then
      item.filename, item.lnum, item.col = record.filename, record.lnum + 1, record.col + 1
    end
    items[#items + 1] = item
  end
  return records, items
end

local function update_quickfix(items, select_list)
  local current = vim.fn.getqflist({ id = 0 }).id
  local exists = qfid and vim.fn.getqflist({ id = qfid }).id == qfid
  local data = { title = 'Cadence compiler checks', items = items, context = { cadence = true } }
  if exists and (not select_list or current == qfid) then
    data.id = qfid
    vim.fn.setqflist({}, 'r', data)
  else
    vim.fn.setqflist({}, ' ', data)
    qfid = vim.fn.getqflist({ id = 0 }).id
  end
end

publish = function()
  local records, items = quickfix_items()
  local by_buffer = {}
  for _, record in ipairs(records) do
    if record.filename then
      local buf = vim.fn.bufadd(record.filename)
      by_buffer[buf] = by_buffer[buf] or {}
      by_buffer[buf][#by_buffer[buf] + 1] = {
        lnum = record.lnum, col = record.col, severity = record.severity,
        source = record.tool, code = record.code, message = record.message,
      }
    end
  end
  for buf in pairs(published) do
    if not by_buffer[buf] then vim.diagnostic.reset(namespace, buf) end
  end
  published = {}
  for buf, diagnostics in pairs(by_buffer) do
    vim.diagnostic.set(namespace, buf, diagnostics)
    published[buf] = true
  end
  if config.quickfix then
    -- Do not create an empty list during initial setup/disable.
    if qfid or #items > 0 then update_quickfix(items, false) end
    if config.open_quickfix and #items > 0 then
      update_quickfix(items, true)
      vim.cmd.copen()
    end
  end
end

local function current(run)
  return enabled and states[run.bufnr] and states[run.bufnr].run == run
    and api.nvim_buf_is_loaded(run.bufnr)
    and api.nvim_buf_get_name(run.bufnr) == run.filename
    and api.nvim_buf_get_changedtick(run.bufnr) == run.tick
    and not vim.bo[run.bufnr].modified
end

local function output_text(run, result)
  local log = run.scratch .. '/xmvlog.log'
  local pieces = { result.stdout or '', result.stderr or '' }
  if vim.fn.filereadable(log) == 1 then
    table.insert(pieces, 1, table.concat(vim.fn.readfile(log), '\n'))
  end
  return table.concat(pieces, '\n')
end

local function finish(run, result)
  run.finished = true
  active_runs[run] = nil
  close_timer(run.timer)
  close_timer(run.kill_timer)
  local output = output_text(run, result)
  local is_current = current(run)
  if is_current then
    local state = states[run.bufnr]
    local cache = vim.fn.stdpath('cache') .. '/cadence'
    local log = cache .. '/' .. vim.fn.sha256(run.filename):sub(1, 24) .. '.log'
    local log_ok, log_result = pcall(function()
      vim.fn.mkdir(cache, 'p', 448)
      return vim.fn.writefile(vim.split(output, '\n', { plain = true }), log)
    end)
    local saved = log_ok and log_result == 0
    if not saved then notify_once('log', 'Could not retain compiler output under ' .. cache) end
    state.last = {
      command = run.argv, cwd = run.scratch, root = run.root,
      code = result.code, signal = result.signal, timed_out = run.timed_out or false,
      log = saved and log or nil,
    }
    state.run = nil
    local records = parser.parse(output, run.scratch)
    local filtered, has_error, stale_input = {}, false, false
    for _, record in ipairs(records) do
      local buf = record.filename and vim.fn.bufnr(record.filename) or -1
      local stale = buf >= 0 and api.nvim_buf_is_loaded(buf)
        and (vim.bo[buf].modified or (run.ticks[buf] and run.ticks[buf] ~= api.nvim_buf_get_changedtick(buf)))
      stale_input = stale_input or stale
      if not stale then
        filtered[#filtered + 1] = record
        has_error = has_error or record.severity == vim.diagnostic.severity.ERROR
      end
    end
    if stale_input then
      filtered = {}
      state.last.stale = true
    elseif run.timed_out or ((result.code ~= 0 or result.signal ~= 0) and not has_error) then
      local message = run.timed_out and ('Compiler timed out after ' .. config.timeout_ms .. ' ms.')
        or ('Compiler failed (exit ' .. result.code .. ', signal ' .. result.signal .. ') without a located error.')
      message = message .. (saved and (' Full output: ' .. log) or ' Could not retain the compiler log.')
      filtered[#filtered + 1] = {
        tool = 'cadence', level = 'E', code = run.timed_out and 'TIMEOUT' or 'PROCESS',
        severity = vim.diagnostic.severity.ERROR, message = message,
      }
      notify_once(run.timed_out and 'timeout' or 'process', message)
    end
    state.records = filtered
    publish()
  elseif states[run.bufnr] and states[run.bufnr].run == run then
    states[run.bufnr].run = nil
  end
end

local function complete(run, result)
  local ok, err = pcall(finish, run, result)
  -- Cleanup still runs if a filesystem or diagnostic handler raises an error.
  vim.fn.delete(run.scratch, 'rf')
  if not ok then
    if states[run.bufnr] and states[run.bufnr].run == run then
      states[run.bufnr].run = nil
    end
    notify_once('completion', 'Could not process compiler output: ' .. tostring(err))
  end
end

function M.check(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  if not enabled or not api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= ''
    or not vim.tbl_contains(config.filetypes, vim.bo[bufnr].filetype) then return false end
  local filename = api.nvim_buf_get_name(bufnr)
  if filename == '' or vim.bo[bufnr].modified or vim.fn.filereadable(filename) ~= 1 then return false end
  local state = states[bufnr] or {}
  states[bufnr] = state
  cancel(state)
  state.records = nil
  publish()
  if vim.fn.executable(config.command) ~= 1 then
    state.last = { error = 'Executable not found: ' .. config.command }
    notify_once('missing:' .. config.command, state.last.error .. '; checks skipped. Check PATH or disable the plugin.')
    return false
  end
  local ok, run = pcall(compiler.prepare, config, bufnr)
  if not ok then
    state.last = { error = tostring(run) }
    notify_once('configuration', state.last.error)
    return false
  end
  run.tick, run.ticks = api.nvim_buf_get_changedtick(bufnr), {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then run.ticks[buf] = api.nvim_buf_get_changedtick(buf) end
  end
  state.run = run
  active_runs[run] = true
  local spawned, process = pcall(vim.system, run.argv, {
    cwd = run.scratch, text = true, detach = true,
  }, function(result) vim.schedule(function() complete(run, result) end) end)
  if not spawned then
    active_runs[run] = nil
    state.run, state.last = nil, { error = tostring(process) }
    vim.fn.delete(run.scratch, 'rf')
    notify_once('spawn', state.last.error)
    return false
  end
  run.process = process
  run.timer = vim.defer_fn(function()
    if not run.finished then
      run.timed_out = true
      stop(run)
    end
  end, config.timeout_ms)
  return true
end

local function invalidate(bufnr)
  local filename = api.nvim_buf_get_name(bufnr)
  local changed = false
  for owner, state in pairs(states) do
    local dependent = false
    for _, record in ipairs(state.records or {}) do
      dependent = dependent or record.filename == filename
    end
    if owner == bufnr or dependent then
      cancel(state)
      changed = changed or state.records ~= nil
      state.records = nil
    end
  end
  if changed then publish() end
end

function M.disable()
  enabled = false
  if group then api.nvim_del_augroup_by_id(group); group = nil end
  for _, state in pairs(states) do cancel(state); state.records = nil end
  vim.diagnostic.reset(namespace)
  published = {}
  if qfid and vim.fn.getqflist({ id = qfid }).id == qfid then update_quickfix({}, false) end
end

function M.enable()
  M.disable()
  enabled = true
  group = api.nvim_create_augroup('CadenceChecks', { clear = true })
  if config.on_save then
    api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(event) M.check(event.buf) end })
  end
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufFilePost' }, {
    group = group, callback = function(event) invalidate(event.buf) end,
  })
  api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = group, callback = function(event)
      invalidate(event.buf)
      states[event.buf] = nil
    end,
  })
end

function M.setup(opts)
  M.disable()
  config = vim.tbl_extend('force', vim.deepcopy(defaults), opts or {})
  vim.validate('command', config.command, 'string')
  vim.validate('timeout_ms', config.timeout_ms, 'number')
  assert(config.timeout_ms > 0, 'timeout_ms must be positive')
  for _, key in ipairs({ 'filetypes', 'include_dirs' }) do vim.validate(key, config[key], 'table') end
  assert(type(config.args) == 'table' or type(config.args) == 'function', 'args must be an array or function')
  warnings = {}
  api.nvim_create_autocmd('VimLeavePre', {
    group = api.nvim_create_augroup('CadenceCleanup', { clear = true }),
    callback = function()
      for run in pairs(active_runs) do
        kill(run, 9)
        vim.fn.delete(run.scratch, 'rf')
      end
    end,
  })
  if config.enabled then M.enable() end
end

function M.status(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  local state = states[bufnr] or {}
  return vim.deepcopy({ enabled = enabled, running = state.run ~= nil,
    executable = vim.fn.executable(config.command) == 1, last = state.last,
    namespace = namespace, quickfix_id = qfid })
end

function M.quickfix()
  local _, items = quickfix_items()
  update_quickfix(items, true)
  vim.cmd.copen()
end

return M

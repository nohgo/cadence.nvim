vim.opt.runtimepath:prepend(vim.fn.getcwd())
local cadence = require('cadence')
local parser = require('cadence.parser')
local api = vim.api
local root = vim.fn.getcwd()
local work = root .. '/.test-work/run-' .. vim.fn.getpid()
vim.fn.mkdir(work, 'p')
local trace = work .. '/trace.jsonl'
vim.fn.delete(trace)
local tests, notices = 0, {}
vim.notify = function(message) notices[#notices + 1] = message end

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'Expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end

local function wait_for(predicate, message)
  assert(vim.wait(4000, predicate, 10), message or 'Timed out waiting for test condition')
end

local function invocations()
  local result = {}
  if vim.fn.filereadable(trace) == 1 then
    for _, line in ipairs(vim.fn.readfile(trace)) do result[#result + 1] = vim.json.decode(line) end
  end
  return result
end

local function options(extra)
  return vim.tbl_extend('force', {
    command = root .. '/tests/fake-xmvlog',
    args = { '-ams', '--trace', trace }, timeout_ms = 2000,
  }, extra or {})
end

local function reset(extra)
  cadence.disable()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  end
  notices = {}
  cadence.setup(options(extra))
end

local count = 0
local function buffer(mode, save)
  count = count + 1
  vim.cmd.enew()
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_name(buf, work .. '/model with spaces ' .. count .. '.va')
  vim.bo[buf].filetype = 'verilogams'
  api.nvim_buf_set_lines(buf, 0, -1, false, { '// mode=' .. mode, 'module sample;', 'endmodule' })
  if save ~= false then vim.cmd('silent write') end
  return buf
end

local function done(buf)
  wait_for(function() return not cadence.status(buf).running end, 'Compiler did not finish')
  -- Observe any callbacks from cancelled, older jobs too.
  vim.wait(20, function() return false end)
end

local function diagnostics(buf)
  return vim.diagnostic.get(buf, { namespace = cadence.status().namespace })
end

local function items()
  local id = cadence.status().quickfix_id
  return id and vim.fn.getqflist({ id = id, items = 1 }).items or {}
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ': ' .. tostring(err)) end
  tests = tests + 1
  print('PASS ' .. name)
end

test('Cadence diagnostic formats, coordinates, continuations, and severities', function()
  local records = parser.parse(table.concat(vim.fn.readfile('tests/fixtures/messages.log'), '\n'), '/project')
  eq(8, #records)
  eq('/project/src/resistor.va', records[1].filename)
  eq(6, records[1].lnum)
  eq(20, records[1].col)
  eq('Missing statement terminator.\nAdd a terminator before the following declaration.', records[1].message)
  eq(0, records[2].col)
  assert(records[2].message:find('include file:', 1, true))
  eq(3, records[3].lnum)
  eq(0, records[3].col)
  eq(nil, records[4].filename)
  eq('xrun', records[5].tool)
  eq(vim.diagnostic.severity.ERROR, records[6].severity)
  eq(vim.diagnostic.severity.INFO, records[7].severity)
  eq(vim.diagnostic.severity.INFO, records[8].severity)
  local ansi = parser.parse('\27[31mxmvlog: *E,CODE ("/a,b (c)/x.va",1|0): ANSI test.\27[0m\r\n', '/tmp')
  eq('/a,b (c)/x.va', ansi[1].filename)
  eq('ANSI test.', ansi[1].message)
  eq(0, #parser.parse('not a Cadence diagnostic', '/tmp'))
end)

test('real save triggers async compile, diagnostics, quickfix, private artifacts', function()
  reset({ include_dirs = { 'headers' }, root_dir = work })
  local buf = buffer('errors')
  assert(cadence.status(buf).running)
  done(buf)
  local ds = diagnostics(buf)
  eq(1, #ds) -- stdout/log duplication is removed.
  eq(1, ds[1].lnum)
  eq(2, ds[1].col)
  eq('TESTERR', ds[1].code)
  local qf = items()
  eq(1, #qf)
  eq(2, qf[1].lnum)
  eq(3, qf[1].col)
  eq('E', qf[1].type)
  local last = cadence.status(buf).last
  assert(vim.fn.filereadable(last.log) == 1)
  eq(0, vim.fn.isdirectory(last.cwd))
  assert(vim.tbl_contains(last.command, work .. '/headers'))
  eq(0, vim.fn.filereadable(work .. '/cds.lib'))
  eq(0, vim.fn.isdirectory(work .. '/worklib'))
  eq(0, vim.fn.getqflist({ winid = 0 }).winid)
  local first = invocations()[#invocations()]
  eq(last.cwd, first.cwd)
end)

test('successful save clears old results and preserves other diagnostic namespaces', function()
  reset()
  local buf = buffer('errors')
  done(buf)
  local other = api.nvim_create_namespace('another-linter')
  vim.diagnostic.set(other, buf, { { lnum = 0, col = 0, message = 'keep this' } })
  api.nvim_buf_set_lines(buf, 0, 1, false, { '// mode=clean' })
  vim.cmd('silent write')
  done(buf)
  eq(0, #diagnostics(buf))
  eq(0, #items())
  eq(1, #vim.diagnostic.get(buf, { namespace = other }))
end)

test('stderr-only, log-only, and zero-exit warning outputs', function()
  for _, mode in ipairs({ 'stderr', 'logonly', 'warning' }) do
    reset()
    local buf = buffer(mode)
    done(buf)
    eq(1, #diagnostics(buf))
    eq(mode == 'warning' and 'W' or 'E', items()[1].type)
  end
end)

test('included-file diagnostics and dependent edits', function()
  local header = work .. '/test header.vah'
  vim.fn.writefile({ '// header', 'bad declaration' }, header)
  reset({ args = { '-ams', '--trace', trace, '--header', header } })
  local header_buf = vim.fn.bufadd(header)
  vim.fn.bufload(header_buf)
  local buf = buffer('include')
  done(buf)
  eq(0, #diagnostics(buf))
  eq(1, #diagnostics(header_buf))
  eq(header_buf, items()[1].bufnr)
  api.nvim_buf_set_lines(header_buf, 0, 1, false, { '// edited header' })
  api.nvim_exec_autocmds('TextChanged', { buffer = header_buf })
  eq(0, #diagnostics(header_buf))
  eq(0, #items())
end)

test('included-file edits during compilation discard stale diagnostics', function()
  local header = work .. '/stale.vah'
  vim.fn.writefile({ '// header', 'bad declaration' }, header)
  reset({ args = { '-ams', '--trace', trace, '--header', header } })
  local hb = vim.fn.bufadd(header)
  vim.fn.bufload(hb)
  local buf = buffer('include delay=150')
  api.nvim_buf_set_lines(hb, 0, 1, false, { '// edited' })
  done(buf)
  eq(0, #diagnostics(hb))
  eq(0, #items())
  eq(true, cadence.status(buf).last.stale)
end)

test('relative locations resolve against actual compiler cwd', function()
  reset()
  local buf = buffer('relative')
  done(buf)
  local filename = api.nvim_buf_get_name(items()[1].bufnr)
  eq(cadence.status(buf).last.cwd .. '/relative.vah', filename)
end)

test('global license errors remain non-jumpable and unlocated', function()
  reset()
  local buf = buffer('global')
  done(buf)
  eq(0, #diagnostics(buf))
  eq(1, #items())
  eq(0, items()[1].valid)
  assert(items()[1].text:find('NOLICN', 1, true))
end)

test('unrecognized failure remains visible with retained raw output', function()
  reset()
  local buf = buffer('unknown')
  done(buf)
  eq(0, #diagnostics(buf))
  assert(items()[1].text:find('[PROCESS]', 1, true))
  local log = table.concat(vim.fn.readfile(cadence.status(buf).last.log), '\n')
  assert(log:find('shared library', 1, true))
  eq(1, #notices)
end)

test('missing compiler degrades gracefully and warns once', function()
  reset({ command = work .. '/nonexistent-xmvlog' })
  local count_before = #invocations()
  local buf = buffer('errors')
  eq(false, cadence.status(buf).running)
  vim.cmd('silent write')
  eq(1, #notices)
  eq(count_before, #invocations())
  eq(false, cadence.status(buf).executable)
end)

test('overlapping saves cancel older results', function()
  reset()
  local previous = #invocations()
  local buf = buffer('errors delay=500')
  wait_for(function() return #invocations() > previous end)
  local old_cwd = invocations()[#invocations()].cwd
  api.nvim_buf_set_lines(buf, 0, 1, false, { '// mode=clean' })
  vim.cmd('silent write')
  done(buf)
  wait_for(function() return vim.fn.isdirectory(old_cwd) == 0 end)
  eq(0, #diagnostics(buf))
  eq(0, #items())
end)

test('unsaved edits discard late results even without TextChanged event', function()
  reset()
  local buf = buffer('errors delay=150')
  api.nvim_buf_set_lines(buf, 0, 1, false, { '// edited, not saved' })
  done(buf)
  eq(0, #diagnostics(buf))
  eq(0, #items())
end)

test('renames and closed buffers reject in-flight results', function()
  for _, action in ipairs({ 'rename', 'delete' }) do
    reset()
    local previous = #invocations()
    local buf = buffer('errors delay=150')
    wait_for(function() return #invocations() > previous end)
    local scratch = invocations()[#invocations()].cwd
    if action == 'rename' then
      api.nvim_buf_set_name(buf, work .. '/renamed.va')
    else
      api.nvim_buf_delete(buf, { force = true })
    end
    wait_for(function() return vim.fn.isdirectory(scratch) == 0 end)
    eq(0, #items())
  end
end)

test('timeout escalates to kill and cleans scratch files', function()
  reset({ timeout_ms = 150 })
  local buf = buffer('timeout delay=10000')
  done(buf)
  local last = cadence.status(buf).last
  eq(true, last.timed_out)
  eq(0, vim.fn.isdirectory(last.cwd))
  assert(items()[1].text:find('[TIMEOUT]', 1, true))
end)

test('disable cancels process groups including compiler children', function()
  reset()
  local before = #invocations()
  local buf = buffer('child delay=10000')
  wait_for(function() return #invocations() > before end)
  local cwd = invocations()[#invocations()].cwd
  vim.wait(100, function() return false end)
  cadence.disable()
  wait_for(function() return vim.fn.isdirectory(cwd) == 0 end)
  eq(false, cadence.status(buf).enabled)
  eq(false, cadence.status(buf).running)
  eq(0, #diagnostics(buf))
  eq(0, #items())
  local after = #invocations()
  vim.cmd('silent write')
  eq(after, #invocations())
end)

test('disabled setup, manual checks, and filetype scoping', function()
  reset({ enabled = false })
  local before = #invocations()
  local buf = buffer('errors')
  eq(before, #invocations())
  eq(false, cadence.check(buf))
  cadence.setup(options({ on_save = false }))
  vim.cmd('silent write')
  eq(before, #invocations())
  eq(true, cadence.check(buf))
  done(buf)
  eq(1, #diagnostics(buf))
  vim.bo[buf].filetype = 'text'
  eq(false, cadence.check(buf))
end)

test('quickfix updates preserve another tool current list and open on request', function()
  reset()
  local a = buffer('errors')
  done(a)
  local cadence_id = cadence.status().quickfix_id
  vim.fn.setqflist({}, ' ', { title = 'Other tool', items = { { text = 'Keep me', valid = 0 } } })
  local other_id = vim.fn.getqflist({ id = 0 }).id
  local b = buffer('warning')
  done(b)
  eq(other_id, vim.fn.getqflist({ id = 0 }).id)
  eq(2, #vim.fn.getqflist({ id = cadence_id, items = 1 }).items)
  eq('Keep me', vim.fn.getqflist()[1].text)
  cadence.quickfix()
  assert(vim.fn.getqflist({ winid = 0 }).winid ~= 0)
  eq(2, #vim.fn.getqflist())
  vim.cmd.cclose()
  cadence.disable()
  eq('Keep me', vim.fn.getqflist({ id = other_id, items = 1 }).items[1].text)
end)

test('optional automatic quickfix window and diagnostics-only mode', function()
  reset({ open_quickfix = true })
  local buf = buffer('errors')
  done(buf)
  assert(vim.fn.getqflist({ winid = 0 }).winid ~= 0)
  vim.cmd.cclose()
  reset({ quickfix = false })
  local id = vim.fn.getqflist({ id = 0 }).id
  local before = vim.fn.getqflist()
  buf = buffer('errors')
  done(buf)
  eq(1, #diagnostics(buf))
  eq(id, vim.fn.getqflist({ id = 0 }).id)
  eq(before, vim.fn.getqflist())
end)

test('explicit cds.lib, argument callbacks, and configuration errors', function()
  local mapping = work .. '/project cds.lib'
  vim.fn.writefile({ '// site mappings' }, mapping)
  local captured
  reset({ cds_lib = mapping, args = function(ctx)
    captured = ctx
    local lines = vim.fn.readfile(ctx.scratch .. '/cds.lib')
    eq('INCLUDE ' .. string.format('%q', mapping), lines[1])
    eq('UNDEFINE worklib', lines[2])
    return { '-ams', '--trace', trace }
  end })
  local buf = buffer('clean')
  done(buf)
  eq(api.nvim_buf_get_name(buf), captured.filename)
  reset({ args = function() error('synthetic configuration error') end })
  buf = buffer('clean')
  eq(false, cadence.status(buf).running)
  assert(cadence.status(buf).last.error:find('synthetic configuration error', 1, true))
end)

cadence.disable()
print(string.format('All %d tests passed', tests))
vim.cmd('qa!')

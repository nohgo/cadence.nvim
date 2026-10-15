local M = {}
local severity = vim.diagnostic.severity
local severities = {
  F = severity.ERROR, E = severity.ERROR, SE = severity.ERROR,
  W = severity.WARN, N = severity.INFO, I = severity.INFO, Q = severity.INFO,
}
local tools = { xmvlog = true, xmvlog_p = true, ncvlog = true, ncvlog_p = true,
  xrun = true, irun = true, xmelab = true, ncelab = true }

local function clean(line)
  return (line:gsub('\27%[[%d;]*[A-Za-z]', ''):gsub('\r$', ''))
end

local function marker(line)
  return line:match('^%s*[|%^~]+%s*$') ~= nil
end

-- Keep filenames separate from diagnostics: parsing does not create/load buffers.
function M.parse(output, cwd)
  local records, active = {}, nil
  local lines = vim.split(output, '\n', { plain = true })
  for i, raw in ipairs(lines) do
    local line = clean(raw)
    local tool, level, code, tail = line:match('^%s*([%w_]+)%s*:%s*%*([A-Z]+),([%w_]+)%s*(.*)$')
    if not tool then
      tool, level, code, tail = line:match('^%s*([%w_]+)%(%d+%)%s*:%s*%*([A-Z]+),([%w_]+)%s*(.*)$')
    end
    if tools[tool] and severities[level] then
      local location, message = tail:match('^%((.*)%)%s*:%s*(.*)$')
      local filename, row, column
      if location then
        filename, row, column = location:match('^(.*),%s*(%d+)%s*|%s*(%d+)%s*$')
        if not filename then
          filename, row = location:match('^(.*),%s*(%d+)%s*$')
        end
      end
      if not row then
        message = tail:gsub('^:%s*', '')
      end
      local record = {
        tool = tool, code = code, level = level,
        severity = severities[level], message = message,
      }
      if filename then
        filename = vim.trim(filename):gsub('^"(.*)"$', '%1')
        record.filename = vim.fs.normalize(vim.fn.fnamemodify(
          filename:sub(1, 1) == '/' and filename or cwd .. '/' .. filename, ':p'))
        record.lnum = math.max(tonumber(row) - 1, 0)
        record.col = math.max((tonumber(column) or 1) - 1, 0)
      end
      records[#records + 1] = record
      active = record
    elseif active then
      local next_line = clean(lines[i + 1] or '')
      local noise = line == '' or marker(line) or marker(next_line)
        or line:match('^%s*file:') or line:match('^%s*module%s')
        or line:match('^%s*errors:') or line:match('^%s*TOOL:')
        or line:match('^%s*Total errors') or line:match('^%s*[nx][cm]%w*%s*:')
      if not noise and (line:match('^%s+%S') or line:match('^%(`?include file:')) then
        active.message = active.message .. '\n' .. vim.trim(line)
      else
        active = nil
      end
    end
  end
  return records
end

return M

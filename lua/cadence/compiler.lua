local M = {}

function M.absolute(path, root)
  path = vim.fn.expand(path)
  if path:sub(1, 1) ~= '/' then
    path = root .. '/' .. path
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

function M.prepare(opts, bufnr)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local source_dir = vim.fs.dirname(filename)
  local root = type(opts.root_dir) == 'function' and opts.root_dir(bufnr) or opts.root_dir
  root = M.absolute(root or source_dir, vim.fn.getcwd())
  local scratch = vim.fn.tempname()
  local ctx = { filename = filename, root = root, scratch = scratch, bufnr = bufnr }
  -- Assign before evaluating configuration, so callers can clean up failures.
  local ok, result = pcall(function()
    vim.fn.mkdir(scratch .. '/worklib', 'p', 448)
    scratch = vim.uv.fs_realpath(scratch) or scratch
    ctx.scratch = scratch
    local mappings = {}
    if opts.cds_lib then
      local library_file = M.absolute(opts.cds_lib, root)
      assert(not library_file:find('[\r\n]'), 'cds_lib must be a single-line path')
      mappings[#mappings + 1] = 'INCLUDE ' .. string.format('%q', library_file)
      mappings[#mappings + 1] = 'UNDEFINE worklib'
    end
    mappings[#mappings + 1] = 'DEFINE worklib ./worklib'
    assert(vim.fn.writefile(mappings, scratch .. '/cds.lib') == 0, 'cannot write cds.lib')
    assert(vim.fn.writefile({ 'DEFINE WORK worklib' }, scratch .. '/hdl.var') == 0, 'cannot write hdl.var')
    local args = type(opts.args) == 'function' and opts.args(ctx) or opts.args
    assert(type(args) == 'table', 'args must return an argument array')
    local argv = { opts.command }
    for _, arg in ipairs(args) do
      assert(type(arg) == 'string', 'compiler arguments must be strings')
      argv[#argv + 1] = arg
    end
    vim.list_extend(argv, {
      '-work', 'worklib', '-cdslib', scratch .. '/cds.lib',
      '-hdlvar', scratch .. '/hdl.var', '-logfile', scratch .. '/xmvlog.log',
    })
    local directories = { source_dir, root }
    vim.list_extend(directories, opts.include_dirs)
    local seen = {}
    for _, dir in ipairs(directories) do
      dir = M.absolute(dir, root)
      if not seen[dir] then
        vim.list_extend(argv, { '-incdir', dir })
        seen[dir] = true
      end
    end
    argv[#argv + 1] = filename
    ctx.argv = argv
    return ctx
  end)
  if not ok then
    vim.fn.delete(scratch, 'rf')
    error(result)
  end
  return result
end

return M

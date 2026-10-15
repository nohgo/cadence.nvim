# cadence.nvim

Check saved Verilog-A/AMS files with Cadence's `xmvlog -ams`, asynchronously.
Compiler errors and warnings appear as native Neovim diagnostics and in a
dedicated quickfix error list. The initial scope is compiler checking on save;
the Lua modules leave room for future Cadence workflow tools.

No Lua dependencies, build step, `nvim-lint`, or personal dotfile scripts are
required. Neovim **0.11+**, a POSIX host, and a working licensed Xcelium environment
are required for real checks. The offline grammar and formatter work separately.

## Install from GitHub

Add this specification to your `lazy.nvim` plugins:

```lua
return {
  'nohgo/cadence.nvim',
  branch = 'main',
  version = false,
  enabled = vim.g.enable_cadence ~= false,
  ft = { 'verilogams' },
  main = 'cadence',
  opts = {
    command = 'xmvlog',
    args = { '-ams' },
    timeout_ms = 10000,
    -- Add the directories containing your site's standard AMS/PDK headers:
    -- include_dirs = { '/path/to/ams/headers', '/path/to/project/include' },
  },
}
```

Run `:Lazy sync` and restart Neovim. No local workspace path is needed. This
example assumes the repository has been published as `nohgo/cadence.nvim`.

The [Verilog-AMS grammar plugin](https://github.com/nohgo/tree-sitter-verilog-ams#neovim-install-from-github)
already assigns the `verilogams` filetype to `.va`, `.vams`, and `.vah`. Without
that plugin, register it before Lazy setup:

```lua
vim.filetype.add({ extension = { va = 'verilogams', vams = 'verilogams', vah = 'verilogams' } })
```

Other plugin managers can install the same GitHub repository; call
`require('cadence').setup({})` after it is available on `runtimepath`.

## Cadence environment

Start Neovim from the shell in which your site's Cadence environment is loaded.
Check in that shell:

```sh
command -v xmvlog
xmvlog -version
xmvlog -help
```

The plugin inherits your environment, including license configuration. An
executable on `$PATH` does not establish that a license can be checked out.
Missing tools skip checks and issue one notice per setup; PATH can be corrected
without reinstalling the plugin. No remote execution or tool installation is
performed. Use your normal Cadence Linux host for licensed checks.

Set `vim.g.enable_cadence = false` **before Lazy setup** to disable it on another
machine. During a session:

```lua
require('cadence').disable()
require('cadence').enable()
```

Disabling cancels active jobs, removes save triggers, and clears this plugin's
diagnostics and quickfix entries.

## On-save workflow and error window

Open a model, check `:set filetype?`, then save with `:write`. Compilation starts
after the save, so it includes format-on-save changes from Conform. Results refer
to saved source; typing does not continuously invoke Cadence.

- Inline diagnostics use Neovim's existing diagnostic display settings. Use
  `:lua vim.diagnostic.open_float()` for the full message under the cursor.
- Open the Cadence error window with
  `:lua require('cadence').quickfix()`. Use `:cnext`, `:cprevious`, or Enter in
  that window to jump to a located error. `:copen` also works when Cadence's list
  is the current quickfix list.
- Included-file errors point into the included file. Messages without a source
  location, such as license failures, remain non-jumpable quickfix entries.
- Fix the code and save again to replace its results. A successful check clears
  its old entries. Older jobs and results invalidated by edits are discarded.

The plugin creates a dedicated quickfix list and updates it by ID. Existing
lists stay in quickfix history, and later updates do not replace another tool's
current list. The window stays closed by default; set `open_quickfix = true` to
open it when results contain messages. Set `quickfix = false` for native
diagnostics only; the explicit `quickfix()` function remains available.

## Project configuration

The compiler runs in a fresh scratch directory with a private `worklib`,
`cds.lib`, `hdl.var`, and log. The saved file is passed by absolute path. Its
directory and `root_dir` are added as include directories; `root_dir` defaults to
the saved file's directory. Other relative include directories resolve against
that root:

```lua
opts = {
  root_dir = function(bufnr)
    return vim.fs.root(bufnr, { '.git' })
      or vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
  end,
  include_dirs = { 'include', '/path/to/site/ams/headers' },
  args = { '-ams', '-64bit', '+define+MY_MODEL_CHECK=1' },
  -- Optional: explicitly import existing library mappings.
  -- cds_lib = '/path/to/project/cds.lib',
}
```

The plugin does not automatically load a project's `cds.lib` or `hdl.var`.
Explicit `cds_lib` imports mappings and redirects the default `worklib` to
scratch. Site-specific HDL options belong in `args`; source directives that
select other mapped libraries still follow Cadence's normal library rules.

`args` replaces the default `{ '-ams' }`, so retain `-ams`. It can also be a
function accepting `{ filename, root, scratch, bufnr }` and returning an argument
array. Raw argument paths, including paths inside file lists, must be absolute:
the process working directory is scratch. The plugin appends its private-library,
log, include, and source arguments. `command` can be an absolute executable path
or a wrapper that preserves the `xmvlog` argument contract. It is not a shell
command string. There is no automatic `xrun` fallback.

Full defaults also include `enabled = true`, `on_save = true`, and
`filetypes = { 'verilogams' }`. Set `on_save = false` to check only through
`require('cadence').check()`; manual checks require an unmodified, saved buffer.
Headers are checked as standalone input when saved, so non-standalone headers
may need checking through their containing model instead.

## Troubleshooting and licensed-host smoke test

Inspect executable discovery, the latest command, exit status, and log path:

```vim
:echo executable('xmvlog')
:lua vim.print(require('cadence').status())
```

The latest completed output for each source is retained under
`stdpath('cache') .. '/cadence/'`; inspect the `last.log` path with `:edit`.
Scratch compilation databases are removed after each check. Timeouts and
unrecognized process failures enter quickfix with a log reference. A recognized
global compiler error is already preserved as its own quickfix entry.

On a licensed machine, open [examples/resistor.va](examples/resistor.va), save,
and wait until `status().running` is false. Resolve header, installation, or
license errors first. The valid model should compile without errors. Remove the
semicolon after the contribution, save, and open the Cadence quickfix list:
expect a located compiler error. Restore it and save to clear that error. Repeat
with a deliberate undeclared name to exercise a compiler semantic check.
Record `xmvlog -version` and any required options when reporting a problem.

**Real Cadence execution has not been verified on the development machine**:
neither `xmvlog` nor `xrun` is installed. The command and parser are based on
vendor documentation and public Cadence examples; see
[research and sources](docs/RESEARCH.md). This checks compilation, not complete
project elaboration, transient behavior, convergence, or hidden states. Missing
dependencies and simulator-version differences can require project configuration.

## Development

```sh
make test
```

Requires Neovim 0.11+ and Python 3 for the fake compiler only. Headless tests use
isolated state/cache directories and never load or change personal Neovim
configuration. They cover diagnostic formats, async saves, quickfix ownership,
included files, stale jobs, cleanup, timeouts, missing tools, and failures.
CI runs on Linux with Neovim 0.11.5 and 0.12.5; no licensed tests run in CI.

The runtime modules live in `lua/cadence/`. Keep compiler argument construction,
message parsing, and editor integration separate; see
[architecture](docs/ARCHITECTURE.md). Add a sanitized fixture and regression test
when extending a diagnostic format. Use two-space Lua indentation and
`snake_case` names. No simulation commands or broader workflow menus are included
in this initial version.

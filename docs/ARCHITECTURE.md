# Architecture

## Scope

One optional Lua plugin checks saved Verilog-A/AMS files with `xmvlog -ams`.
Neovim 0.11+ supplies asynchronous processes, diagnostics, and quickfix; there are
no plugin dependencies. No simulation, elaboration, formatting, or netlisting is
performed. Cadence syntax and static semantic checks complement the offline
grammar; convergence and hidden-state analysis are outside this scope.

## Modules and flow

- `cadence/init.lua`: setup, save events, job lifecycle, stale-result checks,
  diagnostic publication, and the Cadence-owned quickfix list.
- `cadence/compiler.lua`: build an argument array and isolated work directory.
- `cadence/parser.lua`: independently parse compiler messages into records.

`BufWritePost` captures the filename and buffer revision, cancels the previous
check for that buffer, and starts an asynchronous compiler process. Completion
is scheduled onto Neovim's main loop. Results are discarded after edits, renames,
buffer closure, another save, or disablement. Included-file locations are resolved
against the actual compiler working directory and checked against loaded buffer
revisions. Results from separate source buffers are combined and deduplicated.

## Compiler isolation

Each invocation runs in its own temporary directory with a private `worklib`,
`cds.lib`, `hdl.var`, and log. Source paths and configured include directories are
absolute. The source directory and configured project root are added to include
search paths. Raw extra arguments must use absolute paths, because the compiler
does not run in the project directory. Optional external `cds.lib` mappings are
explicitly included, with `worklib` redirected back to scratch storage.

Only the latest completed log per source filename is retained, under Neovim's
cache directory; scratch libraries are removed on completion. Timeout,
cancellation, disablement, and editor exit terminate active processes. Compiler
availability is checked before creating scratch files. No shell command string,
automatic project script, or personal editor configuration is involved.

## Editor presentation

Located messages become native diagnostics, including included files. Errors and
warnings also enter a dedicated quickfix list; messages without locations stay
non-jumpable list entries instead of inventing a source position. Compiler failure
without a recognized error produces an explicit infrastructure failure entry.
The list is updated by ID, preserving unrelated lists; opening it is opt-in.

## Verification

Headless tests parse sanitized synthetic logs and execute a fake compiler through
the real asynchronous save path. They cover coordinates, severities, continuation
lines, relative paths, included files, missing tools/licenses, timeout, edits,
overlapping saves, disablement, cleanup, and quickfix ownership. A real licensed
Xcelium smoke test remains a separate acceptance step; see `RESEARCH.md`.

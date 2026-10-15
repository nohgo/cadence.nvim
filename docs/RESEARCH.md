# Cadence command and diagnostic research

## Selected check

Use the standalone Verilog compiler, `xmvlog -ams`, rather than launching an AMS
simulation. It performs compilation, including syntax and static semantic checks;
it is not a universal analog lint or convergence analysis command. The private
library setup uses `-work`, `-cdslib`, `-hdlvar`, and `-logfile`:

```text
xmvlog -ams -work worklib -cdslib <scratch>/cds.lib
  -hdlvar <scratch>/hdl.var -logfile <scratch>/xmvlog.log
  -incdir <source-directory> -incdir <project-root> <absolute-source.va>
```

The argument array is passed directly to `vim.system`, without a shell. Relative
paths in compiler diagnostics refer to scratch, its actual working directory.
Includes and additional file paths should be absolute. No undocumented
`-syntax`/`-parse` option is assumed. There is no automatic fallback to `xrun`,
which has a different driver and output-directory contract.

## Primary references

- [Cadence: Xcelium message troubleshooting](https://community.cadence.com/cadence_blogs_8/b/fv/posts/troubleshooting-xcelium-errors-warnings-with-xmhelp-xmbrowse-and-cadence-support-portal)
  explains the tool/severity/mnemonic structure and `xmhelp <tool> <code>`.
- [Cadence: a located xmvlog diagnostic](https://community.cadence.com/cadence_technology_forums/f/functional-verification/46950/xmvlog-e-nopbind-src-soc_tb_top-sv-46-20-package-soc_test_pkg-could-not-be-bound)
  shows `tool: *E,CODE (filename,line|column): message` and source/caret echoes.
- [Cadence: an AMS error without a column](https://community.cadence.com/cadence_technology_forums/f/custom-ic-design/47572/compilation-error-of-verilogams----ncvlog-f-dlcsyn-syntax-error-define-ncsimrc)
  shows the older `ncvlog` prefix and `(filename,line)` configuration errors.
- [Cadence: a message without a source location](https://community.cadence.com/cadence_technology_forums/f/functional-verification/40117/dlcsmd-errors)
  illustrates why global failures must not be discarded.
- [Microchip's Xcelium integration guide](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/UserGuides/libero-soc-simulation-library-setup-instructions.pdf),
  section 4.3, documents `xmvlog` library/configuration/log arguments. This is
  vendor-authored integration documentation, not evidence of an AMS test here.
- [Cadence AMS Simulator User Guide](https://picture.iczhiku.com/resource/eetop/sHKyelZiJElAkmnV.pdf),
  "Compiling", documents the predecessor `ncvlog -ams` and its compile-only
  responsibilities. This is an older Cadence-authored manual hosted on a mirror;
  consult installed Xcelium documentation for the current release.
- [Cadence's June 2025 mixed-signal user guide](https://www.disu.ac.kr/LOCnLOS/AIX/notice?bbsidx=8318&fileidx=9548&md=down),
  page 164, has an `xmvlog -ams` compilation example. This Cadence-authored
  manual is hosted on an academic mirror and was available through indexed text.
- [Cadence: current Xcelium environment requirements](https://community.cadence.com/cadence_technology_forums/f/custom-ic-design/63287/verilog-ams-simulation-error/1402994)
  discusses locating `xmvlog`/`xrun` through the installed tools directory.

The parser accepts `F`, `E`, `SE`, `W`, `N`, `I`, and `Q`, and common
`xmvlog`/`ncvlog`/driver prefixes, including `(64)` suffixes. `F`, `E`, and `SE`
map to errors; `W` to warnings; other supported severities to informational
diagnostics. Cadence's usual coordinates are one-based; zero columns are clamped
to the first column. Indented continuations and include context are retained;
source echoes followed by caret markers are excluded. Fixtures are synthetic,
not proprietary simulator logs.

## Verification boundary

Neither `xmvlog` nor `xrun` is installed on the development machine. The plugin's
process, parser, and Neovim integration are tested offline, but the exact command
and AMS licensing have not been exercised against a licensed Cadence release.
Before relying on results, run the README's licensed-host smoke test. Required
standard AMS headers, PDK includes, macros, library mappings, and tool options
depend on the site's installation. A single-file compilation cannot replace a
complete project's elaboration or simulation.

NVIM ?= nvim

.PHONY: test
test:
	XDG_STATE_HOME="$(CURDIR)/.test-work/state" XDG_CACHE_HOME="$(CURDIR)/.test-work/cache" NVIM_LOG_FILE="$(CURDIR)/.test-work/nvim.log" $(NVIM) --headless -u NONE -i NONE -l tests/run.lua

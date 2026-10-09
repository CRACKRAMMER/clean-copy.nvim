#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .test/xdg/config .test/xdg/data .test/xdg/state .test/xdg/cache
export XDG_CONFIG_HOME="$PWD/.test/xdg/config"
export XDG_DATA_HOME="$PWD/.test/xdg/data"
export XDG_STATE_HOME="$PWD/.test/xdg/state"
export XDG_CACHE_HOME="$PWD/.test/xdg/cache"
export NVIM_LOG_FILE="$PWD/.test/nvim.log"
mode="${1:-all}"
case "$mode" in
  all|unit|integration) ;;
  *) echo "usage: tests/run.sh [all|unit|integration]" >&2; exit 2 ;;
esac
if [ "$mode" != integration ]; then
  python3 tests/test_install_parsers.py
  nvim --clean --headless -l tests/unit.lua
  nvim --clean --headless -l tests/parser_install.lua
  if [ -n "${CLEAN_COPY_TS_PATH:-}" ]; then
    nvim --clean --headless -l tests/parser_tasks.lua
  fi
  for scenario in require plugin conflict lazy lazy-visual legacy legacy-conflict ownership; do
    CLEAN_COPY_TEST_SCENARIO="$scenario" nvim --clean --headless -l tests/lifecycle.lua
  done
  # -l runs before startup completes and suppresses OptionSet. A scheduled command
  # observes the same option events that a normal user session would receive.
  nvim --clean --headless -c 'lua vim.schedule(function() local ok, err = pcall(dofile, "tests/events.lua"); if not ok then print(err); vim.cmd("cquit 1") end end)'
  nvim --clean --headless -l tests/docs.lua
fi
if [ "$mode" = unit ]; then exit 0; fi
# Check the project runtime before integration tests, so missing dependencies produce
# one actionable failure instead of dozens of misleading regression failures.
nvim --clean --headless -l tests/check_parsers.lua
nvim --clean --headless -l tests/run.lua
mkdir -p .test/missing-runtime/parser
for lang in html vue php; do
  ln -sf "$PWD/.test/runtime/parser/$lang.so" ".test/missing-runtime/parser/$lang.so"
done
exec nvim --clean --headless -l tests/missing_parsers.lua

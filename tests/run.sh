#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .test/xdg/config .test/xdg/data .test/xdg/state .test/xdg/cache
export XDG_CONFIG_HOME="$PWD/.test/xdg/config"
export XDG_DATA_HOME="$PWD/.test/xdg/data"
export XDG_STATE_HOME="$PWD/.test/xdg/state"
export XDG_CACHE_HOME="$PWD/.test/xdg/cache"
nvim --clean --headless -l tests/run.lua
mkdir -p .test/missing-runtime/parser
for lang in html vue php; do
  ln -sf "$PWD/.test/runtime/parser/$lang.so" ".test/missing-runtime/parser/$lang.so"
done
exec nvim --clean --headless -l tests/missing_parsers.lua

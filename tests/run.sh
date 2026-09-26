#!/usr/bin/env bash
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

exec nvim --headless -u tests/minimal_init.lua \
  -c "lua dofile('tests/setup_spec.lua')" \
  -c "qa!"

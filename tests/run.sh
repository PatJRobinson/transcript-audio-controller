#!/usr/bin/env bash
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

nvim --headless -u tests/minimal_init.lua \
  -c "lua dofile('tests/setup_spec.lua')" \
  -c "qa!"

nvim --headless -u tests/minimal_init.lua \
  -c "lua dofile('tests/actions_spec.lua')" \
  -c "qa!"

nvim --headless -u tests/minimal_init.lua \
  -c "lua dofile('tests/notation_spec.lua')" \
  -c "qa!"

test_dir=$(mktemp -d)
test_socket="$test_dir/mpv.sock"
server_pid=

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT INT TERM

FAKE_MPV_CONNECTIONS=30 python3 tests/fake_mpv.py "$test_socket" &
server_pid=$!

attempt=0
while [ ! -S "$test_socket" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    echo "fake mpv server did not create its socket" >&2
    exit 1
  fi
  sleep 0.01
done

TRANSCRIPT_AUDIO_TEST_SOCKET="$test_socket" \
  nvim --headless -u tests/minimal_init.lua \
  -c "lua dofile('tests/ipc_spec.lua')"

wait "$server_pid"
server_pid=

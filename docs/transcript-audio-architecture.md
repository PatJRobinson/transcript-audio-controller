# Transcript Audio Controller — Architecture & Implementation Plan

**Status:** Implementation brief / MVP specification  
**Target:** NixOS (Linux), Neovim, SSH-accessible host PC  
**Primary deliverable:** A small Neovim Lua plugin controlling host-local `mpv` playback  
**Intended implementer:** Codex  
**Date:** 2026-09-23

## 1. Project summary

Build a transcription-editing companion, **not** a speech-to-text system. The user already has an AI-generated draft transcript and is manually checking and editing it using Braun & Clarke-style thematic analysis transcription practices. The draft remains an ordinary text file opened in Neovim.

Audio is an MP3 (or any ordinary format supported by `mpv`) stored on the **host PC**. A separate `mpv` process on the host owns decoding, playback, speaker output, and playback state. A minimal Neovim plugin sends playback commands over **mpv's native JSON IPC Unix-domain socket**. When Neovim is accessed through SSH from a tablet in the same room, Neovim and `mpv` are both still processes on the host; sound therefore comes out of the host's speakers rather than the tablet.

The solution should be comfortable for interactive corrections, easy to run with ephemeral Nix packages, and deliberately small. Do **not** build an HTTP service, TCP listener, separate playback daemon, audio renderer, speech recogniser, transcript database, or audio stream to the tablet for the MVP.

## 2. Goals and non-goals

### Goals

1. Control playback from Neovim with commands and normal-mode mappings: load, play, pause, toggle, beginning, end, relative seek back/forward 5, 10, or 30 seconds.
2. Keep playback independent of the SSH or Neovim session. Disconnecting the tablet must not terminate `mpv` or redirect its audio.
3. Keep the plugin dependency-free beyond Neovim's bundled Lua/libuv functionality (`vim.uv`, with `vim.loop` fallback if desired).
4. Give understandable errors for a missing socket, missing file, invalid seek amount, or mpv command failure.
5. Handle mpv's newline-delimited JSON replies safely and non-blockingly.
6. Work with ephemeral `nix shell` usage; avoid requiring a system-wide NixOS configuration change.
7. Keep transcript files editable as plain text and leave decisions about transcription conventions to the user.

### Non-goals for MVP

- Generating or automatically correcting transcripts.
- Automatic text/audio alignment, diarisation, or waveform visualization.
- Web UI, mobile app, HTTP API, exposed TCP port, or tablet-side audio.
- Multiple simultaneous players or per-buffer player instances.
- Automatically launching/stopping `mpv` from inside the plugin.
- A permanently displayed player statusline, background position polling, or automatic timestamp insertion.
- Packaging a published plugin or systemd user service before the MVP works.

## 3. Architecture

```text
   Tablet (SSH terminal)
   ┌─────────────────────────────┐
   │ keyboard + terminal display │
   └──────────────┬──────────────┘
                  │ SSH
                  ▼
   NixOS host PC
   ┌────────────────────────────────────────────────────────────┐
   │ Neovim process                                             │
   │   draft-transcript.txt                                     │
   │   transcript_audio.lua                                     │
   │       │ JSON command + integer request_id                  │
   │       ▼                                                    │
   │   $XDG_RUNTIME_DIR/transcript-mpv.sock (Unix IPC)           │
   │       │                                                    │
   │       ▼                                                    │
   │   mpv --idle=yes --no-video --input-ipc-server=...          │
   │       │ playback and current position                      │
   │       ▼                                                    │
   │   host audio session (usually PipeWire) → PC speakers      │
   └────────────────────────────────────────────────────────────┘
```

**Ownership and lifetime:** `mpv` is started independently, ideally from the PC's graphical login session so it inherits the correct host audio environment. Neovim never owns its process. The IPC socket is local to the host. All files passed to `:Audio load` are resolved on the **host's filesystem**.

**Security:** mpv IPC is *not authenticated*. Its command set can do substantially more than basic playback, including process execution. Use a socket in the user-private `$XDG_RUNTIME_DIR` (normally `/run/user/<UID>`), do not expose or forward it over an untrusted network, and do not make it world-accessible. SSH is the remote transport, not mpv IPC over TCP.

## 4. Runtime and NixOS setup

Run this in a terminal **on the host in its normal desktop session**:

```bash
nix shell nixpkgs#mpv -c mpv \
  --no-video \
  --idle=yes \
  --keep-open=yes \
  --input-ipc-server="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/transcript-mpv.sock"
```

Notes:

- `--idle=yes`: mpv can start and wait without a loaded file.
- `--no-video`: no video window is necessary for MP3 transcription.
- `--keep-open=yes`: retain the file when it ends, allowing a seek back; EOF may leave playback paused.
- Start with a terminal attached for troubleshooting, and keep `mpv` running while using the plugin. A later user service or launcher is optional.
- Verify the host's normal speaker output first. If mpv is started in an SSH session and cannot find the desktop audio session, fix its session environment/start location; do not add remote audio transport.
- Ensure the SSH user and the graphical-session user are the same account (or explicitly plan permissions); by default the runtime socket belongs to that user.
- If a stale socket is suspected after a crash, first check for an active mpv process before manually removing anything. The plugin should never blindly delete the socket.

A useful manual IPC smoke test, if `socat` is available ephemerally:

```bash
nix shell nixpkgs#socat -c sh -c \
  'printf '\''{"command":["get_property","pause"],"request_id":1}\n'\'' | socat - "${XDG_RUNTIME_DIR}/transcript-mpv.sock"'
```

Or simply use the Neovim commands once the plugin is installed. `socat` is **not** a plugin dependency.

## 5. User-facing command contract

Expose one Ex command: `:Audio <action> [argument]`. Actions are case-sensitive for the MVP.

| Command | Behaviour | mpv JSON `command` array |
|---|---|---|
| `:Audio load /path/file.mp3` | Replace the active file; mpv ordinarily begins playback | `["loadfile", "/absolute/path/file.mp3", "replace"]` |
| `:Audio play` | Explicitly resume | `["set_property", "pause", false]` |
| `:Audio pause` | Explicitly pause | `["set_property", "pause", true]` |
| `:Audio toggle` | Toggle pause state | `["cycle", "pause"]` |
| `:Audio speed 80%` | Set playback speed to 80% (the `%` suffix is optional) | `["set_property", "speed", 0.8]` |
| `:Audio beginning` | Seek to zero | `["seek", 0, "absolute"]` |
| `:Audio end` | Seek to end | `["seek", 100, "absolute-percent"]` |
| `:Audio seek 14:32` | Seek to an absolute timestamp | `["seek", 872, "absolute"]` |
| `:Audio forward 5/10/30` | Seek forward by seconds | `["seek", N, "relative"]` |
| `:Audio back 5/10/30` | Seek backward by seconds | `["seek", -N, "relative"]` |
| `:Audio time` | Display current playback position | `["get_property", "time-pos"]` |

**Parsing:** `load` consumes all text after its first space as the path (filenames may contain spaces); expand a leading `~` and resolve to an absolute host path. Check that the file is readable before sending. Validate that relative seek amounts are exactly 5, 10, or 30 for the initial UI. Absolute `seek` accepts `MM:SS`, `HH:MM:SS`, or non-negative raw seconds and converts them to seconds before sending. `speed` accepts numeric percentages from 0 through 200, inclusive, and sends the corresponding mpv multiplier. Document that loading a file starts playback; `pause` remains a separate operation. `time` is a small quality-of-life extra, not a continuously refreshed status indicator.

**End semantics:** The native `absolute-percent` seek is adequate for an MVP. When playback has reached EOF, users may need `:Audio play` after seeking backwards. Do not hide that behaviour with surprising implicit pause changes unless a tested UX decision calls for it.

### Default normal-mode mappings

| Mapping | Action |
|---|---|
| `<leader>aa` | toggle |
| `<leader>ap` | play |
| `<leader>as` | pause |
| `<leader>ah` / `<leader>al` | back 5 / forward 5 |
| `<leader>aj` / `<leader>ak` | back 10 / forward 10 |
| `<leader>aH` / `<leader>aL` | back 30 / forward 30 |
| `<leader>a0` | beginning |
| `<leader>a$` | end |
| `<leader>at` | show current position |
| `<leader>ag` | prompt for an absolute timestamp |

Mappings should be normal-mode only, to avoid intercepting typed transcript text. Support a `setup(opts)` function or a small, clearly documented configuration point so the socket path and mappings can be customised. Preserve the user's existing `<leader>` setting; never overwrite it.

## 6. IPC protocol and client design

mpv accepts newline-delimited UTF-8 JSON with a `command` array. Send one JSON object **followed by `\n`**:

```json
{"command":["seek",-10,"relative"],"request_id":1}
```

The corresponding reply may look like:

```json
{"request_id":1,"error":"success","data":null}
```

mpv may also emit unsolicited events. TCP-style read fragmentation applies to Unix stream sockets as well: one read can be a partial line or multiple lines. The client **must buffer by newline, parse each complete line, ignore unrelated events, and match the integer `request_id`**.

Suggested initial strategy:

1. Open a fresh `vim.uv.new_pipe(false)` connection for each command. This keeps state small; there is no need to observe playback continuously.
2. Register `read_start` and send the JSON request with `pipe:write()`.
3. Accumulate chunks; decode complete lines with `vim.json.decode` inside `pcall`.
4. Ignore event objects and unrelated IDs. Complete on the matching `request_id` response.
5. On `error != "success"`, inform the user of the mpv error. For `time`, schedule the response display on Neovim's main thread.
6. Close the pipe exactly once on success, EOF, connect/read/write failure, or timeout. Avoid calling editor APIs directly inside libuv callbacks; use `vim.schedule` for notifications and UI changes.
7. Add a modest request timeout (for example 3 seconds) so a stalled player cannot leak a socket indefinitely; stop and close any timer during cleanup.

Using a separate connection per request means request ID `1` is acceptable for each connection. If a persistent connection is implemented later, use monotonically increasing IDs and a map of pending requests, and consider serialising dependent commands. The MVP does not require such a connection.

**Error cases:** missing/offline player, unavailable socket, malformed reply, failed command, invalid path, EOF before the response, and timeout. Report errors to the user; do not silently assume success. In particular, successful `loadfile` acknowledgement means the load command was accepted, **not** that the media finished opening. Do not report a verified successful file load unless observed separately.

## 7. Suggested file structure

Start with a single local module:

```text
~/.config/nvim/
├── init.lua
└── lua/
    └── transcript_audio.lua
```

Add to `init.lua`:

```lua
require("transcript_audio").setup()
```

If this grows beyond a personal module, it can become a standalone plugin repository:

```text
transcript-audio.nvim/
├── lua/transcript_audio/init.lua
├── README.md
└── tests/                  # optional, when warranted
```

No plugin manager or additional Lua packages are necessary for the initial local module.

## 8. Reference implementation sketch

The following is a concrete starting point adapted from the initial discussion. Codex should review and test it, particularly libuv error/cleanup behaviour on the installed Neovim version. It is **reference code, not a claim of a tested release**.

```lua
local M = {}
local uv = vim.uv or vim.loop

local runtime = vim.env.XDG_RUNTIME_DIR
  or ("/run/user/" .. vim.fn.getuid())

M.socket = vim.env.TRANSCRIPT_MPV_SOCKET
  or (runtime .. "/transcript-mpv.sock")

local function notify(message)
  vim.schedule(function()
    vim.notify("Transcript audio: " .. message, vim.log.levels.WARN)
  end)
end

-- Send a single request. The caller can supply an optional success callback.
local function send(command, on_reply)
  local pipe = uv.new_pipe(false)
  if not pipe then
    notify("Cannot create IPC pipe")
    return
  end

  local timer = uv.new_timer()
  local buffer = ""
  local done = false

  local function finish(err, data)
    if done then return end
    done = true

    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if not pipe:is_closing() then
      pipe:read_stop()
      pipe:close()
    end

    if err then
      notify(err)
    elseif on_reply then
      vim.schedule(function() on_reply(data) end)
    end
  end

  if timer then
    timer:start(3000, 0, function()
      finish("Timed out waiting for mpv")
    end)
  end

  pipe:connect(M.socket, function(err)
    if err then
      finish("Cannot connect to mpv: " .. err)
      return
    end
    if done then return end

    pipe:read_start(function(read_err, chunk)
      if read_err then
        finish("IPC read error: " .. read_err)
        return
      end
      if not chunk then
        finish("mpv closed the connection")
        return
      end

      buffer = buffer .. chunk
      while true do
        local pos = buffer:find("\n", 1, true)
        if not pos then break end
        local line = buffer:sub(1, pos - 1)
        buffer = buffer:sub(pos + 1)
        local ok, reply = pcall(vim.json.decode, line)
        if ok and type(reply) == "table" and reply.request_id == 1 then
          if reply.error == "success" then
            finish(nil, reply.data)
          else
            finish(tostring(reply.error or "Unknown mpv error"))
          end
          return
        end
      end
    end)

    local message = vim.json.encode({
      command = command,
      request_id = 1,
    }) .. "\n"

    pipe:write(message, function(write_err)
      if write_err then finish("IPC write error: " .. write_err) end
    end)
  end)
end

function M.run(action, arg)
  if action == "load" then
    if not arg or arg == "" then
      notify("Usage: :Audio load /path/to/file.mp3")
      return
    end
    local path = vim.fn.fnamemodify(vim.fn.expand(arg), ":p")
    if vim.fn.filereadable(path) ~= 1 then
      notify("File not found: " .. path)
      return
    end
    send({ "loadfile", path, "replace" })

  elseif action == "play" then
    send({ "set_property", "pause", false })
  elseif action == "pause" then
    send({ "set_property", "pause", true })
  elseif action == "toggle" then
    send({ "cycle", "pause" })
  elseif action == "beginning" then
    send({ "seek", 0, "absolute" })
  elseif action == "end" then
    send({ "seek", 100, "absolute-percent" })

  elseif action == "forward" or action == "back" then
    local seconds = tonumber(arg)
    if seconds ~= 5 and seconds ~= 10 and seconds ~= 30 then
      notify("Seek amount must be 5, 10, or 30 seconds")
      return
    end
    if action == "back" then seconds = -seconds end
    send({ "seek", seconds, "relative" })

  elseif action == "time" then
    send({ "get_property", "time-pos" }, function(seconds)
      if type(seconds) ~= "number" then return end
      local minutes = math.floor(seconds / 60)
      vim.notify(string.format("Audio: %02d:%05.2f", minutes, seconds % 60))
    end)
  else
    notify("Unknown command: " .. tostring(action))
  end
end

function M.setup(opts)
  opts = opts or {}
  if opts.socket then M.socket = opts.socket end

  vim.api.nvim_create_user_command("Audio", function(command_opts)
    local action, arg = command_opts.args:match("^(%S+)%s*(.-)%s*$")
    M.run(action, arg)
  end, { nargs = "+", desc = "Control transcript audio" })

  if opts.mappings == false then return end
  local function map(lhs, action, arg, description)
    vim.keymap.set("n", lhs, function() M.run(action, arg) end,
      { desc = description })
  end

  map("<leader>aa", "toggle", nil, "Audio play/pause")
  map("<leader>ap", "play", nil, "Audio play")
  map("<leader>as", "pause", nil, "Audio pause")
  map("<leader>ah", "back", 5, "Audio back 5s")
  map("<leader>al", "forward", 5, "Audio forward 5s")
  map("<leader>aj", "back", 10, "Audio back 10s")
  map("<leader>ak", "forward", 10, "Audio forward 10s")
  map("<leader>aH", "back", 30, "Audio back 30s")
  map("<leader>aL", "forward", 30, "Audio forward 30s")
  map("<leader>a0", "beginning", nil, "Audio beginning")
  map("<leader>a$", "end", nil, "Audio end")
  map("<leader>at", "time", nil, "Audio position")
end

return M
```

**Implementation note:** Review potential race conditions around a timeout firing during connection establishment or while a write is pending. Tests should assert that completion happens once, callback errors do not crash Neovim, and every handle is released. Consider a more explicit state machine if this is problematic on the installed libuv version. Long or maliciously malformed replies are out of scope for a trusted local server, but imposing a modest buffer size limit is inexpensive defence-in-depth.

## 9. Work plan for Codex

### Phase A — Establish the environment

- Check Neovim version and `vim.uv` availability; verify `mpv` starts via `nix shell`.
- Run mpv in the graphical session; verify sound comes through host speakers.
- Confirm the socket is created in `$XDG_RUNTIME_DIR` and is accessible to the SSH login user.

### Phase B — Implement the minimal plugin

- Implement an asynchronous `send()` with reply matching, timeout, cleanup, and main-thread notification.
- Implement `M.run(action, arg)` and `:Audio` command parsing.
- Implement the normal-mode mappings and optional socket-path configuration.
- Add a short README: NixOS launch command, installation, mappings, and troubleshooting.

### Phase C — Test local and remote behaviour

- Local Neovim: load an MP3, pause/play, seek in both directions, beginning, end, and time display.
- SSH Neovim: repeat those actions while sound remains on host speakers.
- Disconnect and reconnect SSH: mpv should keep running and retain its current file/position.
- Exercise errors: absent socket, nonexistent media, invalid seek amount, no loaded media, EOF, mpv exit during request.
- Ensure typing in insert mode is unaffected and that commands do not block Neovim.

### Phase D — Polish only if needed

- Adjust mappings to the user's tablet keyboard/terminal capabilities (shifted keys may be awkward).
- Improve notifications or handle a stale socket through documentation.
- Only after real usage, evaluate bookmarks, timestamp insertion, or a custom launcher.

## 10. Acceptance criteria

- [ ] `mpv` independently starts on NixOS using ephemeral packages and accepts local JSON IPC connections.
- [ ] `:Audio load /some/path with spaces/interview.mp3` loads the expected host file.
- [ ] Play, pause, toggle, beginning, end, and ±5/10/30-second seek work.
- [ ] Normal-mode mappings work; insert-mode transcription input is unchanged.
- [ ] Neovim remains responsive while IPC is pending or mpv is unavailable.
- [ ] Socket/reply failures appear as comprehensible Neovim notifications, without a stack trace for routine errors.
- [ ] MP3 sound comes from host speakers when controlled from Neovim over SSH.
- [ ] Exiting/disconnecting remote Neovim does not terminate the player.
- [ ] The implementation requires no new network-facing service and no additional Neovim dependencies.
- [ ] README documents startup, the socket path, all commands/mappings, and the EOF/pause caveat.

## 11. Future feature: timestamp bookmarks (explicitly defer)

A natural next feature is a shortcut that queries `time-pos` and inserts a timestamp on the current transcript line, for example:

```text
[00:14:32] Interviewer: So what happened next?
```

A complementary shortcut could parse a timestamp from the current line and seek with `seek <seconds> absolute`. This is helpful for returning to passages during manual corrections or thematic analysis. It is **not** part of the MVP; do not implement unless separately requested.

## 12. Reference documentation

- mpv JSON IPC: https://github.com/mpv-player/mpv/blob/master/DOCS/man/ipc.rst
- mpv command interface (`seek`, `loadfile`): https://github.com/mpv-player/mpv/blob/master/DOCS/man/input.rst
- mpv stable manual (runtime options): https://mpv.io/manual/stable/
- Neovim libuv reference (`new_pipe`, `pipe:connect`, `read_start`): https://neovim.io/doc/user/luvref/
- Neovim Lua API reference: https://neovim.io/doc/user/lua/

---

**Implementation instruction to Codex:** Build the smallest working implementation matching this contract, rather than expanding the design. Use the reference Lua code only as a starting point: review it, test it, and correct any issues found. Put host audio ownership in mpv, not in Neovim. Preserve ordinary-text transcript editing, and report any environment-specific changes you make.

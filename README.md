# transcript-audio.nvim

`transcript-audio.nvim` is a small, dependency-free Neovim plugin for controlling an independently running `mpv` player over a user-local Unix-domain JSON IPC socket. It is designed for manually checking and editing an ordinary text transcript while listening to audio on the host computer, including when Neovim is being used through SSH from a tablet.

It is a playback controller, not a transcription engine. It does not generate or align transcripts, stream audio to the SSH client, launch or stop `mpv`, run a media server, or provide a waveform, timestamp-bookmark, or continuously updating status UI.

## Architecture

`mpv` runs independently in the host's graphical user session and owns media decoding, playback state, and speaker output. Neovim sends one-shot JSON commands to `mpv` through a Unix socket on that same host. SSH carries the keyboard and terminal display only; it does not carry the audio. Consequently, disconnecting Neovim or SSH does not terminate `mpv` or move audio output to the tablet.

Media paths passed to `:Audio load` are paths on the host filesystem.

## Installation

For a local plugin checkout, add the repository to Neovim's runtime path and call `setup()`:

```lua
vim.opt.rtp:append("/path/to/transcript-audio.nvim")
require("transcript_audio").setup()
```

Alternatively, place or symlink this repository under a plugin manager's normal package/plugin directory. No Lua runtime dependency or plugin framework is required.

The default socket is resolved in this order:

1. `opts.socket`
2. `TRANSCRIPT_MPV_SOCKET`
3. `$XDG_RUNTIME_DIR/transcript-mpv.sock`
4. `/run/user/<uid>/transcript-mpv.sock`

Example configuration:

```lua
require("transcript_audio").setup({
  socket = "/run/user/1000/transcript-mpv.sock",
  timeout_ms = 3000,
})
```

To disable all default mappings:

```lua
require("transcript_audio").setup({ mappings = false })
```

The plugin preserves the existing `mapleader` value. Calling `setup()` again updates the configuration and replaces the plugin's own mappings without changing unrelated mappings.

## Start mpv on NixOS

Start `mpv` independently on the host, preferably from a terminal in the normal graphical user session so it inherits the expected PipeWire/audio environment:

```bash
nix shell nixpkgs#mpv -c mpv \
  --no-video \
  --idle=yes \
  --keep-open=yes \
  --input-ipc-server="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/transcript-mpv.sock"
```

Keep this process running while using the plugin. The socket belongs to the user running `mpv`, so Neovim and the graphical-session `mpv` should normally run as the same user.

`--keep-open=yes` retains the loaded file after it reaches EOF. Seeking backwards from EOF may still leave playback paused; use `:Audio play` explicitly when needed.

The IPC socket is unauthenticated and can expose powerful `mpv` commands, so it must remain a user-local Unix socket. Do not make it world-accessible, expose it as a network service, or forward it over an untrusted network.

## Commands

The plugin provides one Ex command: `:Audio <action> [argument]`. Actions are case-sensitive.

| Command | Description |
| --- | --- |
| `:Audio load /path/to/file.mp3` | Load a host filesystem path, including paths with spaces; `~` is expanded and the file must be readable. |
| `:Audio play` | Resume playback. |
| `:Audio pause` | Pause playback. |
| `:Audio toggle` | Toggle pause state. |
| `:Audio beginning` | Seek to the beginning. |
| `:Audio end` | Seek to the end. |
| `:Audio forward 5` | Seek forward 5 seconds. |
| `:Audio forward 10` | Seek forward 10 seconds. |
| `:Audio forward 30` | Seek forward 30 seconds. |
| `:Audio back 5` | Seek backward 5 seconds. |
| `:Audio back 10` | Seek backward 10 seconds. |
| `:Audio back 30` | Seek backward 30 seconds. |
| `:Audio time` | Show the current position, for example `Audio: 14:32.18`. |

Seek amounts are deliberately limited to exactly 5, 10, or 30 seconds. A successful `loadfile` response means that `mpv` accepted the command; it does not verify that the media has finished opening.

## Default mappings

The mappings are normal-mode only, so typing transcript text in insert mode is unaffected.

| Mapping | Action |
| --- | --- |
| `<leader>aa` | Toggle |
| `<leader>ap` | Play |
| `<leader>as` | Pause |
| `<leader>ah` | Back 5 seconds |
| `<leader>al` | Forward 5 seconds |
| `<leader>aj` | Back 10 seconds |
| `<leader>ak` | Forward 10 seconds |
| `<leader>aH` | Back 30 seconds |
| `<leader>aL` | Forward 30 seconds |
| `<leader>a0` | Beginning |
| `<leader>a$` | End |
| `<leader>at` | Show position |

## SSH workflow

1. On the host PC, start `mpv` in the graphical session with the Unix socket command above.
2. From the tablet or another device, SSH into that same host and start Neovim.
3. Open the plain-text transcript, then use `:Audio load /host/path/recording.mp3` or the mappings.
4. Edit the transcript over SSH while the host PC speakers play the audio.
5. Exit Neovim or disconnect SSH; `mpv` remains independent and can be controlled again after reconnecting.

## Troubleshooting

- **Missing socket:** Confirm that `mpv` is still running and that its `--input-ipc-server` path exactly matches the plugin's configured path. Check `TRANSCRIPT_MPV_SOCKET` and `XDG_RUNTIME_DIR`.
- **Wrong user or runtime directory:** The socket is normally under `/run/user/<uid>`. Start `mpv` and Neovim as the same user, or configure an explicitly accessible user-local socket.
- **No sound or wrong output:** Start `mpv` from the host's graphical user session so it inherits the normal PipeWire/audio environment. Check the host's selected output device independently of Neovim.
- **Invalid media path:** `:Audio load` uses the host filesystem, not the tablet's filesystem. Use an absolute host path or a `~` path and confirm that the file exists and is readable by the host user.
- **Playback stopped at EOF:** With `--keep-open=yes`, run `:Audio play` after seeking backwards from the end.
- **Stale socket suspicion:** Check for an active `mpv` process before removing anything manually. The plugin never deletes a socket automatically.

## Development and tests

Enter the development shell from the repository root:

```bash
nix develop
```

Run the headless setup, action, and fake-`mpv` IPC tests with:

```bash
tests/run.sh
```

The test fake server uses only Python's standard library and binds to a temporary Unix socket. Python is a development/test tool only; it is not a runtime dependency of the plugin.

Timestamp bookmarks or transcript/audio alignment, background position polling, and richer player status are intentionally future work outside this MVP.

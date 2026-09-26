# Implementation Stint — Transcript Audio Controller for Neovim

**Audience:** Codex (Luna High)
**Primary spec:** `transcript-audio-architecture.md`
**Goal:** Implement the MVP described in the architecture document as a small, reliable Neovim Lua plugin that controls an independently running host-local `mpv` instance over its Unix-domain JSON IPC socket.

## 0. Read this before changing code

Treat `transcript-audio-architecture.md` as the product/architecture contract. This stint is the execution plan.

The core user workflow is:

1. `mpv` runs independently on the NixOS host and owns playback/audio output.
2. The user SSHes into that same host from a tablet.
3. Neovim runs on the host inside the SSH session and edits a plain-text transcript.
4. The Neovim plugin sends playback commands to mpv over a local Unix socket.
5. Sound continues to come from the host PC speakers.
6. Closing Neovim or disconnecting SSH does not terminate mpv.

Do **not** turn this into a transcription engine, media server, HTTP service, daemon manager, waveform UI, timestamp system, or general mpv client.

### Working rules

- Inspect the repository before editing. Preserve unrelated files and existing conventions.
- If the repository is empty, use the standalone plugin layout specified below.
- If this code is being added inside an existing Neovim config, keep the same logical module separation but do not reorganise unrelated config.
- Use Neovim's built-in Lua/libuv facilities only at runtime: `vim.uv` with `vim.loop` fallback if needed.
- No runtime Lua dependencies and no plugin-framework dependency.
- A dev/test-only Python or shell helper is acceptable if it materially simplifies a fake Unix-socket mpv server; it must not become a runtime dependency.
- Keep the implementation asynchronous. Never use `vim.fn.system()`, shelling to `socat`, polling loops, or blocking reads for normal playback control.
- Prefer a fresh Unix socket connection per request. Do not build persistent-connection machinery for this stint.
- Use mpv request IDs and newline-delimited JSON correctly. Never assume the next message is necessarily the reply because mpv may emit events.
- Do not silently swallow routine failures. User-facing failures should become concise Neovim notifications rather than stack traces.
- Do not delete a possibly stale socket automatically.
- Do not automatically launch or kill mpv from the plugin.
- Do not implement the deferred timestamp/bookmark feature.
- Do not change the transcript file format.
- Make the commits below as separate commits in order. Do not squash them unless explicitly asked later.

## 1. Target repository shape

For an empty/standalone repository, prefer this structure:

```text
transcript-audio.nvim/
├── lua/
│   └── transcript_audio/
│       ├── init.lua       # setup(), :Audio command, mappings, notifications
│       ├── actions.lua    # action parsing/validation -> mpv command arrays
│       └── ipc.lua        # one-request-per-connection mpv JSON IPC client
├── tests/
│   ├── minimal_init.lua   # minimal headless-Neovim bootstrap if needed
│   ├── fake_mpv.py        # optional stdlib Unix-socket test server
│   └── run.sh             # optional reproducible test entry point
└── README.md
```

Three Lua modules are enough. Do not introduce classes, object systems, dependency injection frameworks, event buses, or a large abstraction layer.

The split should be approximately:

- `ipc.lua`: transport only. It knows sockets, JSON lines, request IDs, timeout, and cleanup. It does not know what `back 10` means.
- `actions.lua`: converts the user-facing action and argument to an mpv command or a local validation error. It should be mostly pure/testable logic. File-path expansion/readability may remain in the command/UI layer if that makes testing cleaner.
- `init.lua`: public API and Neovim integration: config, notifications, `:Audio`, mappings, path handling, and rendering `:Audio time` output.

If a simpler two-file split is clearly superior in the existing repository, that is acceptable, but keep transport separate from editor-facing UI logic.

## 2. Public behaviour to implement

Expose:

```vim
:Audio load /absolute/or/~/path with spaces/interview.mp3
:Audio play
:Audio pause
:Audio toggle
:Audio beginning
:Audio end
:Audio forward 5
:Audio forward 10
:Audio forward 30
:Audio back 5
:Audio back 10
:Audio back 30
:Audio time
```

The corresponding mpv command arrays are:

```lua
{ "loadfile", path, "replace" }
{ "set_property", "pause", false }
{ "set_property", "pause", true }
{ "cycle", "pause" }
{ "seek", 0, "absolute" }
{ "seek", 100, "absolute-percent" }
{ "seek", 5, "relative" }
{ "seek", 10, "relative" }
{ "seek", 30, "relative" }
{ "seek", -5, "relative" }
{ "seek", -10, "relative" }
{ "seek", -30, "relative" }
{ "get_property", "time-pos" }
```

`load` consumes the full remainder of the Ex command as its path. Expand `~`, resolve to an absolute host path, and reject unreadable/nonexistent files before sending an IPC request.

Seek amounts exposed by the command must be **exactly** 5, 10, or 30 seconds in this MVP.

`time` should display a compact position such as:

```text
Audio: 14:32.18
```

Do not add continuous position polling.

### Default normal-mode mappings

Install these by default:

```text
<leader>aa   toggle
<leader>ap   play
<leader>as   pause
<leader>ah   back 5
<leader>al   forward 5
<leader>aj   back 10
<leader>ak   forward 10
<leader>aH   back 30
<leader>aL   forward 30
<leader>a0   beginning
<leader>a$   end
<leader>at   time
```

They must be normal-mode mappings only. Never replace the user's `mapleader` value.

Provide at least:

```lua
require("transcript_audio").setup({
  socket = "/optional/custom/path.sock",
  mappings = true, -- false disables all default mappings
})
```

Default socket resolution:

1. `opts.socket`, if supplied.
2. `TRANSCRIPT_MPV_SOCKET`, if set.
3. `$XDG_RUNTIME_DIR/transcript-mpv.sock`.
4. `/run/user/<uid>/transcript-mpv.sock` as fallback.

Do not invent a TCP fallback.

## 3. IPC correctness requirements

The transport is the highest-risk part of the implementation. Implement it deliberately.

For one request:

1. Create a `uv.new_pipe(false)` handle.
2. Create a one-shot timeout timer; default around 3000 ms unless the architecture or existing config says otherwise.
3. Connect to the configured Unix socket.
4. Begin reading.
5. Encode a request as one JSON object followed by `\n`:

   ```json
   {"command":["seek",-10,"relative"],"request_id":1}
   ```

6. Buffer read chunks because a JSON line may be fragmented across reads and one read may contain multiple lines.
7. Split only on complete newline delimiters.
8. Decode each complete line safely.
9. Ignore valid JSON event objects and valid replies for unrelated request IDs.
10. Complete only when `request_id == 1` for this per-request connection.
11. Treat `error == "success"` as transport/command success and return `data` to the caller.
12. Convert a non-success mpv `error` into an ordinary callback error/user notification.
13. On connection error, read error, write error, EOF before matching reply, malformed matching reply, or timeout: fail once and clean up.
14. Close/stop the pipe and timer exactly once.
15. Do not call unsafe Neovim editor APIs directly from arbitrary libuv callbacks. Schedule UI-facing callbacks/notifications onto the main loop.

A single `finish()`/`complete()` function guarded by a boolean is the preferred cleanup shape. Ensure races such as timeout-vs-write-callback or timeout-vs-connect-callback do not double-close handles or invoke the caller twice.

Do not implement a persistent connection, pending-request map, subscriptions, or observation APIs.

## 4. Commit plan

Make **six commits**. Each commit should leave the repository in a coherent state and should include the tests appropriate to that increment.

---

### Commit 1 — `chore: scaffold transcript audio plugin`

#### Scope

Create the minimal plugin/repository skeleton and public setup surface without implementing live mpv IPC yet.

#### Required work

- Establish the `lua/transcript_audio/` module layout.
- Add `init.lua`, `actions.lua`, and `ipc.lua` placeholders with sensible module boundaries.
- Implement configuration/default resolution for:
  - socket path,
  - request timeout,
  - default mappings enabled/disabled.
- Ensure `require("transcript_audio").setup()` is safe to call once in a minimal Neovim session.
- Decide and document how duplicate `setup()` calls behave. Prefer idempotent user-command creation and predictable mapping replacement rather than crashing on `:Audio` already existing.
- Add a minimal README heading and a one-paragraph statement of purpose; detailed documentation comes later.
- Add minimal test/bootstrap infrastructure sufficient to run later headless Neovim tests.

#### Do not do yet

- No live socket connection.
- No actual `:Audio` playback actions.
- No full mappings table yet if it would imply functional playback.

#### Verification before commit

At minimum, this must exit successfully:

```bash
nvim --headless -u NONE \
  "+set rtp+=." \
  "+lua require('transcript_audio').setup({ mappings = false })" \
  "+qa"
```

Adapt the command if repository/test bootstrap conventions differ.

#### Commit

```text
chore: scaffold transcript audio plugin
```

---

### Commit 2 — `feat: add mpv JSON IPC transport`

#### Scope

Implement and test the asynchronous one-request-per-connection Unix-socket client in `ipc.lua`.

#### Required work

Implement a small internal API along these lines:

```lua
ipc.request({
  socket = "/path/to/socket",
  timeout_ms = 3000,
  command = { "get_property", "pause" },
}, function(err, data)
  -- exactly one completion
end)
```

The exact signature may differ, but keep it narrow.

Cover:

- successful connection/write/read/reply,
- newline framing,
- fragmented JSON reply over multiple reads,
- multiple JSON lines in one read,
- ignoring an unsolicited event before the reply,
- ignoring unrelated `request_id` values,
- mpv response with `error != "success"`,
- connection failure/missing socket,
- timeout,
- EOF before matching response,
- single-shot completion/cleanup.

Use `request_id = 1` for the per-request connection.

A stdlib Python fake server under `tests/` is acceptable and probably the simplest way to deliberately fragment replies and inject events. If used, it must bind only to a temporary Unix socket and must not be required at plugin runtime.

#### Important edge cases

- A libuv callback may arrive after `finish()` has already run. It must become a no-op.
- Do not call `pipe:read_stop()` or `:close()` unsafely after the handle is already closing.
- Stop and close the timer during all non-timeout completion paths.
- If creating a timer fails, either fail immediately or continue with an explicitly justified safe fallback; do not dereference a nil timer.
- If JSON decoding fails on a line that should be treated as protocol traffic, return a clear protocol error rather than throwing through Neovim.

#### Verification before commit

Run all transport tests headlessly. Also manually test against real mpv if available:

```bash
nix shell nixpkgs#mpv -c mpv \
  --no-video \
  --idle=yes \
  --keep-open=yes \
  --input-ipc-server="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/transcript-mpv.sock"
```

Then issue at least a harmless `get_property pause` request from a headless Neovim invocation or test helper.

#### Commit

```text
feat: add mpv JSON IPC transport
```

---

### Commit 3 — `feat: implement audio command actions`

#### Scope

Implement the action grammar, validation, mpv command mapping, `:Audio` user command, and time-position rendering.

#### Required work

In `actions.lua`, implement the user-facing action mapping for:

- play,
- pause,
- toggle,
- beginning,
- end,
- forward 5/10/30,
- back 5/10/30,
- time.

Keep validation logic deterministic and easy to test.

In `init.lua`:

- Register `:Audio` with `nargs = "+"`.
- Parse the first token as the action and the full remainder as the argument.
- For `load`, preserve spaces in the filename, expand `~`, absolutise it, check readability, then construct `{"loadfile", path, "replace"}`.
- Route commands through the IPC transport.
- Render routine errors via a concise prefix such as `Transcript audio:`.
- Render `time-pos` as `MM:SS.xx` or `HH:MM:SS.xx` when appropriate. Do not let hour-long recordings produce a misleading minute field if a straightforward hour-aware formatter is easy to implement.
- Do not claim that `loadfile` means the file has fully opened; only report an error if the command itself fails.

#### Validation/error cases

Tests must cover at least:

- missing load path,
- path with spaces,
- `~` expansion,
- nonexistent/unreadable path,
- missing seek amount,
- unsupported seek amount such as `7`,
- nonnumeric seek amount,
- unknown action,
- `time` receiving numeric data,
- `time` receiving nil/non-numeric data,
- transport error being converted to a user-facing notification without stack trace.

Avoid erroring on ordinary user mistakes.

#### Verification before commit

With a real mpv session and a small test audio file, manually check:

```vim
:Audio load /path/to/file.mp3
:Audio pause
:Audio play
:Audio back 5
:Audio forward 10
:Audio beginning
:Audio end
:Audio time
```

Confirm Neovim stays responsive during requests.

#### Commit

```text
feat: implement audio command actions
```

---

### Commit 4 — `feat: add configurable playback keymaps`

#### Scope

Add the default normal-mode mappings and finish the supported `setup(opts)` behaviour.

#### Required work

Install the mappings from the public contract exactly unless a repository-wide convention clearly requires a namespaced variation:

```text
<leader>aa   toggle
<leader>ap   play
<leader>as   pause
<leader>ah   back 5
<leader>al   forward 5
<leader>aj   back 10
<leader>ak   forward 10
<leader>aH   back 30
<leader>aL   forward 30
<leader>a0   beginning
<leader>a$   end
<leader>at   time
```

Requirements:

- normal mode only,
- descriptive `desc` values,
- respect the user's existing `mapleader`,
- `setup({ mappings = false })` creates no default mappings,
- `setup({ socket = ... })` overrides the environment/default socket,
- environment variable `TRANSCRIPT_MPV_SOCKET` works when `opts.socket` is absent,
- no mapping should exist in insert mode,
- do not create buffer-local mappings unless the architecture is intentionally revised and documented.

If you expose custom mapping overrides, keep them small and backwards-compatible with `mappings = false`; this is optional. Do not turn mapping configuration into a mini keymap DSL.

#### Verification before commit

Use `nvim --headless` assertions where possible to inspect mapping presence/mode. Also open a normal interactive Neovim session and ensure insert-mode transcript typing is unaffected.

#### Commit

```text
feat: add configurable playback keymaps
```

---

### Commit 5 — `test: harden playback failure handling`

#### Scope

Perform the robustness pass and add regression tests for failure/race conditions discovered during implementation. This commit should primarily be tests plus narrowly scoped fixes required by those tests.

#### Required scenarios

Exercise and verify:

1. Socket path does not exist.
2. Socket exists but server disappears during a request.
3. Fake server accepts then closes before reply.
4. Fake server sends an event then the actual reply.
5. Reply is fragmented across reads.
6. Two JSON lines arrive together.
7. Reply has a different request ID before the matching one.
8. mpv returns a non-success error.
9. Request times out.
10. Timeout and another completion callback race; callback fires once.
11. Repeated commands do not accumulate open uv handles in an obvious way.
12. Invalid Ex command input does not create an IPC connection.
13. `setup()` does not crash when invoked again.
14. `:Audio time` on a player with no usable position fails gracefully.
15. Exiting Neovim while no request is pending requires no special teardown and does not affect mpv.

If practical, run a small loop of many fake requests under headless Neovim and inspect for warnings/errors. Do not build elaborate resource instrumentation unless an actual leak is observed.

#### Manual SSH acceptance pass

On the actual NixOS host, perform this workflow if the environment is available:

1. Start mpv from the host graphical session with the documented socket.
2. Verify host-speaker playback locally.
3. SSH into the same host from another terminal/device/session.
4. Start Neovim remotely.
5. Load media and exercise play/pause/seek/time.
6. Confirm the audio remains on host speakers.
7. Exit the remote Neovim/SSH session.
8. Confirm mpv remains alive with its playback/file state independent of Neovim.
9. Reconnect and control the same mpv instance again.

If this exact physical SSH/audio test cannot be performed in the coding environment, do not fake the result. State it clearly in the final handoff as the only manual environment check remaining.

#### Commit

```text
test: harden playback failure handling
```

---

### Commit 6 — `docs: document NixOS transcription workflow`

#### Scope

Finish the README and make the repository handoff-quality. Do not add new features in this commit except tiny corrections required to keep documentation truthful.

#### README must include

- What the plugin is and is not.
- Architecture in one paragraph: host mpv + local Unix socket + Neovim over local/SSH session.
- Installation for a local plugin and/or plugin-manager-agnostic runtime-path usage.
- `require("transcript_audio").setup()` example.
- NixOS/ephemeral mpv startup command:

  ```bash
  nix shell nixpkgs#mpv -c mpv \
    --no-video \
    --idle=yes \
    --keep-open=yes \
    --input-ipc-server="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/transcript-mpv.sock"
  ```

- All `:Audio` commands.
- All default mappings.
- Custom socket example.
- `mappings = false` example.
- The fact that media paths are host filesystem paths.
- The fact that mpv should usually be started in the graphical user session on NixOS so it has the normal PipeWire/audio environment.
- SSH usage explanation: SSH carries keyboard/terminal traffic; it is not carrying the audio.
- Security note: mpv IPC is unauthenticated and must remain a user-local Unix socket; do not expose it as an untrusted network service.
- EOF caveat: with `--keep-open=yes`, seeking backwards from EOF may still require an explicit play command.
- Troubleshooting for missing socket, wrong user/runtime directory, wrong audio session/output, and invalid media path.
- Test command(s), including any dev-only Python dependency if the fake server uses it.
- Explicitly list timestamp bookmarks/alignment/status polling as future/non-MVP work rather than implying they exist.

#### Final verification before commit

Run the complete automated test suite from a clean shell and record the exact command in the README if appropriate.

Then inspect:

```bash
git status --short
git log --oneline -6
```

There should be no accidental generated files, socket files, media files, editor swap files, or unrelated changes committed.

#### Commit

```text
docs: document NixOS transcription workflow
```

## 5. Testing expectations

Do not rely only on mocked Lua functions. The transport should be exercised against a real Unix-domain socket server in tests, because framing, EOF, fragmentation, and handle cleanup are core risks.

A good lightweight test stack is:

- Neovim headless for plugin execution,
- Python standard library `socket.AF_UNIX` fake server for deterministic IPC scenarios,
- POSIX shell test runner,
- optional real-mpv smoke test when the environment has mpv and audio.

Do **not** add Plenary/Busted solely for this small plugin unless the repository already uses one of them. If an existing test framework is already present, use it rather than adding a parallel harness.

Every bug discovered during the stint should receive a regression test when reasonably reproducible.

## 6. Definition of done

The stint is complete only when all of the following are true:

- [ ] `:Audio load <path with spaces>` loads the intended host-side media path.
- [ ] `play`, `pause`, `toggle`, `beginning`, `end`, and ±5/10/30-second seeking work.
- [ ] `:Audio time` displays the current position cleanly.
- [ ] All default mappings work in normal mode and do not intercept insert-mode text entry.
- [ ] `setup({ mappings = false })` suppresses default mappings.
- [ ] Socket path override works through both setup options and `TRANSCRIPT_MPV_SOCKET`.
- [ ] IPC is asynchronous and Neovim does not freeze when mpv is absent/unresponsive.
- [ ] Unsolicited mpv events do not get mistaken for replies.
- [ ] Fragmented/multiple-line socket reads are handled correctly.
- [ ] Each IPC request completes at most once and cleans up its uv handles.
- [ ] Routine errors are concise notifications, not uncaught Lua traces.
- [ ] No network-facing service is introduced.
- [ ] mpv remains independent of Neovim/SSH lifetime.
- [ ] Runtime dependency remains Neovim + mpv only.
- [ ] README truthfully documents setup, use, NixOS/SSH behaviour, security, and limitations.
- [ ] Exactly the six planned logical commits exist unless a genuine implementation discovery required an extra small fix commit; if so, explain why rather than rewriting history unnecessarily.

## 7. Explicit non-goals / stop conditions

Stop after the MVP. Do not implement any of these during this stint:

- timestamp insertion,
- seeking from timestamps in transcript lines,
- waveform display,
- auto-pause while typing,
- loop-current-sentence or A/B loops,
- playback speed UI,
- volume UI,
- automatic transcript/audio alignment,
- transcription generation,
- speaker diarisation,
- multiple mpv instances,
- multiple independent sessions,
- persistent IPC connection,
- mpv event subscriptions,
- statusline component,
- periodic playback-position polling,
- systemd user service,
- automatic mpv launch/kill,
- TCP/HTTP/WebSocket server,
- packaging/release automation.

If one of these seems useful while implementing, add it to a short `Future work` note only; do not code it.

## 8. Final handoff expected from Codex

At the end, return a concise implementation report containing:

1. What was implemented.
2. The six commit hashes and subjects, in order.
3. Exact automated test command(s) run and their result.
4. Whether a real mpv smoke test was run.
5. Whether the physical SSH-from-another-device + host-speaker test was run; if not, say it remains manual verification.
6. Any deliberate deviation from `transcript-audio-architecture.md` and the reason.
7. Any known limitations or edge cases still present.
8. `git status --short` result confirming the tree is clean (or explaining intentional uncommitted files).

Do not end the stint by proposing additional feature work. Finish with the MVP status and remaining verification, if any.

## 9. Commit checklist

Use this checklist to track completion of the six commits. Check an item only after the implementation and the corresponding verification are complete.

- [ ] **Commit 1 — `chore: scaffold transcript audio plugin`**
  - [ ] Module layout and setup/configuration surface exist.
  - [ ] Socket, timeout, and mapping defaults resolve correctly.
  - [ ] Minimal README and headless-Neovim test bootstrap exist.
  - [ ] Setup smoke test passes.
  - [ ] Commit created with the exact planned subject.

- [ ] **Commit 2 — `feat: add mpv JSON IPC transport`**
  - [ ] Asynchronous one-request-per-connection Unix-socket transport works.
  - [ ] Framing, fragmentation, multiple lines, events, request IDs, errors, EOF, and timeout cases are tested.
  - [ ] Completion and uv-handle cleanup are single-shot and race-safe.
  - [ ] Transport test suite passes.
  - [ ] Real-mpv smoke test performed when available, or explicitly recorded as unavailable.
  - [ ] Commit created with the exact planned subject.

- [ ] **Commit 3 — `feat: implement audio command actions`**
  - [ ] Action grammar and mpv command mapping are implemented and tested.
  - [ ] `:Audio` parses full load paths, validates files and seek amounts, and handles invalid input cleanly.
  - [ ] `:Audio time` formats valid positions and handles unusable data gracefully.
  - [ ] Transport errors become concise user-facing notifications.
  - [ ] Manual command verification is complete when real mpv and test media are available.
  - [ ] Commit created with the exact planned subject.

- [ ] **Commit 4 — `feat: add configurable playback keymaps`**
  - [ ] All default normal-mode mappings are installed with descriptions.
  - [ ] Existing `mapleader` is respected and insert mode is unaffected.
  - [ ] `mappings = false`, socket overrides, and environment socket resolution are verified.
  - [ ] Headless mapping assertions and interactive sanity check pass.
  - [ ] Commit created with the exact planned subject.

- [ ] **Commit 5 — `test: harden playback failure handling`**
  - [ ] Failure, race, cleanup, repeated-request, invalid-command, repeated-setup, and no-position scenarios have regression coverage.
  - [ ] Manual SSH/host-speaker acceptance workflow is performed when available, or its remaining status is recorded honestly.
  - [ ] No obvious uv-handle leak or teardown issue remains.
  - [ ] Commit created with the exact planned subject.

- [ ] **Commit 6 — `docs: document NixOS transcription workflow`**
  - [ ] README documents installation, setup, commands, mappings, NixOS/mpv startup, SSH audio behaviour, security, troubleshooting, tests, and non-MVP features.
  - [ ] Full automated test suite passes from a clean shell.
  - [ ] Final repository inspection shows no generated or unrelated files.
  - [ ] Commit created with the exact planned subject.

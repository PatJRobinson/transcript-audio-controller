# transcript-audio.nvim

`transcript-audio.nvim` is a small, dependency-free Neovim plugin for controlling an independently running, host-local `mpv` player over mpv's Unix-domain JSON IPC socket. It is intended to make plain-text transcript editing convenient, including from an SSH session, while audio continues to play through the host computer's speakers.

The initial scaffold exposes the setup surface; playback commands, mappings, and transport behavior will be added incrementally.

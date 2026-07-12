# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] — 2026-07-11

### Added
- **Doc mode**: a split-terminal markdown drafting workflow inside the Concierge
  window. `doc new "<title>"` seeds `~/Desktop/<title>.md` (spaces preserved) and
  opens a live, neon-themed viewer in a right pane — **without stealing focus**
  from the Claude chat on the left (`split-window -d`). The viewer polls the file
  and, on every save, re-renders a git-diff-style **per-turn diff**: a
  full-context view of the whole document with a right-aligned line-number gutter,
  added lines in green (`+`), removed lines in magenta (`-`), and unchanged lines
  dimmed as context. Reference "line X" to your AI, iterate, then `doc snapshot`
  to advance the turn baseline so the next diff shows only what changed since.
  The file is **not** git-versioned — doc mode snapshots the baseline itself.
  Also `doc open <path>` (draft an existing file), `doc close` (kill the viewer
  pane), and `doc status`. Pure zsh + standard macOS userland (`awk`, `diff`,
  `stat`) — no Python, no watchers, no dependencies. Honors `NO_COLOR`. Installed
  to `~/.local/bin/doc` and `~/.local/bin/doc-view` by `install.sh`.

## [0.3.0] — 2026-07-07

### Added
- **Model + effort in the header**: the status bar now shows the active model
  and reasoning effort level next to the version info (`cc 0.3.0 · claude
  2.1.202 · opus 4.8 · xhigh`). The model is derived from the launch `--model`
  and prettified (`claude-opus-4-8` → `opus 4.8`, trailing date snapshots
  dropped); the effort reads the Claude Code `effortLevel` setting, overridable
  per-launch with `CONCIERGE_EFFORT`. Both are cached as tmux user options and
  refreshed on every window open/reattach, alongside the existing version info.
- Response timestamps: every Claude message is stamped with its arrival time.
  Implemented via Claude Code's native `showMessageTimestamps` setting, ensured
  idempotently by `start.sh` at every launch. (Deliberately not tmux/iTerm-level:
  tmux can't annotate an app's output stream per-message, and iTerm's row
  timestamps reflect tmux redraws rather than message arrival.)

## [0.2.0] — 2026-07-05

### Added
- **`tmux` wrapper**: installs to `~/.local/bin/tmux`, ahead of the real tmux
  on `PATH`. Any tool that spins up its own tmux session/pane (dev-swarm
  orchestrators, ad-hoc dashboards, etc.) now defaults onto the **Concierge
  socket** instead of tmux's own bare "default" socket — unless it's already
  inside a tmux client (`$TMUX` set) or explicitly passes `-L`/`-S`, both of
  which are respected unchanged. This means a plain `Ctrl-b + s` / `j`/`k`
  from any Concierge-attached client shows everything, instead of your
  session list being split across two separate tmux servers. `install.sh`
  now also checks `PATH` *ordering* (not just presence) and tells you the
  exact fix if `~/.local/bin` doesn't come before the real tmux's directory.
- **Version info in the header**: the status-bar now shows the installed
  Concierge version and the running Claude Code version (`cc 0.2.0 · claude
  2.1.201`), read once per window-open (including on reattach, so an upgrade
  since the last window shows up without killing the session) and cached as
  tmux user options rather than shelled out on every status-bar tick.

## [0.1.1] — 2026-06-11

### Fixed
- Mouse wheel no longer leaks arrow keys to full-screen apps, which Claude Code
  flagged as "scroll wheel is sending arrow keys · use PgUp/PgDn to scroll". Both
  wheel directions now forward as a real mouse event when the app grabs the
  mouse, and the alternate-screen fallback sends `PgUp`/`PgDn` instead of arrow
  keys. Also fixes `WheelDownPane` ignoring `mouse_any_flag` (scrolling down
  leaked arrows even while mouse mode was active).

## [0.1.0] — 2026-06-11

Initial release.

### Added
- `concierge` launcher: opens a themed iTerm2 window running Claude Code in a
  dedicated tmux session (own socket + config, isolated from any other tmux).
- Mouse/copy/scroll behavior: `mouse on`, drag-release / double-click /
  triple-click copy to the macOS clipboard with `✓ copied` feedback, guarded
  `pbcopy` (empty selections never clobber the clipboard), smooth wheel
  scrolling, 50k-line scrollback, copy-mode escape hatch.
- Auto-resume: launches with `--continue` so a crash/reboot resumes the last
  conversation; `--new` forces a fresh one.
- Durable, ANSI-stripped, dated pane transcript under
  `~/.claude/concierge-logs/`, auto-pruned after 60 days.
- Neon/synthwave iTerm2 dynamic profile with Monaspace (Nerd Font) ligatures,
  blur, a persistent top banner, and a `CONCIERGE` badge watermark.
- Defaults to the Fable model; honors the Claude Code voice tap-to-send setting.
- `install.sh` (idempotent), local `test/run.sh` (no CI), docs, MIT license.

[0.4.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.4.0
[0.3.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.3.0
[0.2.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.2.0
[0.1.1]: https://github.com/tbaums/claude-concierge/releases/tag/v0.1.1
[0.1.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.1.0

# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.3] — 2026-09-22

### Changed
- **Concierge sessions default to Opus 5.5** (`claude-opus-5-5`) instead of
  Opus 5. `CONCIERGE_MODEL` in `~/.zshenv` still overrides. (#34)

## [0.9.2] — 2026-09-22

### Fixed
- **`concierge snapshot` records the real model and flags for wrapper-launched
  panes.** `claude_cmd()` matched the substring `claude` anywhere in a command
  line, so a pane started via `pane-claude` (or with `claude` in a path or env
  assignment) stopped at the wrapper's `zsh -c` line and recorded an empty model
  and a shell fragment as flags — `restore` would then relaunch every pane on
  the default model. It now matches only a first token of `claude` or
  `*/claude` and descends past wrappers; a wrapper snapshot→restore→snapshot
  regression test covers it. (#32)

## [0.9.1] — 2026-09-22

### Fixed
- **Backup sync is safe to install on a second machine.** The one-time
  `memory/` migration now runs only when the top-level files byte-match this
  machine's memory (`CONCIERGE_BACKUP_MIGRATE=1` overrides), so a second
  machine can no longer relabel the coordinator's memory as its own. `sync.sh`
  refuses to pull or push while a legacy root `sync.sh` (the pre-0.9.0
  `rsync --delete` script) is still in the repo, `concierge backup status`
  flags it, and `install.sh` removes it on the owning machine and prints the
  upgrade order: the machine that owns the single-machine repo first, other
  machines after. (#30)

## [0.9.0] — 2026-09-22

### Added
- **Skills and memory are backed up from every machine.** With
  `CONCIERGE_BACKUP_REPO` set in `~/.zshenv`, `install.sh` renders and loads a
  `com.tbaums.claude-backup` launch agent that runs the shipped
  `config/sync.sh` every 5 minutes: `rsync -aL` (symlinked skills arrive as
  real files, never dangling `120000` links), a shared `skills/` tree, per-host
  `memory/<hostname>/` and `settings/<hostname>/settings.json`, a one-time
  migration of the old single-machine `memory/` layout, `pull --rebase` before
  push, and never `--delete`. Unset the variable and nothing is installed (one
  line says so). `concierge backup status` reports agent state, last-commit
  age and unpushed commits, and flags a repo whose last push is older than
  `CONCIERGE_BACKUP_STALE_MIN` (60). (#26)

### Fixed
- **`snapshot.sh --retire` and its test no longer race.** The manifest is
  re-captured before the retired entry is written, so the retired entry is the
  completion signal, and `test/run.sh` polls for the manifest condition instead
  of asserting once — the "killed session is still in the manifest" flake is
  gone (5/5 back-to-back runs). (#28)

## [0.8.0] — 2026-09-19

### Added
- **Helper sessions come back after a reboot.** `start.sh` recreates static
  helper tmux sessions (a dash grid, a log tailer) from
  `~/.config/claude-concierge/helpers.conf` (`name<TAB>command`) after the main
  session is up: skips sessions already alive, warns and continues on failure,
  never affects exit status; `CONCIERGE_HELPERS=0` opts out. (#7)
- **`concierge snapshot`** captures the live socket into a generated manifest
  (`~/.config/claude-concierge/session-manifest`): every session's cwd, model
  and launch flags read from the pane's process tree, splits, and dash grids
  read back from `pane_tty` → `list-clients`. Nothing is hand-maintained. (#18)
- **`concierge restore [name…] [--dash N] [--list] [--dry-run] [--force]`**
  rebuilds sessions, splits and dashes from the manifest in their recorded
  cwds, so `claude --continue` finds the right conversation. Idempotent by
  name; a vanished cwd is skipped with a warning; dashes wait for member panes
  to be ready (`CONCIERGE_RESTORE_READY_TIMEOUT`, default 60s) and never hang;
  manifests older than `CONCIERGE_RESTORE_MAX_AGE_HOURS` (72) are refused
  unless `--force`. Startup prints a one-line offer when a manifest exists and
  its sessions are absent — nothing launches unasked. (#19)
- **The manifest is captured continuously.** tmux `session-created` /
  `session-closed` hooks trigger a backgrounded snapshot, and the 5s status
  refresh runs `snapshot --quiet --throttle 600` as a backstop. Deliberately
  killed sessions land in a `retired` list and are not resurrected; the last
  five manifests are rotated. (#20)
- **Stable, speakable handles for parts of a response.** A `Stop` hook runs a
  budgeted headless Haiku call over each finished reply and surfaces its
  addressable items as `<turn><letter>` handles (`4a`, `4b`…) in the hook's
  `systemMessage`; a `UserPromptSubmit` hook attaches the last five turns'
  maps so "on 4b, do it the other way" resolves. Per-cwd state survives
  `--continue`; extraction failures never delay the reply;
  `CONCIERGE_HANDLES=0` disables it. (#9)

## [0.7.0] — 2026-09-19

### Added
- **New sessions default to Claude's Concise output style.** `start.sh` seeds
  `"outputStyle": "Concise"` into `~/.claude/settings.json` on a fresh launch via
  a generalised `ensure_setting KEY VALUE seed|force` helper; a value you have
  already set is left alone. (#10)
- **Live model/effort in the status bar.** The header used to be written once at
  launch and went stale on every in-session `/model` or effort change. It now
  reads the live values off the session transcript through the new pure-shell
  `config/status-model.sh`, refreshed from `status-right` every 5s. (#4)

### Fixed
- **`bin/tmux` wrapper no longer exec-loops under a foreign `HOME`.** It
  identified itself by `$HOME/.local/bin/tmux`, so any caller with a different
  `HOME` (sandboxes, CI, launchd agents, `sudo -H`) picked the wrapper itself as
  the "real" tmux and re-exec'd forever, hanging `test/run.sh` and the caller. It
  now resolves its own canonical path (`BASH_SOURCE` via `realpath`, `cd -P`
  fallback) and canonicalises every PATH candidate. (#14)

### Changed
- **`start.sh` no longer needs python3.** The one-shot `showMessageTimestamps`
  edit to `settings.json` is now pure shell (`jq` when present, `grep`/`sed`/`awk`
  fallback), with tests. (#3)

## [0.6.0] — 2026-09-16

### Added
- **Claude in Chrome is enabled by default.** `start.sh` now launches Claude Code
  with `--chrome`, so the Concierge can drive your logged-in Chrome (per-site
  extension permission is still the gate). Worker panes launched via
  `pane-claude` already did this; the coordinator was the one session without it.

### Changed
- **Full width is now the default.** Narrow-display mode used to be hardcoded ON
  (`CONCIERGE_NARROW=1`), injecting a system-prompt instruction that asserted the
  session was "read in a terminal on a small/older iPad (~50 cols)" and asked the
  agent to wrap everything to ~48 characters. On a laptop that threw away most of
  the window. It's now **auto-detected from the launching terminal's width**:
  - unset (default) — **auto**: narrow only below 70 columns;
  - `CONCIERGE_NARROW=1` — force narrow, whatever the width;
  - `CONCIERGE_NARROW=0` — force full width, whatever the width.

  The threshold is overridable with the new `CONCIERGE_NARROW_COLS`. 70 sits
  below every normal desktop width (a stock terminal is 80 columns, the
  Concierge's own iTerm profile opens at 120) and well above the ~40–55 columns a
  tablet SSH client reports. Existing `CONCIERGE_NARROW=0`/`=1` overrides keep
  working unchanged — only the *unset* default moved.
- Width is measured with a real `ioctl` on the controlling terminal
  (`stty size < /dev/tty`), falling back to `tput cols` only once stdout is known
  to be a TTY. Neither is trustworthy alone: with no TTY at all `tput cols` still
  reports terminfo's 80 and zsh sets `COLUMNS=0`, so neither can tell "80 columns
  wide" from "no idea". When the width genuinely can't be determined (cron, a
  pipe, a detached launcher) the Concierge picks **full width** — unknown never
  means narrow.
- The narrow instruction, when it does fire, now describes **the viewport rather
  than asserting a device** ("a narrow viewport (about 44 columns)") and derives
  its wrap target from the measured width instead of a fixed ~48 characters.

### Fixed
- Documented `CONCIERGE_NARROW` for the first time — it shipped in v0.1.x and
  appeared in no README, doc page, or changelog entry, so the only way to
  discover the opt-out was to read `config/start.sh`.
- Named the `~/.zshenv` trap in the docs: `start.sh` runs as a *non-interactive
  login* shell, and zsh reads `~/.zshrc` only for interactive shells, so an
  override exported from `~/.zshrc` is invisible to a normal `concierge` launch
  — yet it *does* reach `concierge --here`, which inherits the interactive
  environment. That asymmetry makes the failure look intermittent. Same trap
  previously hit `CONCIERGE_MODEL`.
- Documented that the mode is a launch argument and therefore fixed for the life
  of the tmux session: re-running `concierge` re-attaches rather than relaunching
  Claude, so a long-lived session keeps whatever width mode it was born with
  until it's actually killed.

## [0.5.0] — 2026-08-03

### Changed
- **Default model is now Opus 5** (`claude-opus-5`), previously Fable 5.
  `CONCIERGE_MODEL=… concierge --here` still overrides it per launch, and the
  status header label follows whatever is launched.

### Fixed
- Docs described the launch `--model` as merely "independent of" your global
  `~/.claude/settings.json` `model` setting. It actually **overrides** it, so
  changing `settings.json` alone never affects what a Concierge window launches
  — a trap worth naming explicitly. Both `docs/configuration.md` and
  `docs/troubleshooting.md` now say so.
- Docs told you to change the default by editing `MODEL=` in
  `~/.config/claude-concierge/start.sh` — the *installed* copy, which
  `install.sh` overwrites on every upgrade, so the change silently disappeared.
  They now point at the repo's `config/start.sh` plus a re-run of `install.sh`.

## [0.4.1] — 2026-07-11

### Fixed
- Fix `doc open` — a `local path` declaration clobbered zsh's special `PATH`
  array, breaking mkdir/cp/awk so the file never opened; renamed to `target` +
  added a regression test exercising `doc open`.

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

[0.9.3]: https://github.com/tbaums/claude-concierge/releases/tag/v0.9.3
[0.9.2]: https://github.com/tbaums/claude-concierge/releases/tag/v0.9.2
[0.9.1]: https://github.com/tbaums/claude-concierge/releases/tag/v0.9.1
[0.9.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.9.0
[0.8.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.8.0
[0.7.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.7.0
[0.6.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.6.0
[0.5.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.5.0
[0.4.1]: https://github.com/tbaums/claude-concierge/releases/tag/v0.4.1
[0.4.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.4.0
[0.3.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.3.0
[0.2.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.2.0
[0.1.1]: https://github.com/tbaums/claude-concierge/releases/tag/v0.1.1
[0.1.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.1.0

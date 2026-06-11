# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.1]: https://github.com/tbaums/claude-concierge/releases/tag/v0.1.1
[0.1.0]: https://github.com/tbaums/claude-concierge/releases/tag/v0.1.0

# Troubleshooting

### `concierge: command not found`
`~/.local/bin` isn't on your `PATH`. Add to `~/.zshrc`:
```sh
export PATH="$HOME/.local/bin:$PATH"
```

### Nothing opens / "Claude Concierge" profile missing
iTerm2 reads dynamic profiles live, but only while running. Make sure iTerm2 is
open, then re-run `bash install.sh` to regenerate the profile. Confirm it exists:
```sh
ls ~/Library/Application\ Support/iTerm2/DynamicProfiles/claude-concierge.json
```

### A pane is stuck in copy-mode / scrolled up
Press `q` or `Esc`. (Selecting text enters copy-mode; this exits it.)

### Copy isn't working
The Concierge copies via `pbcopy` through `clip.sh`, which **intentionally
ignores empty selections**. Select actual text and you'll see a `✓ copied`
flash. Verify the clipboard tool works: `echo hi | pbcopy && pbpaste`.

### Status bar shows boxes instead of icons/separators
Your font lacks the glyphs. Install a Nerd Font and set it:
```sh
CONCIERGE_FONT="MonaspaceNeonNF-Regular 15" bash install.sh
```

### It didn't resume my last conversation
Resume uses Claude Code's transcript for the launch directory
(`~/.claude/projects/<cwd>/*.jsonl`). If you launched from a different directory,
or ran `concierge --new`, there's nothing to continue. The Concierge always
launches from `$HOME` to keep this consistent.

### Reboot killed the session
Expected — the tmux server dies on reboot. Just run `concierge` again; it
relaunches and `--continue` resumes the conversation from disk.

### Wrong model
The Concierge forces `--model claude-opus-5`, which overrides your
`~/.claude/settings.json` `model` — so editing that alone won't help. Override
per-launch with `CONCIERGE_MODEL=… concierge --here`, or edit `MODEL=` in the
repo's `config/start.sh` and re-run `bash install.sh` (editing the installed
`~/.config/claude-concierge/start.sh` doesn't stick — upgrades overwrite it).

### Replies are squeezed into a skinny column on a wide window
The session is in narrow-display mode. Since v0.6.0 that's auto-detected from
the terminal width and off by default above 70 columns — but the mode is a
**launch argument**, fixed for the life of the tmux session, and re-running
`concierge` only re-attaches. A session created before v0.6.0 (or in a narrow
window) keeps its narrow instruction until it actually ends: `Ctrl-b`
`:kill-session`, or `exit` out of the pane, then run `concierge` again.
`--continue` picks the conversation right back up.

If it comes back on a wide terminal, check for a stale override:
```sh
grep -rn CONCIERGE_NARROW ~/.zshenv ~/.zprofile ~/.zshrc
```
Note that setting `CONCIERGE_NARROW` in `~/.zshrc` does **not** reach a normal
`concierge` launch (non-interactive login shell — zsh skips `~/.zshrc`), but
*does* reach `concierge --here`, which makes it look intermittent. Use
`~/.zshenv`. See [`configuration.md`](configuration.md).

### Logs growing
Pane transcripts live in `~/.claude/concierge-logs/` and auto-prune after 60
days. Delete them anytime; nothing depends on them for resume.

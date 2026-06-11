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
The Concierge forces `--model claude-fable-5`. Override per-launch with
`CONCIERGE_MODEL=… concierge --here`, or edit `MODEL=` in `start.sh`.

### Logs growing
Pane transcripts live in `~/.claude/concierge-logs/` and auto-prune after 60
days. Delete them anytime; nothing depends on them for resume.

# Configuration

Everything the Concierge installs lives in three places:

| Path | What |
|------|------|
| `~/.config/claude-concierge/` | `tmux.conf`, `start.sh`, `clip.sh`, `logsink.sh` |
| `~/.local/bin/concierge` | the launcher you invoke |
| `~/Library/Application Support/iTerm2/DynamicProfiles/claude-concierge.json` | the themed iTerm2 profile |

## The model (defaults to Fable)

The Concierge launches Claude with `--model claude-fable-5`, independent of your
global `~/.claude/settings.json` `model` setting (so your other Claude sessions
keep whatever default you've chosen).

Override per-launch with an env var:

```sh
CONCIERGE_MODEL=claude-opus-4-8 concierge --here
```

Or change the default permanently by editing `MODEL=` in
`~/.config/claude-concierge/start.sh`.

## Voice tap-to-send

Voice is a Claude Code setting, not a Concierge one. It comes from
`~/.claude/settings.json`:

```json
{
  "voice": { "enabled": true, "mode": "tap" }
}
```

Because it's global, it applies inside the Concierge window automatically.

## Auto-resume vs. fresh

- `concierge` resumes your last conversation (`claude --continue`).
- `concierge --new` starts fresh (drops a one-shot sentinel that `start.sh`
  consumes on next launch).
- Inside Claude, `/clear` also starts a clean context without closing the
  window.

Resume relies on Claude Code's own transcript at
`~/.claude/projects/<cwd>/*.jsonl`. The Concierge always launches from your home
directory so the same transcript is found every time.

## Scrollback & logging

- tmux scrollback: `history-limit 50000` (plus iTerm "Unlimited Scrollback").
- Pane transcript: `~/.claude/concierge-logs/YYYY-MM-DD.log`, ANSI-stripped,
  auto-pruned after 60 days (`find -mtime +60 -delete` on launch). Change the
  retention window in `start.sh`.

## Running without the themed window

`concierge --here` runs the tmux+Claude session in your current terminal — no
new iTerm window, no profile theming. Useful over SSH or in a plain shell.

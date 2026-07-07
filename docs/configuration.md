# Configuration

Everything the Concierge installs lives in three places:

| Path | What |
|------|------|
| `~/.config/claude-concierge/` | `tmux.conf`, `start.sh`, `clip.sh`, `logsink.sh`, `VERSION` |
| `~/.local/bin/concierge` | the launcher you invoke |
| `~/.local/bin/tmux` | wrapper that defaults new tmux sessions onto the Concierge socket |
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

## Effort level

The status header also shows the reasoning **effort level** next to the model
(e.g. `opus 4.8 · xhigh`). By default this reflects the Claude Code
`effortLevel` in `~/.claude/settings.json`. Override the *displayed* label
per-launch with an env var:

```sh
CONCIERGE_EFFORT=high concierge --here
```

If neither is set it shows `default`.

## Status header

The top-right of the status bar shows, at a glance, what's running:

```
cc 0.2.0 · claude 2.1.202   opus 4.8 · xhigh   Tue 3:14 PM
```

— the Concierge version, the Claude Code version, then the active model and
effort level. These are read fresh each time a window opens or reattaches, so a
model/effort/version change shows up without killing the session.

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

## Default tmux socket for other tools

`install.sh` installs a `tmux` wrapper to `~/.local/bin/tmux`, ahead of the
real tmux on `PATH`. Any tool that spins up its own tmux session (a dev-swarm
orchestrator, an ad-hoc dashboard, etc.) now defaults onto the **Concierge
socket** — so `Ctrl-b + s` / `j`/`k` from any Concierge-attached client shows
all of it, not just the Concierge session itself.

The wrapper only overrides the *bare* case:

- Already inside a tmux client (`$TMUX` set)? Passed through unchanged — tmux's
  own default already resolves to that session's socket.
- Caller explicitly passed `-L <name>` or `-S <path>`? Respected unchanged —
  this is the "unless otherwise specified" opt-out.
- Otherwise, `-L concierge` is injected.

This requires `~/.local/bin` to come **before** the real tmux's directory on
`PATH` (usually `/opt/homebrew/bin`) — `install.sh` checks the actual PATH
*order*, not just whether `~/.local/bin` is present, and prints the exact
line to prepend in `~/.zshrc` if it isn't. Prepend, not append:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

To bypass the wrapper for one call, invoke the real tmux by its absolute path.

## Running without the themed window

`concierge --here` runs the tmux+Claude session in your current terminal — no
new iTerm window, no profile theming. Useful over SSH or in a plain shell.

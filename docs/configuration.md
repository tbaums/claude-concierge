# Configuration

Everything the Concierge installs lives in three places:

| Path | What |
|------|------|
| `~/.config/claude-concierge/` | `tmux.conf`, `start.sh`, `clip.sh`, `logsink.sh`, `VERSION` |
| `~/.local/bin/concierge` | the launcher you invoke |
| `~/.local/bin/tmux` | wrapper that defaults new tmux sessions onto the Concierge socket |
| `~/Library/Application Support/iTerm2/DynamicProfiles/claude-concierge.json` | the themed iTerm2 profile |

## The model (defaults to Opus 5)

The Concierge launches Claude with `--model claude-opus-5`, independent of your
global `~/.claude/settings.json` `model` setting (so your other Claude sessions
keep whatever default you've chosen). Note the direction of that independence:
the explicit `--model` flag **overrides** `settings.json`, so changing
`settings.json` alone will not change what a Concierge window launches.

Override per-launch with an env var:

```sh
CONCIERGE_MODEL=claude-fable-5 concierge --here
```

Or change the default permanently by editing `MODEL=` in the repo's
`config/start.sh` and re-running `bash install.sh`. Edit the repo copy, not the
installed `~/.config/claude-concierge/start.sh` — `install.sh` overwrites that
one on every upgrade, so changes made there are silently lost.

## Effort level

The status header also shows the reasoning **effort level** next to the model
(e.g. `opus 4.8 · xhigh`). Once the session has taken a turn this is the effort
that turn actually ran at, re-read live from the transcript. Until then it's the
launch-time label: the Claude Code `effortLevel` in `~/.claude/settings.json`,
which you can override per-launch with an env var:

```sh
CONCIERGE_EFFORT=high concierge --here
```

If neither is set it shows `default`.

## Output width (narrow-display mode)

By default the Concierge uses **the full width of your terminal**. It measures
the launching terminal and only when that terminal is genuinely narrow does it
append a system-prompt instruction asking the agent to keep its output narrow
(short lines, no wide tables, wrapped shell commands) — which is what you want
when you're reading the session on a tablet or a small SSH client, and very much
not what you want on a laptop.

| `CONCIERGE_NARROW` | Behavior |
|---|---|
| unset (default) | **auto** — narrow only below the column threshold |
| `1` | force narrow, whatever the terminal width |
| `0` | force full width, whatever the terminal width |

The threshold is **70 columns**, overridable with `CONCIERGE_NARROW_COLS`. A
stock terminal is 80 columns wide and the Concierge's own iTerm profile opens at
120, so 70 sits below every normal desktop width while staying well above the
~40–55 columns a tablet SSH client reports.

If the width can't be determined at all (no TTY — launched from cron, a pipe, a
detached launcher), the Concierge chooses **full width**. Unknown never means
narrow.

```sh
CONCIERGE_NARROW=1 concierge --here      # force narrow for this launch
CONCIERGE_NARROW_COLS=60 concierge --here  # only go narrow under 60 columns
```

### Setting it persistently: `~/.zshenv`, not `~/.zshrc`

To make an override stick, export it from **`~/.zshenv`**:

```sh
echo 'export CONCIERGE_NARROW=1' >> ~/.zshenv
```

`~/.zshrc` will *appear* to work and then silently fail. `start.sh` runs as a
non-interactive login shell (`#!/bin/zsh -l`), and zsh reads `~/.zshrc` only for
**interactive** shells — so when iTerm launches `start.sh` as its profile
command, a `~/.zshrc` export is invisible. It does reach `concierge --here`,
which inherits your interactive shell's environment. Same trap as
`CONCIERGE_MODEL`. `~/.zshenv` is read in every case.

### It only applies to a *new* session

The instruction is a launch argument to `claude`, so it's fixed for the life of
the tmux session. Re-running `concierge` while a session is alive just
re-attaches — it does not relaunch Claude, so a changed `CONCIERGE_NARROW` has
no effect until the session actually ends (`Ctrl-b` `:kill-session`, `exit` out
of the pane, or a reboot). A long-lived session keeps whatever width mode it was
born with.

## Status header

The top-right of the status bar shows, at a glance, what's running:

```
cc 0.2.0 · claude 2.1.202   opus 4.8 · xhigh   Tue 3:14 PM
```

— the Concierge version, the Claude Code version, then the active model and
effort level.

The versions are read fresh each time a window opens or reattaches. The **model
and effort are live**: every status refresh (5s) `config/status-model.sh` reads
the model and effort off the most recent turn in the session's own transcript,
so switching models in-session with `/model` shows up in the header within one
tick — no reattach, no restart. Before the first turn of a fresh session there's
nothing to read yet, so the header shows the launch-time model/effort until then.

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

## Claude in Chrome

`start.sh` launches with `--chrome`, so Claude Code's Chrome integration is on
in the Concierge window by default. Two things still gate it: the tab has to be
open in your Chrome, and the extension needs per-site permission the first time
it touches a domain. To launch without it, remove `--chrome` from the `RUN=`
line in `~/.config/claude-concierge/start.sh`.

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

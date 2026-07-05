#!/bin/zsh -l
# ───────────────────────────────────────────────────────────────────────────
#  Inner launcher — what runs *inside* the Claude Concierge window.
#  Starts (or re-attaches to) a dedicated tmux server running Claude Code,
#  auto-resuming the previous conversation so a crash/reboot picks up exactly
#  where you left off. Uses its own socket (-L concierge) + config, so it never
#  touches any other tmux setup.
# ───────────────────────────────────────────────────────────────────────────
set -e

CFG="$HOME/.config/claude-concierge"
CONF="$CFG/tmux.conf"
SOCK="concierge"
SESSION="concierge"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
MODEL="${CONCIERGE_MODEL:-claude-fable-5}"         # default to Fable
WORKDIR="$HOME"                                    # cwd Claude keys its transcript on
LOGDIR="$HOME/.claude/concierge-logs"
FRESH_SENTINEL="$CFG/.start-fresh"

cd "$WORKDIR"

# Where Claude Code stores this dir's structured transcript (path-sanitised cwd).
PROJ="$HOME/.claude/projects/$(printf '%s' "$WORKDIR" | sed 's#[/.]#-#g')"

T() { tmux -L "$SOCK" "$@"; }

# Version info for the status-bar header — read fresh on every window open
# (cheap: one `cat` + one `claude --version` call, not per status-bar tick)
# and cached as tmux user options; tmux.conf's status-right reads them via
# #{@concierge_version} / #{@claude_version}. Refreshed on reattach too, so
# an upgrade since the last window open shows up without killing the session.
set_version_opts() {
  local cc_version claude_version
  cc_version="$(cat "$CFG/VERSION" 2>/dev/null || echo '?')"
  claude_version="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"
  T set-option -t "$SESSION" @concierge_version "$cc_version"
  T set-option -t "$SESSION" @claude_version "${claude_version:-?}"
}

# Re-attach if a concierge session is already alive (survives window close).
if T has-session -t "$SESSION" 2>/dev/null; then
  set_version_opts
  exec env TMUX= tmux -L "$SOCK" attach -t "$SESSION"
fi

# Decide: resume the previous conversation, or start fresh?
#   - `concierge --new` drops a sentinel to force a fresh conversation.
#   - otherwise, if Claude has a stored transcript for this dir, --continue it.
CONT=""
if [[ -f "$FRESH_SENTINEL" ]]; then
  rm -f "$FRESH_SENTINEL"
elif ls "$PROJ"/*.jsonl >/dev/null 2>&1; then
  CONT="--continue"
fi

# Default the concierge to Fable (your global default model is left untouched).
# Voice tap-to-send comes from ~/.claude/settings.json ("voice".mode = "tap").

# Narrow-display mode (default ON): the concierge is usually read in a terminal
# on a small/older iPad, where wide output runs off-screen. Inject a formatting
# instruction so the agent keeps replies narrow. Opt out with CONCIERGE_NARROW=0.
NARROW="${CONCIERGE_NARROW:-1}"
NARROW_FLAG=""
if [ "$NARROW" = "1" ]; then
  NARROW_TEXT="DISPLAY: this session is read in a terminal on a small/older iPad (narrow viewport, ~50 cols). Keep ALL output narrow: short lines (wrap prose by ~48 chars), no wide tables or box-drawing, break long shell commands across lines with backslashes, prefer short vertical bullet lists over wide rows, and do not dump long/wide code or log blocks (show only the few relevant lines). Be terse and scannable."
  NARROW_FLAG="--append-system-prompt $(printf '%q' "$NARROW_TEXT")"
fi

# If Claude exits, fall back to an interactive shell so the window persists.
RUN="$CLAUDE $CONT --model $MODEL --dangerously-skip-permissions $NARROW_FLAG; exec \$SHELL"

T -f "$CONF" new-session -d -s "$SESSION" "$RUN"
set_version_opts

# Durable raw-pane transcript (ANSI-stripped, dated). -o appends. Prune logs
# older than 60 days so this stays bounded for months without attention.
mkdir -p "$LOGDIR"
find "$LOGDIR" -name '*.log' -type f -mtime +60 -delete 2>/dev/null || true
T pipe-pane -o -t "$SESSION" "exec '$CFG/logsink.sh'"

exec env TMUX= tmux -L "$SOCK" attach -t "$SESSION"

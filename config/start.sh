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
MODEL="${CONCIERGE_MODEL:-claude-opus-5}"          # default to Opus 5
WORKDIR="$HOME"                                    # cwd Claude keys its transcript on
LOGDIR="$HOME/.claude/concierge-logs"
FRESH_SENTINEL="$CFG/.start-fresh"

cd "$WORKDIR"

# Where Claude Code stores this dir's structured transcript (path-sanitised cwd).
PROJ="$HOME/.claude/projects/$(printf '%s' "$WORKDIR" | sed 's#[/.]#-#g')"

T() { tmux -L "$SOCK" "$@"; }

# Turn a model id into a friendly status-bar label:
#   claude-fable-5          -> fable 5
#   claude-opus-4-8         -> opus 4.8
#   claude-haiku-4-5-2025.. -> haiku 4.5   (trailing date snapshot dropped)
pretty_model() {
  local id="${1#claude-}"                    # drop the claude- prefix
  id="$(printf '%s' "$id" | sed -E 's/-[0-9]{8}$//')"  # drop -YYYYMMDD snapshot
  local family="${id%%-*}"                    # first token is the family
  local rest="${id#"$family"}"                # remaining -x-y version tokens
  rest="${rest#-}"                            # trim leading dash
  if [ -n "$rest" ]; then
    printf '%s %s' "$family" "$(printf '%s' "$rest" | tr '-' '.')"
  else
    printf '%s' "$family"
  fi
}

# The effort level the running session uses: CONCIERGE_EFFORT wins, else the
# Claude Code `effortLevel` setting, else a neutral label.
resolve_effort() {
  if [ -n "$CONCIERGE_EFFORT" ]; then
    printf '%s' "$CONCIERGE_EFFORT"
    return
  fi
  local e
  e="$(grep -oE '"effortLevel"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$HOME/.claude/settings.json" 2>/dev/null | head -1 \
        | sed -E 's/.*"([^"]*)"$/\1/')"
  printf '%s' "${e:-default}"
}

# Version info for the status-bar header — read fresh on every window open
# (cheap: one `cat` + one `claude --version` call, not per status-bar tick)
# and cached as tmux user options; tmux.conf's status-right reads them via
# #{@concierge_version} / #{@claude_version} / #{@concierge_model} /
# #{@concierge_effort}. Refreshed on reattach too, so an upgrade (or a model/
# effort change) since the last window open shows up without killing the session.
set_version_opts() {
  local cc_version claude_version
  cc_version="$(cat "$CFG/VERSION" 2>/dev/null || echo '?')"
  claude_version="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"
  T set-option -t "$SESSION" @concierge_version "$cc_version"
  T set-option -t "$SESSION" @claude_version "${claude_version:-?}"
  T set-option -t "$SESSION" @concierge_model "$(pretty_model "$MODEL")"
  T set-option -t "$SESSION" @concierge_effort "$(resolve_effort)"
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

# Timestamp every Claude response. This must live at the Claude level:
# tmux can't annotate an app's output stream per-message, and iTerm's row
# timestamps (⌘⇧E) reflect tmux redraws, not when a message actually arrived.
# Claude Code has a native setting for it — ensure it idempotently (only
# rewrites the file when the key isn't already true).
python3 - <<'PY' 2>/dev/null || true
import json, os
p = os.path.expanduser("~/.claude/settings.json")
try:
    with open(p) as f:
        s = json.load(f)
except Exception:
    s = {}
if s.get("showMessageTimestamps") is not True:
    s["showMessageTimestamps"] = True
    with open(p, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
PY

# Default the concierge to Fable (your global default model is left untouched).
# Voice tap-to-send comes from ~/.claude/settings.json ("voice".mode = "tap").

# ── Narrow-display mode (auto-detected; default is FULL WIDTH) ─────────────
# Wide output is the right default: use however many columns the terminal
# actually has. Only when the launching terminal is genuinely narrow (reading
# the session on a tablet or a small SSH client) do we inject a formatting
# instruction telling the agent to keep its output narrow.
#
#   CONCIERGE_NARROW=1   force narrow, whatever the width
#   CONCIERGE_NARROW=0   force full width, whatever the width
#   unset                auto — narrow only below CONCIERGE_NARROW_COLS columns
#
# Threshold: 70. A plain terminal defaults to 80 columns and the Concierge's own
# iTerm profile opens at 120, so 70 sits below every normal desktop width (a
# stock 80-col window is never mistaken for narrow) while staying well above the
# ~40–55 columns a tablet SSH client reports.
#
# NOTE: to set CONCIERGE_NARROW persistently it must be exported from
# ~/.zshenv, NOT ~/.zshrc. This script's shebang is a *non-interactive login*
# zsh, and zsh reads ~/.zshrc only for interactive shells — so a ~/.zshrc export
# is invisible here when iTerm launches start.sh as its profile command, yet it
# does reach `concierge --here` (which inherits your interactive shell's env).
# That split is what makes the failure look intermittent.
NARROW_COLS="${CONCIERGE_NARROW_COLS:-70}"

# Columns of the terminal that launched us, or "" when we genuinely can't tell
# (no TTY: cron, a pipe, a detached launcher). Deliberately does NOT trust
# `tput cols` or $COLUMNS on their own — with no TTY at all `tput cols` still
# reports terminfo's 80 and zsh sets COLUMNS=0, so neither can distinguish
# "80 columns wide" from "no idea". A real ioctl on the tty is the only honest
# answer; tput is a fallback only once we know stdout IS a tty.
term_cols() {
  local c
  # 2>/dev/null must come FIRST: redirections apply left to right, and with no
  # controlling terminal it's the `< /dev/tty` redirection itself that fails, so
  # the shell prints "/dev/tty: Device not configured" unless stderr is already
  # silenced by the time it's attempted.
  c="$(stty size 2>/dev/null < /dev/tty | awk '{print $2}')"
  if [ -z "$c" ] && [ -t 1 ]; then
    c="$(tput cols 2>/dev/null)"
  fi
  printf '%s' "$c"
}

# Should the narrow instruction be injected? Pure decision, no I/O, so it can be
# tested directly: $1 = CONCIERGE_NARROW ("" = auto), $2 = measured columns
# ("" / non-numeric / 0 = unknown), $3 = threshold. Prints 1 (narrow) or 0.
# Unknown width must never mean narrow — full width is what we want when in doubt.
want_narrow() {
  case "$1" in
    1) printf '1'; return ;;
    0) printf '0'; return ;;
  esac
  case "$2" in
    ''|*[!0-9]*) printf '0'; return ;;
  esac
  if [ "$2" -gt 0 ] && [ "$2" -lt "$3" ]; then printf '1'; else printf '0'; fi
}

COLS="$(term_cols)"
NARROW_FLAG=""
if [ "$(want_narrow "${CONCIERGE_NARROW-}" "$COLS" "$NARROW_COLS")" = "1" ]; then
  # Describe the viewport, don't assert a device. Quote the measured width only
  # when it really is narrow — with CONCIERGE_NARROW=1 forced on a wide terminal
  # (creating a session you'll read from a small screen later) the measurement is
  # exactly what the user is overriding, so fall back to a generic description.
  WRAP=48
  WIDTH_DESC="a narrow viewport (roughly 50 columns)"
  if [ -n "$COLS" ] && [ "$COLS" -gt 12 ] && [ "$COLS" -lt "$NARROW_COLS" ]; then
    WRAP=$((COLS - 2))
    WIDTH_DESC="a narrow viewport (about $COLS columns)"
  fi
  NARROW_TEXT="DISPLAY: this session is being read in $WIDTH_DESC, where wide output runs off-screen. Keep ALL output narrow: short lines (wrap prose by ~$WRAP chars), no wide tables or box-drawing, break long shell commands across lines with backslashes, prefer short vertical bullet lists over wide rows, and do not dump long/wide code or log blocks (show only the few relevant lines). Be terse and scannable."
  NARROW_FLAG="--append-system-prompt $(printf '%q' "$NARROW_TEXT")"
fi

# If Claude exits, fall back to an interactive shell so the window persists.
RUN="$CLAUDE $CONT --model $MODEL --dangerously-skip-permissions --chrome $NARROW_FLAG; exec \$SHELL"

T -f "$CONF" new-session -d -s "$SESSION" "$RUN"
set_version_opts

# Durable raw-pane transcript (ANSI-stripped, dated). -o appends. Prune logs
# older than 60 days so this stays bounded for months without attention.
mkdir -p "$LOGDIR"
find "$LOGDIR" -name '*.log' -type f -mtime +60 -delete 2>/dev/null || true
T pipe-pane -o -t "$SESSION" "exec '$CFG/logsink.sh'"

exec env TMUX= tmux -L "$SOCK" attach -t "$SESSION"

#!/bin/sh
# ───────────────────────────────────────────────────────────────────────────
#  Live "model · effort" segment for the status bar.
#
#  tmux.conf calls this from status-right's #(...), so tmux re-runs it every
#  status-interval (5s). It prints what the session is ACTUALLY running right
#  now, not what it was launched with: an in-session /model switch used to
#  leave the header showing the launch-time label forever.
#
#  The signal is already on disk — Claude Code appends every turn to the
#  session transcript, and each `"type":"assistant"` line carries that turn's
#  `message.model` and top-level `effort`. So: newest transcript in the (fixed)
#  project dir, bounded tail of it, last assistant line, two greps. No hook, no
#  interpreter, no unbounded read however large the transcript grows.
#
#  Fallback, used when there's no usable line yet (fresh launch, first turn not
#  sent) or the last one is torn mid-write: the @concierge_model /
#  @concierge_effort session options — seeded by start.sh at launch and
#  refreshed here, so they always hold the last value actually displayed.
#
#    usage: status-model.sh [session-name]     (default: concierge)
# ───────────────────────────────────────────────────────────────────────────
set -u

CFG="$HOME/.config/claude-concierge"
LIB="$CFG/model-label.sh"
[ -f "$LIB" ] || LIB="$(dirname "$0")/model-label.sh"   # running from a checkout
# shellcheck disable=SC1090
. "$LIB"

# tmux expands #{session_name} into our argv. If a tmux old enough not to do
# that ever ships it through literally, ignore it rather than print nonsense.
SESSION="concierge"
if [ $# -gt 0 ]; then
  SESSION="$*"                       # joined: session names may contain spaces
  case "$SESSION" in ''|*'#{'*) SESSION="concierge" ;; esac
fi

# start.sh always runs Claude with WORKDIR="$HOME", so the transcript project
# dir is this one fixed path — no session discovery needed.
PROJ="$HOME/.claude/projects/$(printf '%s' "$HOME" | sed 's#[/.]#-#g')"
TAIL_BYTES="${CONCIERGE_STATUS_TAIL:-65536}"

opt() { tmux show-options -qv -t "$SESSION" "$1" 2>/dev/null; }
field() {  # $1 = key, $2 = line — first top-level match wins (escaped
  # occurrences inside message text read as \"key\", so they can't match)
  printf '%s' "$2" \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 | sed -E 's/.*"([^"]*)"$/\1/'
}

# Backstop capture of the working set. This tick already runs every 5s, so the
# manifest gets refreshed without a launchd agent or a second timer: --throttle
# makes all but one call in ten minutes a single stat. Errors stay here — a
# failed capture must never reach the status bar.
[ -x "$CFG/snapshot.sh" ] && "$CFG/snapshot.sh" --quiet \
  --throttle "${CONCIERGE_SNAPSHOT_THROTTLE:-600}" >/dev/null 2>&1

prev_model="$(opt @concierge_model)"
prev_effort="$(opt @concierge_effort)"

# Newest transcript = the one this session is actively appending to.
newest="$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)"

# A torn final line is simply skipped: `"type":"assistant"` is written near the
# END of the line, so a half-flushed one can't match and the previous complete
# turn is used instead.
line=""
[ -n "$newest" ] && line="$(tail -c "$TAIL_BYTES" "$newest" 2>/dev/null \
  | grep '"type":"assistant"' | tail -1)"

model=""
[ -n "$line" ] && model="$(field model "$line")"

if [ -n "$model" ]; then
  label="$(pretty_model "$model")"
  effort="$(field effort "$line")"
  effort="${effort:-default}"          # same neutral label as resolve_effort()
  # Remember what we're showing, so the next tick has something honest to fall
  # back on. Only on change — no point poking the server every 5 seconds.
  [ "$label" = "$prev_model" ] || tmux set-option -t "$SESSION" \
    @concierge_model "$label" 2>/dev/null || true
  [ "$effort" = "$prev_effort" ] || tmux set-option -t "$SESSION" \
    @concierge_effort "$effort" 2>/dev/null || true
else
  label="$prev_model"                  # launch-time value, or last displayed
  effort="$prev_effort"
fi

if [ -n "$label" ] && [ -n "$effort" ]; then
  printf '%s · %s\n' "$label" "$effort"
else
  printf '%s%s\n' "$label" "$effort"   # at most one of them is set
fi

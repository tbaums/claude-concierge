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
HELPERS_CONF="$CFG/helpers.conf"                   # optional: see run_helpers()

cd "$WORKDIR"

# Where Claude Code stores this dir's structured transcript (path-sanitised cwd).
PROJ="$HOME/.claude/projects/$(printf '%s' "$WORKDIR" | sed 's#[/.]#-#g')"

T() { tmux -L "$SOCK" "$@"; }

# pretty_model() — shared with config/status-model.sh, which formats the same
# ids live on every status-bar tick. Installed alongside us; fall back to our
# own directory when running straight out of a checkout.
LIB="$CFG/model-label.sh"
[ -f "$LIB" ] || LIB="${0:A:h}/model-label.sh"
. "$LIB"

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
# and cached as tmux user options; tmux.conf's status-right reads the versions
# via #{@concierge_version} / #{@claude_version}. Refreshed on reattach too, so
# an upgrade since the last window open shows up without killing the session.
#
# @concierge_model / @concierge_effort are seeded here too, but they're no
# longer what the header displays: status-model.sh reads the live model/effort
# off the transcript every tick and only falls back to these when there's no
# assistant turn to read yet. Seeding them is what makes a fresh launch show
# the launch-time label instead of a blank segment.
set_version_opts() {
  local cc_version claude_version
  cc_version="$(cat "$CFG/VERSION" 2>/dev/null || echo '?')"
  claude_version="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"
  T set-option -t "$SESSION" @concierge_version "$cc_version"
  T set-option -t "$SESSION" @claude_version "${claude_version:-?}"
  T set-option -t "$SESSION" @concierge_model "$(pretty_model "$MODEL")"
  T set-option -t "$SESSION" @concierge_effort "$(resolve_effort)"
}

# Helper sessions — the static utility sessions you want back after a reboot
# (a dashboard grid, a log tailer, a status board). The main concierge session
# auto-resumes; these used to just vanish, with nothing to say they were gone.
#
# $CFG/helpers.conf, one per line, `name<TAB>command`; blank lines and #
# comments ignored. Split on the FIRST tab only, so a command keeps its own
# spacing verbatim:
#
#   # name  command
#   dash    dash --cols 3 chord-a chord-b
#   logs    tail -F ~/.claude/concierge-logs/today.log
#
# Rules: an existing session of that name is left strictly alone (tmux has no
# "dead session" state — existing is the whole check, and we never kill or
# recreate), a helper that won't start prints one warning and the rest carry
# on, and nothing here can change this script's exit status or hold up the
# main session. CONCIERGE_HELPERS=0 skips the step; no file at all is silent.
run_helpers() {
  if [ "${CONCIERGE_HELPERS:-1}" = 0 ]; then return 0; fi
  if [ ! -f "$HELPERS_CONF" ]; then return 0; fi

  local created=0 skipped=0 failed=0 n=0
  local line stripped name cmd
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    stripped="${line//[[:space:]]/}"
    case "$stripped" in ''|'#'*) continue ;; esac     # blank or comment
    name="${line%%$'\t'*}"
    cmd="${line#*$'\t'}"
    if [ "$name" = "$line" ] || [ -z "$name" ] || [ -z "$cmd" ]; then
      printf 'concierge: helpers.conf line %d: expected "name<TAB>command"\n' "$n" >&2
      failed=$((failed + 1))
      continue
    fi
    if T has-session -t "$name" 2>/dev/null; then     # includes "concierge"
      skipped=$((skipped + 1))
      continue
    fi
    # tmux forks before it discovers a command doesn't exist, so `new-session`
    # returns 0 either way and whether the dead session has been reaped by the
    # time we look is a race. Settle the common case up front: if the command
    # starts with a plain binary name that isn't on PATH, it was never going to
    # run. Anything shell-ish (a pipeline, VAR=x prefixes, ~ or $ to expand) is
    # left for tmux to try.
    local first="${cmd%%[[:space:]]*}"
    case "$first" in *=*|*'$'*|*'~'*|*'('*|*'`'*) first="" ;; esac
    if [ -n "$first" ] && ! command -v "$first" >/dev/null 2>&1; then
      printf 'concierge: helper "%s" failed to start (no such command: %s)\n' \
        "$name" "$first" >&2
      failed=$((failed + 1))
      continue
    fi
    # Then create it and check it's still there — a helper that died on the
    # spot left no session behind, and that's a failure too.
    if T new-session -d -s "$name" "$cmd" 2>/dev/null \
       && T has-session -t "$name" 2>/dev/null; then
      created=$((created + 1))
    else
      printf 'concierge: helper "%s" failed to start\n' "$name" >&2
      failed=$((failed + 1))
    fi
  done < "$HELPERS_CONF"

  if [ $((created + skipped + failed)) -gt 0 ]; then
    printf 'concierge: helpers — %d created, %d skipped, %d failed\n' \
      "$created" "$skipped" "$failed"
  fi
  return 0
}

# One line, once, when there's a working set on disk that isn't running. The
# manifest (`concierge snapshot`) is never restored for you — twenty Claude
# sessions at boot is a lot of processes and tokens for sessions you may not
# want today — so this only points at the command.
offer_restore() {
  local manifest="${CONCIERGE_MANIFEST:-$CFG/session-manifest}"
  [ -f "$manifest" ] || return 0
  local name absent=0
  for name in $(grep '^SESSION|' "$manifest" 2>/dev/null | cut -d'|' -f2); do
    if ! T has-session -t "$name" 2>/dev/null; then absent=$((absent + 1)); fi
  done
  if [ "$absent" -gt 0 ]; then
    printf 'concierge: %d session(s) from your last snapshot are not running — `concierge restore` brings them back\n' "$absent"
  fi
  return 0
}

# Re-attach if a concierge session is already alive (survives window close).
if T has-session -t "$SESSION" 2>/dev/null; then
  set_version_opts
  run_helpers
  offer_restore
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

# Claude Code settings the concierge wants in place before the session starts.
# Both live in ~/.claude/settings.json; this runs on the fresh-launch path only
# (the reattach above already exec'd), so a live session is never rewritten
# under itself.
#
# Two modes, deliberately different:
#
#   force — the concierge owns this setting and re-asserts it every launch.
#           `showMessageTimestamps` must live at the Claude level: tmux can't
#           annotate an app's output stream per-message, and iTerm's row
#           timestamps (⌘⇧E) reflect tmux redraws, not when a message actually
#           arrived.
#   seed  — a default, only applied when the key is absent (or null/empty).
#           `outputStyle` is a native, persistent user preference: running
#           `/output-style <name>` writes back to this same file. Concise suits
#           the concierge's dictation-first, read-it-on-a-phone workflow, so we
#           supply it out of the box — but once you've picked your own style the
#           next launch must not fight you for it.
#
# Pure shell, no interpreter: the launch path depends only on zsh + the standard
# macOS userland. `jq` is used *opportunistically* when it happens to be on PATH
# (robust against any JSON shape); otherwise a best-effort grep/sed/awk tweak
# handles the flat, human-edited object settings.json is in practice. Anything
# unexpected (malformed JSON, unwritable file) returns non-zero and leaves the
# file alone — the caller swallows it so a failure never blocks launch.
ensure_setting() {                  # $1 = key, $2 = JSON value, $3 = force|seed
  local key="$1" val="$2" mode="$3"
  local f="$HOME/.claude/settings.json"
  local dir="${f%/*}"
  local tmp="$f.concierge.$$"
  local minimal
  minimal="$(printf '{\n  "%s": %s\n}' "$key" "$val")"

  [ -d "$dir" ] || mkdir -p "$dir" || return 1

  if command -v jq >/dev/null 2>&1; then
    # Missing or zero-byte: nothing to preserve, write the minimal object.
    [ -s "$f" ] || { printf '%s\n' "$minimal" > "$f"; return; }
    if [ "$mode" = seed ]; then
      # Any real value already there is the user's — leave the file alone.
      jq -e --arg k "$key" 'has($k) and .[$k] != null and .[$k] != ""' \
        "$f" >/dev/null 2>&1 && return 0
    else
      # Already the wanted value → byte-for-byte no-op (never reformat a file).
      jq -e --arg k "$key" --argjson v "$val" '.[$k] == $v' \
        "$f" >/dev/null 2>&1 && return 0
    fi
    jq --arg k "$key" --argjson v "$val" '.[$k] = $v' "$f" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$f" && return 0
    rm -f "$tmp"                      # malformed JSON: leave the file untouched
    return 1
  fi

  # ── Fallback: no jq ───────────────────────────────────────────────────────
  # Every pattern anchors on the 2-space top-level indent, so a same-named key
  # nested inside another object can't produce a false match. The keys and
  # values we pass are plain literals, with no regex metacharacters to escape.
  [ -s "$f" ] || { printf '%s\n' "$minimal" > "$f"; return; }
  local squashed
  squashed="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
  case "$squashed" in
    ''|'{}') printf '%s\n' "$minimal" > "$f"; return ;;  # blank / empty object
    '{'*)    ;;                                          # looks like an object
    *)       return 1 ;;                                 # anything else: hands off
  esac
  if grep -qE "^  \"$key\"[[:space:]]*:" "$f"; then
    if [ "$mode" = seed ]; then
      # Present with a real value → hands off. null / "" counts as unset.
      grep -qE "^  \"$key\"[[:space:]]*:[[:space:]]*(null|\"\")[[:space:]]*,?$" "$f" \
        || return 0
    else
      grep -qE "^  \"$key\"[[:space:]]*:[[:space:]]*$val[[:space:]]*,?$" "$f" && return 0
    fi
    # Replace the value in place, keeping the trailing comma as found.
    sed -E "s/^(  \"$key\"[[:space:]]*:[[:space:]]*)[^,]*(,?)$/\1$val\2/" \
      "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" && return 0
  elif grep -qE '"[^"]*"[[:space:]]*:' "$f"; then
    # Absent → insert as the first key, right after the opening brace.
    awk -v ins="  \"$key\": $val," 'done != 1 && index($0, "{") {
           p = index($0, "{")
           printf "%s\n%s%s\n", substr($0, 1, p), ins, substr($0, p + 1)
           done = 1; next
         }
         { print }' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" && return 0
  fi
  rm -f "$tmp"
  return 1
}
ensure_setting showMessageTimestamps true force 2>/dev/null || true
ensure_setting outputStyle '"Concise"' seed 2>/dev/null || true

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

# Main session is up — bring back the helper sessions before we attach.
run_helpers
offer_restore

exec env TMUX= tmux -L "$SOCK" attach -t "$SESSION"

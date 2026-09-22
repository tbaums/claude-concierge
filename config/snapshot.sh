#!/bin/sh
# ───────────────────────────────────────────────────────────────────────────
#  concierge snapshot — capture the live socket into a manifest.
#
#  A reboot (or `tmux -L concierge kill-server`) takes the whole working set
#  with it: which sessions existed, each one's cwd, model and launch flags, the
#  splits inside them, how the dash grids were composed. The conversations
#  themselves already survive — Claude Code keys its transcript on the cwd and
#  `--continue` finds it — so the only thing missing is the manifest of WHAT to
#  restore and WHERE. A hand-typed roster drifts silently (one drifted wrong
#  inside a fortnight: sessions missing, a non-default model unrecorded, and
#  everything still came up, just wrong), so this is read off the live socket
#  and never written by hand.
#
#  Written to ~/.config/claude-concierge/session-manifest, pipe-delimited:
#
#    SESSION|name|cwd|model|flags
#    SPLIT|parent|pane-title|cwd|model|flags
#    DASH|name|cols|member member member
#
#  `flags` (and SPLIT's trailing field) is "everything after the last fixed
#  pipe" — an appended system prompt is arbitrary text and may itself contain a
#  literal `|`, so a parser must never count tokens.
#
#  Flags:
#    --quiet            say nothing on success (this runs from tmux hooks)
#    --throttle SECS    do nothing unless the manifest is older than SECS —
#                       one stat, no tmux queries, so the 5s status tick can
#                       call it as a backstop for free
#    --retire NAME      the session just closed: remember it was deliberately
#                       killed, so a later restore doesn't resurrect it.
#                       The manifest is re-captured BEFORE the retired entry is
#                       written, so callers poll the retired file as "done".
#    --unretire NAME    the session just came back: forget that
#
#  Overrides, for tests: CONCIERGE_SOCK, CONCIERGE_SESSION, CONCIERGE_MANIFEST,
#  CONCIERGE_RETIRED.
# ───────────────────────────────────────────────────────────────────────────
set -u

SOCK="${CONCIERGE_SOCK:-concierge}"
MAIN="${CONCIERGE_SESSION:-concierge}"
CFG="$HOME/.config/claude-concierge"
MANIFEST="${CONCIERGE_MANIFEST:-$CFG/session-manifest}"
RETIRED="${CONCIERGE_RETIRED:-$CFG/retired}"
KEEP=5                              # rotated copies: session-manifest.1 … .5

QUIET=0; THROTTLE=""; RETIRE=""; UNRETIRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)    QUIET=1 ;;
    --throttle) shift; THROTTLE="${1-}" ;;
    --retire)   shift; RETIRE="${1-}" ;;
    --unretire) shift; UNRETIRE="${1-}" ;;
    *)          printf 'concierge snapshot: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

T() { tmux -L "$SOCK" "$@"; }

# The command line to restore a pane with. A pane's own pid is the `zsh -c`
# wrapper, which carries no flags at all — `ps -p #{pane_pid}` silently reports
# an empty model, and a re-snapshot after a restore writes that emptiness back.
# So descend through the children until a claude command line turns up. Only
# the first token counts: a launcher like `pane-claude`, or a cwd or env
# assignment mentioning claude, must not stop the descent short of the real one.
claude_cmd() {
  local out c tok
  out="$(ps -ww -o command= -p "$1" 2>/dev/null)"
  tok="${out%% *}"
  case "$tok" in claude|*/claude) printf '%s' "$out"; return 0 ;; esac
  for c in $(pgrep -P "$1" 2>/dev/null); do
    claude_cmd "$c" && return 0
  done
  return 1
}

model_of() { printf '%s' "$1" | sed -nE 's/.*--model[ =]+([^ ]+).*/\1/p'; }

# Everything after the binary, verbatim. "The binary" is the first token that
# names claude, which handles both `claude --flags…` and a `zsh -c claude
# --flags…` wrapper without hard-coding either shape.
flags_of() {
  local rest tok
  rest="$1"
  while [ -n "$rest" ]; do
    tok="${rest%% *}"
    case "$rest" in *' '*) rest="${rest#* }" ;; *) rest="" ;; esac
    case "$tok" in *claude*) printf '%s' "$rest"; return 0 ;; esac
  done
  return 1
}

# Dash grids are read back, never declared: every pane of a grid holds a `tmux
# attach` client, so a pane's tty showing up as a client tty tells us both that
# this is a grid and which session that tile is watching.
CLIENTS="$(T list-clients -F '#{client_tty}|#{client_session}' 2>/dev/null || true)"
member_of() {
  printf '%s\n' "$CLIENTS" | sed -n "s#^$1|##p" | head -1
}

PANE_FMT='#{pane_index}|#{pane_top}|#{pane_pid}|#{pane_tty}|#{pane_current_path}|#{pane_title}'

emit_rows() {
  local sessions s panes idx top pid tty cwd title
  local members nmembers tops rows cols m
  local n cmd model flags seen_first

  sessions="$(T list-sessions -F '#{session_name}' 2>/dev/null | sort || true)"
  [ -n "$sessions" ] || return 0

  for s in $sessions; do
    panes="$(T list-panes -s -t "$s" -F "$PANE_FMT" 2>/dev/null || true)"
    [ -n "$panes" ] || continue

    # Pass 1: is this a dash grid, and if so what is it showing?
    members=""; nmembers=0; tops=""
    while IFS='|' read -r idx top pid tty cwd title; do
      [ -n "${tty:-}" ] || continue
      m="$(member_of "$tty")"
      [ -n "$m" ] || continue
      members="${members:+$members }$m"
      nmembers=$((nmembers + 1))
      case " $tops " in *" $top "*) ;; *) tops="${tops:+$tops }$top" ;; esac
    done <<EOF
$panes
EOF

    if [ "$nmembers" -gt 0 ]; then
      rows=0
      for m in $tops; do rows=$((rows + 1)); done
      [ "$rows" -gt 0 ] || rows=1
      cols=$(( (nmembers + rows - 1) / rows ))          # ceil(members / rows)
      printf 'DASH|%s|%s|%s\n' "$s" "$cols" "$members"
      continue
    fi

    # Pass 2: the session itself, then its splits. The concierge session is
    # excluded — `concierge` recreates it — but its extra panes are not.
    n=0; seen_first=0
    while IFS='|' read -r idx top pid tty cwd title; do
      [ -n "${pid:-}" ] || continue
      n=$((n + 1))
      if [ "$s" = "$MAIN" ] && [ "$n" -eq 1 ]; then continue; fi
      cmd="$(claude_cmd "$pid" 2>/dev/null || true)"
      [ -n "$cmd" ] || continue        # a bare shell has nothing to restore
      model="$(model_of "$cmd")"
      flags="$(flags_of "$cmd" || true)"
      if [ "$s" != "$MAIN" ] && [ "$seen_first" -eq 0 ]; then
        seen_first=1
        printf 'SESSION|%s|%s|%s|%s\n' "$s" "$cwd" "$model" "$flags"
      else
        printf 'SPLIT|%s|%s|%s|%s|%s\n' "$s" "$title" "$cwd" "$model" "$flags"
      fi
    done <<EOF
$panes
EOF
  done
}

dir="${MANIFEST%/*}"
[ -d "$dir" ] || mkdir -p "$dir" || exit 1

# The 5s status tick calls us with --throttle, so the common case must cost one
# stat and nothing else — no tmux queries, no ps walk.
if [ -n "$THROTTLE" ] && [ -f "$MANIFEST" ]; then
  age=$(( $(date '+%s') - $(stat -f '%m' "$MANIFEST" 2>/dev/null || echo 0) ))
  [ "$age" -ge "$THROTTLE" ] || exit 0
fi

# A session you deliberately killed should not come back on the next restore.
# Only sessions that had something to restore are worth recording — the same
# "nothing to restore" line snapshot draws for a bare shell.
had_row() { grep -qE "^(SESSION|DASH)\|$1\|" "$MANIFEST" 2>/dev/null; }
forget() {                          # drop $1's line from the retired list
  local tmpr
  [ -f "$RETIRED" ] || return 0
  tmpr="$RETIRED.$$"
  # NB: grep -v exits 1 when it filters every line away, which is exactly the
  # case where the list becomes empty — so don't gate the mv on its status.
  grep -v "^$1	" "$RETIRED" > "$tmpr" 2>/dev/null
  [ -f "$tmpr" ] && mv "$tmpr" "$RETIRED" 2>/dev/null || rm -f "$tmpr"
}
# Eligibility is judged against the manifest as it stands before re-capture;
# the retired entry itself is written last (below), as the completion signal.
RETIRE_OK=0
if [ -n "$RETIRE" ] && had_row "$RETIRE"; then
  forget "$RETIRE"
  RETIRE_OK=1
fi
[ -n "$UNRETIRE" ] && forget "$UNRETIRE"

# Keep the last few captures so a bad one can be rolled back. Pure mv chain: an
# interrupted rotation costs one slot, and the live write below is still atomic.
rotate() {
  local i prev
  [ -f "$MANIFEST" ] || return 0
  i=$KEEP
  while [ "$i" -gt 1 ]; do
    prev=$((i - 1))
    [ -f "$MANIFEST.$prev" ] && mv "$MANIFEST.$prev" "$MANIFEST.$i" 2>/dev/null
    i=$prev
  done
  cp "$MANIFEST" "$MANIFEST.1" 2>/dev/null || true
}
rotate

tmp="$MANIFEST.$$"

{
  printf '# claude-concierge session manifest — captured %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  emit_rows
} > "$tmp" || { rm -f "$tmp"; exit 1; }

mv "$tmp" "$MANIFEST" || { rm -f "$tmp"; exit 1; }

if [ "$RETIRE_OK" = 1 ]; then
  printf '%s\t%s\n' "$RETIRE" "$(date '+%s')" >> "$RETIRED" 2>/dev/null || true
fi

[ "$QUIET" = 1 ] && exit 0
rows="$(grep -cv '^#' "$MANIFEST" 2>/dev/null || printf 0)"
printf 'concierge: snapshot → %s (%s rows)\n' "$MANIFEST" "$rows"

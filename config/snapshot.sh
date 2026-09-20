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
#  Overrides, for tests: CONCIERGE_SOCK, CONCIERGE_SESSION, CONCIERGE_MANIFEST.
# ───────────────────────────────────────────────────────────────────────────
set -u

SOCK="${CONCIERGE_SOCK:-concierge}"
MAIN="${CONCIERGE_SESSION:-concierge}"
CFG="$HOME/.config/claude-concierge"
MANIFEST="${CONCIERGE_MANIFEST:-$CFG/session-manifest}"

T() { tmux -L "$SOCK" "$@"; }

# The command line to restore a pane with. A pane's own pid is the `zsh -c`
# wrapper, which carries no flags at all — `ps -p #{pane_pid}` silently reports
# an empty model, and a re-snapshot after a restore writes that emptiness back.
# So descend through the children until a claude command line turns up.
claude_cmd() {
  local out c
  out="$(ps -ww -o command= -p "$1" 2>/dev/null)"
  case "$out" in *claude*) printf '%s' "$out"; return 0 ;; esac
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
tmp="$MANIFEST.$$"

{
  printf '# claude-concierge session manifest — captured %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  emit_rows
} > "$tmp" || { rm -f "$tmp"; exit 1; }

mv "$tmp" "$MANIFEST" || { rm -f "$tmp"; exit 1; }

rows="$(grep -cv '^#' "$MANIFEST" 2>/dev/null || printf 0)"
printf 'concierge: snapshot → %s (%s rows)\n' "$MANIFEST" "$rows"

#!/bin/sh
# ───────────────────────────────────────────────────────────────────────────
#  concierge restore — bring the working set back from the manifest.
#
#  `concierge snapshot` (slice 1) records what was running; this puts it back,
#  on demand and never on its own. Auto-launching twenty Claude sessions at
#  boot is a lot of processes and tokens for sessions you may not want today,
#  so nothing here runs unless you ask for it.
#
#    concierge restore                 everything in the manifest that's absent
#    concierge restore <name>…         those sessions (and their splits)
#    concierge restore --dash <name>   that grid, members first if they're absent
#    concierge restore --list          print the manifest
#    concierge restore --dry-run       say what would change, change nothing
#    concierge restore --force         ignore a stale manifest
#
#  Idempotent BY NAME: a session or grid that's already up is skipped, never
#  killed, recreated or reconciled against the manifest. Same name means
#  "already up", full stop.
#
#  Conversations come back because of the cwd: Claude Code keys its transcript
#  on the working directory, so `--continue` in the recorded cwd resumes that
#  session's own history. Flags are replayed verbatim.
#
#  Env: CONCIERGE_RESTORE_MAX_AGE_HOURS (default 72) — refuse a manifest older
#       than this; CONCIERGE_RESTORE_READY_TIMEOUT (default 60) — how long to
#       wait for a dash member to come up before building the grid anyway.
#  Tests also set CONCIERGE_SOCK / CONCIERGE_MANIFEST / CONCIERGE_CLAUDE.
# ───────────────────────────────────────────────────────────────────────────
set -u

SOCK="${CONCIERGE_SOCK:-concierge}"
CFG="$HOME/.config/claude-concierge"
MANIFEST="${CONCIERGE_MANIFEST:-$CFG/session-manifest}"
CLAUDE="${CONCIERGE_CLAUDE:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
MAX_AGE_HOURS="${CONCIERGE_RESTORE_MAX_AGE_HOURS:-72}"
READY_TIMEOUT="${CONCIERGE_RESTORE_READY_TIMEOUT:-60}"

T() { tmux -L "$SOCK" "$@"; }

DRY=0; FORCE=0; LIST=0; DASH=""; NAMES=""; SKIPS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --list)    LIST=1 ;;
    --dash)    shift; DASH="${1-}" ;;
    -*)        printf 'concierge restore: unknown option %s\n' "$1" >&2; exit 2 ;;
    *)         NAMES="${NAMES:+$NAMES }$1" ;;
  esac
  shift
done

if [ ! -f "$MANIFEST" ]; then
  printf 'concierge: no manifest at %s — run `concierge snapshot` first\n' "$MANIFEST" >&2
  exit 1
fi

CAPTURED="$(sed -n '1s/^#[^0-9]*\([0-9T:-]*Z\).*/\1/p' "$MANIFEST")"
printf 'concierge: manifest captured %s\n' "${CAPTURED:-at an unknown time}"

if [ "$LIST" = 1 ]; then
  grep -v '^#' "$MANIFEST" || true
  exit 0
fi

# A weeks-old manifest restores confidently and wrongly, so say no by default.
if [ "$FORCE" = 0 ] && [ -n "$CAPTURED" ]; then
  then_s="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$CAPTURED" '+%s' 2>/dev/null || true)"
  now_s="$(date -u '+%s')"
  if [ -n "$then_s" ] && [ $(( (now_s - then_s) / 3600 )) -ge "$MAX_AGE_HOURS" ]; then
    printf 'concierge: manifest is older than %sh (captured %s) — re-snapshot, or pass --force\n' \
      "$MAX_AGE_HOURS" "$CAPTURED" >&2
    exit 1
  fi
fi

rows()      { grep "^$1|" "$MANIFEST" 2>/dev/null || true; }
has()       { T has-session -t "$1" 2>/dev/null; }
wanted()    {                       # is session $1 in this run's scope?
  [ -z "$NAMES" ] && return 0
  case " $NAMES " in *" $1 "*) return 0 ;; esac
  return 1
}

# The pid of the claude under a pane. The pane's own pid is the `zsh -c`
# wrapper, so descend through the children — same shape as snapshot.sh's
# claude_cmd(), which is why a pane's flags aren't readable from the pane pid.
claude_pid() {
  local out c p
  out="$(ps -ww -o command= -p "$1" 2>/dev/null)"
  case "$out" in *claude*) printf '%s' "$1"; return 0 ;; esac
  for c in $(pgrep -P "$1" 2>/dev/null); do
    p="$(claude_pid "$c")" && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Ready = the pane is alive, a claude is running under it, and that claude has
# owned the tty for a couple of seconds. Deliberately NOT capture-pane: Claude
# draws on the alternate screen, so a perfectly live pane can capture empty.
pane_ready() {
  local pid cpid age
  [ "$(T display -p -t "$1" '#{pane_dead}' 2>/dev/null)" = 0 ] || return 1
  pid="$(T display -p -t "$1" '#{pane_pid}' 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  cpid="$(claude_pid "$pid")" || return 1
  age="$(ps -o etimes= -p "$cpid" 2>/dev/null | tr -d ' ')"
  [ -n "$age" ] && [ "$age" -ge 2 ]
}

wait_ready() {                       # $1 = target pane; never blocks forever
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    pane_ready "$1" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  printf 'concierge: %s not ready after %ss — building anyway\n' "$1" "$READY_TIMEOUT" >&2
  return 1
}

start_session() {                    # $1 name, $2 cwd, $3 flags
  if has "$1"; then
    printf '  already up: %s\n' "$1"
    return 0
  fi
  if [ ! -d "$2" ]; then
    printf 'concierge: skipping %s — cwd is gone (%s)\n' "$1" "$2" >&2
    SKIPS=$((SKIPS + 1))
    return 1
  fi
  if [ "$DRY" = 1 ]; then
    printf '  would restore: %s (%s) %s\n' "$1" "$2" "$3"
    return 0
  fi
  if T new-session -d -s "$1" -c "$2" "$CLAUDE $3" 2>/dev/null; then
    printf '  restored: %s\n' "$1"
  else
    printf 'concierge: failed to start %s\n' "$1" >&2
    SKIPS=$((SKIPS + 1))
    return 1
  fi
}

pane_titled() {                      # does session $1 already hold a pane titled $2?
  T list-panes -s -t "$1" -F '#{pane_title}' 2>/dev/null | grep -qxF "$2"
}

restore_splits() {                   # $1 = parent session
  local kind parent title cwd rest pane
  rows SPLIT | while IFS='|' read -r kind parent title cwd rest; do
    [ "$parent" = "$1" ] || continue
    has "$parent" || continue
    pane_titled "$parent" "$title" && { printf '  already up: %s split %s\n' "$parent" "$title"; continue; }
    if [ ! -d "$cwd" ]; then
      printf 'concierge: skipping %s split %s — cwd is gone (%s)\n' "$parent" "$title" "$cwd" >&2
      continue
    fi
    if [ "$DRY" = 1 ]; then
      printf '  would restore: %s split %s\n' "$parent" "$title"
      continue
    fi
    # rest is "model|flags" — flags is everything after the last fixed pipe.
    pane="$(T split-window -d -P -F '#{pane_id}' -t "$parent" -c "$cwd" \
              "$CLAUDE ${rest#*|}" 2>/dev/null)"
    if [ -n "$pane" ]; then
      T select-pane -t "$pane" -T "$title" 2>/dev/null || true
      printf '  restored: %s split %s\n' "$parent" "$title"
    else
      printf 'concierge: failed to split %s\n' "$parent" >&2
    fi
  done
}

session_row() { rows SESSION | awk -F'|' -v n="$1" '$2 == n { print; exit }'; }

restore_session_named() {            # $1 = session name from the manifest
  local row cwd rest
  row="$(session_row "$1")"
  if [ -z "$row" ]; then
    printf 'concierge: %s is not in the manifest\n' "$1" >&2
    SKIPS=$((SKIPS + 1))
    return 1
  fi
  cwd="$(printf '%s' "$row" | cut -d'|' -f3)"
  rest="$(printf '%s' "$row" | cut -d'|' -f5-)"   # everything after the model
  start_session "$1" "$cwd" "$rest" || return 1
  restore_splits "$1"
}

restore_dash() {                     # $1 = grid name
  local row cols members m panes first target
  row="$(rows DASH | awk -F'|' -v n="$1" '$2 == n { print; exit }')"
  if [ -z "$row" ]; then
    printf 'concierge: no dash named %s in the manifest\n' "$1" >&2
    exit 1
  fi
  members="$(printf '%s' "$row" | cut -d'|' -f4-)"
  if has "$1"; then printf '  already up: %s\n' "$1"; return 0; fi
  if [ "$DRY" = 1 ]; then
    printf '  would restore: dash %s (%s)\n' "$1" "$members"
    return 0
  fi
  # Members first — a grid can only attach to tiles that already exist.
  for m in $members; do
    has "$m" || restore_session_named "$m" || true
  done
  for m in $members; do
    if has "$m"; then wait_ready "$m" || true; fi   # warns by name on timeout
  done
  first=1
  for m in $members; do
    has "$m" || { printf 'concierge: dash %s: member %s never came up\n' "$1" "$m" >&2; continue; }
    if [ "$first" = 1 ]; then
      T new-session -d -s "$1" "env TMUX= tmux -L $SOCK attach -t $m" 2>/dev/null && first=0
    else
      T split-window -h -d -t "$1" "env TMUX= tmux -L $SOCK attach -t $m" 2>/dev/null || true
    fi
  done
  [ "$first" = 0 ] && printf '  restored: dash %s\n' "$1"
}

if [ -n "$DASH" ]; then
  restore_dash "$DASH"
else
  up=0
  for n in $(rows SESSION | cut -d'|' -f2); do
    wanted "$n" || continue
    has "$n" && up=$((up + 1))
    restore_session_named "$n" || true
  done
  # Grids come last: their members have to exist (and be up) first.
  if [ -z "$NAMES" ]; then
    for d in $(rows DASH | cut -d'|' -f2); do
      has "$d" && up=$((up + 1))
      restore_dash "$d" || true
    done
  fi
  [ "$DRY" = 1 ] && [ "$up" -gt 0 ] && printf 'concierge: %d already up\n' "$up"
fi

[ "$SKIPS" -gt 0 ] && exit 1
exit 0

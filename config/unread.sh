#!/bin/sh
# ───────────────────────────────────────────────────────────────────────────
#  unread — which sessions finished a turn you haven't looked at yet.
#
#  With two dozen Claude sessions on the socket, a chime says *something*
#  finished but not *which*. So the Stop hook (handles.sh) stamps the pane:
#  `@unread <epoch>`. Focusing the pane clears it (tmux.conf's pane-focus-in /
#  client-session-changed hooks call `clear` here); a pane merely visible in a
#  dash tile stays unread until it is focused or acked. The flag is a pane
#  option, so it lives exactly as long as the pane — no state file.
#
#    unread.sh list [--short]   the queue, oldest first, with age + last line
#                               (--short: one line for the status bar, or
#                               nothing when the queue is empty)
#    unread.sh next [session]   focus the oldest unread pane (or <session>);
#                               outside a tmux client, print its session name
#    unread.sh ack <session>|--all   clear without focusing
#    unread.sh clear <pane-id> [client-created]
#                               the one clear path — hooks and ack both use
#                               it; the hooks pass the focusing client's
#                               creation time, and a client that attached
#                               moments ago is not someone reading
#
#  `concierge unread|next|ack` dispatch here.
#  Overrides, for tests: CONCIERGE_SOCK.
# ───────────────────────────────────────────────────────────────────────────
set -u

# Inside a tmux client (or a tmux hook/job) $TMUX already names the right
# socket; otherwise default to the Concierge socket like every other script.
T() {
  if [ -n "${CONCIERGE_SOCK:-}" ]; then tmux -L "$CONCIERGE_SOCK" "$@"
  elif [ -n "${TMUX:-}" ]; then tmux "$@"
  else tmux -L concierge "$@"
  fi
}

clear_unread() {         # $1 = pane id
  T set -pu -t "$1" @unread 2>/dev/null
}

# "<epoch>\t<session>\t<pane>" for every unread pane, oldest first.
queue() {
  T list-panes -a -F '#{@unread}	#{session_name}	#{pane_id}' 2>/dev/null \
    | awk -F'\t' '$1 != ""' | sort -n -k1,1
}

age() {                  # $1 = seconds -> 42s / 7m / 3h / 2d
  if   [ "$1" -lt 60 ];    then printf '%ss' "$1"
  elif [ "$1" -lt 3600 ];  then printf '%sm' $(($1 / 60))
  elif [ "$1" -lt 86400 ]; then printf '%sh' $(($1 / 3600))
  else                          printf '%sd' $(($1 / 86400))
  fi
}

session_exists() {
  T has-session -t "=$1" 2>/dev/null && return 0
  printf 'unread: no such session: %s\n' "$1" >&2
  return 1
}

do_list() {
  local q now ts s p line
  q="$(queue)"
  if [ "${1-}" = --short ]; then
    [ -n "$q" ] || return 0
    printf 'unread %s: %s \n' "$(printf '%s\n' "$q" | wc -l | tr -d ' ')" \
      "$(printf '%s\n' "$q" | cut -f2 | paste -sd, - | sed 's/,/, /g')"
    return 0
  fi
  if [ -z "$q" ]; then
    echo "unread queue is empty"
    return 0
  fi
  now="$(date +%s)"
  printf '%s\n' "$q" | while IFS='	' read -r ts s p; do
    line="$(T capture-pane -p -t "$p" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-100)"
    printf '%-20s %5s  %s\n' "$s" "$(age $((now - ts)))" "$line"
  done
}

do_next() {
  local s p
  if [ -n "${1-}" ]; then
    session_exists "$1" || return 1
    s="$1"
    p="$(T display-message -p -t "=$1" '#{pane_id}')"
  else
    p="$(queue | head -1)"
    if [ -z "$p" ]; then
      echo "unread queue is empty"
      return 0
    fi
    s="$(printf '%s' "$p" | cut -f2)"
    p="$(printf '%s' "$p" | cut -f3)"
  fi
  # Only a real client can be switched; without one there is nothing to
  # focus, so say where to go and leave the flag alone.
  if [ -n "${TMUX:-}" ] && T switch-client -t "$p" 2>/dev/null; then
    clear_unread "$p"    # the focus hook does this too; don't depend on it
  else
    printf '%s\n' "$s"
  fi
}

do_ack() {
  local panes p
  case "${1-}" in
    '') echo "usage: concierge ack <session>|--all" >&2; return 2 ;;
    --all) panes="$(T list-panes -a -F '#{pane_id}' 2>/dev/null)" ;;
    *) session_exists "$1" || return 1
       panes="$(T list-panes -s -t "=$1" -F '#{pane_id}' 2>/dev/null)" ;;
  esac
  for p in $panes; do clear_unread "$p"; done
}

MODE="${1-}"
[ $# -gt 0 ] && shift
case "$MODE" in
  list)  do_list "$@" ;;
  next)  do_next "$@" ;;
  ack)   do_ack "$@" ;;
  clear) [ -n "${1-}" ] || exit 2
         [ -n "${2-}" ] && [ $(( $(date +%s) - $2 )) -lt 2 ] && exit 0
         clear_unread "$1" ;;
  *)     echo "usage: unread.sh list [--short] | next [session] | ack <session>|--all | clear <pane>" >&2
         exit 2 ;;
esac

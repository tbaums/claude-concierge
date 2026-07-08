#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────────────
#  session-menu.sh — the Ctrl-b s session picker, with the concierge session
#  PINNED to position 0 (press `0` to jump home from anywhere).
#
#  Why not just re-sort choose-tree? Its three sort orders (index/name/time)
#  are all unstable for this: session ids reshuffle when the concierge
#  session is recreated (crash/reconnect), names sort concierge mid-list,
#  and activity time jitters with background workers. A generated menu is
#  the only deterministic "concierge first, always" ordering.
#
#  The full tree UI stays available on Ctrl-b S (capital).
# ───────────────────────────────────────────────────────────────────────────
set -euo pipefail

PIN="concierge"

# Resolve the real tmux binary (bypass the ~/.local/bin wrapper, which can
# misbehave when invoked from inside run-shell).
TMUX_BIN=""
for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
  [ -x "$c" ] && TMUX_BIN="$c" && break
done
[ -z "$TMUX_BIN" ] && TMUX_BIN="tmux"

current="$($TMUX_BIN display-message -p '#{session_name}')"

# keys: 0 = pinned; then 1-9, then a..z for the rest
keys=(1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r t u v w x y z)

args=(-T "#[align=centre] sessions ")
ki=0

add_item() {
  local name="$1" key="$2" label="$1"
  [ "$name" = "$current" ] && label="$name ←"
  args+=("$label" "$key" "switch-client -t '$name'")
}

# pinned first
if $TMUX_BIN has-session -t "$PIN" 2>/dev/null; then
  add_item "$PIN" 0
fi

# the rest, alphabetical
while IFS= read -r s; do
  [ "$s" = "$PIN" ] && continue
  add_item "$s" "${keys[$ki]}"
  ki=$((ki + 1))
done < <($TMUX_BIN list-sessions -F '#{session_name}' | sort)

exec "$TMUX_BIN" display-menu "${args[@]}"

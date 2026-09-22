#!/bin/bash
# ───────────────────────────────────────────────────────────────────────────
#  concierge backup — health of the ~/.claude skills/memory/settings backup.
#
#    concierge backup status   agent loaded?, last-commit age, unpushed count,
#                              age of the last successful sync; exits 1 and
#                              says STALE when anything needs attention.
#    backup.sh resolve         print the local repo dir for
#                              CONCIERGE_BACKUP_REPO (used by install.sh)
#
#  A clean error log is not a health signal (a sync once "succeeded" for four
#  weeks while pushing dangling symlinks), so this checks outcomes instead.
#  CONCIERGE_BACKUP_STALE_MIN (default 60) is the staleness threshold.
# ───────────────────────────────────────────────────────────────────────────
set -u

LABEL="com.tbaums.claude-backup"
LAUNCHCTL="${CONCIERGE_LAUNCHCTL:-launchctl}"
STALE_MIN="${CONCIERGE_BACKUP_STALE_MIN:-60}"

# CONCIERGE_BACKUP_REPO is a local path or a git URL. A URL is cloned to
# ~/claude-backup (CONCIERGE_BACKUP_DIR overrides) and synced from there.
resolve_dir() {
  local r="${CONCIERGE_BACKUP_REPO:-}"
  case "$r" in
    "") return 1 ;;
    *://*|*@*:*) printf '%s' "${CONCIERGE_BACKUP_DIR:-$HOME/claude-backup}" ;;
    "~"/*) printf '%s' "$HOME/${r#\~/}" ;;
    *) printf '%s' "$r" ;;
  esac
}

ago() {  # seconds → "Nm ago" / "Nh Mm ago"
  local s=$1
  if [ "$s" -lt 3600 ]; then printf '%dm ago' $((s / 60))
  else printf '%dh %dm ago' $((s / 3600)) $((s % 3600 / 60)); fi
}

status() {
  local dir now problems=()
  if ! dir="$(resolve_dir)"; then
    echo "backup: CONCIERGE_BACKUP_REPO is not set (set it in ~/.zshenv, then re-run install.sh)"
    return 1
  fi
  now=$(date +%s)
  echo "repo:          $dir"

  if "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "agent:         loaded ($LABEL)"
  else
    echo "agent:         NOT loaded ($LABEL)"
    problems+=("launch agent not loaded — re-run install.sh")
  fi

  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "STALE: $dir is not a git repo"
    return 1
  fi

  local ct
  ct="$(git -C "$dir" log -1 --format=%ct 2>/dev/null)"
  if [ -n "$ct" ]; then echo "last commit:   $(ago $((now - ct)))"
  else echo "last commit:   none"; fi

  if git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    local n
    n="$(git -C "$dir" rev-list --count '@{u}..HEAD')"
    echo "unpushed:      $n"
    [ "$n" -gt 0 ] && problems+=("$n unpushed commit(s) — see $dir/logs/sync.log")
  else
    echo "unpushed:      (no upstream branch)"
    problems+=("no upstream branch — nothing is leaving this machine")
  fi

  local ok="$dir/logs/last-ok" mt
  if [ -f "$ok" ]; then
    mt="$(stat -f %m "$ok" 2>/dev/null || stat -c %Y "$ok")"
    echo "last good sync: $(ago $((now - mt)))"
    [ $((now - mt)) -gt $((STALE_MIN * 60)) ] \
      && problems+=("last good sync older than ${STALE_MIN}m")
  else
    echo "last good sync: never"
    problems+=("no successful sync recorded yet")
  fi

  local links
  links="$(git -C "$dir" ls-files -s | awk '$1 == "120000" {print $4}')"
  if [ -n "$links" ]; then
    problems+=("symlinks committed instead of content: $(echo $links)")
  fi

  if [ ${#problems[@]} -eq 0 ]; then
    echo "OK"
  else
    local p
    for p in "${problems[@]}"; do echo "STALE: $p"; done
    return 1
  fi
}

case "${1:-status}" in
  status)  status ;;
  resolve) resolve_dir ;;
  *) echo "usage: concierge backup status" >&2; exit 2 ;;
esac

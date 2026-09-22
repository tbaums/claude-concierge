#!/bin/bash
# ───────────────────────────────────────────────────────────────────────────
#  Off-machine backup of ~/.claude skills, memory and settings.
#
#  Run every 5 minutes by the com.tbaums.claude-backup launch agent that
#  install.sh generates when CONCIERGE_BACKUP_REPO is set. Idempotent: commits
#  only if something changed, pushes only if ahead. Transcripts (*.jsonl) are
#  never copied.
#
#  Layout in the backup repo (several machines may share one repo):
#    skills/                             shared, additive (never --delete)
#    memory/<host>/                      this machine's Claude memory
#    settings/<host>/settings.json       this machine's ~/.claude/settings.json
#  <host> = `hostname -s`, lowercased (CONCIERGE_BACKUP_HOST overrides).
#
#  rsync -L follows symlinks: a skill that is a symlink into another directory
#  must land as real files, never as a dangling mode-120000 link.
#
#  On success it touches logs/last-ok; `concierge backup status` reads that,
#  so a sync that silently stops reaching a pushed state shows up as stale.
# ───────────────────────────────────────────────────────────────────────────
set -u

REPO="${CONCIERGE_BACKUP_REPO:?CONCIERGE_BACKUP_REPO must be the local backup repo}"
HOST="${CONCIERGE_BACKUP_HOST:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
CLAUDE_DIR="$HOME/.claude"
MEMORY_SRC="$CLAUDE_DIR/projects/$(printf '%s' "$HOME" | sed 's#[/.]#-#g')/memory"
LOGDIR="$REPO/logs"

mkdir -p "$LOGDIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGDIR/sync.log"; }

cd "$REPO" || { echo "backup repo not found: $REPO" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { log "not a git repo: $REPO"; exit 1; }

# Logs are local-only; keep them out of every commit.
EXCLUDE="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCLUDE")"
grep -qx 'logs/' "$EXCLUDE" 2>/dev/null || echo 'logs/' >> "$EXCLUDE"

# One-time migration: the old single-machine layout kept memory files directly
# in memory/. Move them into memory/<host>/ as their own commit.
top_level="$(git ls-files memory/ | grep -E '^memory/[^/]+$' || true)"
if [ -n "$top_level" ]; then
  mkdir -p "memory/$HOST"
  while IFS= read -r f; do
    git mv "$f" "memory/$HOST/${f#memory/}"
  done <<< "$top_level"
  git commit -q -m "backup: move memory/ into memory/$HOST/ (per-machine layout)" \
    && log "migrated top-level memory/ into memory/$HOST/"
fi

status=0

# skills/ — shared across machines, additive: no --delete.
if [ -d "$CLAUDE_DIR/skills" ]; then
  mkdir -p skills
  rsync -aL --exclude '*.jsonl' "$CLAUDE_DIR/skills/" skills/ \
    || { log "rsync skills failed (exit $?)"; status=1; }
fi

if [ -d "$MEMORY_SRC" ]; then
  mkdir -p "memory/$HOST"
  rsync -aL --exclude '*.jsonl' "$MEMORY_SRC/" "memory/$HOST/" \
    || { log "rsync memory failed (exit $?)"; status=1; }
else
  log "no memory dir at $MEMORY_SRC; skipping memory"
fi

if [ -f "$CLAUDE_DIR/settings.json" ]; then
  mkdir -p "settings/$HOST"
  rsync -aL "$CLAUDE_DIR/settings.json" "settings/$HOST/settings.json" \
    || { log "rsync settings failed (exit $?)"; status=1; }
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "backup: $HOST $(date '+%Y-%m-%d %H:%M')" \
    || { log "commit failed"; exit 1; }
fi

# Push only if there is an upstream and we're ahead of it. Pull --rebase first
# so two machines interleave; a conflict aborts this run and stays visible as
# unpushed commits in `concierge backup status`.
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  if ! git pull -q --rebase; then
    git rebase --abort >/dev/null 2>&1
    log "pull --rebase failed (conflict?); aborted, not pushing"
    exit 1
  fi
  if [ "$(git rev-list --count '@{u}..HEAD')" -gt 0 ]; then
    git push -q || { log "push failed"; exit 1; }
  fi
fi

[ "$status" -eq 0 ] && touch "$LOGDIR/last-ok"
exit "$status"

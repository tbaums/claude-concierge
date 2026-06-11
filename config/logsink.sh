#!/bin/sh
# Durable raw-pane transcript. tmux pipe-pane feeds this script the full byte
# stream of the pane; we strip terminal escape sequences (so the log is
# human-readable and far smaller) and append to a dated file. Streaming through
# perl is effectively free — it's line-buffered I/O, not compute.
#
# This is the belt-and-suspenders log for *shell* output. The authoritative
# record of the Claude conversation itself is Claude Code's own structured
# transcript under ~/.claude/projects/<cwd>/*.jsonl, which is what `--continue`
# resumes from.
LOGDIR="$HOME/.claude/concierge-logs"
mkdir -p "$LOGDIR"
exec perl -pe '
  s/\e\][0-9;]*;[^\a\e]*(?:\a|\e\\)//g;   # OSC (window title, etc.)
  s/\e[PX^_].*?\e\\//g;                    # DCS/PM/APC strings
  s/\e[\(\)][AB0]//g;                      # charset selection
  s/\e\[[0-9;?]*[ -\/]*[@-~]//g;           # CSI (colors, cursor moves)
  s/\e[=>NODEHM78]//g;                     # misc single-char escapes
  s/\r//g; s/\x00//g;
' >> "$LOGDIR/$(date +%Y-%m-%d).log"

#!/bin/sh
# ───────────────────────────────────────────────────────────────────────────
#  handles — short, speakable names for the parts of an assistant reply.
#
#  There's no way to point at one part of a response. A follow-up either quotes
#  text back or describes the item in prose ("the thing you flagged"), which is
#  slower than just answering — and worst on a dense, well-structured reply,
#  where there's most to point at. So after each turn the Concierge builds a
#  little index: `4a proposal · 4b flagged concern`. Saying "on 4b, no, the
#  other way" then lands exactly.
#
#  Two hooks, one script:
#
#    handles.sh stop     Stop hook. Reads the finished turn off stdin, asks a
#                        headless Haiku for the reply's addressable units, and
#                        shows them via the hook's systemMessage.
#    handles.sh prompt   UserPromptSubmit hook. Attaches the recent handle maps
#                        as additionalContext so `4b` resolves to its item.
#
#  Handles are <turn><letter> — 4a, 4b. The turn counter is per cwd and never
#  repeats, so a handle means the same thing for the whole conversation, and it
#  survives `--continue` because the state is keyed by cwd, exactly like Claude
#  Code's own transcripts.
#
#  Nothing here may ever delay or alter a reply: the extraction is a fixed-
#  budget side call, and any failure, timeout or oddity means no index at all
#  and a silent, ordinary turn.
#
#  Env: CONCIERGE_HANDLES=0 turns it off outright (no model call);
#       CONCIERGE_HANDLES_MODEL overrides the extraction model;
#       CONCIERGE_HANDLES_STATE overrides the state directory (tests).
# ───────────────────────────────────────────────────────────────────────────
set -u

MODE="${1-}"
MODEL="${CONCIERGE_HANDLES_MODEL:-claude-haiku-4-5-20251001}"
STATE_DIR="${CONCIERGE_HANDLES_STATE:-$HOME/.local/state/claude-concierge/handles}"
MIN_CHARS=300           # shorter replies have nothing worth indexing
MAX_ITEMS=12            # a..l; beyond that, no handle and no note about it
KEEP_TURNS=5            # how many turns' maps stay resolvable
TIMEOUT_MS=4000         # hard budget for the extraction call

[ "${CONCIERGE_HANDLES:-1}" = 0 ] && exit 0

# State lives under the same sanitised-cwd key Claude Code uses for transcripts,
# so a resumed session finds its own counter again.
state_file() {
  printf '%s/%s.tsv' "$STATE_DIR" "$(printf '%s' "$PWD" | sed 's#[/.]#-#g')"
}

json_escape() {          # $1 -> a JSON string body (no surrounding quotes)
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
    | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# stdin payload -> the text of the turn that just finished. Claude Code hands
# the Stop hook `last_assistant_message`; if a build doesn't, fall back to the
# transcript's final assistant text blocks.
payload_text() {
  local payload msg transcript
  payload="$1"
  msg="$(printf '%s' "$payload" \
        | sed -n 's/.*"last_assistant_message"[[:space:]]*:[[:space:]]*"\(.*\)/\1/p' \
        | sed 's/",[[:space:]]*"[a-zA-Z_]*"[[:space:]]*:.*$//; s/"}[[:space:]]*$//')"
  if [ -n "$msg" ]; then
    printf '%b' "$msg"
    return 0
  fi
  transcript="$(printf '%s' "$payload" \
        | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  tail -c 262144 "$transcript" | grep '"type":"assistant"' | tail -1 \
    | grep -oE '"text":"([^"\\]|\\.)*"' \
    | sed -e 's/^"text":"//' -e 's/"$//' \
    | while IFS= read -r line; do printf '%b\n' "$line"; done
}

# One model call, on a leash. macOS has no `timeout`, so run it detached and
# reap it ourselves — a slow extraction must never hold up the next prompt.
extract() {              # $1 = reply text -> one "label" per line
  local out pid waited
  out="$(mktemp)"
  printf '%s' "$1" | claude -p --model "$MODEL" --max-tokens 300 "$(cat <<'ASK'
List the top-level addressable units of the assistant reply on stdin: its
headings, list items and questions, in the order they appear. One per line, a
short label of at most six words, no numbering, no punctuation at the start, no
preamble. If the reply has fewer than two such units, output nothing.
ASK
)" > "$out" 2>/dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt $((TIMEOUT_MS / 100)) ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$out"
    return 1              # over budget: no index, no message, ordinary turn
  fi
  wait "$pid" 2>/dev/null || { rm -f "$out"; return 1; }
  sed -e 's/^[[:space:]]*[-*•][[:space:]]*//' -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//' "$out" | grep -v '^$'
  rm -f "$out"
}

do_stop() {
  local payload text file turn line n handle labels index
  payload="$(cat)"
  text="$(payload_text "$payload")" || exit 0
  [ "${#text}" -ge "$MIN_CHARS" ] || exit 0

  labels="$(extract "$text")" || exit 0
  # Fewer than two addressable units is not an index worth showing.
  [ "$(printf '%s\n' "$labels" | grep -cv '^$')" -ge 2 ] || exit 0

  file="$(state_file)"
  mkdir -p "${file%/*}" 2>/dev/null || exit 0
  turn="$(sed -n 's/^TURN	//p' "$file" 2>/dev/null | tail -1)"
  turn=$(( ${turn:-0} + 1 ))

  n=0
  index=""
  {
    printf 'TURN\t%s\n' "$turn"
    printf '%s\n' "$labels" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1))
      [ "$n" -le "$MAX_ITEMS" ] || break
      handle="$turn$(printf '%s' abcdefghijkl | cut -c"$n")"
      printf 'MAP\t%s\t%s\t%s\n' "$turn" "$handle" "$line"
    done
  } >> "$file" 2>/dev/null || exit 0

  # Keep only the last few turns resolvable; older maps are dropped.
  prune "$file" "$turn"

  index="$(awk -F'\t' -v t="$turn" '$1 == "MAP" && $2 == t { printf "%s%s %s", sep, $3, $4; sep = " · " }' "$file")"
  [ -n "$index" ] || exit 0
  printf '{"systemMessage":"handles: %s"}\n' "$(json_escape "$index")"
}

prune() {                # $1 = state file, $2 = current turn
  local keep tmp
  keep=$(( $2 - KEEP_TURNS + 1 ))
  [ "$keep" -gt 1 ] || return 0
  tmp="$1.$$"
  awk -F'\t' -v k="$keep" '$1 != "MAP" || $2 >= k' "$1" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$1" 2>/dev/null || rm -f "$tmp"
}

do_prompt() {
  local file maps
  cat >/dev/null                      # drain the payload; we don't need it
  file="$(state_file)"
  [ -f "$file" ] || exit 0
  maps="$(awk -F'\t' '$1 == "MAP" { printf "%s: %s\n", $3, $4 }' "$file")"
  [ -n "$maps" ] || exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' \
    "$(json_escape "Handles like 4b refer to these items from recent replies:
$maps")"
}

case "$MODE" in
  stop)   do_stop ;;
  prompt) do_prompt ;;
  *)      printf 'usage: handles.sh stop|prompt\n' >&2; exit 2 ;;
esac
exit 0

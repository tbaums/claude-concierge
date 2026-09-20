#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────────────
#  Local test runner for Claude Concierge. No CI, no network, no GitHub Actions
#  — just run it on your machine:
#
#      bash test/run.sh
#
#  It exercises the real scripts in a throwaway sandbox (temp HOME + temp tmux
#  socket) so it never touches your actual install. Exits non-zero on failure.
# ───────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }

echo "Claude Concierge — local tests"
echo "repo: $REPO"

# 1) Required files present -------------------------------------------------
echo "› files"
for f in LICENSE README.md RELEASING.md CHANGELOG.md install.sh VERSION \
         bin/concierge bin/tmux bin/doc bin/doc-view config/tmux.conf \
         config/start.sh config/clip.sh config/model-label.sh \
         config/status-model.sh \
         config/logsink.sh config/iterm-profile.py; do
  [[ -f "$REPO/$f" ]] && ok "exists: $f" || bad "missing: $f"
done

# 2) Shell syntax -----------------------------------------------------------
echo "› syntax"
for f in bin/concierge config/start.sh bin/doc bin/doc-view; do
  zsh -n "$REPO/$f" 2>/dev/null && ok "zsh -n $f" || bad "zsh -n $f"
done
for f in config/clip.sh config/logsink.sh config/model-label.sh config/status-model.sh; do
  sh -n "$REPO/$f" 2>/dev/null && ok "sh -n $f" || bad "sh -n $f"
done
bash -n "$REPO/install.sh" && ok "bash -n install.sh" || bad "bash -n install.sh"
bash -n "$REPO/bin/tmux" && ok "bash -n bin/tmux" || bad "bash -n bin/tmux"
python3 -c "compile(open('$REPO/config/iterm-profile.py').read(),'p','exec')" \
  && ok "py compile iterm-profile.py" || bad "py compile iterm-profile.py"

# 3) tmux config parses + key options apply ---------------------------------
echo "› tmux config"
if have tmux; then
  SOCK="cc_selftest_$$"
  if tmux -L "$SOCK" -f "$REPO/config/tmux.conf" new-session -d 'sleep 2' 2>/dev/null; then
    ok "tmux loads config"
    [[ "$(tmux -L "$SOCK" show-options -gv mouse)" == "on" ]] \
      && ok "mouse on" || bad "mouse on"
    [[ "$(tmux -L "$SOCK" show-options -gv status-position)" == "top" ]] \
      && ok "status-position top" || bad "status-position top"
    [[ "$(tmux -L "$SOCK" show-options -gv history-limit)" == "50000" ]] \
      && ok "history-limit 50000" || bad "history-limit 50000"
    cc="$(tmux -L "$SOCK" show-options -sv copy-command)"
    [[ "$cc" == */clip.sh && "$cc" != *'$HOME'* ]] \
      && ok "copy-command expands to $cc" || bad "copy-command not expanded ($cc)"
    n=$(tmux -L "$SOCK" list-keys 2>/dev/null \
        | grep -cE "MouseDragEnd1Pane|WheelUpPane|WheelDownPane|DoubleClick1Pane|TripleClick1Pane")
    [[ "$n" -ge 7 ]] && ok "mouse/copy/scroll binds present ($n)" || bad "binds missing ($n)"
    tmux -L "$SOCK" kill-server 2>/dev/null
  else
    bad "tmux failed to load config"
  fi
else
  bad "tmux not installed (required at runtime)"
fi

# 3b) status header: model prettifier + effort resolver ---------------------
echo "› status header (model + effort)"
# Source the real code: pretty_model now lives in its own file (shared with
# status-model.sh), resolve_effort is still start.sh's.
# shellcheck disable=SC1090
. "$REPO/config/model-label.sh"
HELPERS="$(mktemp)"
sed -n '/^resolve_effort()/,/^}/p' "$REPO/config/start.sh" > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"
check_model() {
  local got; got="$(pretty_model "$1")"
  [[ "$got" == "$2" ]] && ok "pretty_model $1 -> $2" || bad "pretty_model $1 -> '$got' (want '$2')"
}
check_model claude-opus-4-8 "opus 4.8"
check_model claude-fable-5 "fable 5"
check_model claude-sonnet-5 "sonnet 5"
check_model claude-haiku-4-5-20251001 "haiku 4.5"
# effort: env override wins
[[ "$(CONCIERGE_EFFORT=medium resolve_effort)" == "medium" ]] \
  && ok "resolve_effort honors CONCIERGE_EFFORT" || bad "resolve_effort ignored CONCIERGE_EFFORT"
# effort: reads effortLevel from settings.json when no override
ESB="$(mktemp -d)"; mkdir -p "$ESB/.claude"
printf '{\n  "model": "x",\n  "effortLevel": "xhigh"\n}\n' > "$ESB/.claude/settings.json"
[[ "$(HOME="$ESB" CONCIERGE_EFFORT="" resolve_effort)" == "xhigh" ]] \
  && ok "resolve_effort reads settings.json effortLevel" || bad "resolve_effort did not read settings.json"
# effort: neutral fallback when nothing is set
[[ "$(HOME="$ESB/nope" CONCIERGE_EFFORT="" resolve_effort)" == "default" ]] \
  && ok "resolve_effort falls back to 'default'" || bad "resolve_effort missing fallback"
rm -rf "$ESB"; rm -f "$HELPERS"
# The model · effort segment must be a LIVE #() job, not a static user option —
# a static one is exactly the staleness this replaced. The version segments, on
# the other hand, stay options (set once per window open, by design).
grep -q 'status-right .*#(\$STATUS_MODEL' "$REPO/config/tmux.conf" \
  && ok "status-right runs status-model.sh live" || bad "status-right does not run status-model.sh"
grep -q 'status-right .*#{@concierge_model}' "$REPO/config/tmux.conf" \
  && bad "status-right still shows the static @concierge_model option" \
  || ok "status-right no longer shows the static model option"
grep -q 'status-right .*#{@concierge_version}.*#{@claude_version}' "$REPO/config/tmux.conf" \
  && ok "version segments unchanged" || bad "version segments changed"
# start.sh still seeds the options — that's the fresh-launch fallback.
grep -q 'set-option -t "\$SESSION" @concierge_model' "$REPO/config/start.sh" \
  && ok "start.sh still seeds @concierge_model (launch-time fallback)" \
  || bad "start.sh no longer seeds @concierge_model"

# 3b2) live model/effort: read off the session transcript, every tick ---------
echo "› live model/effort (transcript)"
SM="$REPO/config/status-model.sh"
# No interpreter may sneak back in (start.sh's python3 went in #3).
grep -qE '\b(python3?|jq|perl|node|ruby)\b' "$SM" \
  && bad "status-model.sh introduces an interpreter dependency" \
  || ok "status-model.sh stays pure shell (no python/jq/perl/node)"

# Sandbox: a fake $HOME holding a fake transcript dir, plus a stub `tmux` so a
# test can NEVER read or write options on a real tmux server. The stub answers
# show-options from $STUB_OPTS and logs every set-option to $STUB_SETLOG.
SMTMP="$(mktemp -d)"
STUBDIR="$SMTMP/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/tmux" <<'EOF'
#!/bin/sh
# show-options -qv -t <session> <@opt>   |   set-option -t <session> <@opt> <value>
case "$1" in
  show-options)
    case "$5" in
      @concierge_model)  printf '%s' "${STUB_MODEL:-}" ;;
      @concierge_effort) printf '%s' "${STUB_EFFORT:-}" ;;
    esac ;;
  set-option) printf '%s=%s\n' "$4" "$5" >> "$STUB_SETLOG" ;;
esac
EOF
chmod +x "$STUBDIR/tmux"

sm_proj() { printf '%s/.claude/projects/%s' "$1" "$(printf '%s' "$1" | sed 's#[/.]#-#g')"; }
sm_box() {  # prints a fresh sandbox HOME with an empty transcript dir
  local d; d="$(mktemp -d "$SMTMP/home.XXXXXX")"; mkdir -p "$(sm_proj "$d")"; printf '%s' "$d"
}
sm_line() {  # $1 = model ("" = omit), $2 = effort ("" = omit) -> one assistant JSONL line
  local m="" e=""
  [[ -n "${1-}" ]] && m="\"model\":\"$1\","
  [[ -n "${2-}" ]] && e="\"effort\":\"$2\","
  printf '{"parentUuid":"p","message":{%s"role":"assistant","content":[]},%s"type":"assistant","uuid":"u"}\n' \
    "$m" "$e"
}
sm_run() {  # $1 = sandbox HOME; the stub tmux shadows the real one
  ( export HOME="$1" PATH="$STUBDIR:$PATH" STUB_SETLOG="$SMTMP/setlog" \
           STUB_MODEL="${FALLBACK_MODEL-}" STUB_EFFORT="${FALLBACK_EFFORT-}"
    sh "$SM" )
}
FALLBACK_MODEL="fable 5"; FALLBACK_EFFORT="medium"   # what start.sh seeded

# The headline bug: the transcript says opus 4.8, so the header must say so —
# whatever the launch-time option (fable 5) still holds.
S="$(sm_box)"; sm_line claude-opus-4-8 xhigh > "$(sm_proj "$S")/a.jsonl"
[[ "$(sm_run "$S")" == "opus 4.8 · xhigh" ]] \
  && ok "live model+effort win over the stale launch-time option" \
  || bad "live model+effort not used (got '$(sm_run "$S")')"
# …and a later turn with a different model is picked up with no restart.
sm_line claude-sonnet-5 low >> "$(sm_proj "$S")/a.jsonl"
[[ "$(sm_run "$S")" == "sonnet 5 · low" ]] \
  && ok "a mid-session model switch shows up on the next tick" \
  || bad "mid-session switch not picked up (got '$(sm_run "$S")')"

# Fresh launch, no transcript yet -> the launch-time option, never blank.
S="$(sm_box)"
[[ "$(sm_run "$S")" == "fable 5 · medium" ]] \
  && ok "no transcript -> launch-time model/effort" || bad "no transcript -> wrong fallback"

# Newest transcript wins (a resumed session leaves older files behind).
S="$(sm_box)"; P="$(sm_proj "$S")"
sm_line claude-haiku-4-5-20251001 high > "$P/old.jsonl"
sm_line claude-opus-4-8 xhigh > "$P/new.jsonl"
touch -t 202001010000 "$P/old.jsonl"
[[ "$(sm_run "$S")" == "opus 4.8 · xhigh" ]] \
  && ok "most-recently-modified transcript is the one read" \
  || bad "older transcript won (got '$(sm_run "$S")')"

# A turn without an effort field -> the same neutral label resolve_effort uses.
S="$(sm_box)"; sm_line claude-opus-4-8 "" > "$(sm_proj "$S")/a.jsonl"
[[ "$(sm_run "$S")" == "opus 4.8 · default" ]] \
  && ok "missing effort field -> 'default'" || bad "missing effort -> wrong label"

# Torn last line (mid-write): "type":"assistant" is written late, so a partial
# line can't match and the previous complete turn is what shows — never blank.
S="$(sm_box)"; P="$(sm_proj "$S")"
sm_line claude-opus-4-8 xhigh > "$P/a.jsonl"
printf '%s' '{"parentUuid":"p","message":{"model":"claude-sonn' >> "$P/a.jsonl"
[[ "$(sm_run "$S")" == "opus 4.8 · xhigh" ]] \
  && ok "torn final line -> previous turn kept, no flash of blank" \
  || bad "torn final line broke the segment (got '$(sm_run "$S")')"

# Bounded read: with the only assistant line far outside the tail window, the
# segment falls back instead of scanning the whole (arbitrarily large) file.
S="$(sm_box)"; P="$(sm_proj "$S")"
sm_line claude-opus-4-8 xhigh > "$P/a.jsonl"
awk 'BEGIN { s = sprintf("%0200000d", 0); printf "{\"pad\":\"%s\"}\n", s }' >> "$P/a.jsonl"
[[ "$(sm_run "$S")" == "fable 5 · medium" ]] \
  && ok "reads only a bounded tail (old turn beyond the window is not scanned)" \
  || bad "tail is not bounded (got '$(sm_run "$S")')"

# The live value is written back to the options, so the fallback above is the
# last value actually DISPLAYED rather than a launch-time fossil.
S="$(sm_box)"; sm_line claude-opus-4-8 xhigh > "$(sm_proj "$S")/a.jsonl"
: > "$SMTMP/setlog"; sm_run "$S" >/dev/null
grep -q '@concierge_model=opus 4.8' "$SMTMP/setlog" \
  && ok "live value is cached back into @concierge_model" \
  || bad "live value not cached back into @concierge_model"
# Unchanged value -> no pointless server round-trip every 5 seconds.
FALLBACK_MODEL="opus 4.8"; FALLBACK_EFFORT="xhigh"
: > "$SMTMP/setlog"; sm_run "$S" >/dev/null
[[ ! -s "$SMTMP/setlog" ]] && ok "unchanged value -> no option write per tick" \
  || bad "writes the option on every tick"
FALLBACK_MODEL="fable 5"; FALLBACK_EFFORT="medium"
rm -rf "$SMTMP"

# 3c) narrow-display mode: auto-detect, with both-direction override ---------
echo "› narrow mode (width auto-detect)"
# Source the real functions out of start.sh so we test the shipped code.
NHELP="$(mktemp)"
sed -n '/^term_cols()/,/^}/p;/^want_narrow()/,/^}/p' "$REPO/config/start.sh" > "$NHELP"
# shellcheck disable=SC1090
. "$NHELP"
# $1 = CONCIERGE_NARROW ("" = auto), $2 = cols ("" = unknown), $3 = want, $4 = label
check_narrow() {
  local got; got="$(want_narrow "$1" "$2" 70)"
  [[ "$got" == "$3" ]] && ok "narrow: $4" || bad "narrow: $4 (got $got, want $3)"
}
# Default (auto) on any normal desktop width must be FULL WIDTH.
check_narrow "" 120 0 "auto @120 cols -> full width"
check_narrow "" 80  0 "auto @80 cols (stock terminal) -> full width"
check_narrow "" 70  0 "auto @70 cols (at threshold) -> full width"
# Genuinely narrow viewports still get the instruction.
check_narrow "" 69  1 "auto @69 cols -> narrow"
check_narrow "" 44  1 "auto @44 cols (tablet SSH) -> narrow"
# Unknown / bogus width must NEVER mean narrow (non-TTY, cron, COLUMNS=0 leak).
check_narrow "" ""    0 "auto, width unknown -> full width"
check_narrow "" 0     0 "auto, width 0 -> full width"
check_narrow "" abc   0 "auto, non-numeric width -> full width"
check_narrow "" -5    0 "auto, negative width -> full width"
# Explicit override wins in BOTH directions, whatever the measurement says.
check_narrow 1 120 1 "CONCIERGE_NARROW=1 forces narrow on a wide terminal"
check_narrow 0 44  0 "CONCIERGE_NARROW=0 forces full width on a narrow terminal"
check_narrow 1 ""  1 "CONCIERGE_NARROW=1 works with width unknown"
# term_cols only ever yields a plain number or nothing — never a bogus token.
# (Runs green both with a tty, e.g. inside Concierge, and without, e.g. in CI.)
tc="$(term_cols)"
[[ -z "$tc" || "$tc" =~ ^[0-9]+$ ]] \
  && ok "term_cols returns a number or empty (got '${tc:-<empty>}')" \
  || bad "term_cols returned a non-numeric value ('$tc')"
rm -f "$NHELP"
# Regressions: the default must not be hardcoded on, and the prompt must not
# assert a device (it described the user's iPad as fact through v0.5.0).
grep -q 'CONCIERGE_NARROW:-1' "$REPO/config/start.sh" \
  && bad "start.sh still hardcodes narrow mode ON by default" \
  || ok "narrow mode is not hardcoded ON"
grep -qi 'ipad' "$REPO/config/start.sh" \
  && bad "start.sh still asserts 'iPad' in the injected prompt" \
  || ok "injected prompt describes a viewport, not a device"

# 3d) settings.json seeding (pure shell — no python3 in the launch path) -----
echo "› settings.json seeding"
grep -q 'python3' "$REPO/config/start.sh" \
  && bad "start.sh still shells out to python3" \
  || ok "start.sh has no python3 dependency"

# Source the real function out of start.sh so we test the shipped code.
ETS="$(mktemp)"
sed -n '/^ensure_setting()/,/^}/p' "$REPO/config/start.sh" > "$ETS"
# shellcheck disable=SC1090
. "$ETS"
# A PATH holding the standard userland but deliberately NO jq, so the pure-shell
# fallback is exercised even on a machine that has jq installed.
NOJQDIR="$(mktemp -d)"
for t in grep sed awk tr mv rm mkdir; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQDIR/$t"
done

ets_run() {  # $1 = HOME, $2 = jq|nojq, $3.. = ensure_setting args (default: the
  # timestamps call). Subshell: no env leaks into the runner.
  local -a call=( "${@:3}" )
  [[ ${#call[@]} -eq 0 ]] && call=( showMessageTimestamps true force )
  if [[ "$2" == nojq ]]; then ( export HOME="$1" PATH="$NOJQDIR"; ensure_setting "${call[@]}" )
  else                        ( export HOME="$1"; ensure_setting "${call[@]}" ); fi
}
ets_box() {  # $1 = initial settings.json content ("" = no file), $2 = "empty" to touch a 0-byte file
  local d; d="$(mktemp -d)"; mkdir -p "$d/.claude"
  [[ -n "${1-}" ]] && printf '%s' "$1" > "$d/.claude/settings.json"
  [[ "${2-}" == empty ]] && : > "$d/.claude/settings.json"
  printf '%s' "$d"
}
ets_val() {  # $1 = file, $2 = key (default showMessageTimestamps) -> JSON value,
  # "<none>" when absent, or INVALID when the file doesn't parse
  python3 - "$1" "${2:-showMessageTimestamps}" <<'PY' 2>/dev/null || printf 'INVALID'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2], "<none>")), end="")
PY
}
ets_rest() {  # every OTHER key, canonicalised — proves nothing else was touched
  python3 - "$1" "${2:-showMessageTimestamps}" <<'PY' 2>/dev/null || printf 'INVALID'
import json, sys
d = json.load(open(sys.argv[1])); d.pop(sys.argv[2], None)
print(json.dumps(d, sort_keys=True), end="")
PY
}

WITHOUT=$'{\n  "model": "claude-opus-5",\n  "effortLevel": "high"\n}\n'
WITHFALSE=$'{\n  "model": "claude-opus-5",\n  "showMessageTimestamps": false\n}\n'
WITHTRUE=$'{\n  "model": "claude-opus-5",\n  "showMessageTimestamps": true\n}\n'
NESTED=$'{\n  "model": "claude-opus-5",\n  "nested": {\n    "showMessageTimestamps": false\n  }\n}\n'
WITHSTYLE=$'{\n  "model": "claude-opus-5",\n  "outputStyle": "Explanatory"\n}\n'
NESTEDSTYLE=$'{\n  "model": "claude-opus-5",\n  "nested": {\n    "outputStyle": "Learning"\n  }\n}\n'

for mode in jq nojq; do
  if [[ "$mode" == jq ]] && ! have jq; then
    ok "[jq] jq not installed — opportunistic jq path skipped"
    continue
  fi
  # Missing file -> created, valid JSON, key true.
  S="$(ets_box "")"; ets_run "$S" "$mode"
  [[ "$(ets_val "$S/.claude/settings.json")" == "true" ]] \
    && ok "[$mode] missing settings.json -> created with the key true" \
    || bad "[$mode] missing settings.json not handled"
  rm -rf "$S"
  # Zero-byte file -> same as missing.
  S="$(ets_box "" empty)"; ets_run "$S" "$mode"
  [[ "$(ets_val "$S/.claude/settings.json")" == "true" ]] \
    && ok "[$mode] zero-byte settings.json -> key true" \
    || bad "[$mode] zero-byte settings.json not handled"
  rm -rf "$S"
  # Key absent -> added, every pre-existing key preserved.
  S="$(ets_box "$WITHOUT")"; ets_run "$S" "$mode"
  [[ "$(ets_val "$S/.claude/settings.json")" == "true" ]] \
    && ok "[$mode] key absent -> added as true" || bad "[$mode] key absent -> not added"
  [[ "$(ets_rest "$S/.claude/settings.json")" == '{"effortLevel": "high", "model": "claude-opus-5"}' ]] \
    && ok "[$mode] other keys preserved when adding" || bad "[$mode] other keys lost when adding"
  rm -rf "$S"
  # Key false -> flipped, other keys untouched.
  S="$(ets_box "$WITHFALSE")"; ets_run "$S" "$mode"
  [[ "$(ets_val "$S/.claude/settings.json")" == "true" ]] \
    && ok "[$mode] false -> flipped to true" || bad "[$mode] false -> not flipped"
  [[ "$(ets_rest "$S/.claude/settings.json")" == '{"model": "claude-opus-5"}' ]] \
    && ok "[$mode] other keys preserved when flipping" || bad "[$mode] other keys lost when flipping"
  rm -rf "$S"
  # Already true -> byte-for-byte no-op (never reformat someone's file).
  S="$(ets_box "$WITHTRUE")"; F="$S/.claude/settings.json"
  cp "$F" "$S/before"; ets_run "$S" "$mode"
  cmp -s "$S/before" "$F" && ok "[$mode] already true -> file unchanged byte-for-byte" \
    || bad "[$mode] already true -> file was rewritten"
  rm -rf "$S"
  # Same-named key NESTED only: the top-level key must still be added, and the
  # nested one left alone (the fallback's patterns anchor on the 2-space indent).
  S="$(ets_box "$NESTED")"; ets_run "$S" "$mode"
  [[ "$(ets_val "$S/.claude/settings.json")" == "true" ]] \
    && ok "[$mode] nested same-named key -> top-level key still added" \
    || bad "[$mode] nested same-named key -> top-level key missing"
  [[ "$(ets_rest "$S/.claude/settings.json")" == '{"model": "claude-opus-5", "nested": {"showMessageTimestamps": false}}' ]] \
    && ok "[$mode] nested key left untouched" || bad "[$mode] nested key was rewritten"
  rm -rf "$S"
  # Malformed JSON: the launcher runs under `set -e`, so the block must not
  # abort it — reproduce the shipped call site verbatim and check we get past it.
  S="$(ets_box '{ "model": "x",')"
  survived="$( set -e
               export HOME="$S"
               if [[ "$mode" == nojq ]]; then export PATH="$NOJQDIR"; fi
               ensure_setting showMessageTimestamps true force 2>/dev/null || true
               ensure_setting outputStyle '"Concise"' seed 2>/dev/null || true
               printf 'yes' )"
  [[ "$survived" == yes ]] && ok "[$mode] malformed JSON -> launch still proceeds" \
    || bad "[$mode] malformed JSON -> aborted the launch path"
  rm -rf "$S"

  # ── outputStyle: SEEDED, not forced ─────────────────────────────────────
  # A default for a fresh install, but /output-style writes back to this same
  # file, so a style the user picked must survive the next launch untouched.
  # Missing file -> created with the default style.
  S="$(ets_box "")"; ets_run "$S" "$mode" outputStyle '"Concise"' seed
  [[ "$(ets_val "$S/.claude/settings.json" outputStyle)" == '"Concise"' ]] \
    && ok "[$mode] missing settings.json -> outputStyle Concise" \
    || bad "[$mode] missing settings.json -> outputStyle not seeded"
  rm -rf "$S"
  # Key absent -> seeded, every pre-existing key preserved.
  S="$(ets_box "$WITHOUT")"; ets_run "$S" "$mode" outputStyle '"Concise"' seed
  [[ "$(ets_val "$S/.claude/settings.json" outputStyle)" == '"Concise"' ]] \
    && ok "[$mode] outputStyle absent -> seeded Concise" \
    || bad "[$mode] outputStyle absent -> not seeded"
  [[ "$(ets_rest "$S/.claude/settings.json" outputStyle)" == '{"effortLevel": "high", "model": "claude-opus-5"}' ]] \
    && ok "[$mode] other keys preserved when seeding outputStyle" \
    || bad "[$mode] other keys lost when seeding outputStyle"
  rm -rf "$S"
  # The user's own style wins — forever, not just for this session.
  S="$(ets_box "$WITHSTYLE")"; F="$S/.claude/settings.json"
  cp "$F" "$S/before"; ets_run "$S" "$mode" outputStyle '"Concise"' seed
  [[ "$(ets_val "$F" outputStyle)" == '"Explanatory"' ]] \
    && ok "[$mode] existing outputStyle is not overwritten" \
    || bad "[$mode] existing outputStyle was overwritten"
  cmp -s "$S/before" "$F" && ok "[$mode] existing outputStyle -> file unchanged byte-for-byte" \
    || bad "[$mode] existing outputStyle -> file was rewritten"
  rm -rf "$S"
  # null / "" count as unset: seed over them.
  for empty in 'null' '""'; do
    S="$(ets_box "$(printf '{\n  "model": "x",\n  "outputStyle": %s\n}\n' "$empty")")"
    ets_run "$S" "$mode" outputStyle '"Concise"' seed
    [[ "$(ets_val "$S/.claude/settings.json" outputStyle)" == '"Concise"' ]] \
      && ok "[$mode] outputStyle $empty -> treated as unset, seeded" \
      || bad "[$mode] outputStyle $empty -> not seeded"
    rm -rf "$S"
  done
  # A same-named key nested elsewhere must not read as "already set".
  S="$(ets_box "$NESTEDSTYLE")"; ets_run "$S" "$mode" outputStyle '"Concise"' seed
  [[ "$(ets_val "$S/.claude/settings.json" outputStyle)" == '"Concise"' ]] \
    && ok "[$mode] nested outputStyle -> top-level key still seeded" \
    || bad "[$mode] nested outputStyle -> top-level key missing"
  [[ "$(ets_rest "$S/.claude/settings.json" outputStyle)" == '{"model": "claude-opus-5", "nested": {"outputStyle": "Learning"}}' ]] \
    && ok "[$mode] nested outputStyle left untouched" || bad "[$mode] nested outputStyle rewritten"
  rm -rf "$S"

  # Both shipped call sites, in order, against a virgin HOME: the two settings
  # coexist and the result is still valid JSON.
  S="$(ets_box "")"
  ets_run "$S" "$mode" showMessageTimestamps true force
  ets_run "$S" "$mode" outputStyle '"Concise"' seed
  F="$S/.claude/settings.json"
  [[ "$(ets_val "$F")" == "true" && "$(ets_val "$F" outputStyle)" == '"Concise"' ]] \
    && ok "[$mode] fresh launch seeds both settings, valid JSON" \
    || bad "[$mode] fresh launch did not seed both settings"
  rm -rf "$S"
done
rm -f "$ETS"; rm -rf "$NOJQDIR"

# Placement: the seeding must sit on the fresh-launch path, AFTER the reattach
# exec — otherwise reattaching a live session would rewrite settings under it.
att="$(grep -n 'exec env TMUX= tmux -L "\$SOCK" attach' "$REPO/config/start.sh" | head -1 | cut -d: -f1)"
seed="$(grep -n '^ensure_setting ' "$REPO/config/start.sh" | head -1 | cut -d: -f1)"
[[ -n "$att" && -n "$seed" && "$seed" -gt "$att" ]] \
  && ok "seeding runs only on the fresh-launch path (after the reattach exec)" \
  || bad "seeding is not behind the reattach exec (att=$att seed=$seed)"
# Both call sites are actually wired up, with the intended modes.
grep -q '^ensure_setting showMessageTimestamps true force' "$REPO/config/start.sh" \
  && ok "showMessageTimestamps is force-applied every launch" || bad "timestamps call site missing"
grep -q "^ensure_setting outputStyle '\"Concise\"' seed" "$REPO/config/start.sh" \
  && ok "outputStyle is seeded (not forced)" || bad "outputStyle call site missing"

# 3e) helper sessions (helpers.conf) -----------------------------------------
# All of this runs on a throwaway socket — never the live -L concierge one.
echo "› helper sessions"
if have tmux; then
  HELP="$(mktemp -d)"
  HELPERS_CONF="$HELP/helpers.conf"
  SOCK="cc_helpers_$$"
  T() { tmux -L "$SOCK" "$@"; }          # what run_helpers talks through
  RH="$(mktemp)"
  sed -n '/^run_helpers()/,/^}/p' "$REPO/config/start.sh" > "$RH"
  # shellcheck disable=SC1090
  . "$RH"

  rh_run() {   # $1 = CONCIERGE_HELPERS ("" = unset). Prints stdout+stderr.
    if [[ -n "${1-}" ]]; then ( export CONCIERGE_HELPERS="$1"; run_helpers 2>&1 )
    else                      ( run_helpers 2>&1 ); fi
  }
  rh_live() {  # is session $1 alive on the sandbox socket?
    tmux -L "$SOCK" has-session -t "$1" 2>/dev/null
  }

  # Missing helpers.conf: silent, no error.
  out="$(rh_run)"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] && ok "no helpers.conf -> silent, rc 0" \
    || bad "no helpers.conf -> rc=$rc out='$out'"

  # All-comments/blank file: same as missing.
  printf '# name\tcommand\n\n   \n' > "$HELPERS_CONF"
  out="$(rh_run)"
  [[ -z "$out" ]] && ok "comments/blank-only helpers.conf -> no helpers, no output" \
    || bad "comments-only file produced output ('$out')"

  # CONCIERGE_HELPERS=0: entries present, nothing created, nothing said.
  printf 'off1\tsleep 30\noff2\tsleep 30\n' > "$HELPERS_CONF"
  out="$(rh_run 0)"
  if [[ -z "$out" ]] && ! rh_live off1 && ! rh_live off2; then
    ok "CONCIERGE_HELPERS=0 -> creates nothing, says nothing"
  else
    bad "CONCIERGE_HELPERS=0 still ran ('$out')"
  fi

  # Two helpers: both come up, and the command keeps its own spacing (we split
  # on the FIRST tab only, so the marker below lands verbatim).
  MARK="$HELP/cmd.out"
  printf 'h1\tsleep 30\nh2\tsh -c '"'"'printf "%%s" "a  b" > %s; sleep 30'"'"'\n' "$MARK" \
    > "$HELPERS_CONF"
  out="$(rh_run)"
  if rh_live h1 && rh_live h2; then ok "two helpers -> both sessions created"
  else bad "two helpers -> not both created ('$out')"; fi
  [[ "$out" == *"2 created, 0 skipped, 0 failed"* ]] \
    && ok "summary reports 2 created" || bad "summary wrong ('$out')"
  # Give the helper's own command a moment to land its marker.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$MARK" ]] && break; sleep 0.2; done
  [[ "$(cat "$MARK" 2>/dev/null)" == "a  b" ]] \
    && ok "command after the first tab is passed through verbatim" \
    || bad "command was mangled ('$(cat "$MARK" 2>/dev/null)')"

  # Second run with the same sessions alive: nothing created, both skipped.
  out="$(rh_run)"
  [[ "$out" == *"0 created, 2 skipped, 0 failed"* ]] \
    && ok "second run -> 2 skipped, nothing recreated" || bad "second run wrong ('$out')"

  # A live session is never killed or recreated by the skip path.
  before="$(tmux -L "$SOCK" display-message -p -t h1 '#{session_created}' 2>/dev/null)"
  rh_run >/dev/null
  after="$(tmux -L "$SOCK" display-message -p -t h1 '#{session_created}' 2>/dev/null)"
  [[ -n "$before" && "$before" == "$after" ]] \
    && ok "existing helper session left strictly alone" || bad "existing helper was recreated"

  # A helper whose command doesn't exist: named in a warning, the good one still
  # comes up, and the caller's exit status is untouched (start.sh runs `set -e`).
  printf 'bad1\tdefinitely-not-a-binary-xyz\ngood1\tsleep 30\n' > "$HELPERS_CONF"
  out="$( set -e; run_helpers 2>&1; printf '\nrc=%s' "$?" )"
  [[ "$out" == *'helper "bad1" failed to start'* ]] \
    && ok "failing helper is named in a warning" || bad "no warning for the failing helper ('$out')"
  rh_live good1 && ok "a failing helper does not stop the next one" \
    || bad "the helper after the failing one never started"
  [[ "$out" == *"rc=0"* ]] && ok "run_helpers returns 0 (exit status unaffected)" \
    || bad "run_helpers returned non-zero ('$out')"
  [[ "$out" == *"1 created, 0 skipped, 1 failed"* ]] \
    && ok "summary counts the failure" || bad "failure not counted ('$out')"

  # Malformed line: warned with its line number, the rest still processed.
  printf '# comment\nno-tab-here\nafter\tsleep 30\n' > "$HELPERS_CONF"
  out="$(rh_run)"
  [[ "$out" == *"helpers.conf line 2"* ]] \
    && ok "malformed line is reported with its line number" || bad "malformed line not reported ('$out')"
  rh_live after && ok "parsing continues past a malformed line" \
    || bad "a malformed line stopped the rest of the file"

  # A helper named like the main session counts as "already exists" -> skipped.
  tmux -L "$SOCK" new-session -d -s concierge 'sleep 30' 2>/dev/null
  printf 'concierge\tsleep 30\n' > "$HELPERS_CONF"
  out="$(rh_run)"
  [[ "$out" == *"0 created, 1 skipped, 0 failed"* ]] \
    && ok "a helper colliding with the main session name is skipped" \
    || bad "main-session collision not skipped ('$out')"

  tmux -L "$SOCK" kill-server 2>/dev/null
  rm -rf "$HELP"; rm -f "$RH"
  unset -f T
else
  bad "tmux not installed (helper sessions test skipped)"
fi

# 3f) snapshot: capture the live socket into a manifest ----------------------
# Everything runs on a throwaway socket with a fake `claude` — never the real
# socket, and no customer/engagement names anywhere.
echo "› snapshot (working set capture)"
if have tmux; then
  SNAP="$(cd "$(mktemp -d)" && pwd -P)"
  SSOCK="cc_snap_$$"
  MANIFEST="$SNAP/manifest"
  FAKE="$SNAP/bin/claude"
  mkdir -p "$SNAP/bin" "$SNAP/w1" "$SNAP/w2"
  # A fake claude that stays alive: the real one is found by walking a pane's
  # children for a claude command line, and this is found exactly the same way.
  printf '#!/bin/sh\nsleep 300\n' > "$FAKE"; chmod +x "$FAKE"
  ST() { tmux -L "$SSOCK" "$@"; }
  snap() { ( export CONCIERGE_SOCK="$SSOCK" CONCIERGE_MANIFEST="$MANIFEST"
             sh "$REPO/config/snapshot.sh" >/dev/null 2>&1 ); }
  rows() { grep -v '^#' "$MANIFEST" 2>/dev/null; }

  # Empty-ish socket: the main session alone is a header and nothing else.
  ST new-session -d -s concierge -c "$SNAP" "$FAKE --dangerously-skip-permissions --chrome"
  snap
  if [[ -s "$MANIFEST" ]] && [[ -z "$(rows)" ]] && head -1 "$MANIFEST" | grep -q '^#'; then
    ok "only the main session -> header, zero rows (not an error)"
  else
    bad "empty socket -> unexpected manifest ($(rows))"
  fi

  # A populated socket: two sessions with different launch flags, a split
  # inside the main session, a bare shell that has nothing to restore, and a
  # dash grid of two tiles side by side.
  ST split-window -d -t concierge -c "$SNAP/w2" \
     "$FAKE --model claude-opus-5 --append-system-prompt 'pipe | inside'"
  ST new-session -d -s work -c "$SNAP/w1" "$FAKE --model claude-sonnet-5 --dangerously-skip-permissions"
  ST new-session -d -s web  -c "$SNAP/w2" "$FAKE --chrome"
  ST new-session -d -s shellonly -c "$SNAP" 'sleep 300'
  ST new-session -d -s grid -c "$SNAP" "env TMUX= tmux -L $SSOCK attach -t work"
  ST split-window -h -d -t grid "env TMUX= tmux -L $SSOCK attach -t web"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(ST list-clients -F '#{client_session}' 2>/dev/null | wc -l)" -ge 2 ]] && break
    sleep 0.3
  done
  snap

  grep -q "^SESSION|work|$SNAP/w1|claude-sonnet-5|--model claude-sonnet-5 --dangerously-skip-permissions$" "$MANIFEST" \
    && ok "SESSION row: cwd + model + flags for a --model session" \
    || bad "SESSION row for 'work' wrong: $(grep '^SESSION|work' "$MANIFEST")"
  grep -q "^SESSION|web|$SNAP/w2||--chrome$" "$MANIFEST" \
    && ok "SESSION row: a --chrome session (no model) is captured" \
    || bad "SESSION row for 'web' wrong: $(grep '^SESSION|web' "$MANIFEST")"
  grep -q '^SESSION|concierge|' "$MANIFEST" \
    && bad "the main session should not get a SESSION row" \
    || ok "the main session is excluded from SESSION rows"
  grep -q '^SESSION|grid|' "$MANIFEST" \
    && bad "a dash grid should not also be a SESSION row" \
    || ok "a dash grid is not double-counted as a session"
  grep -q '^SESSION|shellonly|' "$MANIFEST" \
    && bad "a bare shell was captured (nothing to restore)" \
    || ok "a pane with no claude command line is omitted, not an error"
  # SESSION rows == list-sessions minus concierge, minus the grid.
  want="$(ST list-sessions -F '#{session_name}' | grep -vx concierge | grep -vx grid | grep -vx shellonly | sort | tr '\n' ' ')"
  got="$(grep '^SESSION|' "$MANIFEST" | cut -d'|' -f2 | sort | tr '\n' ' ')"
  [[ "$want" == "$got" ]] && ok "SESSION rows match list-sessions ($got)" \
    || bad "SESSION rows '$got' != sessions '$want'"
  # The split inside the main session, with a literal | in its appended prompt.
  sp="$(grep '^SPLIT|concierge|' "$MANIFEST")"
  [[ -n "$sp" && "$sp" == *"|$SNAP/w2|claude-opus-5|--model claude-opus-5 --append-system-prompt pipe | inside" ]] \
    && ok "SPLIT row keeps everything after the last fixed pipe verbatim" \
    || bad "SPLIT row wrong: $sp"
  grep -q '^DASH|grid|2|work web$' "$MANIFEST" \
    && ok "DASH row: membership and column count read back off the socket" \
    || bad "DASH row wrong: $(grep '^DASH' "$MANIFEST")"

  # Round trip: snapshot -> destroy -> restore (stub; slice 2 is the real one)
  # -> snapshot again. Every failure mode in here is silent, so this is the
  # acceptance core: the two manifests must agree line for line.
  cp "$MANIFEST" "$SNAP/before"
  ST kill-session -t work 2>/dev/null; ST kill-session -t web 2>/dev/null
  ST kill-session -t grid 2>/dev/null || true
  ST kill-pane -t concierge.1 2>/dev/null
  restore_stub() {  # replays a manifest; parses by record, never by token count
    local kind name cwd model rest parent title first m
    # Sessions first — a grid can only attach to tiles that already exist.
    while IFS='|' read -r kind name cwd model rest; do
      ST new-session -d -s "$name" -c "$cwd" "$FAKE $rest"
    done < <(grep '^SESSION|' "$SNAP/before")
    # Splits carry one more fixed field before the trailing flags.
    while IFS='|' read -r kind parent title cwd model rest; do
      ST split-window -d -t "$parent" -c "$cwd" "$FAKE $rest"
    done < <(grep '^SPLIT|' "$SNAP/before")
    # Then the grids, one pane per member, in the recorded order.
    while IFS='|' read -r kind name cols rest; do
      first=1
      for m in $rest; do
        if [[ $first == 1 ]]; then
          ST new-session -d -s "$name" -c "$SNAP" "env TMUX= tmux -L $SSOCK attach -t $m"
          first=0
        else
          ST split-window -h -d -t "$name" "env TMUX= tmux -L $SSOCK attach -t $m"
        fi
      done
    done < <(grep '^DASH|' "$SNAP/before")
  }
  restore_stub >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(ST list-clients -F '#{client_session}' 2>/dev/null | wc -l)" -ge 2 ]] && break
    sleep 0.3
  done
  snap
  if diff <(grep -v '^#' "$SNAP/before") <(grep -v '^#' "$MANIFEST") >/dev/null; then
    ok "round trip: snapshot -> destroy -> restore -> snapshot is identical"
  else
    bad "round trip differs:
$(diff <(grep -v '^#' "$SNAP/before") <(grep -v '^#' "$MANIFEST"))"
  fi
  # Only the header moves between captures.
  [[ "$(head -1 "$SNAP/before")" == '#'* && "$(head -1 "$MANIFEST")" == '#'* ]] \
    && ok "both captures carry a timestamped header line" || bad "header line missing"

  # The manifest is written atomically and overwritten in place, no history.
  ls "$(dirname "$MANIFEST")" | grep -q "^$(basename "$MANIFEST")\..*" \
    && bad "a temp manifest was left behind" || ok "atomic write leaves no temp file"

  # `concierge snapshot` dispatches here without opening a window.
  grep -q 'snapshot' "$REPO/bin/concierge" \
    && ok "bin/concierge dispatches the snapshot subcommand" \
    || bad "bin/concierge has no snapshot subcommand"

  ST kill-server 2>/dev/null
  rm -rf "$SNAP"
  unset -f ST snap rows restore_stub
else
  bad "tmux not installed (snapshot test skipped)"
fi

# 3g) restore: rebuild the working set from a manifest -----------------------
# Throwaway socket, fake `claude`, generic names — never the real socket.
echo "› restore (working set rebuild)"
if have tmux; then
  RST="$(cd "$(mktemp -d)" && pwd -P)"
  RSOCK="cc_rest_$$"
  RMAN="$RST/manifest"
  RFAKE="$RST/bin/claude"
  mkdir -p "$RST/bin" "$RST/a" "$RST/b"
  printf '#!/bin/sh\nsleep 300\n' > "$RFAKE"; chmod +x "$RFAKE"
  RT() { tmux -L "$RSOCK" "$@"; }
  restore() { ( export CONCIERGE_SOCK="$RSOCK" CONCIERGE_MANIFEST="$RMAN" \
                       CONCIERGE_CLAUDE="$RFAKE" CONCIERGE_RESTORE_READY_TIMEOUT=3
                sh "$REPO/config/restore.sh" "$@" 2>&1 ); }
  sessions() { RT list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }

  # No manifest at all: a clear message, no crash.
  out="$(restore)"; rc=$?
  [[ $rc -ne 0 && "$out" == *"no manifest"* ]] \
    && ok "no manifest -> clear message, no crash" || bad "no manifest -> rc=$rc '$out'"

  {
    printf '# claude-concierge session manifest — captured %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'SPLIT|alpha|notes|%s|claude-opus-5|--continue --model claude-opus-5\n' "$RST/b"
    printf 'DASH|grid|2|alpha beta\n'
    printf 'SESSION|alpha|%s|claude-sonnet-5|--continue --model claude-sonnet-5\n' "$RST/a"
    printf 'SESSION|beta|%s||--continue --chrome\n' "$RST/b"
    printf 'SESSION|gone|%s/nowhere||--continue\n' "$RST"
  } > "$RMAN"

  # --list prints the manifest and changes nothing.
  out="$(restore --list)"
  [[ "$out" == *"SESSION|alpha|"* && "$out" == *"DASH|grid|"* && -z "$(sessions)" ]] \
    && ok "--list prints the manifest, restores nothing" || bad "--list wrong ('$out')"
  [[ "$out" == *"manifest captured"* ]] \
    && ok "capture time is printed on every run" || bad "capture time not printed"

  # --dry-run reports and changes nothing.
  out="$(restore --dry-run)"
  [[ "$out" == *"would restore: alpha"* && -z "$(sessions)" ]] \
    && ok "--dry-run reports without creating anything" || bad "--dry-run created something ('$out')"

  # The real thing: two sessions with different flags, a split, and a grid.
  out="$(restore)"; rc=$?
  [[ "$(sessions)" == *"alpha"* && "$(sessions)" == *"beta"* ]] \
    && ok "restore recreates the manifest's sessions" || bad "sessions missing ('$(sessions)')"
  cmd="$(RT list-panes -s -t alpha -F '#{pane_pid}' | head -1)"
  RT list-panes -s -t alpha -F '#{pane_current_path}' | grep -qx "$RST/a" \
    && ok "a restored session lands in its recorded cwd" || bad "wrong cwd for alpha"
  [[ "$(RT list-panes -s -t alpha -F '#{pane_title}' | grep -cx notes)" == 1 ]] \
    && ok "the split comes back, titled from the manifest" || bad "split/title missing"
  [[ "$(RT list-panes -s -t alpha | wc -l | tr -d ' ')" == 2 ]] \
    && ok "the split is a second pane in its parent" || bad "split pane count wrong"
  RT has-session -t grid 2>/dev/null && ok "the dash grid is assembled" || bad "dash grid missing"
  [[ "$(RT list-panes -t grid | wc -l | tr -d ' ')" == 2 ]] \
    && ok "the grid has one pane per member" || bad "grid pane count wrong"

  # A missing cwd is skipped with a warning, the rest still comes up, and the
  # exit status says something was skipped.
  [[ "$out" == *"skipping gone"* ]] \
    && ok "a session whose cwd is gone is skipped with a warning" || bad "no warning for missing cwd"
  RT has-session -t gone 2>/dev/null && bad "the session with a missing cwd was started" \
    || ok "the session with a missing cwd was not started"
  [[ $rc -ne 0 ]] && ok "exit status reflects the skip" || bad "skips did not affect exit status"

  # Second run is a no-op: same names, nothing killed or recreated.
  born="$(RT display -p -t alpha '#{session_created}')"
  out="$(restore)"
  [[ "$out" == *"already up: alpha"* && "$out" == *"already up: grid"* ]] \
    && ok "a second restore reports what's already up" || bad "second restore wrong ('$out')"
  [[ "$(RT display -p -t alpha '#{session_created}')" == "$born" ]] \
    && ok "an existing session is never killed or recreated" || bad "session was recreated"
  [[ "$(RT list-panes -s -t alpha | wc -l | tr -d ' ')" == 2 ]] \
    && ok "splits are idempotent (matched by pane title)" || bad "a duplicate split was added"
  out="$(restore --dry-run)"
  [[ "$out" == *"already up"* && "$out" != *"would restore"* ]] \
    && ok "--dry-run on a full socket reports 'already up' only" || bad "--dry-run wrong ('$out')"

  # A single name restores just that session.
  RT kill-session -t beta 2>/dev/null
  out="$(restore beta)"
  RT has-session -t beta 2>/dev/null && ok "restore <name> brings back just that session" \
    || bad "restore <name> did not restore it"

  # --dash naming something absent from the manifest: named error, no action.
  out="$(restore --dash nosuch)"; rc=$?
  [[ $rc -ne 0 && "$out" == *"no dash named nosuch"* ]] \
    && ok "--dash for an unknown grid errors by name" || bad "--dash unknown wrong ('$out')"

  # Readiness timeout: a member that's up but never gets a claude under it can
  # never be "ready", so the grid must warn and assemble anyway, not block. (A
  # pane that just dies takes its session with it, which is a different path —
  # this is the slow/stuck one the timeout exists for.)
  RT kill-session -t grid 2>/dev/null; RT kill-session -t beta 2>/dev/null
  RT new-session -d -s beta -c "$RST/b" 'sleep 300'
  restore --dash grid > "$RST/timeout.out" 2>&1
  if grep -q "not ready after 3s" "$RST/timeout.out" && RT has-session -t grid 2>/dev/null; then
    ok "a member that never becomes ready times out and the grid still builds"
  else
    bad "readiness timeout path wrong: $(cat "$RST/timeout.out")"
  fi

  # Flags are recorded argv TEXT, not shell source, and tmux runs a one-string
  # pane command through `$SHELL -c`. An appended system prompt with a `|` or a
  # `;` in it used to be truncated at the first metacharacter by that second
  # parse — silently, with "restored:" and exit 0. So round-trip one through the
  # REAL snapshot.sh -> restore.sh and check the restored PROCESS's own command
  # line, not just the manifest text.
  cmdline_under() {  # DEEPEST command line under pid $1 that names claude
    # Children first, deliberately: the pane's own process is the `$SHELL -c`
    # wrapper, whose command line quotes the whole string and therefore always
    # looks intact. Only the process the shell actually spawned shows the argv
    # that survived the parse — which is the thing under test.
    local out c sub
    for c in $(pgrep -P "$1" 2>/dev/null); do
      sub="$(cmdline_under "$c")" && { printf '%s' "$sub"; return 0; }
    done
    out="$(ps -ww -o command= -p "$1" 2>/dev/null)"
    case "$out" in *claude*) printf '%s' "$out"; return 0 ;; esac
    return 1
  }
  claude_line() {    # the claude command line running in session $1
    cmdline_under "$(RT display -p -t "$1" '#{pane_pid}' 2>/dev/null)"
  }
  PROMPT='be terse | avoid fluff; stay short'
  RMAN2="$RST/manifest2"
  RT new-session -d -s meta -c "$RST/a" \
     "$RFAKE --model claude-opus-5 --append-system-prompt '$PROMPT'"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -n "$(claude_line meta)" ]] && break; sleep 0.3; done
  orig="$(claude_line meta)"
  ( export CONCIERGE_SOCK="$RSOCK" CONCIERGE_MANIFEST="$RMAN2"
    sh "$REPO/config/snapshot.sh" >/dev/null 2>&1 )
  row="$(grep '^SESSION|meta|' "$RMAN2")"
  [[ "$row" == *"--append-system-prompt $PROMPT" ]] \
    && ok "snapshot records a prompt containing | and ; whole" || bad "snapshot lost it: $row"

  RT kill-session -t meta 2>/dev/null
  ( export CONCIERGE_SOCK="$RSOCK" CONCIERGE_MANIFEST="$RMAN2" CONCIERGE_CLAUDE="$RFAKE"
    sh "$REPO/config/restore.sh" meta >/dev/null 2>&1 )
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -n "$(claude_line meta)" ]] && break; sleep 0.3; done
  back="$(claude_line meta)"
  [[ "$back" == *"$PROMPT"* ]] \
    && ok "restore replays a prompt with shell metacharacters as literal text" \
    || bad "restored argv was mangled: '$back' (was '$orig')"
  [[ "$(RT display -p -t meta '#{pane_dead}' 2>/dev/null)" == 0 ]] \
    && ok "the restored pane is alive (no stray shell operator)" || bad "restored pane died"
  # And it survives another lap: re-snapshotting the restored session gives the
  # same row, so a snapshot/restore cycle can't erode the flags over time.
  ( export CONCIERGE_SOCK="$RSOCK" CONCIERGE_MANIFEST="$RST/manifest3"
    sh "$REPO/config/snapshot.sh" >/dev/null 2>&1 )
  [[ "$(grep '^SESSION|meta|' "$RST/manifest3")" == "$row" ]] \
    && ok "re-snapshot after restore reproduces the same SESSION row" \
    || bad "row drifted: $(grep '^SESSION|meta|' "$RST/manifest3")"
  RT kill-session -t meta 2>/dev/null

  # Stale manifest: every form refuses unless --force.
  sed -i '' '1s/.*/# claude-concierge session manifest — captured 2020-01-01T00:00:00Z/' "$RMAN"
  out="$(restore)"; rc=$?
  [[ $rc -ne 0 && "$out" == *"older than 72h"* ]] \
    && ok "a stale manifest is refused outright" || bad "stale manifest not refused ('$out')"
  out="$(restore --force --dry-run)"
  [[ "$out" != *"older than"* ]] && ok "--force overrides staleness" || bad "--force did not override"

  # The startup offer is exactly one line, and only when something is absent.
  RT kill-server 2>/dev/null
  offer="$(sed -n '/^offer_restore()/,/^}/p' "$REPO/config/start.sh")"
  [[ -n "$offer" ]] && ok "start.sh carries the startup offer" || bad "start.sh has no offer_restore"
  [[ "$(printf '%s' "$offer" | grep -c 'printf')" == 1 ]] \
    && ok "the startup offer is a single line of output" || bad "the offer prints more than one line"
  grep -q 'restore' "$REPO/bin/concierge" \
    && ok "bin/concierge dispatches the restore subcommand" || bad "no restore subcommand"

  rm -rf "$RST"
  unset -f RT restore sessions cmdline_under claude_line
else
  bad "tmux not installed (restore test skipped)"
fi

# 3h) handles: short names for the parts of a reply --------------------------
# Everything runs against a stubbed `claude` on PATH and a sandbox state dir —
# no model is ever called, and the real state directory is never touched.
echo "› handles (addressable parts of a reply)"
HND="$(cd "$(mktemp -d)" && pwd -P)"
HSH="$REPO/config/handles.sh"
mkdir -p "$HND/bin" "$HND/state" "$HND/w"
HLONG="$(python3 -c "print('A structured reply with several parts. ' * 12, end='')")"
HENV=""
stub() { printf '#!/bin/sh\ntouch "%s/called"\n%s\n' "$HND" "$1" > "$HND/bin/claude"
         chmod +x "$HND/bin/claude"; rm -f "$HND/called"; }
hrun() {  # $1 = stop|prompt, $2 = the reply text ("" for the prompt hook)
  ( cd "$HND/w"
    printf '{"last_assistant_message":"%s","transcript_path":"/nonexistent"}' "$2" \
      | env PATH="$HND/bin:$PATH" CONCIERGE_HANDLES_STATE="$HND/state" ${HENV:-} \
            sh "$HSH" "$1" 2>/dev/null )
}
hstate() { cat "$HND/state"/*.tsv 2>/dev/null; }

# A long, multi-item reply gets an index, and the state to resolve it later.
stub 'printf "the proposal\na flagged concern\nthe diff question\n"'
out="$(hrun stop "$HLONG")"
[[ "$out" == *'"systemMessage":"handles: 1a the proposal · 1b a flagged concern'* ]] \
  && ok "a multi-item reply gets a systemMessage handle index" || bad "no index: '$out'"
[[ "$(hstate)" == *$'MAP\t1\t1b\ta flagged concern'* ]] \
  && ok "the handle map is persisted for later resolution" || bad "state not written"

# The next turn counts on — handles never repeat inside a conversation. The
# state is keyed by cwd exactly like Claude Code's transcripts, so this is also
# what makes them survive `--continue`.
out="$(hrun stop "$HLONG")"
[[ "$out" == *"handles: 2a the proposal"* ]] \
  && ok "the turn counter advances (handles never reuse)" || bad "turn did not advance: '$out'"
[[ "$(hstate | grep -c '^TURN')" == 2 ]] \
  && ok "the counter survives a fresh process (so it survives --continue)" \
  || bad "counter not persisted across invocations"

# Resolution: the next prompt carries the recent maps, so "on 1b, …" lands.
out="$(hrun prompt "")"
[[ "$out" == *'"hookEventName":"UserPromptSubmit"'* && "$out" == *'1b: a flagged concern'* ]] \
  && ok "UserPromptSubmit attaches the maps as additionalContext" || bad "no context: '$out'"

# Over budget: the turn must be unaffected, and quickly. A 30s stub against a
# 4s leash — if the leash slipped, this test would take half a minute.
stub 'sleep 30'
start=$SECONDS
out="$(hrun stop "$HLONG")"
elapsed=$((SECONDS - start))
[[ -z "$out" && $elapsed -lt 15 ]] \
  && ok "an extraction that hangs is killed and shows nothing (${elapsed}s)" \
  || bad "timeout path wrong (out='$out', ${elapsed}s)"
# A failing extraction is equally silent.
stub 'exit 1'
[[ -z "$(hrun stop "$HLONG")" ]] && ok "a failing extraction shows nothing" \
  || bad "failure path produced output"

# More than twelve units: the first twelve get handles, and nothing says so.
stub 'i=1; while [ $i -le 15 ]; do printf "item %s\n" "$i"; i=$((i+1)); done'
out="$(hrun stop "$HLONG")"
[[ "$out" == *"a item 1"* && "$out" == *"l item 12"* && "$out" != *"item 13"* ]] \
  && ok "only the first 12 units get handles (a…l)" || bad "truncation wrong: '$out'"

# Too small or too plain to be worth indexing: silence, and no model call.
stub 'printf "one\ntwo\n"'
[[ -z "$(hrun stop "short reply")" && ! -f "$HND/called" ]] \
  && ok "a short reply is not even sent for extraction" || bad "short reply was sent/indexed"
stub 'printf "only one unit\n"'
[[ -z "$(hrun stop "$HLONG")" ]] && ok "fewer than two units -> no index" || bad "single unit indexed"

# The kill switch stops it dead, before any model call.
stub 'printf "a\nb\nc\n"'
HENV="CONCIERGE_HANDLES=0"
[[ -z "$(hrun stop "$HLONG")" && ! -f "$HND/called" ]] \
  && ok "CONCIERGE_HANDLES=0 skips the extraction call entirely" || bad "kill switch did not work"
HENV=""

# Wiring: start.sh registers both hooks, and honours the same kill switch.
grep -q 'handles.sh stop' "$REPO/config/start.sh" && grep -q 'handles.sh prompt' "$REPO/config/start.sh" \
  && ok "start.sh registers the Stop and UserPromptSubmit hooks" || bad "hooks not registered"
grep -q 'CONCIERGE_HANDLES:-1' "$REPO/config/start.sh" \
  && ok "the kill switch also keeps the hooks out of settings.json" || bad "kill switch not honoured at install"

rm -rf "$HND"
unset -f stub hrun hstate

# 4) logsink strips ANSI ----------------------------------------------------
echo "› logsink (ANSI strip)"
SB="$(mktemp -d)"; export HOME="$SB"
printf '\033[31mRED\033[0m text\r\n\033[2J\033[1;1Hmoved\007' \
  | sh "$REPO/config/logsink.sh"
LOG="$SB/.claude/concierge-logs/$(date +%Y-%m-%d).log"
if [[ -f "$LOG" ]]; then
  if LC_ALL=C grep -q $'\033' "$LOG"; then bad "log still contains escapes"; else ok "no escape bytes in log"; fi
  grep -q "RED text" "$LOG" && ok "readable text preserved" || bad "text not preserved"
else
  bad "log file not written"
fi
HOME="$REPO"  # restore-ish; subshell-safe below anyway
rm -rf "$SB"

# 5) clip.sh guards empty input --------------------------------------------
echo "› clip guard"
SHIM="$(mktemp -d)"; MARK="$SHIM/clip.out"
cat > "$SHIM/pbcopy" <<EOF
#!/bin/sh
cat > "$MARK"
EOF
chmod +x "$SHIM/pbcopy"
printf '' | PATH="$SHIM:$PATH" sh "$REPO/config/clip.sh"
[[ ! -f "$MARK" ]] && ok "empty selection does not touch clipboard" || bad "empty selection wrote clipboard"
printf 'hello concierge' | PATH="$SHIM:$PATH" sh "$REPO/config/clip.sh"
[[ -f "$MARK" && "$(cat "$MARK")" == "hello concierge" ]] \
  && ok "non-empty selection copied" || bad "non-empty selection not copied"
rm -rf "$SHIM"

# 6) iTerm profile generates valid JSON -------------------------------------
echo "› iterm profile"
OUT="$(mktemp -d)/p.json"
python3 "$REPO/config/iterm-profile.py" --out "$OUT" --start "/tmp/start.sh" >/dev/null 2>&1
python3 - "$OUT" <<'PY' && ok "profile is valid JSON with expected keys" || bad "profile JSON invalid"
import json,sys
d=json.load(open(sys.argv[1]))
p=d["Profiles"][0]
assert p["Name"]=="Claude Concierge"
assert p["Custom Command"]=="Yes" and p["Command"]=="/tmp/start.sh"
assert "Badge Text" in p and "Background Color" in p and "Ansi 5 Color" in p
PY
rm -rf "$(dirname "$OUT")"

# 7) tmux wrapper defaults new sessions onto the concierge socket -----------
echo "› tmux wrapper"
WSB="$(mktemp -d)"
mkdir -p "$WSB/home/.local/bin" "$WSB/realbin"
cp "$REPO/bin/tmux" "$WSB/home/.local/bin/tmux"
chmod +x "$WSB/home/.local/bin/tmux"
cat > "$WSB/realbin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$WMARK"
EOF
chmod +x "$WSB/realbin/tmux"

run_wrapper() {
  # -u TMUX: the test runner itself may already be inside a tmux client
  # (e.g. run from within Concierge), which would otherwise leak through
  # and mask the "no $TMUX" scenario these tests exist to check.
  env -u TMUX WMARK="$WSB/argv.out" HOME="$WSB/home" PATH="$WSB/home/.local/bin:$WSB/realbin:$PATH" \
    "$WSB/home/.local/bin/tmux" "$@"
}

rm -f "$WSB/argv.out"
run_wrapper new-session -d -s foo
if [[ -f "$WSB/argv.out" ]] && [[ "$(sed -n 1p "$WSB/argv.out")" == "-L" ]] \
   && [[ "$(sed -n 2p "$WSB/argv.out")" == "concierge" ]]; then
  ok "no \$TMUX, no -L/-S -> injects -L concierge"
else
  bad "no \$TMUX, no -L/-S -> did not inject -L concierge"
fi

rm -f "$WSB/argv.out"
env TMUX="/tmp/fake,123,0" WMARK="$WSB/argv.out" HOME="$WSB/home" \
  PATH="$WSB/home/.local/bin:$WSB/realbin:$PATH" "$WSB/home/.local/bin/tmux" new-session -d -s foo
if [[ -f "$WSB/argv.out" ]] && ! grep -qx -- "-L" "$WSB/argv.out"; then
  ok "\$TMUX set -> passes through unchanged"
else
  bad "\$TMUX set -> wrapper still injected a socket"
fi

rm -f "$WSB/argv.out"
run_wrapper -L other new-session -d -s foo
if [[ -f "$WSB/argv.out" ]] && [[ "$(sed -n 1p "$WSB/argv.out")" == "-L" ]] \
   && [[ "$(sed -n 2p "$WSB/argv.out")" == "other" ]]; then
  ok "explicit -L -> respected, not overridden"
else
  bad "explicit -L -> was overridden"
fi

# A foreign $HOME used to be fatal: the wrapper identified itself as
# "$HOME/.local/bin/tmux", so under any other HOME (sandbox, CI, sudo -H) it
# failed to spot itself in the PATH scan, picked ITSELF as the real tmux and
# exec'd in a loop — same PID, spinning forever. These runs are therefore
# watchdogged: a hang must FAIL the suite, not wedge it (this hung the suite
# for 40+ minutes on the machine the bug was found on).
guarded() {  # $1 = seconds, $2.. = command. 124 = still running, killed.
  local secs="$1"; shift
  "$@" & local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && (( i < secs * 20 )); do sleep 0.05; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
  fi
  wait "$pid"
}

rm -f "$WSB/argv.out"
guarded 10 env -u TMUX WMARK="$WSB/argv.out" HOME="$WSB/nowhere" \
  PATH="$WSB/home/.local/bin:$WSB/realbin:$PATH" \
  "$WSB/home/.local/bin/tmux" -L t new-session -d 'sleep 1'
rc=$?
if [[ $rc -eq 124 ]]; then
  bad "foreign \$HOME -> wrapper hung (self-exec loop)"
elif [[ $rc -eq 0 ]] && [[ -f "$WSB/argv.out" ]] \
     && [[ "$(sed -n 1p "$WSB/argv.out")" == "-L" ]] \
     && [[ "$(sed -n 2p "$WSB/argv.out")" == "t" ]]; then
  ok "foreign \$HOME -> execs the real tmux, returns promptly"
else
  bad "foreign \$HOME -> did not exec the real tmux (rc=$rc)"
fi

# Self-detection must not depend on $HOME existing at all.
rm -f "$WSB/argv.out"
guarded 10 env -u HOME -u TMUX WMARK="$WSB/argv.out" \
  PATH="$WSB/home/.local/bin:$WSB/realbin:$PATH" \
  "$WSB/home/.local/bin/tmux" new-session -d -s foo
rc=$?
if [[ $rc -eq 124 ]]; then
  bad "unset \$HOME -> wrapper hung (self-exec loop)"
elif [[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$WSB/argv.out" 2>/dev/null)" == "-L" ]] \
     && [[ "$(sed -n 2p "$WSB/argv.out" 2>/dev/null)" == "concierge" ]]; then
  ok "unset \$HOME -> still self-identifies and injects -L concierge"
else
  bad "unset \$HOME -> wrapper misbehaved (rc=$rc)"
fi

# Last resort: when the ONLY tmux on PATH is the wrapper itself, it must say so
# and exit 127 — never exec itself as a fallback.
MINI="$WSB/mini"; mkdir -p "$MINI"
cp "$REPO/bin/tmux" "$MINI/tmux"; chmod +x "$MINI/tmux"
for t in realpath dirname basename; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MINI/$t"
done
mini_out="$WSB/mini.out"
guarded 10 env -u TMUX HOME="$WSB/nowhere" PATH="$MINI" \
  "$BASH" "$MINI/tmux" new-session -d -s foo > "$mini_out" 2>&1
rc=$?
if [[ $rc -eq 124 ]]; then
  bad "no other tmux on PATH -> wrapper hung (exec'd itself)"
elif [[ $rc -eq 127 ]] && grep -q "could not find the real tmux" "$mini_out"; then
  ok "no other tmux on PATH -> exits 127 instead of exec'ing itself"
else
  bad "no other tmux on PATH -> expected 127 + message (rc=$rc)"
fi

# The old HOME-derived identity must not come back.
grep -q 'SELF="\$HOME' "$REPO/bin/tmux" \
  && bad "bin/tmux still derives SELF from \$HOME" \
  || ok "bin/tmux identifies itself by its own path, not \$HOME"

rm -rf "$WSB"

# 8) doc mode --------------------------------------------------------------
# Everything runs in a throwaway sandbox: temp dirs, NO_COLOR, and a throwaway
# tmux socket. NEVER touches the live -L concierge socket/session or real $HOME.
echo "› doc mode"
DOCSOCK="doctest-$$"
DTMP="$(mktemp -d)"
DOC="$REPO/bin/doc"
DOCVIEW="$REPO/bin/doc-view"

# `doc` calls bare `tmux`, which on a real install resolves to the Concierge
# tmux WRAPPER (~/.local/bin/tmux). This runner mutates $HOME earlier, which
# breaks that wrapper's $HOME-based self-detection. To stay hermetic we resolve
# the REAL tmux and (a) hand `doc` a PATH shim that points `tmux` straight at it,
# (b) use it directly for our own assertions. Never touches the live socket.
RTMUX=""
IFS=: read -ra _pd <<< "$PATH"
for _d in "${_pd[@]}"; do
  _c="$_d/tmux"
  [ -x "$_c" ] || continue
  # Skip the Concierge tmux wrapper (a shell script starting with a shebang) —
  # we want the REAL compiled tmux binary. (This runner mutated $HOME above, so
  # we can't identify the wrapper by its ~/.local/bin path.)
  [ "$(head -c2 "$_c" 2>/dev/null)" = '#!' ] && continue
  RTMUX="$_c"; break
done
DSHIM="$DTMP/shim"; mkdir -p "$DSHIM"
[ -n "$RTMUX" ] && ln -sf "$RTMUX" "$DSHIM/tmux"
DOCPATH="$DSHIM:$PATH"

# doc new "my test doc" --dir "$DTMP" seeds the H1 + writes active/baseline.
# (No server on $DOCSOCK yet, so the split just no-ops; we only check seeding.)
(
  export CONCIERGE_SOCK="$DOCSOCK" CONCIERGE_SESSION="nonesession-$$" \
         DOC_STATE_DIR="$DTMP/state" PATH="$DOCPATH"
  "$DOC" new "my test doc" --dir "$DTMP" >/dev/null 2>&1
) || true
DOCFILE="$DTMP/my test doc.md"
[[ -f "$DOCFILE" ]] && ok "doc new creates '<title>.md' (spaces preserved)" \
  || bad "doc new did not create the file"
grep -qx "# my test doc" "$DOCFILE" \
  && ok "doc new seeds the H1 title" || bad "doc new did not seed the H1"
[[ -f "$DTMP/state/active" ]] && ok "doc new writes state/active" \
  || bad "doc new missing state/active"
ls "$DTMP/state"/*.baseline >/dev/null 2>&1 \
  && ok "doc new creates a baseline file" || bad "doc new missing baseline"
BASE="$(ls "$DTMP/state"/*.baseline 2>/dev/null | head -1)"
[[ -f "$BASE" && ! -s "$BASE" ]] \
  && ok "doc new baseline starts empty (first draft is all-added)" \
  || bad "doc new baseline is not empty"

# doc-view --once (NO_COLOR) on (empty baseline, file with content): the doc
# text renders AND an added-line marker is present; no crash.
V1="$(NO_COLOR=1 "$DOCVIEW" "$DOCFILE" "$BASE" --once 2>&1)"
rc=$?
[[ $rc -eq 0 ]] && ok "doc-view --once exits cleanly on empty baseline" \
  || bad "doc-view --once crashed (rc=$rc)"
printf '%s' "$V1" | grep -q "my test doc" \
  && ok "doc-view renders the doc text" || bad "doc-view missing doc text"
printf '%s' "$V1" | grep -qE '\│ \+ ' \
  && ok "doc-view marks added lines (empty baseline → all added)" \
  || bad "doc-view did not mark added lines"
# NO_COLOR really means no escapes.
if printf '%s' "$V1" | LC_ALL=C grep -q $'\033'; then
  bad "doc-view emitted ANSI escapes under NO_COLOR"
else
  ok "doc-view emits no ANSI escapes under NO_COLOR"
fi

# doc snapshot: baseline becomes equal to the file → viewer shows zero added
# markers (everything is context).
(
  export DOC_STATE_DIR="$DTMP/state"
  "$DOC" snapshot >/dev/null 2>&1
)
if diff -q "$BASE" "$DOCFILE" >/dev/null 2>&1; then
  ok "doc snapshot advances baseline to equal the file"
else
  bad "doc snapshot did not sync baseline to file"
fi
V2="$(NO_COLOR=1 "$DOCVIEW" "$DOCFILE" "$BASE" --once 2>&1)"
if printf '%s' "$V2" | grep -qE '\│ \+ '; then
  bad "doc-view still marked added lines after snapshot"
else
  ok "doc-view shows zero added markers after snapshot (all context)"
fi
printf '%s' "$V2" | grep -q "my test doc" \
  && ok "doc-view still renders the doc as context after snapshot" \
  || bad "doc-view lost the doc text after snapshot"

# Append a line: the new line is marked added; an older line is NOT (context).
printf 'a brand new line\n' >> "$DOCFILE"
V3="$(NO_COLOR=1 "$DOCVIEW" "$DOCFILE" "$BASE" --once 2>&1)"
printf '%s' "$V3" | grep -qE '\│ \+ a brand new line' \
  && ok "doc-view marks the appended line as added" \
  || bad "doc-view did not mark the appended line added"
printf '%s' "$V3" | grep -qE '\│   # my test doc' \
  && ok "doc-view shows the older H1 as context (not added)" \
  || bad "doc-view wrongly marked the older line"

# tmux split preserves focus (pane 0 stays active thanks to split-window -d).
if [ -n "$RTMUX" ]; then
  "$RTMUX" -L "$DOCSOCK" new-session -d -s doctest -x 200 -y 50 'sleep 30' 2>/dev/null
  (
    export CONCIERGE_SOCK="$DOCSOCK" CONCIERGE_SESSION="doctest" \
           DOC_STATE_DIR="$DTMP/state2" PATH="$DOCPATH"
    "$DOC" new "split doc" --dir "$DTMP" >/dev/null 2>&1
  )
  np="$("$RTMUX" -L "$DOCSOCK" list-panes -t doctest 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$np" == "2" ]] && ok "doc new splits the window into 2 panes" \
    || bad "doc new did not create a second pane (got $np)"
  act="$("$RTMUX" -L "$DOCSOCK" list-panes -t doctest -F '#{pane_index}#{?pane_active,*,}' 2>/dev/null | grep '\*' | tr -d '*')"
  [[ "$act" == "0" ]] && ok "focus preserved: active pane is still 0 (split -d)" \
    || bad "focus stolen: active pane is $act, not 0"
  "$RTMUX" -L "$DOCSOCK" kill-server 2>/dev/null
else
  bad "real tmux not found (doc mode split test skipped)"
fi

# doc open on an EXISTING file (spaces in name). This is the v0.4.0 regression:
# cmd_open used `local path="$1"`, which in zsh blanks the special PATH array for
# the function and its callees, so mkdir/cp/tmux became "command not found" — no
# state was written and no pane appeared, yet the suite stayed green. The state
# and baseline assertions below are the direct proof that PATH was intact (they
# FAIL against the buggy code, PASS against the fix). Own state dir + session.
if [ -n "$RTMUX" ]; then
  OPENFILE="$DTMP/some file.md"
  printf '# opened doc\n\nbody line\n' > "$OPENFILE"
  "$RTMUX" -L "$DOCSOCK" new-session -d -s docopen -x 200 -y 50 'sleep 30' 2>/dev/null
  oout="$(
    export CONCIERGE_SOCK="$DOCSOCK" CONCIERGE_SESSION="docopen" \
           DOC_STATE_DIR="$DTMP/state3" PATH="$DOCPATH"
    "$DOC" open "$OPENFILE" 2>&1
  )"; orc=$?
  [[ $orc -eq 0 ]] && ok "doc open exits 0 on an existing file" \
    || bad "doc open exited non-zero ($orc)"
  printf '%s' "$oout" | grep -q "opened" \
    && ok "doc open prints 'opened'" || bad "doc open did not print 'opened'"
  # State written → mkdir + the redirect ran → PATH was intact (fails under bug).
  ap="$(cat "$DTMP/state3/active" 2>/dev/null)"
  if [[ -f "$DTMP/state3/active" && -n "$ap" && "$ap" -ef "$OPENFILE" ]]; then
    ok "doc open writes state/active pointing at the file"
  else
    bad "doc open did not write state/active at the file (PATH clobbered?)"
  fi
  # Baseline copied → cp ran → PATH intact (fails under bug). It equals the file.
  OBASE="$(ls "$DTMP/state3"/*.baseline 2>/dev/null | head -1)"
  if [[ -n "$OBASE" && -f "$OBASE" ]] && diff -q "$OBASE" "$OPENFILE" >/dev/null 2>&1; then
    ok "doc open creates a baseline copy of the file (cp ran → PATH intact)"
  else
    bad "doc open missing/!matching baseline (cp failed → PATH clobbered?)"
  fi
  onp="$("$RTMUX" -L "$DOCSOCK" list-panes -t docopen 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$onp" == "2" ]] && ok "doc open splits the session into 2 panes" \
    || bad "doc open did not create a second pane (got $onp)"
  oact="$("$RTMUX" -L "$DOCSOCK" list-panes -t docopen -F '#{pane_index}#{?pane_active,*,}' 2>/dev/null | grep '\*' | tr -d '*')"
  [[ "$oact" == "0" ]] && ok "doc open preserves focus on pane 0 (split -d)" \
    || bad "doc open stole focus (active pane $oact, not 0)"
  "$RTMUX" -L "$DOCSOCK" kill-server 2>/dev/null
else
  bad "real tmux not found (doc open test skipped)"
fi
rm -rf "$DTMP"

# 7b) install.sh lands doc + doc-view into $BIN (temp HOME) ------------------
echo "› install (doc mode)"
IHOME="$(mktemp -d)"
# Pre-seed a matching font so install.sh's Homebrew font-install branch is
# skipped — the test must never trigger a real `brew install`.
mkdir -p "$IHOME/Library/Fonts"
: > "$IHOME/Library/Fonts/MonaspaceNeonNF-Regular.otf"
if HOME="$IHOME" CONCIERGE_FONT="Menlo 12" bash "$REPO/install.sh" >/dev/null 2>&1; then :; fi
IBIN="$IHOME/.local/bin"
[[ -x "$IBIN/doc" ]] && ok "install.sh installs bin/doc (executable)" \
  || bad "install.sh did not install doc"
[[ -x "$IBIN/doc-view" ]] && ok "install.sh installs bin/doc-view (executable)" \
  || bad "install.sh did not install doc-view"
rm -rf "$IHOME"

# 9) VERSION matches the latest CHANGELOG entry ------------------------------
echo "› version"
V="$(cat "$REPO/VERSION")"
grep -q "^## \[$V\]" "$REPO/CHANGELOG.md" \
  && ok "VERSION ($V) has a matching CHANGELOG entry" \
  || bad "VERSION ($V) has no matching CHANGELOG entry"

# Summary -------------------------------------------------------------------
echo
echo "──────────────────────────────"
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

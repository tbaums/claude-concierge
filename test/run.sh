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
         config/start.sh config/clip.sh \
         config/logsink.sh config/iterm-profile.py; do
  [[ -f "$REPO/$f" ]] && ok "exists: $f" || bad "missing: $f"
done

# 2) Shell syntax -----------------------------------------------------------
echo "› syntax"
for f in bin/concierge config/start.sh bin/doc bin/doc-view; do
  zsh -n "$REPO/$f" 2>/dev/null && ok "zsh -n $f" || bad "zsh -n $f"
done
for f in config/clip.sh config/logsink.sh; do
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
# Source just the pure helpers out of start.sh so we test the real code.
HELPERS="$(mktemp)"
sed -n '/^pretty_model()/,/^}/p;/^resolve_effort()/,/^}/p' "$REPO/config/start.sh" > "$HELPERS"
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
# tmux.conf wires both new options into the status bar
grep -q '@concierge_model' "$REPO/config/tmux.conf" \
  && ok "status-right references @concierge_model" || bad "status-right missing @concierge_model"
grep -q '@concierge_effort' "$REPO/config/tmux.conf" \
  && ok "status-right references @concierge_effort" || bad "status-right missing @concierge_effort"

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

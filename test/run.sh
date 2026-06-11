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
for f in LICENSE README.md RELEASING.md CHANGELOG.md install.sh \
         bin/concierge config/tmux.conf config/start.sh config/clip.sh \
         config/logsink.sh config/iterm-profile.py; do
  [[ -f "$REPO/$f" ]] && ok "exists: $f" || bad "missing: $f"
done

# 2) Shell syntax -----------------------------------------------------------
echo "› syntax"
for f in bin/concierge config/start.sh; do
  zsh -n "$REPO/$f" 2>/dev/null && ok "zsh -n $f" || bad "zsh -n $f"
done
for f in config/clip.sh config/logsink.sh; do
  sh -n "$REPO/$f" 2>/dev/null && ok "sh -n $f" || bad "sh -n $f"
done
bash -n "$REPO/install.sh" && ok "bash -n install.sh" || bad "bash -n install.sh"
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

# Summary -------------------------------------------------------------------
echo
echo "──────────────────────────────"
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────────────
#  Claude Concierge installer (macOS + iTerm2).
#
#    bash install.sh
#
#  Installs the config into ~/.config/claude-concierge, the launcher into
#  ~/.local/bin/concierge, and the iTerm2 dynamic profile. Idempotent — safe to
#  re-run to update an existing install. Set CONCIERGE_FONT to override the font.
# ───────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.config/claude-concierge"
BIN="$HOME/.local/bin"
PROFILES="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
FONT="${CONCIERGE_FONT:-MonaspaceNeonNF-Regular 15}"

echo "→ Installing config to $CFG"
mkdir -p "$CFG"
cp "$REPO_DIR"/config/{tmux.conf,start.sh,clip.sh,logsink.sh,session-menu.sh} "$CFG/"
cp "$REPO_DIR/VERSION" "$CFG/VERSION"
chmod +x "$CFG"/{start.sh,clip.sh,logsink.sh,session-menu.sh}

echo "→ Installing launcher to $BIN/concierge"
mkdir -p "$BIN"
cp "$REPO_DIR/bin/concierge" "$BIN/concierge"
chmod +x "$BIN/concierge"

echo "→ Installing tmux wrapper to $BIN/tmux (defaults new tmux sessions onto the concierge socket)"
cp "$REPO_DIR/bin/tmux" "$BIN/tmux"
chmod +x "$BIN/tmux"

# Fonts: install Monaspace (Nerd Font) if Homebrew is present and it's missing.
if command -v brew >/dev/null 2>&1; then
  if ! ls "$HOME/Library/Fonts"/Monaspace*NF-Regular.otf >/dev/null 2>&1; then
    echo "→ Installing Monaspace Nerd Font (font-monaspace-nf)"
    brew install --cask font-monaspace-nf || echo "  (font install skipped/failed — set your own with CONCIERGE_FONT)"
  fi
else
  echo "→ Homebrew not found; skipping font install. Pick any installed mono font via CONCIERGE_FONT."
fi

echo "→ Generating iTerm2 profile (font: $FONT)"
mkdir -p "$PROFILES"
python3 "$REPO_DIR/config/iterm-profile.py" --font "$FONT" --start "$CFG/start.sh"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "⚠  $BIN is not on your PATH. Add it to ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# The tmux wrapper only takes effect if $BIN comes BEFORE the real tmux's
# directory on PATH — check the order PATH would actually resolve, not just
# whether $BIN is present somewhere in it.
REAL_TMUX_DIR=""
IFS=: read -ra _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
  if [ -x "$_dir/tmux" ] && [ "$_dir" != "$BIN" ]; then
    REAL_TMUX_DIR="$_dir"
    break
  fi
done
if [ -n "$REAL_TMUX_DIR" ]; then
  bin_pos=-1; tmux_pos=-1; i=0
  for _dir in "${_path_dirs[@]}"; do
    [ "$_dir" = "$BIN" ] && [ "$bin_pos" = -1 ] && bin_pos=$i
    [ "$_dir" = "$REAL_TMUX_DIR" ] && [ "$tmux_pos" = -1 ] && tmux_pos=$i
    i=$((i + 1))
  done
  if [ "$bin_pos" = -1 ] || { [ "$tmux_pos" != -1 ] && [ "$bin_pos" -gt "$tmux_pos" ]; }; then
    echo "⚠  $BIN comes after $REAL_TMUX_DIR on your PATH, so the tmux wrapper"
    echo "   (defaults new tmux sessions onto the concierge socket) won't take"
    echo "   effect. Fix by PREPENDING (not appending) in ~/.zshrc:"
    echo "     export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
fi

echo
echo "✓ Installed. Open a new window:  concierge"
echo "  (iTerm picks up the new profile automatically — no restart needed.)"

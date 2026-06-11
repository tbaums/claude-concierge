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
cp "$REPO_DIR"/config/{tmux.conf,start.sh,clip.sh,logsink.sh} "$CFG/"
chmod +x "$CFG"/{start.sh,clip.sh,logsink.sh}

echo "→ Installing launcher to $BIN/concierge"
mkdir -p "$BIN"
cp "$REPO_DIR/bin/concierge" "$BIN/concierge"
chmod +x "$BIN/concierge"

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

echo
echo "✓ Installed. Open a new window:  concierge"
echo "  (iTerm picks up the new profile automatically — no restart needed.)"

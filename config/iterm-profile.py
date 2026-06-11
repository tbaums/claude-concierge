#!/usr/bin/env python3
"""Generate the 'Claude Concierge' iTerm2 dynamic profile.

Writes a JSON profile to iTerm2's DynamicProfiles directory: neon/synthwave
palette, Monaspace Neon (Nerd Font) by default, a persistent CONCIERGE badge
watermark, and a Command that launches config/start.sh.

Usage:
    python3 iterm-profile.py [--font "MonaspaceNeonNF-Regular 15"] [--start PATH]
"""
import argparse
import json
import os
from pathlib import Path


def col(hex_, alpha=1.0):
    h = hex_.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    d = {"Color Space": "sRGB",
         "Red Component": round(r, 5),
         "Green Component": round(g, 5),
         "Blue Component": round(b, 5)}
    if alpha != 1.0:
        d["Alpha Component"] = alpha
    return d


def main():
    home = Path.home()
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default="MonaspaceNeonNF-Regular 15",
                    help='iTerm "Normal Font" string: "<PostScriptName> <size>"')
    ap.add_argument("--start", default=str(home / ".config/claude-concierge/start.sh"),
                    help="Path to the inner launcher to run as the profile Command")
    ap.add_argument("--out", default=str(
        home / "Library/Application Support/iTerm2/DynamicProfiles/claude-concierge.json"))
    args = ap.parse_args()

    prof = {
        "Name": "Claude Concierge",
        "Guid": "claude-concierge-neon-0001",
        "Custom Command": "Yes",
        "Command": args.start,
        "Working Directory": str(home),
        "Custom Directory": "Yes",
        "Normal Font": args.font,
        "Use Non-ASCII Font": False,
        "ASCII Anti Aliased": True,
        "Horizontal Spacing": 1.0,
        "Vertical Spacing": 1.06,
        "Use Bold Font": True,
        "Use Italic Font": True,
        "Use Ligatures": True,
        "ASCII Ligatures": True,
        "Badge Text": "CONCIERGE",
        "Badge Color": col("#ff2e97", 0.18),
        "Badge Top Margin": 6, "Badge Right Margin": 8,
        "Badge Max Width": 40, "Badge Max Height": 8,
        "Title Components": 32,
        "Custom Window Title": "🤵‍♀️ Claude Concierge",
        "Allow Title Setting": True,
        "Columns": 120, "Rows": 34,
        "Transparency": 0.06, "Blur": True, "Blur Radius": 12.0,
        "Use Cursor Guide": False,
        "Cursor Type": 2, "Blinking Cursor": False,
        "Unlimited Scrollback": True,
        "Background Color": col("#15101f"),
        "Foreground Color": col("#e6dcff"),
        "Bold Color": col("#ffffff"),
        "Cursor Color": col("#ff2e97"),
        "Cursor Text Color": col("#15101f"),
        "Selection Color": col("#3a2b5e"),
        "Selected Text Color": col("#ffffff"),
        "Link Color": col("#00e8ff"),
        "Cursor Guide Color": col("#b14bff", 0.25),
        "Ansi 0 Color": col("#2a2140"),  "Ansi 8 Color": col("#6f5b9a"),
        "Ansi 1 Color": col("#ff3c6f"),  "Ansi 9 Color": col("#ff6e94"),
        "Ansi 2 Color": col("#4dffb8"),  "Ansi 10 Color": col("#8affd1"),
        "Ansi 3 Color": col("#ffd23f"),  "Ansi 11 Color": col("#ffe17a"),
        "Ansi 4 Color": col("#6f9bff"),  "Ansi 12 Color": col("#a6c0ff"),
        "Ansi 5 Color": col("#ff2e97"),  "Ansi 13 Color": col("#ff7ac0"),
        "Ansi 6 Color": col("#00e8ff"),  "Ansi 14 Color": col("#6ff4ff"),
        "Ansi 7 Color": col("#c9b6ff"),  "Ansi 15 Color": col("#f3ecff"),
    }

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"Profiles": [prof]}, indent=2))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()

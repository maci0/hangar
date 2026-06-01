#!/usr/bin/env bash
# FLTK visual screenshot regression test — captures all dialogs under Xvfb
# and verifies every screenshot is non-blank.
#
# Requires: Xvfb, ImageMagick (import), Python 3, Pillow, a WM (openbox/fluxbox/kwin_x11)
# Usage: tests/visual/e2e_fltk_screenshots.sh   (run from repo root; builds first)
#
# Add to build.zig with:
#   const fltk_screenshots = b.step("fltk-screenshots", "FLTK visual regression screenshots");
#   fltk_screenshots.dependOn(&exe_install.step);
#   const fltk_ss_cmd = b.addSystemCommand(&.{ "bash", "tests/visual/e2e_fltk_screenshots.sh" });
#   fltk_screenshots.dependOn(&fltk_ss_cmd.step);
set -euo pipefail
cd "$(dirname "$0")/../.."

# ── Prerequisites ──
fail() { echo "SCREENSHOT FAIL: $1"; exit 1; }

command -v Xvfb    >/dev/null || { echo "SKIP: Xvfb not installed";    exit 0; }
command -v import   >/dev/null || { echo "SKIP: ImageMagick missing";  exit 0; }
command -v python3  >/dev/null || { echo "SKIP: python3 not found";    exit 0; }
python3 -c "from PIL import Image" 2>/dev/null || { echo "SKIP: Pillow not installed"; exit 0; }

# ── Build ──
zig build || fail "build failed"

# ── Run the capture script ──
echo "=== FLTK Visual Screenshot Regression ==="
export FLTK_BACKEND=x11
python3 tests/visual/screenshot_all_dialogs.py | sed 's/^/  /'

# ── Verify ──
SCREENSHOT_DIR="tests/visual/screenshots"
EXPECTED=22
FOUND=0
BLANK=0

for f in "$SCREENSHOT_DIR"/all_*.png; do
    if [ -f "$f" ]; then
        FOUND=$((FOUND + 1))
        # Check for blank images (mean pixel value near 0 or near 255)
        MEAN=$(python3 -c "
from PIL import Image, ImageStat
img = Image.open('$f').convert('RGB')
s = ImageStat.Stat(img)
m = sum(s.mean)/3
print('{:.1f}'.format(m))
")
        if (( $(echo "$MEAN < 5 || $MEAN > 250" | bc -l) )); then
            echo "  ⚠ BLANK: $f (mean=$MEAN)"
            BLANK=$((BLANK + 1))
        fi
    fi
done

echo ""
echo "  Screenshots: $FOUND found, $BLANK blank (expected $EXPECTED)"

if [ "$FOUND" -lt "$EXPECTED" ]; then
    fail "only $FOUND/$EXPECTED screenshots captured"
fi

if [ "$BLANK" -gt 0 ]; then
    fail "$BLANK screenshots are blank"
fi

echo "PASS: all $EXPECTED FLTK screenshots captured and non-blank"

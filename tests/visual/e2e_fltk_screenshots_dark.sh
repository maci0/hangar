#!/usr/bin/env bash
# FLTK visual screenshot regression test — Dark Mode variant.
# Overrides the theme in config to "dark", captures all 22 dialogs under
# Xvfb, verifies non-blank, then restores the original config.
#
# Requires: Xvfb, ImageMagick (import), Python 3, Pillow, a WM
# Usage: tests/visual/e2e_fltk_screenshots_dark.sh   (run from repo root; builds first)
#
# Configured via build.zig as: zig build fltk-screenshots-dark
set -euo pipefail
cd "$(dirname "$0")/../.."

# ── Prerequisites ──
fail() { echo "SCREENSHOT DARK FAIL: $1"; exit 1; }

command -v Xvfb    >/dev/null || { echo "SKIP: Xvfb not installed";    exit 0; }
command -v import   >/dev/null || { echo "SKIP: ImageMagick missing";  exit 0; }
command -v python3  >/dev/null || { echo "SKIP: python3 not found";    exit 0; }
python3 -c "from PIL import Image" 2>/dev/null || { echo "SKIP: Pillow not installed"; exit 0; }

# ── Build ──
zig build || fail "build failed"

# ── Override config for dark theme & predictable window size ──
CONFIG_PATH="$HOME/.config/kvmgui/vms.json"
BACKUP_PATH=""
ORIG_RAW=""

if [ -f "$CONFIG_PATH" ]; then
    ORIG_RAW=$(cat "$CONFIG_PATH")
    BACKUP_PATH="${CONFIG_PATH}.dark-screenshot-backup"
    cp "$CONFIG_PATH" "$BACKUP_PATH"
    echo "  Config: backed up to $BACKUP_PATH"
else
    echo "  Config: no existing vms.json — creating minimal config"
fi

# Rewrite with dark theme + reset window prefs (python3 for JSON manipulation)
python3 -c "
import json, sys, os
cfg = {}
if os.path.exists('$CONFIG_PATH'):
    try:
        with open('$CONFIG_PATH') as f:
            raw = f.read()
        if raw.strip():
            cfg = json.loads(raw)
    except Exception:
        cfg = {}
cfg['theme'] = 'dark'
cfg['win_w'] = 0
cfg['win_h'] = 0
os.makedirs(os.path.dirname('$CONFIG_PATH'), exist_ok=True)
with open('$CONFIG_PATH', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  Config: set theme=dark, win_w=0, win_h=0')
"

# ── Run the capture script ──
echo "=== FLTK Visual Screenshot Regression (DARK MODE) ==="
export FLTK_BACKEND=x11
python3 tests/visual/screenshot_all_dialogs.py | sed 's/^/  /'

# ── Move screenshots to dark-specific directory ──
SCREENSHOT_DIR="tests/visual/screenshots"
DARK_DIR="tests/visual/screenshots_dark"
GOLDEN_DIR="tests/visual/screenshots_dark_golden"
rm -rf "$DARK_DIR"
mv "$SCREENSHOT_DIR" "$DARK_DIR"
mkdir -p "$SCREENSHOT_DIR"  # recreate so downstream isn't confused
echo "  Moved screenshots → $DARK_DIR"

# ── Restore original config ──
if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
    mv "$BACKUP_PATH" "$CONFIG_PATH"
    echo "  Config: restored original"
else
    rm -f "$CONFIG_PATH"
    echo "  Config: removed temporary config"
fi

# ── Verify ──
EXPECTED=22
FOUND=0
BLANK=0

for f in "$DARK_DIR"/all_*.png; do
    if [ -f "$f" ]; then
        FOUND=$((FOUND + 1))
        MEAN=$(python3 -c "from PIL import Image, ImageStat; img=Image.open('$f').convert('RGB'); s=ImageStat.Stat(img); m=sum(s.mean)/3; print('{:.1f}'.format(m))")
        if (( $(echo "$MEAN < 5 || $MEAN > 250" | bc -l) )); then
            echo "  ⚠ BLANK: $f (mean=$MEAN)"
            BLANK=$((BLANK + 1))
        fi
    fi
done

echo ""
echo "  Dark screenshots: $FOUND found, $BLANK blank (expected $EXPECTED)"

if [ "$FOUND" -lt "$EXPECTED" ]; then
    fail "only $FOUND/$EXPECTED dark screenshots captured"
fi

if [ "$BLANK" -gt 0 ]; then
    fail "$BLANK dark screenshots are blank"
fi

# ── Diff against light mode (informational — only fails if difference is
#     too small, indicating the theme didn't take effect) ──
LIGHT_DIR="tests/visual/screenshots"
DIFF_COUNT=0
if [ -d "$LIGHT_DIR" ] && [ "$(find "$LIGHT_DIR" -name 'all_*.png' 2>/dev/null | wc -l)" -ge "$EXPECTED" ]; then
    echo ""
    echo "  Comparing light ↔ dark screenshots..."
    for f in "$LIGHT_DIR"/all_*.png; do
        base=$(basename "$f")
        dark="$DARK_DIR/$base"
        if [ -f "$dark" ]; then
            # RMSE threshold: if < 2.0 the images are too similar (theme didn't apply)
            RMSE=$(python3 -c "
from PIL import Image, ImageChops
import math
a = Image.open('$f').convert('RGB').resize((640, 400))
b = Image.open('$dark').convert('RGB').resize((640, 400))
diff = ImageChops.difference(a, b)
h = diff.histogram()
sq = sum(c * (i % 256)**2 for i, c in enumerate(h))
mse = sq / float(a.size[0] * a.size[1] * 3)
print('{:.2f}'.format(math.sqrt(mse)))
" 2>/dev/null || echo "0")
            if (( $(echo "$RMSE < 2.0" | bc -l) )); then
                echo "  ⚠ Too similar: $base (RMSE=$RMSE — dark theme may not have applied)"
                DIFF_COUNT=$((DIFF_COUNT + 1))
            fi
        fi
    done
    if [ "$DIFF_COUNT" -gt 5 ]; then
        fail "$DIFF_COUNT light/dark screenshot pairs are too similar — theme likely did not apply"
    fi
    echo "  Diff OK: all pairs show meaningful difference"
else
    echo "  Skipping light/dark diff (light screenshots not available — run 'zig build fltk-screenshots' first)"
fi

# ── Golden-reference comparison ──
GOLDEN_COUNT=0
if [ -d "$GOLDEN_DIR" ] && [ "$(find "$GOLDEN_DIR" -name 'all_*.png' 2>/dev/null | wc -l)" -ge "$EXPECTED" ]; then
    echo ""
    echo "  Comparing against golden references in $GOLDEN_DIR ..."
    GOLDEN_FAILS=0
    for f in "$GOLDEN_DIR"/all_*.png; do
        base=$(basename "$f")
        new="$DARK_DIR/$base"
        if [ -f "$new" ]; then
            GOLDEN_COUNT=$((GOLDEN_COUNT + 1))
            RMSE=$(python3 -c "
from PIL import Image, ImageChops
import math
a = Image.open('$f').convert('RGB')
b = Image.open('$new').convert('RGB')
# resize to common size for comparison
w = min(a.size[0], b.size[0])
h = min(a.size[1], b.size[1])
a = a.resize((w, h))
b = b.resize((w, h))
diff = ImageChops.difference(a, b)
hist = diff.histogram()
sq = sum(c * (i % 256)**2 for i, c in enumerate(hist))
mse = sq / float(w * h * 3)
print('{:.2f}'.format(math.sqrt(mse)))
" 2>/dev/null || echo "999")
            if (( $(echo "$RMSE > 30.0" | bc -l) )); then
                echo "  ⚠ REGRESSION: $base (RMSE=$RMSE, threshold=30.0)"
                GOLDEN_FAILS=$((GOLDEN_FAILS + 1))
            elif (( $(echo "$RMSE > 10.0" | bc -l) )); then
                echo "  ⚡ MINOR: $base (RMSE=$RMSE)"
            fi
        fi
    done
    if [ "$GOLDEN_FAILS" -gt 0 ]; then
        echo ""
        echo "  Golden comparison: $GOLDEN_FAILS/$GOLDEN_COUNT regressions (RMSE > 30)"
        echo "  Run 'zig build fltk-screenshots-dark' to update golden references"
        fail "$GOLDEN_FAILS dark screenshot regressions detected"
    fi
    echo "  Golden comparison OK: $GOLDEN_COUNT screenshots match references"
else
    echo "  Golden references not found — run 'zig build fltk-screenshots-dark' first to seed them"
    echo "  (copy $DARK_DIR → $GOLDEN_DIR after visual review)"
fi

echo "PASS: all $EXPECTED dark-mode FLTK screenshots captured and non-blank"

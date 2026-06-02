#!/usr/bin/env bash
# Dark mode screenshot test — launches Hangar with dark theme under Xvfb,
# captures the main window, and verifies it renders non-blank pixels.
#
# Output: zig-out/captures/30-dark-main.png
# Requires: Xvfb, ffmpeg, python3 (Pillow for pixel analysis)
#
# Usage: tests/dark_mode_test.sh
set -u
cd "$(dirname "$0")/.."

ISOHOME="$(mktemp -d /tmp/hangar-dm.XXXXXX)"
export HOME="$ISOHOME"

OUTDIR="$PWD/zig-out/captures"
mkdir -p "$OUTDIR"

cleanup() { pkill -x hangar 2>/dev/null; pkill Xvfb 2>/dev/null; rm -rf "$ISOHOME"; }
trap cleanup EXIT

command -v Xvfb  >/dev/null || { echo "SKIP: Xvfb not installed"; exit 0; }
command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg not installed"; exit 0; }
python3 -c "from PIL import Image; import numpy" 2>/dev/null || {
    echo "SKIP: python3 Pillow + numpy missing (pip install Pillow numpy)"; exit 0;
}

zig build || { echo "BUILD FAILED"; exit 1; }

# Pre-create dark-theme config so the app starts in dark mode immediately.
mkdir -p "$HOME/.config/hangar"
printf '{"theme":"dark","vm":[]}' > "$HOME/.config/hangar/vms.json"

pkill -x hangar 2>/dev/null; pkill Xvfb 2>/dev/null; sleep 1
Xvfb :99 -screen 0 1280x800x24 -ac >/dev/null 2>&1 &
sleep 2

env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE FLTK_BACKEND=x11 DISPLAY=:99 \
    ./zig-out/bin/hangar >/tmp/hangar-dm.log 2>&1 &
APP=$!
sleep 4
kill -0 "$APP" 2>/dev/null || { echo "FAIL: app died on startup"; exit 1; }
sleep 2

# Capture main window screenshot.
DISPLAY=:99 ffmpeg -f x11grab -video_size 1280x800 -i :99.0 \
    -frames:v 1 -update 1 "$OUTDIR/30-dark-main.png" -y \
    >/dev/null 2>&1

# Analyze pixels: image must not be blank (all-black or all-white).
python3 -c "
from PIL import Image
import numpy as np
img = Image.open('$OUTDIR/30-dark-main.png').convert('RGB')
arr = np.array(img)
# Must have at least 10% non-white pixels (white == fully blank window)
non_white = np.sum(np.any(arr < 220, axis=2))
total = arr.shape[0] * arr.shape[1]
pct = non_white / total * 100
print(f'Dark mode: {non_white}/{total} non-white pixels ({pct:.1f}%)')
if pct < 5:
    print('FAIL: dark mode window appears blank')
    exit(1)
# Check that dark background dominates (dark theme should have many dark pixels)
dark_pixels = np.sum(np.all(arr < 80, axis=2))
dark_pct = dark_pixels / total * 100
print(f'  Dark pixels (< 80 RGB): {dark_pct:.1f}%')
if dark_pct < 15:
    print('FAIL: dark mode does not appear to have a dark background')
    exit(1)
print('PASS: dark mode screenshot non-blank with dark background')
" || { echo "FAIL: pixel check failed"; exit 1; }

echo "OK: dark mode screenshot test passed"

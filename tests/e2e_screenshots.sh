#!/usr/bin/env bash
# end-to-end screenshot capture — renders the full UI + every dialog under Xvfb
# and grabs PNG frames for visual review of the FLTK layout and styling.
#
# Captures: 1) main window  2) New VM dialog  3) Settings dialog
#           4) Snapshot Manager  5) Virtual Network Editor  6) About dialog
#           7) Rename dialog  8) Connect to Server
#
# Output: zig-out/captures/*.png
# Requires: Xvfb, ffmpeg, python-Xlib
#
# Usage: tests/e2e_screenshots.sh   (run from repo root; builds first)
set -u
cd "$(dirname "$0")/.."

# Isolate config to a throwaway HOME so the test never touches real user data.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ISOHOME="$(mktemp -d /tmp/hangar-sshome.XXXXXX)"
export HOME="$ISOHOME"

OUTDIR="$PWD/zig-out/captures"
mkdir -p "$OUTDIR"

fail() { echo "SS FAIL: $1"; cleanup; exit 1; }
cleanup() { pkill -x hangar 2>/dev/null; pkill Xvfb 2>/dev/null; rm -rf "$ISOHOME"; }
trap cleanup EXIT

command -v Xvfb  >/dev/null || { echo "SKIP: Xvfb not installed";  exit 0; }
command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg not installed"; exit 0; }
python3 -c "import Xlib" 2>/dev/null || { echo "SKIP: python-Xlib missing"; exit 0; }

zig build || fail "build failed"
mkdir -p "$HOME/.config/hangar" "$HOME/VMs"

pkill -x hangar 2>/dev/null; pkill Xvfb 2>/dev/null; sleep 1
Xvfb :99 -screen 0 1280x800x24 -ac >/dev/null 2>&1 &
sleep 2

env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE FLTK_BACKEND=x11 DISPLAY=:99 \
    ./zig-out/bin/hangar >/tmp/hangar-ss.log 2>&1 &
APP=$!
sleep 4
kill -0 "$APP" 2>/dev/null || fail "app died on startup"
sleep 2  # extra wait for window to fully render under Xvfb

# Drive UI + capture all frames from one python process.
DISPLAY=:99 OUTDIR="$OUTDIR" python3 - <<'PY' || true
import time, os, subprocess
from Xlib import display, X, XK
from Xlib.ext import xtest

d = display.Display(':99')
OUT = os.environ.get('OUTDIR', '/tmp')
SCR_W, SCR_H = 1280, 800

# ── Find the Hangar window and its screen position ──
root = d.screen().root
win_x, win_y = 0, 0
win_w, win_h = SCR_W, SCR_H
for c in root.query_tree().children:
    try:
        name = c.get_wm_name()
        if name and 'Hangar' in name:
            geom = c.get_geometry()
            win_x, win_y = geom.x, geom.y
            win_w, win_h = geom.width, geom.height
            print(f"Found Hangar at ({win_x},{win_y}) size {win_w}x{win_h}", flush=True)
            break
    except:
        pass
else:
    print("WARNING: Hangar window not found, using (0,0)", flush=True)

# Offset to convert window-relative coordinates to screen coordinates.
WX, WY = win_x, win_y

def click(x, y):
    xtest.fake_input(d, X.MotionNotify, x=x, y=y); d.sync(); time.sleep(0.15)
    xtest.fake_input(d, X.ButtonPress, 1); d.sync()
    xtest.fake_input(d, X.ButtonRelease, 1); d.sync(); time.sleep(0.4)

def fast_key(sym, mods=[]):
    """Key press with minimal delay — for menu navigation."""
    for m in mods:
        xtest.fake_input(d, X.KeyPress, d.keysym_to_keycode(m)); d.sync()
    kc = d.keysym_to_keycode(sym)
    xtest.fake_input(d, X.KeyPress, kc); d.sync()
    xtest.fake_input(d, X.KeyRelease, kc); d.sync()
    for m in reversed(mods):
        xtest.fake_input(d, X.KeyRelease, d.keysym_to_keycode(m)); d.sync()
    time.sleep(0.03)

def key(sym, mods=[]):
    """Key press with standard 0.5s delay."""
    for m in mods:
        xtest.fake_input(d, X.KeyPress, d.keysym_to_keycode(m)); d.sync()
    kc = d.keysym_to_keycode(sym)
    xtest.fake_input(d, X.KeyPress, kc); d.sync()
    xtest.fake_input(d, X.KeyRelease, kc); d.sync()
    for m in reversed(mods):
        xtest.fake_input(d, X.KeyRelease, d.keysym_to_keycode(m)); d.sync()
    time.sleep(0.5)

def capture(name):
    time.sleep(0.3)
    path = os.path.join(OUT, f"{name}.png")
    subprocess.run([
        "ffmpeg", "-f", "x11grab", "-video_size", f"{SCR_W}x{SCR_H}",
        "-i", ":99.0", "-frames:v", "1", "-update", "1", path, "-y"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"  -> {path}")

# Dialog sizes and button offsets (dialog-relative centres).
# Dialogs are screen-centered by FLTK.
def dlg_center(dw, dh):
    """Screen-centred dialog origin."""
    return (SCR_W - dw) // 2, (SCR_H - dh) // 2

# 1 — Main window (already visible)
capture("01-main")

# 2 — New VM dialog (toolbar btn ~(45, 48) window-relative)
click(WX + 45, WY + 48)
time.sleep(1.2)
capture("02-newvm")
# Cancel: dlg 460x230, Cancel btn rel (370+40, 185+15) = (410,200)
dx, dy = dlg_center(460, 230)
click(dx + 410, dy + 200)
time.sleep(0.8)

# 3 — Settings dialog (toolbar btn ~(640, 48) window-relative)
click(WX + 640, WY + 48)
time.sleep(1.0)
capture("03-settings")
# Cancel: dlg 420x290, Cancel btn rel (320+45, 250+15) = (365,265)
dx, dy = dlg_center(420, 290)
click(dx + 365, dy + 265)
time.sleep(0.8)

# Create a VM for selection-dependent dialogs
click(WX + 45, WY + 48)   # New VM toolbar
time.sleep(1.0)
# Create: dlg 460x230, Create btn rel (280+40, 185+15) = (320,200)
dx, dy = dlg_center(460, 230)
click(dx + 320, dy + 200)
time.sleep(2.0)

# Select the VM in the browser list (sidebar at window x=130, first VM at window y=~140)
click(WX + 130, WY + 140)
time.sleep(0.5)

# 4 — Snapshot Manager via VM menu (window-relative ~(93, 5), item 9)
click(WX + 93, WY + 5)
time.sleep(0.5)
for _ in range(9): fast_key(XK.XK_Down)
fast_key(XK.XK_Return)
time.sleep(1.2)
capture("04-snapshots")
# Close: dlg 480x200, Close btn rel (10+40, 160+15) = (50,175)
dx, dy = dlg_center(480, 200)
click(dx + 50, dy + 175)
time.sleep(0.8)

# 5 — Virtual Network Editor (Edit menu window-relative ~(55, 5), item 1)
click(WX + 55, WY + 5)
time.sleep(0.4)
fast_key(XK.XK_Down); fast_key(XK.XK_Return)
time.sleep(1.0)
capture("05-vnet")
# Close: dlg 580x420, Close btn rel (480+45, 375+15) = (525,390)
dx, dy = dlg_center(580, 420)
click(dx + 525, dy + 390)
time.sleep(0.8)

# 6 — About dialog (Help menu window-relative ~(180, 5), item 0)
click(WX + 180, WY + 5)
time.sleep(0.4)
fast_key(XK.XK_Return)
time.sleep(0.8)
capture("06-about")
# OK: dlg 400x250, OK btn rel (310+40, 210+15) = (350,225)
dx, dy = dlg_center(400, 250)
click(dx + 350, dy + 225)
time.sleep(0.8)

# 7 — Rename dialog via VM menu (item 8)
click(WX + 93, WY + 5)
time.sleep(0.5)
for _ in range(8): fast_key(XK.XK_Down)
fast_key(XK.XK_Return)
time.sleep(1.0)
capture("07-rename")
# Cancel: dlg 340x110, Cancel btn rel (180+35, 75+12) = (215,87)
dx, dy = dlg_center(340, 110)
click(dx + 215, dy + 87)
time.sleep(0.8)

# 8 — Connect to Server (File menu window-relative ~(25, 5), item 3)
click(WX + 25, WY + 5)
time.sleep(0.4)
for _ in range(3): fast_key(XK.XK_Down)
fast_key(XK.XK_Return)
time.sleep(1.0)
capture("08-remote")
# Local Mode: dlg 420x220, Local btn rel (290+55, 175+15) = (345,190)
dx, dy = dlg_center(420, 220)
click(dx + 345, dy + 190)
time.sleep(0.8)

print("all interactions done")
PY

sleep 1
kill -0 "$APP" 2>/dev/null || echo "WARNING: app died during interaction"

echo "Captures saved to $OUTDIR/"
ls -la "$OUTDIR/"*.png 2>/dev/null || echo "No captures produced"

# Check if captures are unique
echo ""
echo "MD5 checksums:"
md5sum "$OUTDIR/"*.png 2>/dev/null

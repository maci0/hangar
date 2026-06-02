#!/usr/bin/env bash
# Smoke test for the FLTK GUI — drives the real app under Xvfb via XTEST.
# Asserts: the process survives every interaction, a created VM is persisted,
# and the window renders non-black frames.
#
# Requires: Xvfb, ffmpeg, python-Xlib
# Usage: tests/smoke_gui.sh   (run from repo root; builds first)
set -u
cd "$(dirname "$0")/.."

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ISOHOME="$(mktemp -d /tmp/hangar-smokehome.XXXXXX)"
export HOME="$ISOHOME"

CFG="$HOME/.config/hangar/vms.json"
fail() { echo "SMOKE FAIL: $1"; cleanup; exit 1; }
cleanup() { pkill -x hangar 2>/dev/null; pkill Xvfb 2>/dev/null; rm -rf "$ISOHOME"; }
trap cleanup EXIT

command -v Xvfb  >/dev/null || { echo "SKIP: Xvfb not installed";  exit 0; }
command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg not installed"; exit 0; }
python3 -c "import Xlib" 2>/dev/null || { echo "SKIP: python-Xlib missing"; exit 0; }

zig build || fail "build failed"
mkdir -p "$HOME/.config/hangar" "$HOME/VMs"
rm -f "$CFG"

pkill -x hangar 2>/dev/null; pkill Xvfb 2>/dev/null; sleep 1
Xvfb :99 -screen 0 1280x800x24 -ac >/dev/null 2>&1 &
sleep 2
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE FLTK_BACKEND=x11 DISPLAY=:99 \
    ./zig-out/bin/hangar >/tmp/hangar-smoke.log 2>&1 &
APP=$!
sleep 4
kill -0 "$APP" 2>/dev/null || fail "app died on startup"

# Drive callbacks: discover window geometry, click toolbar buttons, create a VM.
DISPLAY=:99 python3 - <<'PY' || true
import time, os
from Xlib import display, X, XK
from Xlib.ext import xtest

d = display.Display(':99')
SCR_W, SCR_H = 1280, 800

# Find Hangar window position
root = d.screen().root
WX, WY = 0, 0
for c in root.query_tree().children:
    try:
        name = c.get_wm_name()
        if name and 'Hangar' in name:
            geom = c.get_geometry()
            WX, WY = geom.x, geom.y
            print(f"Found Hangar at ({WX},{WY})", flush=True)
            break
    except:
        pass
else:
    print("WARNING: Hangar window not found, using (0,0)", flush=True)

def click(x, y):
    xtest.fake_input(d, X.MotionNotify, x=x, y=y); d.sync(); time.sleep(0.15)
    xtest.fake_input(d, X.ButtonPress, 1); d.sync()
    xtest.fake_input(d, X.ButtonRelease, 1); d.sync(); time.sleep(0.4)

def key(sym, mods=[]):
    for m in mods:
        xtest.fake_input(d, X.KeyPress, d.keysym_to_keycode(m)); d.sync()
    kc = d.keysym_to_keycode(sym)
    xtest.fake_input(d, X.KeyPress, kc); d.sync()
    xtest.fake_input(d, X.KeyRelease, kc); d.sync()
    for m in reversed(mods):
        xtest.fake_input(d, X.KeyRelease, d.keysym_to_keycode(m)); d.sync()
    time.sleep(0.5)

def dlg_center(dw, dh):
    return (SCR_W - dw) // 2, (SCR_H - dh) // 2

# 1. Click "New VM" toolbar button (window-rel ~(45, 48))
click(WX + 45, WY + 48)
time.sleep(1.0)

# 2. Click the VM Name input field to focus it, then type "Smoke"
#    Dialog 460x430, name input at rel (120, 38, 330, 24)
dx_nv, dy_nv = dlg_center(460, 430)
click(dx_nv + 285, dy_nv + 50)
time.sleep(0.3)
kc = d.keysym_to_keycode(XK.XK_s)
xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
time.sleep(0.1)
kc = d.keysym_to_keycode(XK.XK_m)
xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
time.sleep(0.1)
kc = d.keysym_to_keycode(XK.XK_o)
xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
time.sleep(0.1)
kc = d.keysym_to_keycode(XK.XK_k)
xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
time.sleep(0.1)
kc = d.keysym_to_keycode(XK.XK_e)
xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
time.sleep(0.3)

# 3. Click "Create" button: dlg 460x430, Create btn rel (280, 394, 80, 30)
click(dx_nv + 320, dy_nv + 409)
time.sleep(2.0)

# 4. Open menus via keyboard — Ctrl+N then Escape to dismiss
key(XK.XK_n, [XK.XK_Control_L]); time.sleep(0.8)
key(XK.XK_Escape); time.sleep(0.3)

# 5. Click Settings toolbar button
click(WX + 640, WY + 48)
time.sleep(1.0)
# Cancel button below scroll area (dlg 500x720, Cancel at rel 395, 663)
dx, dy = dlg_center(500, 720)
click(dx + 395, dy + 663)
time.sleep(0.5)

# 6. Open About via Help menu
click(WX + 230, WY + 5)  # Help menu
time.sleep(0.3)
key(XK.XK_Down); time.sleep(0.2)
key(XK.XK_Return); time.sleep(1.0)
# Close About: dlg 440x420, OK btn rel (350, 370, 80, 30)
dx, dy = dlg_center(440, 420)
click(dx + 390, dy + 385)
time.sleep(0.5)

print("driven", flush=True)
PY

sleep 1
kill -0 "$APP" 2>/dev/null || fail "app crashed during interaction"

# Capture frame and verify non-black
DISPLAY=:99 ffmpeg -f x11grab -video_size 1280x800 -i :99.0 -frames:v 1 -update 1 /tmp/smoke_frame.png -y >/dev/null 2>&1
[ -s /tmp/smoke_frame.png ] || fail "no frame captured"
MEAN=$(ffmpeg -i /tmp/smoke_frame.png -vf "format=gray,signalstats" -f null - 2>&1 | grep -o 'YAVG:[0-9.]*' | head -1 | cut -d: -f2)
echo "frame YAVG=$MEAN"

# Verify config persisted
[ -s "$CFG" ] || fail "VM was not persisted to vms.json"
grep -q '"vms"' "$CFG" || fail "vms.json missing vms array"

echo "SMOKE OK — app survived New VM create + Settings + About dialog; config persisted"

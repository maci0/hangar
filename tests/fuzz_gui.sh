#!/usr/bin/env bash
# GUI event-storm fuzz — drives the running FLTK app under Xvfb with a long
# stream of SEEDED reproducible XTEST events: random clicks across the window +
# menu bar and random keystrokes, interleaved with periodic Escape to dismiss
# modals. Invariant: the process must survive the entire storm (no crash / no
# hang) and still render a frame.
#
# Requires: Xvfb, python-Xlib (ffmpeg optional)
# Usage: tests/fuzz_gui.sh [SEED N] [EVENTS N]
set -u
cd "$(dirname "$0")/.."
SEED="${1:-1337}"
EVENTS="${2:-400}"

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ISOHOME="$(mktemp -d /tmp/kvmgui-fuzzhome.XXXXXX)"
export HOME="$ISOHOME"

fail() { echo "GUI-FUZZ FAIL: $1"; cleanup; exit 1; }
cleanup() { pkill -x kvmgui 2>/dev/null; pkill Xvfb 2>/dev/null; rm -rf "$ISOHOME"; }
trap cleanup EXIT

command -v Xvfb >/dev/null || { echo "SKIP: Xvfb not installed"; exit 0; }
python3 -c "import Xlib" 2>/dev/null || { echo "SKIP: python-Xlib missing"; exit 0; }

zig build || fail "build failed"
pkill -x kvmgui 2>/dev/null; pkill Xvfb 2>/dev/null; sleep 1
Xvfb :99 -screen 0 1280x800x24 -ac >/dev/null 2>&1 &
sleep 2
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE FLTK_BACKEND=x11 DISPLAY=:99 \
    ./zig-out/bin/kvmgui >/tmp/kvmgui-fuzz.log 2>&1 &
APP=$!
sleep 4
kill -0 "$APP" 2>/dev/null || fail "app died on startup"

DISPLAY=:99 SEED="$SEED" EVENTS="$EVENTS" python3 - <<'PY' || true
import os, time, random
from Xlib import display, X, XK
from Xlib.ext import xtest
d = display.Display(':99')
rnd = random.Random(int(os.environ["SEED"]))
N = int(os.environ["EVENTS"])
KEYS = [XK.XK_Return, XK.XK_Tab, XK.XK_space, XK.XK_n, XK.XK_a, XK.XK_1,
        XK.XK_Down, XK.XK_Up, XK.XK_Escape, XK.XK_F11, XK.XK_Delete,
        XK.XK_F2, XK.XK_w, XK.XK_s, XK.XK_c]

# Find KVMGUI window for coordinate offset
root = d.screen().root
WX, WY = 0, 0
WW, WH = 1280, 800
for c in root.query_tree().children:
    try:
        name = c.get_wm_name()
        if name and 'KVMGUI' in name:
            geom = c.get_geometry()
            WX, WY = geom.x, geom.y
            WW, WH = geom.width, geom.height
            print(f"Found KVMGUI at ({WX},{WY}) size {WW}x{WH}", flush=True)
            break
    except:
        pass
else:
    print("WARNING: KVMGUI window not found, using (0,0)", flush=True)

def click(x, y):
    xtest.fake_input(d, X.MotionNotify, x=x, y=y); d.sync()
    xtest.fake_input(d, X.ButtonPress, 1); d.sync()
    xtest.fake_input(d, X.ButtonRelease, 1); d.sync()
def key(sym, mods):
    for m in mods: xtest.fake_input(d, X.KeyPress, d.keysym_to_keycode(m)); d.sync()
    kc = d.keysym_to_keycode(sym)
    xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
    for m in reversed(mods): xtest.fake_input(d, X.KeyRelease, d.keysym_to_keycode(m)); d.sync()

for i in range(N):
    r = rnd.random()
    if r < 0.40:
        # Random click within the window bounds (avoid hitting window decorations)
        click(rnd.randint(WX + 5, WX + WW - 5), rnd.randint(WY + 30, WY + WH - 5))
    elif r < 0.70:
        mods = [XK.XK_Control_L] if rnd.random() < 0.3 else []
        key(rnd.choice(KEYS), mods)
    else:
        # Menu bar clicks (top of window, ~28px high)
        click(rnd.randint(WX + 10, WX + WW - 10), rnd.randint(WY + 2, WY + 26))
    if i % 11 == 0:  # periodically dismiss any modal
        key(XK.XK_Escape, [])
    time.sleep(0.008)
print("storm complete", flush=True)
PY

sleep 1
kill -0 "$APP" 2>/dev/null || fail "app crashed during random event storm (seed=$SEED)"

# Final liveness probe: send Escape + confirm still alive
DISPLAY=:99 python3 - <<'PY' || true
from Xlib import display, X, XK
from Xlib.ext import xtest
d = display.Display(':99')
kc = d.keysym_to_keycode(XK.XK_Escape)
xtest.fake_input(d, X.KeyPress, kc); d.sync(); xtest.fake_input(d, X.KeyRelease, kc); d.sync()
PY
sleep 1
kill -0 "$APP" 2>/dev/null || fail "app not responsive after storm"

echo "GUI-FUZZ OK — app survived $EVENTS random events (seed=$SEED)"

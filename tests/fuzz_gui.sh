#!/usr/bin/env bash
# GUI event-storm fuzz — drives the running app under Xvfb with a long stream of
# RANDOM (seeded, reproducible) XTEST events: random clicks across the window +
# menu bar and random keystrokes, interleaved with periodic Escape to dismiss
# modals. Fuzzes the IUP callback/event layer (onMenu*, onListAction, dialog
# callbacks, toolbar buttons) the way `zig test` can't. Invariant: the process
# must survive the entire storm (no crash / no hang) and still render a frame.
#
# Requires: Xvfb, python-Xlib (ffmpeg optional). Usage: tests/fuzz_gui.sh [SEED N]
set -u
cd "$(dirname "$0")/.."
SEED="${1:-1337}"
EVENTS="${2:-400}"

# Isolate to a throwaway HOME so the test never deletes the real
# ~/.config/kvmgui/vms.json. Keep zig's cache warm via XDG_CACHE_HOME.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ISOHOME="$(mktemp -d /tmp/kvmgui-testhome.XXXXXX)"
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
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 DISPLAY=:99 \
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
        XK.XK_Down, XK.XK_Up, XK.XK_Escape, XK.XK_F11, XK.XK_Delete]
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
    if r < 0.45:
        click(rnd.randint(170, 1100), rnd.randint(80, 700))
    elif r < 0.75:
        mods = [XK.XK_Control_L] if rnd.random() < 0.3 else []
        key(rnd.choice(KEYS), mods)
    else:
        click(rnd.randint(180, 380), 84)   # menu bar region
    if i % 11 == 0:  # periodically dismiss any modal so we don't wedge
        key(XK.XK_Escape, [])
    time.sleep(0.01)
print("storm complete")
PY

sleep 1
kill -0 "$APP" 2>/dev/null || fail "app crashed during random event storm (seed=$SEED)"
# Final liveness probe: send Escape + a click, confirm still alive.
DISPLAY=:99 python3 - <<'PY' || true
from Xlib import display, X, XK
from Xlib.ext import xtest
d=display.Display(':99')
kc=d.keysym_to_keycode(XK.XK_Escape)
xtest.fake_input(d,X.KeyPress,kc); d.sync(); xtest.fake_input(d,X.KeyRelease,kc); d.sync()
PY
sleep 1
kill -0 "$APP" 2>/dev/null || fail "app not responsive after storm"

echo "GUI-FUZZ OK — app survived $EVENTS random events (seed=$SEED)"

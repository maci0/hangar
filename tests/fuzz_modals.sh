#!/usr/bin/env bash
# Direct fuzz of the unconditionally-modal GUI callbacks (onMenuAbout →
# IupMessage, onMenuImportVm → IupFileDlg). `cbfuzz modals` calls them in a loop;
# each blocks inside its modal until dismissed, so a concurrent XTEST injector
# spams Escape to close them. Standard "auto-dismiss dialogs" GUI-test method —
# gives these two functions a genuine direct harness. Asserts cbfuzz exits 0
# (every modal call returned, nothing crashed/hung).
#
# Requires Xvfb + python-Xlib. Usage: tests/fuzz_modals.sh
set -u
cd "$(dirname "$0")/.."

# Isolate to a throwaway HOME so the test never deletes the real
# ~/.config/kvmgui/vms.json. Keep zig's cache warm via XDG_CACHE_HOME.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ISOHOME="$(mktemp -d /tmp/kvmgui-testhome.XXXXXX)"
export HOME="$ISOHOME"

fail() { echo "MODAL-FUZZ FAIL: $1"; cleanup; exit 1; }
cleanup() { kill "${INJ:-0}" 2>/dev/null; pkill -x cbfuzz 2>/dev/null; pkill Xvfb 2>/dev/null; rm -rf "$ISOHOME"; }
trap cleanup EXIT

command -v Xvfb >/dev/null || { echo "SKIP: Xvfb not installed"; exit 0; }
python3 -c "import Xlib" 2>/dev/null || { echo "SKIP: python-Xlib missing"; exit 0; }

zig build 2>/dev/null # ensure cbfuzz install target is built
zig build cbfuzz >/dev/null 2>&1 || true # builds + installs the binary (run errors ignored; we run it ourselves)
BIN="zig-out/bin/cbfuzz"
[ -x "$BIN" ] || fail "cbfuzz binary not built"

pkill Xvfb 2>/dev/null; sleep 1
Xvfb :99 -screen 0 1280x800x24 -ac >/dev/null 2>&1 &
sleep 2

# Background Escape injector: spam Escape + Return so any modal/file dialog closes.
DISPLAY=:99 python3 - <<'PY' &
import time
from Xlib import display, X, XK
from Xlib.ext import xtest
d = display.Display(':99')
esc = d.keysym_to_keycode(XK.XK_Escape)
ret = d.keysym_to_keycode(XK.XK_Return)
while True:
    for kc in (esc, ret, esc):
        xtest.fake_input(d, X.KeyPress, kc); d.sync()
        xtest.fake_input(d, X.KeyRelease, kc); d.sync()
    time.sleep(0.05)
PY
INJ=$!
sleep 1

env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 DISPLAY=:99 \
    CBFUZZ_MODE=modals timeout 90 "$BIN" > /tmp/cbfuzz-modals.log 2>&1
RC=$?
kill "$INJ" 2>/dev/null
[ "$RC" -eq 0 ] || fail "cbfuzz modals exited $RC (crash or hang dismissing modals)"
grep -q "cbfuzz modals OK" /tmp/cbfuzz-modals.log || fail "cbfuzz modals did not complete"
echo "MODAL-FUZZ OK — onMenuAbout + onMenuImportVm direct-fuzzed under Escape watchdog"

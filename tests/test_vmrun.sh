#!/usr/bin/env bash
# vmrun CLI integration test — drives the real daemon over TCP and Unix.
# Guards the whole vmrun client path, including the per-request redial behavior
# (the daemon answers Connection: close, so every resolve-then-act command
# issues 2+ requests on one Connection and must redial). Requires: python3, Zig.
set -uo pipefail

WEB="$(dirname "$0")/../zig-out/bin/hangar-web"
VMRUN="$(dirname "$0")/../zig-out/bin/vmrun"
PASS=0
FAIL=0
PID=""
TMP_HOME=""

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    [ -n "$TMP_HOME" ] && rm -rf "$TMP_HOME"
    rm -f /tmp/hangar-daemon.sock
}
trap cleanup EXIT INT TERM

pick_port() {
    python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
}

# expect_contains <desc> <needle> <command...>
expect_contains() {
    local desc="$1" needle="$2"; shift 2
    local out
    out="$("$@" 2>&1)"
    if printf '%s' "$out" | grep -qF "$needle"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — output missing '$needle'"
        echo "        got: $out"
        FAIL=$((FAIL + 1))
    fi
}

# expect_fails <desc> <command...>  (expects non-zero exit)
expect_fails() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL: $desc — expected non-zero exit"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

echo "=== Building ==="
cd "$(dirname "$0")/.." || exit 1
zig build
[ -x "$WEB" ] || { echo "FAIL: $WEB not built"; exit 1; }
[ -x "$VMRUN" ] || { echo "FAIL: $VMRUN not built"; exit 1; }

PORT="$(pick_port)"
TMP_HOME="$(mktemp -d)"
export KV_PORT="$PORT" HOME="$TMP_HOME"
rm -f /tmp/hangar-daemon.sock
"$WEB" >/dev/null 2>&1 &
PID=$!
URL="http://127.0.0.1:$PORT"
UNIX="unix:///tmp/hangar-daemon.sock"

# Wait for readiness.
for _ in $(seq 1 80); do
    "$VMRUN" "$URL" status >/dev/null 2>&1 && break
    kill -0 "$PID" 2>/dev/null || { echo "FAIL: daemon exited early"; exit 1; }
    sleep 0.1
done

echo ""
echo "=== vmrun over TCP ==="
expect_contains "status reports ok"        '"status":"ok"' "$VMRUN" "$URL" status
expect_contains "create a VM"              'ok'            "$VMRUN" "$URL" create runVM 1024 1 1
expect_contains "list shows the VM"        'runVM'         "$VMRUN" "$URL" list
# info is resolve-by-name + detail = two requests on one Connection (redial).
expect_contains "info by name (2 requests)" 'Memory:  1024 MB' "$VMRUN" "$URL" info runVM
expect_contains "log reports no log yet"   'no log'        "$VMRUN" "$URL" log runVM
# snapshot on a stopped VM: take then list (resolve + act each time).
expect_contains "snapshot take"            'ok'            "$VMRUN" "$URL" snapshot take runVM snapA
expect_contains "snapshot list shows tag"  'snapA'         "$VMRUN" "$URL" snapshot list runVM
expect_contains "snapshot delete"          'ok'            "$VMRUN" "$URL" snapshot delete runVM snapA
expect_contains "rename"                   'ok'            "$VMRUN" "$URL" rename runVM runVM2
expect_contains "list shows renamed"       'runVM2'        "$VMRUN" "$URL" list
# set a field (partial update), then confirm it took via info.
expect_contains "set mem"                  'ok'            "$VMRUN" "$URL" set runVM2 mem 2048
expect_contains "info reflects set mem"    'Memory:  2048 MB' "$VMRUN" "$URL" info runVM2
# disk maintenance + introspection (stopped VM).
expect_contains "set rtc localtime"        'ok'            "$VMRUN" "$URL" set runVM2 rtc 1
expect_contains "compact disk"             'ok'            "$VMRUN" "$URL" compact runVM2
expect_contains "diskinfo virtual size"    'virtual_bytes' "$VMRUN" "$URL" diskinfo runVM2
expect_contains "guestinfo (no agent)"     'ips'           "$VMRUN" "$URL" guestinfo runVM2
# quickstart from a catalog template, then confirm it was created.
expect_contains "quickstart ubuntu"        'ok'            "$VMRUN" "$URL" quickstart ubuntu2404
expect_contains "list shows quickstart VM" 'Ubuntu 24.04'  "$VMRUN" "$URL" list
expect_fails    "quickstart unknown slug"                  "$VMRUN" "$URL" quickstart nope

echo ""
echo "=== vmrun over Unix socket ==="
expect_contains "unix status"              '"status":"ok"' "$VMRUN" "$UNIX" status
# Memory is 2048 here: the TCP section's `set mem 2048` ran earlier on this VM.
expect_contains "unix info (2 requests)"   'Memory:  2048 MB' "$VMRUN" "$UNIX" info runVM2

echo ""
echo "=== error handling ==="
expect_fails    "unknown command exits non-zero"  "$VMRUN" "$URL" bogus
expect_fails    "missing VM not found"            "$VMRUN" "$URL" info nope
expect_fails    "bad create memory rejected"      "$VMRUN" "$URL" create badVM xx 1 1
expect_fails    "set unknown field rejected"       "$VMRUN" "$URL" set runVM2 frobnicate 1

# Cleanup the created VM.
"$VMRUN" "$URL" delete runVM2 >/dev/null 2>&1

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"
[ "$FAIL" -eq 0 ]

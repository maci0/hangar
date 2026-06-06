#!/usr/bin/env bash
# Web API integration test — validates all HTTP endpoints.
# Requires: curl, python3, and Zig.
set -euo pipefail

PORT="${KV_PORT:-}"
BINARY="$(dirname "$0")/../zig-out/bin/hangar-web"
PASS=0
FAIL=0
PID=""
TMP_HOME=""
TMP_CONFIG=""

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    if [ -n "$TMP_HOME" ]; then
        rm -rf "$TMP_HOME"
    fi
}
trap cleanup EXIT INT TERM

pick_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_ready() {
    local url="$1"
    local i
    for i in $(seq 1 80); do
        if curl -fsS --max-time 1 "$url/api/health" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$PID" 2>/dev/null; then
            echo "FAIL: web server exited before becoming ready"
            return 1
        fi
        sleep 0.1
    done
    echo "FAIL: web server did not become ready at $url"
    return 1
}

# Build
echo "=== Building web server ==="
cd "$(dirname "$0")/.."
zig build

# Start server on custom port
if ! [ -x "$BINARY" ]; then
    echo "FAIL: binary not found: $BINARY"
    exit 1
fi

if [ -z "$PORT" ]; then
    PORT="$(pick_port)"
fi
TMP_HOME="$(mktemp -d)"
TMP_CONFIG="$TMP_HOME/config"
mkdir -p "$TMP_CONFIG" "$TMP_HOME/home"

export KV_PORT=$PORT
export HOME="$TMP_HOME/home"
export HANGAR_CONFIG_HOME="$TMP_CONFIG"
"$BINARY" &
PID=$!
BASE="http://127.0.0.1:$PORT"
wait_ready "$BASE"

# Helper: expect HTTP status code
expect_status() {
    local desc="$1" url="$2" expected="$3"
    local actual
    actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc (HTTP $actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected HTTP $expected, got $actual"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: expect body contains string.
# Polls for up to ~3s so assertions that follow an async mutation (create,
# save, clone) don't depend on a fixed sleep racing the server.
expect_body() {
    local desc="$1" url="$2" needle="$3"
    local body i
    for i in $(seq 1 30); do
        body=$(curl -s --max-time 3 "$url" 2>/dev/null || echo "")
        if echo "$body" | grep -qF "$needle"; then
            echo "  PASS: $desc"
            PASS=$((PASS + 1))
            return
        fi
        sleep 0.1
    done
    echo "  FAIL: $desc — body missing '$needle'"
    FAIL=$((FAIL + 1))
}

# Helper: POST
expect_post() {
    local desc="$1" url="$2" data="$3" expected_body="$4"
    local resp body actual
    resp=$(curl -s -X POST --max-time 3 -w "\n%{http_code}" -d "$data" "$url" 2>/dev/null || printf "\n000")
    actual="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    if [ "$actual" = "200" ] && echo "$body" | grep -qF "$expected_body"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — HTTP $actual body='$body' missing '$expected_body'"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== Health & Serving ==="
expect_status "Root page" "$BASE/" 200
expect_body  "Root page HTML" "$BASE/" "<!DOCTYPE html>"
expect_body  "Health endpoint" "$BASE/api/health" '"status":"ok"'
expect_status "Health status" "$BASE/api/health" 200

echo ""
echo "=== API: VM List & Config ==="
expect_status "VM list GET" "$BASE/api/vms" 200
expect_body  "VM list is JSON array" "$BASE/api/vms" '['
expect_status "Config GET" "$BASE/api/config" 200
expect_status "VNet list GET" "$BASE/api/vnets" 200

echo ""
echo "=== API: VM CRUD ==="
# Create a VM
expect_post "Create VM" "$BASE/api/new" \
    "name=TestVM&memory=1024&cpu=2&os=ubuntu64&disk=qcow2&net=user&display=gtk&firmware=bios&audio=ac97&boot=cd" \
    "ok"

# Verify VM appears in list (expect_body polls)
expect_body "New VM in list" "$BASE/api/vms" "TestVM"

# Save VM
expect_post "Save VM" "$BASE/api/save/0" \
    "name=TestVM-renamed&memory=2048&cpu=4&guest_os=ubuntu64&disk_format=qcow2&nic0_mode=user&display_type=gtk&firmware=bios&audio_device=ac97&boot_order=cd" \
    "ok"
expect_body "Renamed VM in list" "$BASE/api/vms" "TestVM-renamed"

# Clone VM
expect_post "Clone VM" "$BASE/api/clone/0" "" "ok"
expect_body "Cloned VM in list" "$BASE/api/vms" "TestVM-renamed (clone)"

# Delete cloned VM
expect_post "Delete VM" "$BASE/api/delete/1" "" "ok"
sleep 0.2

echo ""
echo "=== API: VNet Save ==="
expect_post "VNet save" "$BASE/api/vnets/save" \
    '[{"name":"VMnet0","type":"nat","subnet":"10.0.2.0","mask":"255.255.255.0","dhcp":true,"gateway":"10.0.2.2","dhcp_start":"10.0.2.128","dhcp_end":"10.0.2.254","host_iface":""}]' \
    "ok"

echo ""
echo "=== API: Error Handling ==="
expect_status "Invalid VM detail" "$BASE/api/vm/99" 404
expect_status "Invalid power" "$BASE/api/power/99" 404
expect_status "Unknown path falls through to index.html" "$BASE/api/nonexistent" 200

echo ""
echo "=== Static Resources ==="
expect_body "index.html title" "$BASE/" "Hangar"
expect_status "favicon 404" "$BASE/favicon.ico" 404

echo ""
echo "=== Config Save ==="
expect_post "Config save" "$BASE/api/config" \
    "default_memory_mb=2048&default_cpu_cores=4&autoprotect_enabled=false&autoprotect_interval=60&autoprotect_max=10&theme=light" \
    "ok"

echo ""
echo "=== Cleanup after test ==="
expect_post "Delete test VM" "$BASE/api/delete/0" "" "ok"

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

cleanup

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

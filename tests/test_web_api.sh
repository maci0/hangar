#!/usr/bin/env bash
# Web API integration test — validates all HTTP endpoints.
# Requires: curl, the kvmgui-web binary built with 'zig build web'.
set -euo pipefail

PORT=9876  # Use non-default port to avoid conflicts
BINARY="$(dirname "$0")/../zig-out/bin/kvmgui-web"
PASS=0
FAIL=0
PID=""

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Build
echo "=== Building web server ==="
cd "$(dirname "$0")/.."
zig build web 2>&1 | tail -1

# Start server on custom port
if ! [ -x "$BINARY" ]; then
    echo "FAIL: binary not found: $BINARY"
    exit 1
fi

export KV_PORT=$PORT
"$BINARY" &
PID=$!
sleep 0.5

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

# Helper: expect body contains string
expect_body() {
    local desc="$1" url="$2" needle="$3"
    local body
    body=$(curl -s --max-time 3 "$url" 2>/dev/null || echo "")
    if echo "$body" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — body missing '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: POST
expect_post() {
    local desc="$1" url="$2" data="$3" expected_body="$4"
    local body
    body=$(curl -s -X POST --max-time 3 -d "$data" "$url" 2>/dev/null || echo "")
    if echo "$body" | grep -qF "$expected_body"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — body='$body' missing '$expected_body'"
        FAIL=$((FAIL + 1))
    fi
}

BASE="http://localhost:$PORT"

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

# Verify VM appears in list
sleep 0.2
expect_body "New VM in list" "$BASE/api/vms" "TestVM"

# Save VM
expect_post "Save VM" "$BASE/api/save/0" \
    "name=TestVM-renamed&memory=2048&cpu=4&guest_os=ubuntu64&disk_format=qcow2&nic0_mode=user&display_type=gtk&firmware=bios&audio_device=ac97&boot_order=cd" \
    "saved"
sleep 0.2
expect_body "Renamed VM in list" "$BASE/api/vms" "TestVM-renamed"

# Clone VM
expect_post "Clone VM" "$BASE/api/clone/0" "" "ok"
sleep 0.2
expect_body "Cloned VM in list" "$BASE/api/vms" "TestVM-renamed (copy)"

# Delete cloned VM
expect_post "Delete VM" "$BASE/api/delete/1" "" "deleted"
sleep 0.2

echo ""
echo "=== API: VNet Save ==="
expect_post "VNet save" "$BASE/api/vnets/save" \
    '[{"name":"VMnet0","type":"nat","subnet":"10.0.2.0","mask":"255.255.255.0","dhcp":true,"gateway":"10.0.2.2","dhcp_start":"10.0.2.128","dhcp_end":"10.0.2.254","host_iface":""}]' \
    "saved"

echo ""
echo "=== API: Error Handling ==="
expect_status "Invalid VM detail" "$BASE/api/vm/99" 404
expect_status "Invalid power" "$BASE/api/power/99" 404
expect_status "404 on missing path" "$BASE/api/nonexistent" 200  # Falls through to index.html

echo ""
echo "=== Static Resources ==="
expect_body "index.html title" "$BASE/" "KVMGUI"
expect_status "favicon 404" "$BASE/favicon.ico" 404

echo ""
echo "=== Config Save ==="
expect_post "Config save" "$BASE/api/config" \
    "default_memory_mb=2048&default_cpu_cores=4&autoprotect_enabled=false&autoprotect_interval=60&autoprotect_max=10&theme=light" \
    "saved"

echo ""
echo "=== Cleanup after test ==="
expect_post "Delete test VM" "$BASE/api/delete/0" "" "deleted"

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

cleanup

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

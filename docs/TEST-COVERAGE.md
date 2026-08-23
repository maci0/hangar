# Hangar — Test Coverage

## Test Results

```
zig build test
→ All tests pass across 50+ registered test modules
```

## Pure Module Tests

Each module carries its own unit + fuzz tests at the bottom of its `.zig`
(thin wrappers `appstate_test.zig` / `hv_*_test.zig` re-export the rest).
Exact per-module counts are intentionally omitted — they drift on every
commit; run `zig build test` for the authoritative result.

| Module | Coverage |
|--------|----------|
| `vm.zig` | Config model, enums, serialization |
| `web_server.zig` | HTTP API handlers, JSON rendering, body parsing, auth, validation, isAuthExempt, clampPref |
| `persist.zig` | JSON parse/emit, VmJson mapping |
| `qemu.zig` | QEMU arg builder, OVMF detection, snapshot funcs |
| `qmp.zig` | QMP protocol parser, unicode escapes |
| `vmrun.zig` | CLI operations, JSON extraction |
| `vnet.zig` | Virtual network model, JSON/validation |
| `form_parsers.zig` | Form data parse/emit, enum fromStr |
| `fbmath.zig` | Math utilities |
| `ringbuf.zig` | Ring buffer operations |
| `serial_console.zig` | Serial console reader + connection lifecycle |
| `serialpath.zig` | Serial Unix-socket path builder |
| `uimath.zig` | UI positioning math |
| `snapparse.zig` | Snapshot output parser (QMP + HMP variants) |
| `termfilter.zig` | Terminal escape filter |
| `ovf.zig` | OVF manifest generation |
| `autoprotect.zig` | Auto-snapshot logic |
| `sync.zig` | SpinMutex operations |
| `usock.zig` | Unix socket operations |
| `appio.zig` | I/O + env helpers |
| `hv/interface.zig` | Accelerator detection |
| `hv/qemu_backend.zig` | QEMU backend dispatch |
| `path_helpers.zig` | Path manipulation |
| `urlencode.zig` | URL encoding/decoding |
| `ws.zig` | WebSocket protocol (RFC 6455) |
| `transport.zig` | HTTP transport, URL parsing, IPv6 |
| `filter.zig` | Request filtering |
| `vmlist.zig` | VM browser line→index mapping |
| `remote.zig` | Remote config |
| `vnet_label.zig` | Network label helpers |
| `spice_client.zig` | SPICE client wrappers |
| `vnc_client.zig` | VNC client wrappers |
| `appstate.zig` | Shared global state, config path helpers |
| `appstate_test.zig` | App-state wiring (test wrapper) |
| `webui_app.zig` | Native WebView desktop wrapper |

## Web End-to-End

The Playwright e2e suite is a standalone `zig build web-e2e` step, NOT part of `zig build test` (which stays hermetic):

```bash
zig build web-e2e      # Web UI end-to-end tests (Playwright, temp port + $HOME)
```

## Web Backend Tests

Standalone integration steps that spawn a real daemon:

```bash
zig build test-api     # HTTP API integration test (tests/test_web_api.sh)
zig build test-vmrun   # vmrun CLI integration test (tests/test_vmrun.sh)
```

## Visual Tests

```bash
node tests/visual/e2e_web_screenshots.mjs   # Playwright screenshots — web UI interaction flow
```

## Running Tests

```bash
zig build test         # All unit + fuzz tests (hermetic; no network/browser)
zig build web          # Build web backend
zig build webui        # Build native WebView desktop wrapper
```

## Known Issues

- No known issues — all tests pass


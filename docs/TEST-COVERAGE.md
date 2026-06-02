# Hangar — Test Coverage

## Test Results

```
zig build test
→ All tests pass across 31 modules (~1755 tests)
```

## Pure Module Tests

| Module | Tests | Coverage |
|--------|-------|----------|
| `vm.zig` | 122 | Config model, enums, serialization |
| `web_server.zig` | 83 | HTTP API handlers, JSON rendering, body parsing, auth, validation, isAuthExempt, clampPref |
| `persist.zig` | 45 | JSON parse/emit, VmJson mapping |
| `qemu.zig` | 36 | QEMU arg builder, OVMF detection, snapshot funcs |
| `qmp.zig` | 32 | QMP protocol parser, unicode escapes |
| `vmrun.zig` | 25 | CLI operations, JSON extraction |
| `vnet.zig` | 36 | Virtual network model, JSON/validation |
| `form_parsers.zig` | 28 | Form data parse/emit, enum fromStr |
| `fbmath.zig` | 10 | Math utilities |
| `ringbuf.zig` | 9 | Ring buffer operations |
| `serialpath.zig` | 6 | Serial Unix-socket path builder |
| `uimath.zig` | 10 | UI positioning math |
| `snapparse.zig` | 17 | Snapshot output parser (QMP + HMP variants) |
| `termfilter.zig` | 4 | Terminal escape filter |
| `ovf.zig` | 10 | OVF manifest generation |
| `autoprotect.zig` | 11 | Auto-snapshot logic |
| `sync.zig` | 5 | SpinMutex operations |
| `usock.zig` | 3 | Unix socket operations |
| `appio.zig` | 3 | I/O + env helpers |
| `hv/interface.zig` | 7 | Accelerator detection |
| `hv/qemu_backend.zig` | 7 | QEMU backend dispatch |
| `path_helpers.zig` | 13 | Path manipulation |
| `urlencode.zig` | 20 | URL encoding/decoding |
| `ws.zig` | 11 | WebSocket protocol (RFC 6455) |
| `transport.zig` | 8 | HTTP transport, URL parsing, IPv6 |
| `filter.zig` | 7 | Request filtering |
| `vmlist.zig` | 8 | VM browser line→index mapping |
| `remote.zig` | 6 | Remote config |
| `vnet_label.zig` | 6 | Network label helpers |
| `spice_client.zig` | 4 | SPICE client wrappers |
| `vnc_client.zig` | 4 | VNC client wrappers |

## Integration Tests (GUI — FLTK)

```bash
zig build smoke        # Xvfb: launch app, create VM, settings, about
zig build fuzzgui      # Xvfb: random event-storm fuzz of the full GUI
zig build fuzzmodals   # Xvfb: direct-fuzz modal callbacks with Escape watchdog
```

## Web Backend Tests

```bash
zig build web          # Build + launch web backend (HTTP on :9080)
bash tests/test_web_api.sh  # Curl-based HTTP API validation
```

## Visual Tests (FLTK)

```bash
python3 tests/visual/e2e_fltk_screenshots.sh   # Xvfb screenshots — 22 dialogs
python3 tests/visual/e2e_web_screenshots.mjs   # Puppeteer screenshots — web UI interaction flow
```

## Running Tests

```bash
zig build test                              # All unit + fuzz tests
zig build                                   # Build FLTK frontend
zig build web                               # Build web backend
python3 tests/visual/test_fltk.py           # FLTK visual (single screenshot)
```

## Known Issues

- No known issues — all tests pass


# KVMGUI — Test Coverage

## Test Results

```
zig build test
→ All tests pass (1425/1425 across 29 modules)
```

## Pure Module Tests

| Module | Tests | Coverage |
|--------|-------|----------|
| `vm.zig` | ~99 | Config model, enums, serialization |
| `web_server.zig` | ~66 | HTTP API handlers, JSON rendering |
| `persist.zig` | ~42 | JSON parse/emit, VmJson mapping |
| `qemu.zig` | ~32 | QEMU arg builder, OVMF detection |
| `qmp.zig` | ~25 | QMP protocol parser |
| `vmrun.zig` | ~25 | VM lifecycle runner |
| `vnet.zig` | ~36 | Virtual network model |
| `form_parsers.zig` | ~28 | Form data parse/emit |
| `fbmath.zig` | ~10 | Math utilities |
| `ringbuf.zig` | ~9 | Ring buffer operations |
| `uimath.zig` | ~10 | UI positioning math |
| `snapparse.zig` | ~17 | Snapshot output parser |
| `termfilter.zig` | ~4 | Terminal escape filter |
| `ovf.zig` | ~10 | OVF manifest generation |
| `autoprotect.zig` | ~11 | Auto-snapshot logic |
| `sync.zig` | ~5 | SpinMutex operations |
| `usock.zig` | ~3 | Unix socket operations |
| `appio.zig` | ~3 | I/O + env helpers |
| `hv/interface.zig` | ~7 | Accelerator detection |
| `hv/qemu_backend.zig` | ~7 | QEMU backend dispatch |
| `path_helpers.zig` | ~13 | Path manipulation |
| `urlencode.zig` | ~9 | URL encoding/decoding |
| `ws.zig` | ~11 | WebSocket protocol |
| `transport.zig` | ~8 | HTTP transport |
| `filter.zig` | ~7 | Request filtering |
| `remote.zig` | ~6 | Remote config |
| `vnet_label.zig` | ~6 | Network label helpers |
| `spice_client.zig` | ~4 | SPICE client wrappers |
| `vnc_client.zig` | ~4 | VNC client wrappers |

## Integration Tests

```bash
zig build itest        # Headless IUP integration (Xvfb)
zig build cbfuzz       # Headless: direct-fuzz main.zig GUI callbacks
bash tests/smoke_gui.sh   # Xvfb+XTEST: drives the running app
bash tests/fuzz_gui.sh    # Xvfb+XTEST: random event-storm fuzz
bash tests/fuzz_modals.sh # Xvfb: direct-fuzz modal callbacks
bash tests/test_web_api.sh  # Curl-based HTTP API validation
```

## Visual Tests (FLTK)

```bash
python3 tests/visual/test_fltk_comprehensive.py
```

Captures screenshots under Xvfb, validates non-blank UI with PIL ImageStat.
Home page: 1280x800, stddev=99 (visible content confirmed).

## Running Tests

```bash
zig build test                              # All 1425 unit/fuzz tests
zig build                                   # Build both frontends
python3 tests/visual/test_fltk.py           # FLTK visual
```

## Known Issues

- No known issues — all 1425 tests pass


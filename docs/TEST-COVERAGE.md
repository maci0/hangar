# KVMGUI — Test Coverage

## Test Results

```
zig build test
→ All tests pass (983/983)
```

## Pure Module Tests

| Module | Tests | Coverage |
|--------|-------|----------|
| `vm.zig` | ~120 | Config model, enums, serialization |
| `persist.zig` | ~80 | JSON parse/emit, VmJson mapping |
| `qemu.zig` | ~60 | QEMU arg builder, OVMF detection |
| `qmp.zig` | ~50 | QMP protocol parser |
| `vnet.zig` | ~30 | Virtual network model |
| `fbmath.zig` | ~20 | Math utilities |
| `ringbuf.zig` | ~25 | Ring buffer operations |
| `uimath.zig` | ~15 | UI positioning math |
| `snapparse.zig` | ~20 | Snapshot output parser |
| `termfilter.zig` | ~15 | Terminal escape filter |
| `ovf.zig` | ~30 | OVF manifest generation |
| `autoprotect.zig` | ~20 | Auto-snapshot logic |
| `sync.zig` | ~15 | SpinMutex operations |
| `usock.zig` | ~10 | Unix socket operations |
| `appio.zig` | ~10 | I/O + env helpers |
| `hv/interface.zig` | ~4 | Accelerator detection |

## Visual Tests (FLTK)

```bash
python3 tests/visual/test_fltk_comprehensive.py
```

Captures screenshots under Xvfb, validates non-blank UI with PIL ImageStat.
Home page: 1280x800, stddev=99 (visible content confirmed).

## Running Tests

```bash
zig build test                              # All 567 tests
zig build                                   # Build both frontends
python3 tests/visual/test_fltk.py           # FLTK visual
```

## Known Issues

- No known issues — all 568 tests pass, smoke + fuzz modals pass

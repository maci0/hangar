# Hangar

Lightweight QEMU virtual-machine manager with a web UI and an optional native
WebView desktop wrapper. No libvirt. Single Zig daemon serves the HTTP API, the
embedded web UI, and the remote control protocol; `vmrun` is a CLI client.

## Features

- Create, clone (full or linked), rename, delete (with undo), import VMs.
- Power on/off, suspend/resume, pause, reset, snapshots (take/revert/delete),
  live CD/ISO change, disk resize/compact, secondary + extra disks, OVF export.
- Browser consoles: VNC (noVNC) and SPICE (spice-html5) with a WebGPU/WebGL2
  presenter, plus a real xterm.js serial terminal — all in the Console tab.
- Optional hardware-accelerated H.264 video streaming of the guest display to
  the browser via WebCodecs (see `docs/VIDEO-PIPELINE.md`).
- Virtual networks (NAT/host-only/bridged) with a visual topology view.
- Host dashboard, sortable inventory, folders, tags, command palette (Ctrl+K),
  multi-select bulk operations, light/dark themes, live updates over SSE.

## Prerequisites

- **Zig 0.16.0** (the build pins backend/linker flags for this version).
- **QEMU** (`qemu-system-x86_64`, `qemu-img`); `cloud-localds` for cloud-init,
  `swtpm` for TPM, OVMF for UEFI — all optional per feature.
- For the encoded-video pipeline: `ffmpeg` (uses `h264_vaapi` when a
  `/dev/dri/renderD*` node is available, else `libx264`).
- For the e2e tests only: Node.js, `npm install`, and Chromium
  (`npm run e2e:install`).

## Build / Run / Test

```bash
zig build web          # build + launch the web backend (HTTP on :9080)
zig build webui        # build + launch the native WebView desktop wrapper
zig build test         # all hermetic unit + fuzz tests (no network/browser)
zig build web-e2e      # Playwright web UI e2e (standalone; needs npm + chromium)
zig build test-api     # HTTP API integration test (spawns a real daemon)
zig build test-vmrun   # vmrun CLI integration test (spawns a real daemon)
```

Open http://127.0.0.1:9080 after `zig build web`.

## Configuration

All optional, read once at daemon startup:

| Variable | Default | Effect |
| --- | --- | --- |
| `KV_API_KEY` | built-in `hangar` (loopback-only) | X-API-Key secret. **Setting it also binds all interfaces (`::`).** With no key, the daemon binds loopback only so the weak default is never reachable off-host. 1–64 printable-ASCII bytes; invalid values abort startup. In exposed mode, data-bearing API reads require the key. |
| `KV_PORT` | `9080` | TCP listen port (non-zero u16). |
| `HANGAR_CONFIG_HOME` | `$HOME` | Base dir for `~/.config/hangar/*` state. |

Never commit a real `KV_API_KEY`. For any non-local deployment set a strong key
and front the daemon with TLS.

## Layout

- `src/` — Zig daemon, CLI, and web assets (see `src/AGENTS.md` for the module
  map). `src/web/` is the embedded vanilla-JS UI.
- `docs/` — design notes (`DESIGN.md`, `VIDEO-PIPELINE.md`, gap analysis, CUJs).
- `tests/` — standalone integration/e2e suites (the in-module unit/fuzz tests
  live at the bottom of each `.zig`).

State lives in `~/.config/hangar/` (`vms.json`, `networks.json`); only
configuration is persisted, never runtime status.

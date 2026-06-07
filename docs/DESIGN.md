# Hangar — Design & Architecture

## Architecture Overview

```
                   ┌─ Pure Modules (shared) ─┐
                   │ vm.zig  persist.zig     │
                   │ qemu.zig qmp.zig        │
                   │ vnc_client.zig          │
                   │ spice_client.zig        │
                   │ ringbuf.zig termfilter  │
                   │ fbmath.zig uimath.zig   │
                   │ snapparse.zig ovf.zig   │
                   │ autoprotect.zig vnet    │
                   │ sync.zig usock.zig      │
                   │ appio.zig               │
                   │ hv/interface.zig        │
                   │ hv/qemu_backend.zig     │
                   └──────────┬──────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
┌───────┴────────┐  ┌─────────┴─────────┐  ┌────────┴────────┐
│ hangar-web     │  │ hangar-webui      │  │ vmrun           │
│ web_server.zig │  │ webui_app.zig     │  │ vmrun.zig       │
│                │  │                   │  │                 │
│ HTTP server +  │  │ Native WebView    │  │ CLI client over │
│ HTML/CSS/JS UI │  │ wrapper; spawns   │  │ transport.zig   │
│ + remote       │◄─┤ hangar-web and    │  │ (talks to the   │
│ daemon         │  │ shows its web UI  │──┤ hangar-web      │
│ (transport.zig)│  │ in a native win   │  │ daemon)         │
└────────────────┘  └───────────────────┘  └─────────────────┘
```

`web_server.zig` is both the local web UI server and the remote daemon;
`hangar-webui` and `vmrun` are clients of it. There is no native FLTK
frontend and no `src/main.zig` — the FLTK GUI was removed.

## Web UI Layout

Dark theme (`#0e0f12` background, `#1b1d21` surface) with WS7-style
sidebar + main content. Canvas for VNC framebuffer display.
5-second auto-refresh via polling `GET /api/vms`.

## Keyboard Shortcuts

Handled in the web UI (`src/web/app.js`); press `?` in the app for the full list.

| Key | Action |
|-----|--------|
| Ctrl+N / Ctrl+Shift+N | New VM / Clone |
| Ctrl+E, F2, Ctrl+Enter | Edit VM Settings |
| Ctrl+I | Import VM |
| Ctrl+S | Save (Settings tab) / Suspend |
| Ctrl+W | Deselect VM |
| Ctrl+F | Focus search |
| Ctrl+P | Preferences |
| F5 | Refresh |
| F11 | Toggle fullscreen / display-only |
| Enter | Power on/off selected VM |
| DEL | Delete selected VM |
| Alt+↑ / Alt+↓ | Reorder VM in list |
| Esc | Close dialog / exit display-only / deselect |

## HTTP API

Resource-rooted under `/api`. State-changing requests require the `X-API-Key`
header (the bundled UI and `vmrun` send it; the built-in default `hangar` is
accepted in loopback mode). GET reads are exempt except `disk2/download`,
`framebuffer`, and migrate status.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Liveness + VM/running counts + persist status |
| GET | `/api/config` · POST `/api/config` | Read / save preferences |
| GET | `/api/capabilities` · `/api/catalog` | Host capabilities / VM templates |
| GET | `/api/vms` | List VMs |
| POST | `/api/vms` | Create VM |
| POST | `/api/vms/{import,reorder,undo,save}` | Import / reorder / undo-delete / persist-all |
| POST | `/api/vms/quickstart/<slug>` | Create VM from a catalog template |
| GET | `/api/vms/<id>` | VM detail |
| POST | `/api/vms/<id>` | Update VM settings |
| POST | `/api/vms/<id>/delete` | Delete VM |
| POST | `/api/vms/<id>/{power,pause,resume,suspend,shutdown,reset,cad,clone,rename}` | Lifecycle actions |
| GET | `/api/vms/<id>/log` | Tail of the QEMU stderr log |
| GET | `/api/vms/<id>/framebuffer` | Current framebuffer (BMP) |
| GET | `/api/vms/<id>/diskinfo` | Primary disk virtual + actual byte sizes |
| POST | `/api/vms/<id>/disk/resize` | Grow the primary disk (stopped, grow-only) |
| GET | `/api/vms/<id>/disk2/download` · POST `/api/vms/<id>/disk2` | Download / upload (streamed) secondary disk |
| POST | `/api/vms/<id>/export` | Export OVF (streamed tarball) |
| GET | `/api/vms/<id>/snapshots` · POST same | List / take snapshot |
| POST | `/api/vms/<id>/snapshots/{revert,delete}` | Revert / delete snapshot (tag in body) |
| GET | `/api/vms/<id>/migrate` · POST same · POST `/api/vms/<id>/migrate/cancel` | Migration status / start / cancel |
| GET | `/api/networks` · POST `/api/networks` | List / save virtual networks |

WebSocket proxies (not under `/api`): `/ws/vnc/<id>`, `/ws/spice/<id>`,
`/ws/serial/<id>`.

## vmrun CLI

`vmrun <server-url> <command> [args]` drives the daemon over the same API.
Server URL is `http://host:port` (default port 9080) or `unix:///path`. The
daemon answers `Connection: close`, so vmrun redials a fresh socket per
request. Write commands send the `X-API-Key` (the built-in default in loopback
mode, or `KV_API_KEY` if set). A VM is addressed by name or list index.

| Command | Purpose |
| --- | --- |
| `list` | List VMs (index, name, status, mem, cpu) |
| `status` | Daemon health |
| `create <name> <mem-mb> <cpu> <disk-gb>` | Create a VM |
| `info <name\|idx>` | Show VM details |
| `log <name\|idx>` | Show the VM's QEMU stderr log |
| `start` / `stop` / `restart` `<name\|idx>` | Power control (idempotent) |
| `suspend` / `pause` / `resume` `<name\|idx>` | Execution state |
| `shutdown` / `reset` / `cad` `<name\|idx>` | ACPI shutdown / hard reset / Ctrl-Alt-Del |
| `clone` / `linked-clone` `<name\|idx>` | Clone (full / qcow2 backing) |
| `rename <name\|idx> <new-name>` | Rename |
| `resize <name\|idx> <new-gb>` | Grow the primary disk (stopped VM) |
| `set <name\|idx> <field> <value>` | Set one config field (mem, cpu, cpu_sockets, network, notes, tags, boot_order, vnc_port, spice_port) |
| `delete <name\|idx>` | Delete |
| `snapshot list\|take\|revert\|delete <name\|idx> [tag]` | Snapshots |
| `import <disk-path>` | Import an existing disk image |
| `export <name\|idx>` | Export as OVF+VMDK |
| `migrate <name\|idx> <host> <port>` | Start a live migration |

## Persistence

VM configs stored in `~/.config/hangar/vms.json`; virtual networks in
`~/.config/hangar/networks.json` (owned by `vnet.zig`). Base dir is
overridable via `HANGAR_CONFIG_HOME`.
Hand-rolled JSON parser (no `std.json` — linker compatibility).
`GpuDevice` enum persisted for virtio-gpu / virtio-vga selection.

## Visual Verification

```bash
node tests/visual/e2e_web_screenshots.mjs   # Playwright screenshots of the web UI
```

The Playwright flow drives a headless browser against a `hangar-web` instance
on a temp port and captures the UI interaction flow.

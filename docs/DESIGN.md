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

## Persistence

VM configs stored in `~/.config/hangar/vms.json`; virtual networks in
`~/.config/hangar/networks.json` (owned by `vnet.zig`). Base dir is
overridable via `HANGAR_CONFIG_HOME`.
Hand-rolled JSON parser (no `std.json` — linker compatibility).
`GpuDevice` enum persisted for virtio-gpu / virtio-vga selection.

## Visual Verification

```bash
node tests/visual/e2e_web_screenshots.mjs   # Puppeteer screenshots of the web UI
```

The puppeteer flow drives a headless browser against a `hangar-web` instance
on a temp port and captures the UI interaction flow.

# KVMGUI — Design & Architecture

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
              ┌───────────────┴───────────────┐
              │                               │
    ┌─────────┴──────────┐     ┌──────────────┴──────────┐
    │ FLTK Frontend       │     │ Web Frontend            │
    │ src/main.zig        │     │ src/web_server.zig      │
    │ (11.8MB binary)     │     │ (6.5MB binary)          │
    │                     │     │                         │
    │ Native C++ FLTK 1.4 │     │ HTTP server + HTML/CSS  │
    │ X11/GTK+ theme      │     │ REST API endpoints      │
    │ Keyboard shortcuts  │     │ Canvas framebuffer      │
    │ Context menus       │     │ Auto-refresh polling    │
    └─────────────────────┘     └─────────────────────────┘
```

## Design Tokens (FLTK)

FLTK uses the `gtk+` scheme for matching the system GTK2 theme.
No custom CSS overrides — widgets inherit the native look.

## Window Structure

```
┌ menu bar ────────────────────────────────────────────────┐
│ File  Edit  VM  View  Help                                │
├ toolbar ─────────────────────────────────────────────────┤
│ [New VM] [Power On] [Suspend] [Settings]                  │
├───────────────────────────────────────────────────────────┤
│ Library │  Summary | Display | Console tabs               │
│ ┌─────┐ │  ┌───────────────────────────────────────────┐ │
│ │search││  │ VM Name (bold, 18pt)                       │ │
│ │ VM1  ││  │ State: ...  Guest OS: ...  Memory: ...    │ │
│ │ VM2  ││  │ CPU: ...    Disk: ...     Network: ...    │ │
│ │ ...  ││  │ CD/DVD: ... Notes: ...                    │ │
│ │      ││  │ [Power On] button                          │ │
│ └─────┘ │  └───────────────────────────────────────────┘ │
├───────────────────────────────────────────────────────────┤
│ Status: "N virtual machine(s)"                            │
└───────────────────────────────────────────────────────────┘
```

## Web UI Layout

Dark theme (`#1e1f23` surface, `#16171a` sidebar) with WS7-style
sidebar + main content. Canvas for VNC framebuffer display.
5-second auto-refresh via polling `GET /api/vms`.

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Ctrl+N | New VM |
| Ctrl+Q | Quit (save + cleanup) |
| Ctrl+W | Deselect VM |
| F2 | Edit VM Settings |
| DEL | Delete selected VM |
| F11 | Toggle fullscreen |

## Persistence

All VM configs stored in `~/.config/kvmgui/vms.json`.
Hand-rolled JSON parser (no `std.json` — linker compatibility).
`GpuDevice` enum persisted for virtio-gpu / virtio-vga selection.

## Visual Verification

```bash
FLTK_BACKEND=x11 DISPLAY=:99 ./zig-out/bin/kvmgui
import -display :99 -window root screenshot.png
```

FLTK renders under Xvfb with `FLTK_BACKEND=x11` (X11 backend).
Standard deviation analysis confirms visible UI content.

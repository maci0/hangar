# Hangar: Product Requirements Document

## Elevator Pitch
Lightweight QEMU/KVM virtual machine manager with a web UI and an optional
native WebView desktop wrapper. Zero libvirt dependency. Single binary per role.

## Target Users
- Developers running local VMs for testing
- Users migrating from VMware Workstation seeking a lightweight alternative
- Homelab users managing QEMU VMs without libvirt complexity

## Architecture Principles
1. **Pure modules shared**: `web_server.zig`, `webui_app.zig`, and `vmrun` reuse the same VM/QEMU logic
2. **Single binary per role**: `hangar-web` (server + daemon), `hangar-webui` (native WebView wrapper), `vmrun` (CLI client)
3. **No dependencies**: hand-rolled JSON parser, no libvirt, no systemd
4. **Platform detection**: KVM on Linux, HVF on macOS, WHPX on Windows, TCG fallback

## Key Features (v1.0)
- Create/edit/delete/clone VMs
- Power on/off with QEMU process management
- VNC/SPICE embedded display
- Serial console with ring buffer
- Snapshot management via qemu-img
- JSON persistence in ~/.config/hangar/
- GPU acceleration (virtio-gpu/virtio-vga with virglrenderer)
- Virtual network editor
- Export to OVF
- Preferences dialog
- Keyboard shortcuts + context menus
- Web frontend with REST API + HTML UI

## Build Targets
| Target | Binary | Build step |
|--------|--------|-----------|
| Web server + daemon | zig-out/bin/hangar-web | `zig build web` |
| Native WebView wrapper | zig-out/bin/hangar-webui | `zig build webui` |
| CLI client | zig-out/bin/vmrun | `zig build` |

## Success Metrics
- All unit + fuzz tests pass (`zig build test`)
- Web API serves all endpoints correctly
- VM create + power on + power off lifecycle works
- Config persists across restarts

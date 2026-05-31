# KVMGUI — Product Requirements Document

## Elevator Pitch
Lightweight QEMU/KVM virtual machine manager with FLTK desktop + web frontend.
Zero libvirt dependency. Single binary for each platform.

## Target Users
- Developers running local VMs for testing
- Users migrating from VMware Workstation seeking a lightweight alternative
- Homelab users managing QEMU VMs without libvirt complexity

## Architecture Principles
1. **Pure modules shared** — both FLTK and Web frontends share the same VM/QEMU logic
2. **Single binary** — FLTK desktop is one statically-linked ELF; web server is one ELF
3. **No dependencies** — hand-rolled JSON parser, no libvirt, no systemd
4. **Platform detection** — KVM on Linux, HVF on macOS, WHPX on Windows, TCG fallback

## Key Features (v1.0)
- Create/edit/delete/clone VMs
- Power on/off with QEMU process management
- VNC/SPICE embedded display
- Serial console with ring buffer
- Snapshot management via qemu-img
- JSON persistence in ~/.config/kvmgui/
- GPU acceleration (virtio-gpu/virtio-vga with virglrenderer)
- Virtual network editor
- Export to OVF
- Preferences dialog
- Keyboard shortcuts + context menus
- Web frontend with REST API + HTML UI

## Build Targets
| Target | Binary | Size |
|--------|--------|------|
| Linux FLTK | zig-out/bin/kvmgui | ~11.8MB |
| Linux Web | zig-out/bin/kvmgui-web | ~6.5MB |

## Success Metrics
- 567/568 pure module tests passing
- FLTK renders correctly under Xvfb (visual verified)
- Web API serves all endpoints correctly
- VM create + power on + power off lifecycle works
- Config persists across restarts

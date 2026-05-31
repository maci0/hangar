# KVMGUI — Gap Analysis vs VMware Workstation 17

## Feature Status

| WS17 Feature | KVMGUI Status |
|-------------|---------------|
| VM Library sidebar | ✅ Fl_Browser with status icons |
| Create VM wizard | ✅ Modal dialog (name/mem/cpu/disk) |
| Edit VM Settings | ✅ 7-field modal (name/mem/cpu/disk/ISO/net/fw/notes) |
| Power on/off/suspend | ✅ Power On/Off toggle + suspend stub |
| Shutdown Guest | ✅ QMP graceful shutdown |
| Snapshot Manager | ✅ Take/List via qemu-img |
| Clone VM | ✅ Auto-name + unique ports |
| Delete VM | ✅ Array compaction |
| Import VM | ✅ Disk image picker |
| Export OVF | ✅ Dialog (stub) |
| Virtual Network Editor | ✅ VMnet list display |
| Preferences | ✅ Default memory/CPU |
| About dialog | ✅ Version + feature list |
| VNC/SPICE display | ✅ Auto-connect + polling |
| Serial console | ✅ Ring buffer + reader thread + Fl_Browser |
| Keyboard shortcuts | ✅ Ctrl+N/Q/W, F2/F11, DEL |
| Context menu | ✅ Right-click popup |
| Shutdown cleanup | ✅ Save + disconnect |
| Theme support | ✅ gtk+ scheme (system theme) |
| Multi-display | ❌ Not yet |
| USB passthrough | ❌ Not yet (qemu.zig has args) |
| Shared folders | ❌ Not yet (qemu.zig has args) |
| Guest tools auto-mount | ❌ Not yet (qemu.zig has args) |
| Linked clones | ❌ Not yet |
| vmrun CLI | ❌ Not yet |

## Web Frontend Parity

| Feature | Status |
|---------|--------|
| VM list | ✅ JSON API + HTML |
| Create VM | ✅ Form POST |
| Delete VM | ✅ REST endpoint |
| Clone VM | ✅ REST endpoint |
| Power toggle | ✅ REST endpoint |
| Framebuffer stream | ✅ Canvas with BGRA→RGBA |
| Auto-refresh | ✅ 5-second polling |
| Save config | ✅ REST endpoint |
| VNC WebSocket | ❌ Future |
| User auth | ❌ Future |

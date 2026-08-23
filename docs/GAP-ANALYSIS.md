# Hangar — Gap Analysis vs VMware Workstation 17

## Feature Status

| WS17 Feature | Hangar Status |
|-------------|---------------|
| VM Library sidebar | ✅ Web sidebar with status icons |
| Create VM wizard | ✅ Modal dialog (name/mem/cpu/disk/ISO/OS) |
| Edit VM Settings | ✅ Full settings dialog (~40 fields) |
| Power on/off/suspend | ✅ Power toggle + suspend + pause/resume |
| Shutdown Guest | ✅ QMP graceful shutdown + reset |
| Snapshot Manager | ✅ Take/list/revert/delete (Web) |
| Clone VM | ✅ Full + linked clones |
| Delete VM | ✅ Array compaction + confirmation |
| Import VM | ✅ Disk image picker + multipart upload (Web) |
| Export OVF | ✅ OVF XML + VMDK conversion + download |
| Virtual Network Editor | ✅ VMnet0/1/8 defaults, add/remove |
| Preferences | ✅ Theme, default mem/CPU, autoprotect defaults |
| About dialog | ✅ Version + feature list + keyboard shortcuts |
| VNC/SPICE display | ✅ Auto-connect + Web VNC WS proxy + canvas framebuffer |
| Serial console | ✅ Ring buffer + reader thread + Web WebSocket serial |
| Keyboard shortcuts | ✅ Ctrl+N/W/E, F2/F11, DEL, Ctrl+Shift+N, Ctrl+I |
| Context menu | ✅ Right-click popup with full action set |
| Autoprotect | ✅ Interval-based auto-snapshots with prune |
| Theme support | ✅ Light/Dark + system (Web) |
| Multi-display | ✅ VmConfig + QEMU args |
| USB passthrough | ✅ VmConfig + QEMU args + UI fields |
| Shared folders | ✅ VmConfig + QEMU args + UI fields |
| Guest tools auto-mount | ✅ VmConfig + QEMU args + UI fields |
| Linked clones | ✅ qemu-img backing-file COW |
| VM rename | ✅ Web API + dialog |
| Send Ctrl+Alt+Del | ✅ QMP sendkey + Web button |
| Port forwarding | ✅ VmConfig + QEMU hostfwd + UI fields |
| Second disk + extra disks + floppy | ✅ VmConfig + QEMU args + UI fields (up to 4 extra disks) |
| Extra NICs (2-8) | ✅ VmConfig + QEMU args + UI fields (up to 8 NICs) |
| Auto MAC generation | ✅ Random unicast/local-admin MAC |
| Remote client/daemon | ✅ transport.zig + HTTP API + vmrun CLI |
| Batch start/stop all | ✅ Web toolbar buttons |
| Favorites | ✅ Star toggle + grouped with separator |
| Window geometry save | ❌ Removed with the FLTK frontend — `Prefs` still persists `win_x/y/w/h` but no current UI saves or restores geometry |
| vmrun CLI | ✅ 30 commands (list/start/stop/clone/delete/snapshot/...) |
| HV abstraction layer | ✅ QEMU backend + dispatch table |
| Live migration | ✅ QMP live migrate + status/cancel (Web + vmrun) |
| Encoded guest video stream | ✅ H.264 via dbus display + ffmpeg encoder, WebCodecs overlay (see docs/VIDEO-PIPELINE.md) |
| Command palette | ✅ Ctrl+K fuzzy palette |
| VM catalog / quickstart | ✅ Built-in templates (`POST /api/vms/quickstart/<slug>`) |
| Tags & folders | ✅ Sidebar filter by tag, collapsible folder tree |
| Cloud-init user-data | ✅ Per-VM `cloud_init` field (8 KB); seed ISO generated via cloud-localds at power-on |
| Host dashboard | ✅ CPU/RAM capacity + inventory totals (VanJS) |

## Web Frontend Parity

| Feature | Status |
|---------|--------|
| VM list sidebar | ✅ JSON API + HTML + status dots + favorites |
| Create VM | ✅ Modal form POST |
| Edit VM Settings | ✅ Full modal (~40 fields) |
| Delete VM | ✅ REST endpoint + confirmation |
| Clone VM | ✅ REST endpoint + linked clone option |
| Power toggle | ✅ REST endpoint |
| Pause/Resume | ✅ REST endpoints |
| Shutdown/Reset | ✅ REST endpoints |
| Suspend | ✅ REST endpoint |
| Rename | ✅ REST endpoint |
| Export OVF | ✅ REST endpoint + download |
| Import VM | ✅ Multipart upload |
| Snapshot take/list/revert/delete | ✅ REST endpoints + modal UI |
| Framebuffer display | ✅ Canvas polling + VNC WebSocket proxy |
| Serial console | ✅ WebSocket serial terminal |
| Virtual Network Editor | ✅ REST endpoints + modal UI |
| Preferences editor | ✅ REST endpoint + modal with theme preview |
| Keyboard shortcuts | ✅ Ctrl+N/E/Del/Esc/Enter/? help modal |
| Theme support | ✅ Light/Dark/System with CSS variables |
| Batch start/stop all | ✅ Toolbar buttons |
| Toast notifications | ✅ Success/error/info with auto-dismiss |
| API key auth | ✅ X-API-Key header on all writes |
| Rate limiting | ✅ Atomic 200 POST/sec |
| Security headers | ✅ CSP, X-Content-Type-Options, X-Frame-Options |
| Favicon | ✅ SVG gradient K logo |


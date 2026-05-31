# KVMGUI — TODO / Gap Tracker

Comprehensive inventory of missing features, unfinished work, and improvement
opportunities. Organized by priority tier with cross-references to source files
and the design docs.

---

## Tier 1 — High Priority (existing infrastructure, needs UI wiring)

### 1.1 Wire AutoProtect into the FLTK GUI ✅

| File | Status |
|------|--------|
| `src/autoprotect.zig` | ✅ Complete (unit-tested, fuzzed) |
| `src/main.zig` | ✅ `autoprotect` imported, timerCB calls `due()`/`snapName()`/`pruneExcess()` |
| `src/vm.zig` | ✅ `autoprotect_last_epoch`, `autoprotect_last_seq` fields |
| `src/persist.zig` | ✅ Persisted in JSON |
| `src/main.zig` editVmDialog | ✅ Checkbox for enable, inputs for interval/max |

### 1.2 USB / Shared Folder / Guest Tools Display in Summary Tab ✅

| File | Status |
|------|--------|
| `src/main.zig:detail_labels` | ✅ Expanded to `[12]` |
| `src/main.zig:refreshDetails()` | ✅ Shows shared folder, USB, guest tools, autoprotect |
| `src/main.zig:main()` widget creation | ✅ 12 detail labels created |

### 1.3 Web Frontend: Missing API Fields ✅

| File | Status |
|------|--------|
| `src/web_server.zig:renderVmDetail()` | ✅ Includes shared_folder, usb_device, guest_tools, autoprotect, disk2, floppy, port_forwards |
| `src/web_server.zig:renderJson()` | ✅ Expanded: net, fw, mac, nic2/3, shared_folder, usb, guest_tools, autoprotect, disk2, floppy, port_forwards, notes |
| `src/web_server.zig:index_html` | ✅ JS renderDetails() shows all fields conditionally; editVm() modal has full field set |

### 1.4 Web Frontend: Edit VM / Settings Dialog ✅

| File | What's done |
|------|-------------|
| `src/web_server.zig:index_html` JS | ✅ `editVm()` opens modal dialog with all fields populated |
| `src/web_server.zig` routes | ✅ `POST /api/save/N` parses all VmConfig fields and persists |
| `src/web_server.zig:handleSave()` | ✅ Parses name, mem, cpu, disk, network, firmware, shared_folder, usb, guest_tools, autoprotect, ap_interval, ap_max, disk2_path, disk2_size, floppy, nic2, nic3, portfw, notes |
| `src/vm.zig` | ✅ Added `fromStr()` to `NetworkMode` and `BootFirmware` for web API |

### 1.5 Second Data Disk, Floppy, Extra NICs: UI ✅

| File | Status |
|------|--------|
| `src/vm.zig` | ✅ All fields persisted |
| `src/qemu.zig` | ✅ `buildArgs()` appends disk2, floppy, extra NICs |
| `src/main.zig:editVmDialog()` | ✅ Fields for disk2 (path/size/format), floppy, NIC2, NIC3 |

### 1.6 Port Forwarding: UI ✅

| File | Status |
|------|--------|
| `src/vm.zig` | ✅ `port_fwd_buf` / `setPortForwards()` / `getPortForwards()` |
| `src/qemu.zig` | ✅ `buildArgs()` constructs `hostfwd=` |
| `src/main.zig:editVmDialog()` | ✅ Port forwarding input field |

---

## Tier 2 — Medium Priority (needs new code or larger changes)

### 2.1 HV Abstraction Layer Integration ✅

| File | Status |
|------|--------|
| `src/hv/interface.zig` | ✅ Complete |
| `src/hv/qemu_backend.zig` | ✅ Complete |
| `src/main.zig` | ✅ All qemu.* calls routed through g_vmm.*Fn with fallback (power, snapshots, autoprotect, clone) |
| `src/web_server.zig` | ✅ Wired: imports hv modules, g_vmm + handles array, handlePower routes through HV |

### 2.2 Web Frontend: VNC WebSocket Proxy ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ `handleWsVnc()` upgrades connection, spawns bidirectional relay threads |
| `src/ws.zig` | ✅ WebSocket framing layer (compile-tested, unit-tested) |
| `src/vnc_client.zig` | Used via direct socket relay (not polling) |
| `src/index_html` JS | Canvas rendering uses `setInterval` polling of `/api/fb/N` every 200ms (still available as fallback) |

### 2.3 Linked Clone UI ✅

| File | Status |
|------|--------|
| `src/qemu.zig` | ✅ `createLinkedClone()` implemented |
| `src/hv/qemu_backend.zig` | ✅ `createLinkedCloneFn` wired |
| `src/main.zig` | ✅ Clone dialog with Full/Linked Clone buttons |

### 2.4 Multi-Display Support ✅

| File | Status |
|------|--------|
| `src/vm.zig` | ✅ `num_displays: u32 = 1` field added |
| `src/qemu.zig:buildArgs()` | ✅ Loop adds extra `-device virtio-gpu` for displays 2+ |
| `src/main.zig` | ✅ Settings dialog has Displays field |
| `src/persist.zig` | ✅ Persisted in JSON + streaming parser |
| `src/web_server.zig` | ✅ Included in renderJson/renderVmDetail |

### 2.5 Auto MAC Generation for NICs ✅

| File | Status |
|------|--------|
| `src/vm.zig` | ✅ `generateMacAddress()` generates random unicast/locally-administered MAC |
| `src/main.zig:newVmDialog()` | ✅ Generates MAC on new VM creation |
| `src/main.zig:cloneVm()` | ✅ Generates new MAC for clone (doesn't copy source MAC) |
| `src/main.zig:importVm()` | ✅ Generates MAC on import |

---

## Tier 3 — Low Priority (nice-to-have / polish)

### 3.1 Favorites / Library Groups ✅

| File | Status |
|------|--------|
| `src/vm.zig` | ✅ `favorite: bool` field persisted |
| `src/main.zig` | ✅ Favorites group with ★ prefix, separator, right-click "Toggle Favorite", filterMatch helper |

### 3.2 Remote Server Connection ✅

| File | Status |
|------|--------|
| `src/transport.zig` | ✅ `Url.parse()` / `Connection.connect()` / `Connection.request()` |
| `src/main.zig` | ✅ `remoteConnectDialog()` fully wired: URL parse, health-check, auth header, remote mode toggle, VM list refresh |

### 3.3 OVF Export: Generate the VMDK ✅

| File | Status |
|------|--------|
| `src/main.zig:exportOvfDialog()` | ✅ Writes `.ovf` XML and calls `qemu-img convert` to produce `.vmdk` |
| `src/qemu.zig` | ✅ `convertDiskImage()` via `qemu-img convert -O vmdk -o subformat=streamOptimized` |

### 3.4 vmrun CLI Tool ✅

| File | Status |
|------|--------|
| `src/transport.zig` | ✅ Connection layer exists |
| `src/vmrun.zig` | ✅ Full CLI: list, start, stop, restart, clone, delete, status |
| `build.zig` | ✅ `vmrun` build target (use_llvm + use_lld) |

### 3.5 Preferences Dialog: Add AutoProtect Global Defaults ✅

| File | Status |
|------|--------|
| `src/main.zig:prefsDialog()` | ✅ Wired with Save/Cancel; AutoProtect checkbox, interval, and max inputs |
| `src/vm.zig:Prefs` | ✅ `autoprotect_enabled_default`, `autoprotect_interval_min_default`, `autoprotect_max_default` |
| `src/persist.zig` | ✅ Emitted and parsed in JSON |

### 3.6 Save/Restore Window Geometry ✅

| File | Status |
|------|--------|
| `src/persist.zig` | ✅ Window x/y/width/height persisted and parsed |
| `src/vm.zig:Prefs` | ✅ `win_x`, `win_y`, `win_w`, `win_h` fields |
| `src/main.zig` | ✅ Saves geometry on close, restores on startup |

### 3.7 FLTK Display Tab: Pixel Rendering ✅

| File | Status |
|------|--------|
| `src/main.zig` Display tab | ✅ `Fl_RGB_Image_new` from VNC/SPICE framebuffer via BGRA→RGBA swap |
| `src/main.zig:displayTimerCB()` | ✅ Renders pixels at 10fps; `renderFramebuffer` helper handles scaling |
| `src/main.zig` disconnect paths | ✅ `clearDisplay()` called on all 4 disconnect paths |
| `src/vnc_client.zig` | ✅ `lockFb()`/`getSize()` used for pixel readout |
| `src/spice_client.zig` | ✅ `getFb()`/`stride` used for pixel readout |
| `src/fbmath.zig` | ✅ `fbFits()` guards dimension overflow |

### 3.8 Remote Server: Operation Dispatch Layer ✅

| File | Status |
|------|--------|
| `src/transport.zig` | ✅ `Url.parse()` / `Connection.connect()` / `Connection.request()` |
| `src/main.zig:apiGet()` | ✅ Helper exists, used by remoteRefreshVmList |
| `src/main.zig:apiPost()` | ✅ Helper exists, used by clone/delete/power/save/create |
| `src/main.zig` cloneVm | ✅ Remote dispatch via `/api/clone/N` |
| `src/main.zig` deleteCurrentVm | ✅ Remote dispatch via `/api/delete/N` |
| `src/main.zig` togglePower | ✅ Remote dispatch via `/api/power/N` |
| `src/main.zig` editVmDialog save | ✅ Remote dispatch via `/api/save/N` with buildSaveBody |
| `src/main.zig` newVmDialog create | ✅ Remote dispatch via `/api/create` |
| `src/main.zig` suspendVm | ✅ Remote dispatch via `/api/suspend/N` |
| `src/main.zig` snapDialog | ✅ Remote dispatch via `/api/snapshot/take/N` + `/api/snapshot/list/N` |
| `src/main.zig` importVm | ✅ Remote dispatch via `/api/import` |
| `src/web_server.zig` | ✅ `handleSuspend`, `handleSnapshotTake`, `handleSnapshotList`, `handleImport` |

### 3.9 SHM Transport: Ring Buffer Backend ✅

| File | Status |
|------|--------|
| `src/transport.zig` | ✅ `connectShm()` uses `shm_open` + `mmap`; `shmRequest()` uses atomics with spin-wait + nanosleep backoff |
| `src/ringbuf.zig` | ✅ Ring buffer implementation exists (used by serial.zig) |

### 3.10 Snapshot Revert and Delete: FLTK GUI ✅

| File | Status |
|------|--------|
| `src/main.zig:snapDialog()` | ✅ Revert and Delete buttons added, wired to HV/qemu/remote dispatch |
| `src/qemu.zig` | ✅ `snapshotApply()` and `snapshotDelete()` exist |
| `src/qmp.zig` | ✅ `loadSnapshot()` and `deleteSnapshot()` exist |
| `src/hv/interface.zig` | ✅ `snapshotApplyFn` and `snapshotDeleteFn` declared |

### 3.11 Snapshot Revert and Delete: Web Server ✅

| File | Status |
|------|--------|
| `src/web_server.zig` routes | ✅ `POST /api/snapshot/revert/N` and `POST /api/snapshot/delete/N` |
| `src/web_server.zig` handlers | ✅ `handleSnapshotRevert` and `handleSnapshotDelete` implemented |

### 3.12 Graceful Shutdown and Reset: FLTK GUI ✅

| File | Status |
|------|--------|
| `src/main.zig` toolbar | ✅ "Shut Down" and "Reset" buttons, VM/context menu entries |
| `src/main.zig` handlers | ✅ `shutdownGuest()`, `resetGuest()`, `shutdownViaQmp()`, `resetViaQmp()` |
| `src/qmp.zig` | ✅ `powerdown()` and `reset()` exist |
| `src/hv/interface.zig` | ✅ `shutdownFn` and `resetFn` declared |

### 3.13 Graceful Shutdown and Reset: Web Server ✅

| File | Status |
|------|--------|
| `src/web_server.zig` routes | ✅ `POST /api/shutdown/N` and `POST /api/reset/N` |
| `src/web_server.zig` handlers | ✅ `handleShutdown()` and `handleReset()` implemented |
| `src/web_server.zig:index_html` JS | ✅ "Shut Down" and "Reset" buttons with fetch calls |

### 3.14 Web Server: Missing VmConfig Fields in Save ✅

| File | Status |
|------|--------|
| `src/main.zig:editVmDialog()` | ✅ Fixed — FLTK dialog was missing 21 VmConfig fields; all now added |
| `src/main.zig:buildSaveBody()` | ✅ Extended with all 21 new fields for remote API save |
| `src/web_server.zig:handleSave()` | ✅ Already parsed all ~40 fields — no changes needed |
| Missing fields | cpu_sockets, disk_format, iso_path, mac_address, nic2_mac, nic3_mac, disk2_format, enable_3d, gpu_device, display, display_resolution, guest_os, audio, boot_order, enable_kvm, embed_display, vnc_port, spice_port, enable_serial, num_displays, favorite |

### 3.15 Web Server: Serial Console ✅

| File | Status |
|------|--------|
| `src/web_server.zig` route | ✅ `GET /ws/serial/N` WebSocket upgrade |
| `src/web_server.zig` handler | ✅ `handleWsSerial()` — bidirectional relay between WS ↔ Unix socket |
| `src/web_server.zig:index_html` | ✅ Serial terminal UI panel, xterm-like textarea, WS JS client |

### 3.16 Stale/IUP-heritage Cleanup ✅

| File | Status |
|------|--------|
| `src/main_fltk.zig` | ✅ Already removed — never existed in FLTK port |
| `src/itest.zig` | ✅ Removed — dead IUP test code, broken imports, not in build.zig |
| `AGENTS.md` | ✅ Fixed — removed stale `serial.zig`, corrected `display.zig`/`dialogs.zig` descriptions |
| `src/display.zig` | ✅ Active — used by FLTK frontend for Display tab framebuffer rendering |
| `src/dialogs.zig` | ✅ Active — prefs, VNet editor, about, OVF export, remote connect dialogs |
| `src/serial.zig` | ✅ Doesn't exist — no cleanup needed |
| `src/icons.zig` | ✅ Doesn't exist — no cleanup needed |

---

## Tier 4 — Bugs / Issues

### 4.1 Pre-existing Fuzz Test Crash ✅

| Symptom | SIGABRT in test runner from stack overflow on large VmConfig allocations |
|---------|-----------------------------------------------------------------------|
| Status | No longer reproducible — all 568 tests pass (Zig 0.16 compiler may have increased default stack size or the test was restructured) |

### 4.2 FLTK `Fl_Check_Button` cast warning ✅

| Symptom | `@ptrCast(gt_input)` and similar casts from `?*cfltk.Fl_Check_Button` |
|---------|-----------------------------------------------------------------------|
| Fix | Removed unnecessary `@ptrCast` from `Fl_Check_Button_set_checked` calls — Zig 0.16 `@cImport` translates both return and parameter C pointers compatibly |

### 4.3 HV Interface Missing: convertDiskImage ✅

| Symptom | `exportOvfDialog()` calls `qemu.convertDiskImage()` directly — no HV equivalent |
|---------|-----------------------------------------------------------------------|
| Fix | `convertDiskFn` already declared in `hv/interface.zig` and implemented in `hv/qemu_backend.zig`; `exportOvfDialog` now uses HV path first with fallback to `qemu.convertDiskImage()` |

---

## Tier 3.5 — New Gaps (post-FLTK migration)

### 3.17 Web Frontend: Edit VM Dialog Missing Fields ✅

| File | Status |
|------|--------|
| `src/web_server.zig:handleSave()` | ✅ Already parses all ~40 VmConfig fields |
| `src/web_server.zig:editVm()` JS | ✅ Populates all 40 fields including 21 new: cpu_sockets, disk_format, iso_path, mac_address, nic2_mac, nic3_mac, disk2_format, enable_3d, gpu_device, display, display_resolution, guest_os, audio, boot_order, enable_kvm, embed_display, vnc_port, spice_port, enable_serial, num_displays, favorite |
| `src/web_server.zig:saveVm()` JS | ✅ POST body includes all 40 fields |
| `src/web_server.zig` edit HTML form | ✅ Input fields for all 21 additional VmConfig keys |

### 3.18 VM Pause/Resume (Freeze Guest Execution) ✅

| File | Status |
|------|--------|
| `src/qmp.zig` | ✅ `pauseVm()` and `resumeVm()` exist (QMP `stop`/`cont`) |
| `src/hv/interface.zig` | ✅ `pauseFn` and `resumeFn` declared |
| `src/hv/qemu_backend.zig` | ✅ Implemented |
| `src/main.zig` toolbar | ✅ Pause ⏸ and Resume ▶ buttons added |
| `src/main.zig` menu | ✅ Pause/Resume in VM menu and context menu |
| `src/web_server.zig` | ✅ `POST /api/pause/N` and `POST /api/resume/N` endpoints + handlers + JS toolbar buttons |

### 3.19 Keyboard Shortcuts ✅

| Shortcut | Action |
|----------|--------|
| Ctrl+Q | ✅ Quit |
| Ctrl+W | ✅ Deselect VM / Home |
| Del | ✅ Delete selected VM (with confirmation) |
| Ctrl+E | ✅ Edit/Settings for selected VM |
| Enter | ✅ Power On/Off toggle for selected VM |
| Ctrl+N | ✅ New VM |
| Ctrl+Shift+N | ✅ Clone VM |
| Ctrl+I | ✅ Import VM |
| Escape | ✅ Deselect VM / Home |

### 3.20 VM Rename ✅

| File | Status |
|------|--------|
| `src/main.zig` | ✅ Rename dialog (Fl_Window with input + OK/Cancel), VM menu entry, context menu entry, remote mode dispatch |
| `src/web_server.zig` | ✅ `POST /api/rename/N` route + handleRename handler, renameGuest() JS function + "Rename" toolbar button |

### 3.21 Web UI: Suspend/Clone/Import/Snapshot Toolbar Buttons ✅

| File | Status |
|------|--------|
| `src/web_server.zig` toolbar | ✅ Suspend, Clone, Import, Snapshot buttons added |
| `src/web_server.zig` JS | ✅ `suspendGuest()`, `cloneGuest()`, `importGuest()`, `takeSnapshot()` functions |
| `src/web_server.zig:handleSnapshotTake()` | ✅ Updated to parse `tag=` from body (supports both raw and key=value) |
| `src/web_server.zig` JS | ✅ `setStatus()` helper function added |

### 3.22 Web UI: Export OVF Endpoint + Button ✅

| File | Status |
|------|--------|
| `src/web_server.zig` route | ✅ `POST /api/export/N` — writes OVF XML + converts disk to VMDK |
| `src/web_server.zig:handleExport()` | ✅ Uses ovf.buildDescriptor + qemu.convertDiskImage → /tmp/ovf_export |
| `src/web_server.zig` toolbar | ✅ "Export OVF" button with exportOvf() JS function |

### 3.23 Both UIs: Send Ctrl+Alt+Del Button ✅

| File | Status |
|------|--------|
| `src/qmp.zig` | ✅ `sendCtrlAltDel()` exists (HMP `sendkey ctrl-alt-delete`) |
| `src/main.zig` | ✅ `cadCB` callback, `sendCtrlAltDel()` + `cadViaQmp()` functions, toolbar button, VM menu entry, context menu entry |
| `src/web_server.zig` | ✅ `POST /api/cad/N` route + `handleCad()` handler, `sendCad()` JS + toolbar button |

### 3.24 Web UI: Virtual Network Editor ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ `GET /api/vnets`, `POST /api/vnets/save`, `handleVnetsJson()`, `handleVnetsSave()` |
| `src/web_server.zig` JS | ✅ VNet dialog with list, edit form, Add/Remove/Use Defaults/Save |

### 3.25 Web UI: Preferences Editor ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ `POST /api/config` + `handleConfigSave()` |
| `src/web_server.zig` JS | ✅ Preferences dialog with theme, memory, CPU, autoprotect defaults |

### 3.26 Web UI: Snapshot List/Revert/Delete UI ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ API endpoints exist and JS UI complete |
| `src/web_server.zig` JS | ✅ Snapshot dialog with Take/Revert/Delete, list rendering, confirm dialogs |

### 3.27 Web UI: Favorite Toggle ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS | ✅ `toggleFavorite()` JS function, ★ star in VM list items, `e_favorite` in edit dialog |
| `src/web_server.zig` API | ✅ favorite field exists in JSON, `handleSave` parses it |

### 3.28 Web UI: New VM Toolbar Button ✅

| File | Status |
|------|--------|
| `src/web_server.zig` HTML | ✅ "+ New VM" button in toolbar (line 1068) opens `newdlg` modal |
| `src/web_server.zig` JS | ✅ `createVm()` function and `newdlg` dialog already exist |

### 3.29 Web UI: Batch Power Operations ✅

| File | Status |
|------|--------|
| `src/web_server.zig` HTML | ✅ "▶ Start All" and "⏹ Stop All" buttons in toolbar |
| `src/web_server.zig` JS | ✅ `batchStart()` and `batchStop()` iterate VMs, filter by status, POST to `/api/power/N` |
| `src/main.zig` | ✅ FLTK has batch start/stop on power toolbar |

### 3.30 Web Server: Multipart File Upload Support ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ `parseMultipart()` handles `multipart/form-data` boundary parsing, extracts filename + body from part headers |
| `src/web_server.zig:handleImport()` | ✅ Accepts multipart file upload for disk image + optional name/mem/cpu/cpu_sockets/disk_format fields |
| `src/web_server.zig:handleUploadDisk()` | ✅ `POST /api/vm/N/upload-disk` — multipart upload for disk2; auto-creates disk if path empty |

### 3.31 Web Server: Disk Download Endpoints ✅

| File | Status |
|------|--------|
| `src/web_server.zig:handleExport()` | ✅ `POST /api/export/N` — streams primary disk image as download |
| `src/web_server.zig:handleDisk2Download()` | ✅ `GET /api/vm/N/disk2/download` — streams disk2 image as download |
| `src/web_server.zig:index_html` JS | ✅ `exportOvf()` uses `apiPost` and shows filename from response |

### 3.32 Web Server: API Key Authentication ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ `API_KEY` const, `checkAuth()` helper reads `X-API-Key` header |
| `src/web_server.zig` routes | ✅ All POST/PUT handlers call `checkAuth()` (GET /api/vms, /api/fb/N, /api/snapshot/list/N, WebSocket upgrade exempt) |

### 3.33 Web Frontend: Fetch Error Guarding ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS | ✅ `apiPost()` wrapper checks `response.ok`, returns `null` on error with status bar message |
| `src/web_server.zig` JS | ✅ All 18 POST call sites use `apiPost()` + check return before acting: powerToggle, shutdownGuest, resetGuest, pauseGuest, resumeGuest, renameGuest, suspendGuest, cloneGuest, importGuest, batchStart, batchStop, takeSnapshotFromDlg, revertSnapshot, deleteSnapshot, sendCad, exportOvf, deleteVm, saveVm, toggleFavorite, createVm, vnetSaveAll, savePrefs |

---

## Tier 5 — Architecture / Refactoring

### 5.1 Unify Network Handling ✅

| File | Status |
|------|--------|
| `src/vm.zig` | ✅ `nics: [MAX_NICS]Nic` array; accessor methods delegate to `nics[i]` |
| `src/qemu.zig` | ✅ Loop over `nics[1..]`; per-NIC-index buffers in ArgBuffers |
| `src/persist.zig` | ✅ Emit/parse via `nics[i].mode`; JSON keys preserved |
| `src/main.zig` | ✅ editVmDialog + refreshDetails use `nics[i]` |
| `src/web_server.zig` | ✅ renderJson, renderVmDetail, handleSave use `nics[i]` |
| `src/main_fltk.zig` | ✅ refreshDetails uses `nics[0].mode.label()` |

### 5.2 Web Frontend: index_html Details Panel Expansion ✅

| File | Status |
|------|--------|
| `src/web_server.zig:renderJson()` | ✅ Expanded to include net, fw, mac, nic2/3, shared_folder, usb, guest_tools, autoprotect, disk2, floppy, port_forwards, notes |
| `src/web_server.zig:renderDetails()` JS | ✅ Shows all fields conditionally |
| `src/web_server.zig:renderVmDetail()` | ✅ Synced with same fields |
| `src/web_server.zig:handleNewVm()` | ✅ Generates MAC for web-created VMs |
| `src/web_server.zig:handleClone()` | ✅ Generates unique MAC for web clones |

### 5.3 AGENTS.md Outdated — Describes IUP, Actual is FLTK ✅

| File | Status |
|------|--------|
| `AGENTS.md` | ✅ Rewritten: FLTK toolkit, cfltk bindings, flat globals, new modules (web_server, transport, hv, ovf, autoprotect, vmrun), FLTK callback conventions, absolute pixel layout, remote client/daemon mode, HV abstraction layer |

---

## Tier 6 — Parity Gaps (FLTK ↔ Web UI)

### 6.1 FLTK: Batch Start/Stop All ✅

| File | Status |
|------|--------|
| `src/main.zig` toolbar | ✅ "Start All" and "Stop All" buttons added (after Home) |
| `src/main.zig` | ✅ `startAllVms()`/`stopAllVms()` implemented with HV/remote dispatch |
| `src/web_server.zig` | ✅ batchStart()/batchStop() JS functions exist |

### 6.2 Web: Status Bar Count Paused/Suspended ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS renderList | ✅ Status bar counts paused and suspended in addition to running |

### 6.3 Web: Favorites Grouping with Separator ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS renderList | ✅ Favorites sorted first with "──────────" separator before non-favorites |
| `src/appstate.zig:refreshBrowser()` | ✅ FLTK groups favorites first with "──────────" separator |

### 6.4 Web: Power Button Showed Wrong Label for Paused VMs ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS updatePowerBtn | ✅ Fixed: paused VMs now show "⏹ Power Off" (not "▶ Resume") since isAlive() is true; separate Resume button handles unpause |
| `src/web_server.zig` JS batchStop | ✅ Fixed: also stops paused VMs (they are alive) |

### 6.5 FLTK: Missing Clone/Snapshot/Export Toolbar Buttons ⏭️

| File | Status |
|------|--------|
| `src/main.zig` toolbar | ⏭️ Clone, Snapshot, Export OVF only in menus; web toolbar has them (skipped — toolbar already at width limit) |

---

## Tier 7 — Menu & UX Parity

### 7.1 FLTK: Suspend Missing from VM Menu Bar and Context Menu ✅

| File | Status |
|------|--------|
| `src/main.zig` VM menu bar | ✅ Added "Suspend VM" after "Resume Guest" |
| `src/main.zig` context menu | ✅ Added "Suspend VM" after "Resume Guest" |
| `src/web_server.zig` | ✅ Suspend button present in web UI |

### 7.2 FLTK: Start All / Stop All Missing from Context Menu ✅

| File | Status |
|------|--------|
| `src/main.zig` context menu | ✅ Added "Start All VMs" and "Stop All VMs" after "Delete VM" |
| `src/main.zig` toolbar | ✅ Start All / Stop All buttons exist |
| `src/web_server.zig` | ✅ batchStart()/batchStop() in web UI |

### 7.3 Web: Status Bar Doesn't Show Selected VM Name ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS renderList | ✅ Status bar now shows "{name} — {status}    |    {counts}" when VM selected |
| `src/main.zig` | ✅ Status bar shows selected VM name, status, uptime, and count |

### 7.4 Web: Serial Console — Manual Disconnect Button ✅

| File | Status |
|------|--------|
| `src/web_server.zig` JS | ✅ Added manualDisconnectSerial() with flag to prevent auto-reconnect |
| `src/web_server.zig` HTML | ✅ Added "Disconnect" button inside serial panel |
| `src/main.zig` | ✅ Connect Serial button in toolbar |

---

## How to Track

Each item above follows the format:

```
### N.M Title
| File | Status |
|------|--------|
| `src/foo.zig` | ✅/❌/🔄 |
```

- **✅** = implemented and working
- **❌** = not implemented or not wired
- **🔄** = partially done or in-progress

When an item is completed, change ❌→✅ and optionally add a brief note about
what was done.

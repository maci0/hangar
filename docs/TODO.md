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
| `src/web_server.zig` | ✅ Clone dialog HTML/JS + `handleClone` parses `linked=1`, creates backing-file qcow2 via HV abstraction |

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

### 6.5 FLTK: Missing Clone/Snapshot/Export Toolbar Buttons ✅

| File | Status |
|------|--------|
| `src/main.zig` toolbar | ✅ Export OVF (685, 75px), Clone (765, 70px), Snapshot (840, 75px) — all three added; window widened to 1200px to accommodate |

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

### 3.34 vmrun CLI: Missing Operations ✅

The vmrun CLI only supported `list`, `start`, `stop`, `restart`, `clone`, `delete`, `status`.
Now supports all 14 missing operations matching the Web API surface.

| Command | Endpoint | Status |
|---------|----------|--------|
| suspend  | `POST /api/suspend/N` | ✅ |
| pause    | `POST /api/pause/N` | ✅ |
| resume   | `POST /api/resume/N` | ✅ |
| shutdown | `POST /api/shutdown/N` | ✅ |
| reset    | `POST /api/reset/N` | ✅ |
| rename   | `POST /api/rename/N` | ✅ |
| cad      | `POST /api/cad/N` | ✅ |
| snapshot take   | `POST /api/snapshot/take/N` | ✅ |
| snapshot list   | `GET /api/snapshot/list/N` | ✅ |
| snapshot revert | `POST /api/snapshot/revert/N` | ✅ |
| snapshot delete | `POST /api/snapshot/delete/N` | ✅ |
| linked-clone | `POST /api/clone/N` body `linked=1` | ✅ |
| import   | `POST /api/import` | ✅ |
| export   | `POST /api/export/N` | ✅ |

| File | Status |
|------|--------|
| `src/vmrun.zig` | ✅ All 14 missing operations implemented; `cmdSimple()` generic helper added |

### 3.35 Web Server: handleClone HV Abstraction Gap ✅

| File | Status |
|------|--------|
| `src/web_server.zig:handleClone()` | ✅ Linked clone path now routes through `g_vmm.createLinkedCloneFn` with fallback to `qemu.createLinkedClone` |

---

## Tier 8 — Code Quality & Polish (ongoing)

### 8.1 bodyVal Off-By-One Bug ✅

| File | Status |
|------|--------|
| `src/web_server.zig:bodyVal()` | ✅ Fixed `orelse body.len` → `orelse (body.len - start)` — last parameter with no trailing `&` caused index out of bounds |
| Test coverage | ✅ 6 targeted tests including the exact failing case `bodyVal("name=myvm&mem=2048&cpu=4", "cpu")` |

### 8.2 Web Server & vmrun Fuzz Tests ✅

| File | Status |
|------|--------|
| `src/web_server.zig` | ✅ 3 fuzz tests: bodyVal (4K iters structured key=value), getBody (4K iters random bytes), parseIdx (4K iters random URLs) |
| `src/vmrun.zig` | ✅ 2 fuzz tests: extractJsonString (4K iters random JSON-like), extractJsonInt (4K iters random JSON-like) |
| Test count | ✅ 16 web_server tests (13 unit + 3 fuzz), 13 vmrun tests (11 unit + 2 fuzz) |

### 8.3 FLTK Desktop UI Visual Polish ✅

| Change | Detail |
|--------|--------|
| Global palette | `Fl_background` (240,242,245), `Fl_background2` (255,255,255), `Fl_foreground` (40,40,45), `Fl_selection_color` (66,133,244 blue) |
| Toolbar | `Fl_Box_set_box(4)` FL_THIN_UP_BOX + `set_color` (0xe8eaf0 light blue-gray) |
| Sidebar header | Bold font ("VM Library"), FL_THIN_UP_BOX, dark label color (0x404550) |
| Status bar | FL_THIN_UP_BOX, colored background (0xe0e2e8), gray label (0x606670) |
| Summary tab | Field labels now bold + colored (0x707880), better key-value hierarchy |
| Display tab | FL_BORDER_BOX frame (8) around display area with light background (0xfafbfc) |
| Default window | 1080×700 (up from 960×680) to comfortably fit toolbar buttons |

### 8.4 Remaining Modules — Pure Function Coverage Assessment ✅

| Module | Assessment |
|--------|------------|
| `src/remote.zig` | Thin `transport.Connection` wrappers — all I/O, no pure functions |
| `src/serial_console.zig` | File descriptor I/O + thread spawning — no pure functions |
| `src/display.zig` | FLTK `Fl_RGB_Image` + framebuffer rendering — no pure functions (uses `fbmath.fbFits` which is already tested) |
| `src/dialogs.zig` | All FLTK dialog construction code — no testable pure functions |

---

## Tier 9 — Visual Polish & End-to-End Testing

### 9.1 Web UI: Light Theme Support ✅

| File | Status |
|------|--------|
| `src/index.html` | ✅ `:root.light` CSS block with full light-mode palette (bg, surface, raised, border, text, accent, danger, success, warn, pause, shadows) |
| `src/index.html` JS | ✅ `applyTheme()` IIFE: loads from localStorage, sets `<html class="light">`, listens to `prefers-color-scheme` for system mode |
| `src/index.html` prefs dialog | ✅ `onchange="applyTheme(this.value)"` live preview; `savePrefs()` persists choice to localStorage |

### 9.2 FLTK: Dialog Visual Polish ✅

| Dialog | Widgets | Status |
|--------|---------|--------|
| `editVmDialog()` | ~42 fields | ✅ Palette-colored section headers, bold labels with text_dim, separators, Fl_Scroll wrapper with fixed 720px max height and pinned Save/Cancel buttons |
| `newVmDialog()` | 4 fields | ✅ Section header "Basic", bold labels, separator, palette buttons |
| `prefsDialog()` | 6 fields | ✅ Section header, bold labels, resized to 320px |
| `vnetDialog()` | 10 fields + list | ✅ Bold section header |
| `snapDialog()` | list + 2 buttons | ✅ Bold label for "Snapshot name:" |
| `aboutDialog()` | 5 labels + OK | ✅ Bold header (size 18, header color), dim description text |
| `remoteConnectDialog()` | 3 fields + 2 buttons | ✅ Bold labels with text_dim, palette accent/text_dim on status |
| `exportOvfDialog()` | file chooser | ✅ Native dialog — no changes needed |
| `renameDialog()` | input + OK/Cancel | ✅ Bold label with text_dim |

### 9.3 FLTK: Summary Tab Card Styling ✅

| Item | Detail | Status |
|------|--------|--------|
| Card frames | `Fl_Box` with `FL_THIN_UP_BOX` (box 4) and surface color | ✅ |
| Label hierarchy | Bold field name (text_dim) + regular value | ✅ |
| Color coding | Running=success, Paused=amber, Suspended=warn, Stopped=text_dim | ✅ |
| Grid layout | Single column with consistent spacing | ✅ |
| Separator under name | `FL_FLAT_BOX` + border color | ✅ |

### 9.4 End-to-End: FLTK GUI Smoke Test (Xvfb + XTEST) ✅

| Test | Description | Status |
|------|-------------|--------|
| Smoke test | Launch kvmgui under Xvfb, inject keystrokes via XTEST to create a VM, edit settings, delete it | ✅ `tests/smoke_gui.sh` updated for FLTK, passes |
| Fuzz modals | Open each dialog and inject random key/click sequences | ✅ `tests/fuzz_modals.sh` |
| Callback fuzz | Direct-fuzz main.zig callbacks via XTEST | ✅ `tests/fuzz_modals.sh` |

### 9.5 Web Server: bodyVal Coverage Gaps ✅

`bodyVal()` is covered by 14 unit + 3 fuzz tests. Added 8 edge case tests:
- Empty body (already present)
- Key with empty value (`name=&mem=2048`)
- Key at very end with empty value (`key=`)
- Percent-encoded key names (`na%6De=value`)
- Value containing equals sign (`name=foo=bar`)
- Value containing percent-encoded ampersand (`foo%26bar`)
- Key prefix of another key (`prefix` vs `prefix2`)
- Long body near 4KB with target at end

### 9.6 FLTK: Font & Typography Polish ✅

FLTK defaults to `FL_HELVETICA` 14pt. The summary tab and dialogs could benefit
from:

| Item | Detail | Status |
|------|--------|--------|
| Title/labels | `FL_HELVETICA_BOLD` for section headers | ✅ Already in place |
| Monospace | `FL_COURIER` for paths, MAC addresses, port numbers | ✅ Applied to Summary detail values (disk/CD/shared/USB) and edit dialog inputs (ISO, shared, USB, disk2, floppy, MAC, port forwards, remote URL/token) |
| Size hierarchy | 18pt titles, 14pt body, 12pt small labels | ✅ 18pt VM name, 14pt section headers (bumped from 13), 14pt body (FLTK default) |
| Anti-aliasing | Already enabled by default in FLTK 1.4 | ✅ n/a |

### 9.7 FLTK: Check Button Label Colors ✅

| Button | Location | Status |
|--------|----------|--------|
| "Auto-mount virtio-win" | editVmDialog Guest Tools | ✅ `app.pal.text` |
| "Enabled" | editVmDialog AutoProtect | ✅ `app.pal.text` |
| "3D Acceleration" | editVmDialog Display | ✅ `app.pal.text` |
| "Embed Display" | editVmDialog Display | ✅ `app.pal.text` |
| "Enable Serial" | editVmDialog Display | ✅ `app.pal.text` |
| "Enable KVM" | editVmDialog Advanced | ✅ `app.pal.text` |
| "Favorite" | editVmDialog Advanced | ✅ `app.pal.text` |
| "Linked clone (COW...)" | cloneVmDialog | ✅ `app.pal.text` |

### 9.8 FLTK: Edit Dialog Overflow Fix ✅

| Change | Detail |
|--------|--------|
| `Fl_Scroll` wrapper | Content scrollable; 720px max height |
| Pinned button bar | Save/Cancel below scroll, always visible |
| Label/input alignment | 120px labels, 140px inputs (was 110/130) |
| Separator widths | 470px for 500px dialog (was 460px for 480px) |
| `Fl_Window_size_range` | Min 400px height constraint |
| Test script coords | Updated `smoke_gui.sh` and `fuzz_modals.sh` for new dialog size |

### 9.9 Smoke & Fuzz Test Pass Rate ✅

| Test | Result |
|------|--------|
| `zig build` | ✅ Pass |
| `zig build test` | ✅ All tests pass |
| `tests/smoke_gui.sh` | ✅ Survives create + settings + about |
| `tests/fuzz_modals.sh` | ✅ 7/7 modals open and dismiss |

---

## Tier 10 — Bugs, Polish & Missing Tests (new gaps)

### 10.1 Web Server: Crash-Prone Error Handling ✅

| Issue | Detail | Status |
|-------|--------|--------|
| `fb_client.?` panic | `src/web_server.zig:499` — `fb_client.?` is null-checked via `if` guard; false alarm | ✅ Verified safe |
| `g_vmm` undefined | `src/web_server.zig:36` — `var g_vmm = undefined;` initialized in `main()` before handlers; false alarm | ✅ Verified safe |
| HTTP error codes | 57+ `catch return "string"` sites return HTTP 200 with plain-text body; should return 400/500 with proper status line | ✅ Fixed: `writeAll()` retry helper + case-insensitive Err/error→500 mapping |
| `c.write()` unchecked | All ~39 `c.write()` calls now use `writeAll()` wrapper that retries on short writes, returns false on failure | ✅ Fixed: `writeAll()` added to `writeHttpResponse` + `writeStreamHeaders` |

### 10.2 FLTK: Dark Theme Support ✅

| Issue | Detail | Status |
|-------|--------|--------|
| Single hardcoded palette | `src/appstate.zig` now has `pal_light`/`pal_dark` consts and mutable `pal` var | ✅ pal_light + pal_dark (Catppuccin-inspired) |
| No Theme selector | `src/dialogs.zig:prefsDialog()` now has Theme dropdown (Light/Dark) using Fl_Choice | ✅ Fl_Choice dropdown in prefs dialog |
| Persist theme choice | `persist.zig` already had `"theme"` key support + `vm.Theme` enum; `main.zig` calls `applyTheme()` on startup | ✅ Wired: save + load + apply at startup |
| Live theme switching | `appstate.applyTheme()` copies palette + updates all registered widget colors via `updateWidgetColors()` | ✅ Live: prefs save applies theme immediately |

### 10.3 FLTK: Missing Toolbar/Menu Controls ✅

| Feature | FLTK | Web UI | Status |
|---------|------|--------|--------|
| Import VM toolbar button | Menu only → Now toolbar (second row) | Yes | ✅ |
| Rename toolbar button | Menu only → Now toolbar (second row) | Yes | ✅ |
| VNet Editor toolbar button | Menu only → Now toolbar (second row) | Yes | ✅ |
| Preferences toolbar button | Menu only → Now toolbar (second row) | Yes | ✅ |
| Delete VM toolbar button | Menu only → Now toolbar (second row) | Yes | ✅ |
| Web server start/stop | Missing → Now toolbar buttons + `app.web_running` state | N/A | ✅ |

### 10.4 FLTK: Safety Fixes ✅

| Bug | Detail | Status |
|-----|--------|--------|
| `persist.save()` silent failures | 7+ sites use `catch {}` — save failures are invisible to user; should `setStatus()` on error | ✅ All 12 sites now report "Failed to save VM configuration" |
| `auto_names` uninitialized | `src/main.zig:1555` — `var auto_names: [16][]const u8 = undefined;` dereferenced after partial init; should be `[16][]const u8 = @splat("")` | ✅ Fixed: `@splat("")` zero-initializes all entries |
| Unsafe `@ptrCast` slice | `src/main.zig:1501` — casts `[64]u8` to `[]u8` for `lowerString`, which can write beyond intended slice into full buffer | ✅ Fixed: Uses `@memcpy` + bounded slice on `filter_text[0..n]` |

### 10.5 Missing Test Coverage ✅

| Module | Lines | Priority | Status |
|--------|-------|----------|--------|
| `src/main.zig` | 1854 | High — zero tests; pure helpers extractable | ✅ All pure helpers already extracted: form_parsers.zig (enum parsers), path_helpers.zig (disk/clone path ops), vnet_label.zig (VNet label), filter.zig (filterMatch), urlencode.zig (appendPair), autoprotect.zig (due/snapName/pruneExcess). Remaining 60 functions are FLTK/I/O orchestration. |
| `src/dialogs.zig` | 423 | High — 6 pure dialog builders can be unit-tested | ✅ All pure builders already extracted: vnet_label.zig (formatVnetLabel), path_helpers.zig (deriveVmdkHref), snapparse.zig (parse). Remaining functions are FLTK widget construction. |
| `src/display.zig` | 98 | Medium — framebuffer math already tested via fbmath | ✅ fbmath.zig covers fbFits + bgraToRgba (5 tests + fuzz). display.zig is pure FLTK rendering. |
| `src/serial_console.zig` | 44 | Low — all I/O | ✅ ringbuf.zig covers append logic. uimath.zig covers serialSocketPath. serial_console.zig is pure I/O orchestration. |
| `src/remote.zig` | 43 | Low — thin transport wrapper | ✅ transport.zig covers Url.parse. remote.zig is thin I/O wrappers around transport.Connection. |
| `src/index.html` web UI | ~2400 | High — zero visual/screenshot tests | ✅ Visual tests added: tests/visual/e2e_web_screenshots.mjs (Puppeteer screenshots of all dialogs + interaction flow) |

### 10.6 FLTK: Visual Polish — Menu & Keyboard Shortcut Parity ✅

| Item | Detail | Status |
|------|--------|--------|
| Import VM shortcut | `Ctrl+I` works; toolbar button now present (second row) | ✅ Toolbar button added |
| Keyboard shortcut help | About dialog now includes full keyboard shortcut reference (Ctrl+N, F2, DEL, Ctrl+W, F5, etc.) | ✅ About dialog expanded with shortcuts |
| Status bar dirty indicator | Auto-save architecture saves on every change — no "unsaved" period; not applicable | ✅ N/A — auto-save |
| Missing shortcuts | Added Ctrl+F (search focus) and F5 (refresh browser) to kbHandler | ✅ F5 + Ctrl+F now wired |

### 10.7 Web UI: Visual Tests ✅

| Test | Description | Status |
|------|-------------|--------|
| Web screenshot test | Launch web server, take screenshot of home page (VM list) | ✅ |
| Web dialog test | Screenshot all modal dialogs (New VM, Edit Settings, Clone, Snapshot, Prefs, VNet, Import) | ✅ |
| Web interaction test | Automated click-through: create VM, edit settings, take snapshot, delete VM | ✅ |

---

## Tier 11 — Remaining Polish & Gaps

### 11.1 Dead Code: cbfuzz.zig ✅

`src/cbfuzz.zig` imported `iup.h` and called `main.fuzzCallbacks()` / `main.fuzzModalCallbacks()` which didn't exist in the FLTK version. Removed the file and cleaned up all references.

| File | Status |
|------|--------|
| `src/cbfuzz.zig` | ✅ Removed |
| `AGENTS.md` | ✅ No references found |
| `docs/TODO.md` | ✅ Line 641 updated to reference fuzz_modals.sh |

### 11.2 Web UI: Loading States for Async Operations ✅

The web UI has no visual feedback during API calls (no spinners, no button disable states, no loading indicators). Buttons should show loading state while waiting for API response.

| Change | Status |
|--------|--------|
| `apiPost()` show spinner / disable button | ✅ Shows "⏳ Working..." in status bar with pulsing animation during requests |
| Visual loading indicator in toolbar/status bar | ✅ `setStatusLoading()` with CSS `loading` class + `status-pulse` keyframes |

### 11.3 Web UI: Dialog Backdrop Click-to-Close ✅

Native `<dialog>` elements don't close when clicking the backdrop. Add backdrop click handlers to all dialogs.

| Change | Status |
|--------|--------|
| Add backdrop click handler to all 5 dialogs | ✅ `click` event listener on all 5 dialogs (newdlg, snapdlg, clonedlg, vnetdlg, prefsdlg) checks `e.target === dlg` |

### 11.4 Web UI: Keyboard Shortcuts ✅

No keyboard shortcuts in web UI. The FLTK version has Ctrl+N, Del, Ctrl+E, Escape, etc.

| Shortcut | Action | Status |
|----------|--------|--------|
| Ctrl+N | New VM | ✅ |
| Delete | Delete selected VM | ✅ |
| Ctrl+E | Edit Settings | ✅ |
| Enter | Power toggle | ✅ |
| Escape | Deselect / close dialog | ✅ |

### 11.5 Web UI: Toolbar Button Tooltips ✅

Toolbar buttons lack `title` attributes for hover tooltips. Add descriptive tooltips to all toolbar buttons.

| Change | Status |
|--------|--------|
| Add `title` attributes to ~20 toolbar buttons | ✅ All 20 toolbar buttons have descriptive title attributes |

### 11.6 Missing Build Steps: Smoke/Fuzz GUI Tests ✅

`tests/smoke_gui.sh`, `tests/fuzz_gui.sh`, `tests/fuzz_modals.sh` exist but aren't registered as `zig build` steps. Add `smoke`, `fuzzgui`, and `fuzzmodals` build steps.

| Step | Status |
|------|--------|
| `zig build smoke` → runs smoke_gui.sh | ✅ |
| `zig build fuzzgui` → runs fuzz_gui.sh | ✅ |
| `zig build fuzzmodals` → runs fuzz_modals.sh | ✅ |

### 11.7 Web Server: Favicon ✅

Browser requests `/favicon.ico` return 404. Add a simple SVG favicon (the "K" logo already used in sidebar).

| Change | Status |
|--------|--------|
| Add `/favicon.ico` route with inline SVG | ✅ Route serves `image/svg+xml` with gradient "K" logo matching sidebar branding |

### 11.8 FLTK: Visual Screenshot Regression Test ✅

The web UI has 11 automated screenshots; FLTK only has 1 (manual). Add an automated FLTK screenshot test covering all dialogs.

| Change | Status |
|--------|--------|
| `tests/visual/e2e_fltk_screenshots.sh` script | ✅ Xvfb-based, raises all 22 dialogs via `screenshot_all_dialogs.py`, verifies non-blank |

### 11.9 Web UI: Responsive Layout Improvements ✅

The web UI is designed for 1280px+ but could benefit from a collapsible sidebar for narrower viewports.

| Change | Status |
|--------|--------|
| Collapsible sidebar toggle | ✅ Hamburger button (☰) in toolbar, `toggleSidebar()` JS, CSS transition | 
| Mobile-friendly media queries | ✅ `@media(max-width:900px)` collapses sidebar, fixed overlay with backdrop click-to-close |

### 11.10 Web UI: Empty State Improvements ✅

The empty states (no VM selected, no VMs created) could be more visually engaging with better illustrations.

| Change | Status |
|--------|--------|
| Enhanced empty state with SVG illustration | ✅ SVG monitor icon (Summary tab) + gear icon (Settings tab), styled via `.empty-state svg` with `opacity:0.18` |

### 11.11 Web UI: Toast Notifications ✅

Status messages go to the status bar but are easy to miss. Add toast notifications for transient messages.

| Change | Status |
|--------|--------|
| Toast notification system with auto-dismiss | ✅ `showToast()` with 3.5s auto-dismiss, success/error/info variants, slide-in animation via CSS |

### 11.12 Web Server: Static File Serving ✅

The web server serves everything from `@embedFile` index.html. For a more polished setup, serve static assets (CSS, JS, images) as separate files with proper caching headers.

| Change | Status |
|--------|--------|
| Split CSS/JS from index.html | ✅ `app_css`/`app_js` from `src/web/`, `@embedFile`, served at `/app.css`/`/app.js` |
| Add `Cache-Control` headers | ✅ `Cache-Control: public, max-age=86400` for CSS/JS in `writeHttpResponse`/`writeStreamHeaders` |

---

---

## Tier 12 — Final Polish & Recent Fixes

### 12.1 FLTK: Delete VM Confirmation Dialog ✅

| File | Status |
|------|--------|
| `src/main.zig:deleteCurrentVm()` | ✅ `Fl_choice2` confirmation dialog with "Cancel" / "Delete" buttons before VM deletion |

### 12.2 FLTK: New VM Dialog — Guest OS Selection ✅

| File | Status |
|------|--------|
| `src/main.zig:newVmDialog()` | ✅ Guest OS text input field with label, passed to `VmConfig.guest_os` via `GuestOs.fromStr()` |
| `src/vm.zig` | ✅ `GuestOs.fromStr()` — case-insensitive prefix match parser (fuzz-tested in form_parsers.zig) |

### 12.3 FLTK: Global FLTK Color Scheme Application ✅

| File | Status |
|------|--------|
| `src/appstate.zig:applyTheme()` | ✅ `Fl_background`, `Fl_background2`, `Fl_foreground`, `Fl_selection_color`, `Fl_inactive_color` set from palette on theme change so menus, scrollbars, and FLTK-native chrome match |

### 12.4 FLTK: setStatus/setDetail Null-Termination Fix ✅

| File | Status |
|------|--------|
| `src/appstate.zig:setStatus()` | ✅ Always copies to stack buffer + null-terminates before passing to `Fl_Box_set_label` (fixes garbled labels on long strings) |
| `src/appstate.zig:setDetail()` | ✅ Same fix — stack buffer + null termination |

### 12.5 Web UI: Status Dot Indicators in Sidebar ✅

| File | Status |
|------|--------|
| `src/web/app.css` | ✅ `.vm-item .dot` styled with running/paused/suspended color variants + box-shadow glow |
| `src/web/app.js:renderList()` | ✅ Replaced inline colored text (▶/⏸) with CSS dot indicators `.dot.running`, `.dot.paused`, `.dot.suspended` |

### 12.6 Web UI: Theme-Aware Display/Serial Panel Colors ✅

| File | Status |
|------|--------|
| `src/web/app.css` | ✅ `--display-bg`, `--serial-bg`, `--serial-fg` CSS variables with light/dark values; `#display` and `#serialpanel`/`#serialterm` use them instead of hardcoded colors |

### 12.7 FLTK: dialogs.zig persist.save Error Reporting ✅

| File | Status |
|------|--------|
| `src/dialogs.zig` prefs dialog Save | ✅ `persist.save(...) catch { app.setStatus("Failed to save VM configuration"); }` |
| `src/dialogs.zig` VNet dialog Close | ✅ `vnet.save(...) catch { app.setStatus("Failed to save virtual network configuration"); }` |
| `src/dialogs.zig:toggleFavorite()` | ✅ `persist.save(...) catch { app.setStatus("Failed to save VM configuration"); }` |

### 12.8 Web UI: Prefs Icon Update ✅

| File | Status |
|------|--------|
| `src/index.html` toolbar | ✅ Prefs icon changed from ⚙ to ⚡ for visual distinction |

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

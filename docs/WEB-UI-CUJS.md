# Hangar Web UI CUJs

Critical user journeys for a VMware Workstation 17-style VM manager web UI.
These describe expected behavior, not only visual layout. Hangar can be
lighter than Workstation, but it should keep the same operational model:
library on the left, selected VM workspace on the right, safe power actions,
settings grouped by virtual hardware, and a display surface that feels like
the center of the product.

## Product Behavior Principles

- The VM Library is persistent navigation, not a content card. It should always
  show VM name, power state, and enough resource context to choose the right VM.
- Selecting a VM should feel immediate. Summary, display, settings, snapshots,
  and console state should all follow the selection.
- The primary action is contextual. Stopped VMs emphasize Power On; running VMs
  emphasize console/display, Shut Down Guest, Suspend, and Power Off.
- Dangerous actions are separated from routine actions. Reset, hard Power Off,
  Delete, and Revert to Snapshot require explicit confirmation and should not
  sit visually equal to Power On.
- Settings are organized by device/category, not by implementation field order.
  A user should understand CPU, memory, disk, display, network, firmware, and
  advanced devices without reading QEMU terms first.
- Display is a first-class workspace. When a VM is running and embedded display
  is available, the console should be visible, scaled predictably, and easy to
  enter full-screen/display-only mode.
- The UI should be honest about backend capability. WebGPU, WebGL, SPICE, VNC,
  virgl, KVM, and software fallback should be visible where they affect user
  expectations, but not as noisy global branding.
- The app should recover visibly from backend churn: daemon disconnects, failed
  QMP calls, dead QEMU processes, display reconnects, and stale serial sessions.

## CUJ-1: Launch And Orient

**User goal:** Open Hangar and understand what VMs exist and what to do next.

**Happy path**

1. App loads the VM Library from persisted config.
2. Sidebar shows search, grouped favorites, VM rows, status dots, and core
   resources.
3. Main workspace shows either a selected VM or an empty state.
4. Status row shows daemon state, VM count, and last operation result.
5. Any daemon/API failure is shown as a persistent connection banner with retry
   behavior.

**Acceptance criteria**

- Empty library offers clear primary actions: New VM, Import VM, Catalog.
- Existing library does not auto-select a VM unless the user had a remembered
  last selection.
- VM rows expose status text to assistive tech and visually distinguish running,
  stopped, paused, and suspended states.
- Search filters immediately and preserves selection when possible.
- The UI remains useful at laptop, desktop, and narrow mobile widths.

## CUJ-2: Select A VM And Read Its State

**User goal:** Click a VM and quickly know what it is, whether it is running,
and what the next safe action is.

**Happy path**

1. User selects a VM in the library.
2. Header shows VM name and power state.
3. Summary shows guest OS, CPU, memory, disk, display/video, network, snapshots,
   notes, and warnings.
4. Primary command updates to the most likely action.
5. Secondary commands are available through toolbar, context menu, or VM menu.

**Acceptance criteria**

- Summary prioritizes state, guest OS, CPU, memory, disk, network, and display.
- Running VMs show a visible display/console area before dense metadata when
  embedded display is enabled.
- Stopped VMs show configuration and boot media readiness.
- Invalid or missing resources are highlighted inline, for example missing disk
  image, ISO path not found, port conflict, or unavailable accelerator.
- Selection does not discard dirty settings without confirmation.

## CUJ-3: Create A New VM

**User goal:** Create a usable VM with enough guidance to avoid broken QEMU
configuration.

**Happy path**

1. User clicks New VM.
2. Wizard asks for install source or catalog template.
3. Wizard captures name, guest OS, CPU, memory, disk, display, firmware, boot
   order, and network.
4. Advanced hardware is hidden until requested.
5. Finish creates disk/config, selects the new VM, and shows next action.

**Acceptance criteria**

- Required fields validate before submit and show field-level errors.
- Defaults are derived from preferences and guest OS choice.
- Display defaults are coherent: embedded display uses VNC or SPICE; virgl 3D
  requires a compatible display path.
- Disk creation failure leaves the wizard open and reports the failing command.
- New VM appears selected in the library after successful creation.

## CUJ-4: Edit VM Settings

**User goal:** Reconfigure a VM without accidentally changing unrelated virtual
hardware.

**Happy path**

1. User opens Settings for a selected VM.
2. Settings show a left category/device list and a focused detail pane.
3. Common devices are easy to find: CPU, Memory, Hard Disk, CD/DVD, Display,
   Network Adapter, Firmware, Boot, Shared Folders, USB, Serial.
4. Dirty changes are tracked.
5. Save persists the VM and returns to Summary; Cancel discards changes.

**Acceptance criteria**

- Settings are disabled or guarded when a running VM cannot safely accept the
  change.
- Display and GPU controls explain compatibility through validation, not prose.
- Ports validate range and conflicts before save.
- MAC addresses validate format and offer regeneration.
- Advanced QEMU fields are available but visually secondary.

## CUJ-5: Power Lifecycle

**User goal:** Start, stop, suspend, resume, and reset VMs with clear safety
semantics.

**Happy path**

1. Stopped VM exposes Power On as primary.
2. Running VM exposes Shut Down Guest, Suspend, and Power Off with different
   language and confirmations.
3. Paused VM exposes Resume.
4. UI enters a transitional state while QEMU/QMP work is in flight.
5. State refreshes from process/QMP truth, not only from optimistic UI state.

**Acceptance criteria**

- Power On is disabled when required config is missing.
- Shut Down Guest is visually safer than hard Power Off.
- Reset and hard Power Off require strong confirmation.
- Operation failures include enough detail to act on, for example QMP connect
  failure, QEMU spawn failure, or display port conflict.
- Batch actions summarize successes and failures per VM.

## CUJ-6: Use The Guest Display

**User goal:** Interact with a running guest in the browser as if it were a VM
console.

**Happy path**

1. User powers on or selects a running VM.
2. Embedded VNC/SPICE display connects automatically.
3. Console scales to fit, preserves aspect ratio, and accepts pointer/keyboard
   input.
4. Renderer badge reports protocol and browser renderer: WebGPU, WebGL2,
   WebGL, or Canvas.
5. User can enter display-only/fullscreen and send common key sequences.

**Acceptance criteria**

- WebGPU/WebGL presentation never blocks input to the underlying VNC/SPICE
  client.
- Canvas fallback works when GPU APIs are unavailable.
- Reconnect behavior is visible and does not duplicate canvases or WebSockets.
- Display-only mode hides chrome and exits with F11 or Esc.
- Running VMs with native GTK/SDL display explain why no embedded browser
  console is visible.

## CUJ-7: Work With Snapshots

**User goal:** Take, inspect, revert, and delete snapshots without losing track
of VM state.

**Happy path**

1. User opens Snapshots from selected VM.
2. Snapshot manager shows current snapshot list, timestamps if available, and
   whether the VM must be powered off for an operation.
3. User takes a named snapshot.
4. User can revert/delete with confirmation.
5. Summary/status reflect the result.

**Acceptance criteria**

- Empty snapshot list explains that there are no snapshots.
- Revert warning states that current guest state may be discarded.
- Snapshot names validate before submit.
- Running-state restrictions are explicit before the backend returns an error.

## CUJ-8: Manage Storage, ISO, Import, Export, And Clone

**User goal:** Move VM data in and out while understanding what will be copied
or linked.

**Happy path**

1. User imports an existing disk or creates a VM from catalog.
2. User attaches/removes ISO media from Settings.
3. User clones a VM as full clone or linked clone.
4. User exports OVF/OVA.
5. Long operations show progress or at least an active status.

**Acceptance criteria**

- Clone dialog explains full vs linked clone storage implications.
- Import validates disk extension and path.
- Upload/download operations show transfer state.
- Export has a success/failure result and downloaded filename matches VM name.

## CUJ-9: Configure Networking

**User goal:** Choose simple networking quickly, and advanced networking when
needed.

**Happy path**

1. User chooses NAT/user, bridged, none, or VMnet in Settings.
2. User can open Virtual Network Editor for VMnet configuration.
3. Port forwarding validates host and guest ports.
4. MAC addresses are generated and validated.

**Acceptance criteria**

- Network labels use VM-manager language first and QEMU terms second.
- VMnet editor separates NAT, host-only, bridged, subnet, DHCP, and forwarding.
- Invalid subnet/mask/range is caught before save.
- VM summary shows enough network detail to debug connectivity.

## CUJ-10: Serial Console And Recovery

**User goal:** Use the serial console for installs, debugging, and headless
guests.

**Happy path**

1. Running VM with serial enabled auto-connects serial console.
2. User can clear, disconnect, and reconnect.
3. Console preserves recent output and sanitizes terminal control sequences.
4. Serial disconnects/reconnects are visible but not noisy.

**Acceptance criteria**

- Serial panel does not steal primary display space unless connected.
- Manual disconnect is respected.
- Output is readable in dark and light themes.
- Reconnect loops back off on repeated failure.

## CUJ-11: Preferences And App State

**User goal:** Set defaults once and trust future workflows to use them.

**Happy path**

1. User opens Preferences.
2. User changes theme, default CPU/memory, AutoProtect defaults, and remote/API
   behavior where supported.
3. Save applies immediately where safe and persists.

**Acceptance criteria**

- Theme preview is immediate and reversible until Save/Cancel.
- Defaults affect new VMs, not existing VMs unexpectedly.
- Preferences errors do not corrupt VM config.

## CUJ-12: Keyboard, Context Menu, And Accessibility

**User goal:** Operate efficiently without hunting through the UI.

**Happy path**

1. Keyboard shortcuts cover selection, new VM, settings, power, delete, search,
   refresh, fullscreen, and help.
2. Right-clicking a VM opens a context menu scoped to that VM.
3. Focus order follows sidebar, toolbar, workspace, dialogs.
4. Dialogs trap focus and restore it on close.

**Acceptance criteria**

- Visible labels and accessible names match VMware-style terminology.
- Disabled actions communicate why they are unavailable.
- Shortcut help is discoverable but not shown repeatedly after first launch.
- Keyboard operation covers all critical actions.

## Current Hangar Web UI Review

### What Already Fits

- The app has the right macro-layout: VM Library sidebar, command toolbar,
  selected VM workspace, summary/settings tabs, status row.
- Current terminology is close to Workstation: VM Library, Power On, Suspend,
  Resume, Shut Down Guest, Settings, Take Snapshot, Revert to Snapshot.
- VM selection is fast and updates Summary/Settings without navigating away.
- The display implementation now has WebGPU to WebGL to Canvas fallback while
  preserving the underlying VNC/SPICE canvas for input.
- The summary includes Video details, which is important for virgl/SPICE/VNC
  troubleshooting.
- Mobile layout is usable: sidebar collapses, toolbar keeps key actions, and
  content no longer scrolls under the status row.
- The browser smoke test covers basic launch, create, dialogs, settings,
  snapshots, theme, clone, favorite, search, delete, and server health.

### Gaps To Address

1. **Toolbar hierarchy is too flat.**
   Routine, advanced, batch, and dangerous actions all compete in the same
   toolbar. Workstation-style behavior should make Power On contextual and move
   Reset, hard Power Off, Delete, batch actions, migration, import/export, and
   lower-frequency tools behind grouped menus or a context menu.

2. **Empty state needs action affordances.**
   The empty Summary state explains selection, but it should also offer primary
   actions: New VM, Import VM, and Catalog. This is the first-run path.

3. **Settings are too field-list oriented.**
   The current Settings tab exposes many fields in one long responsive grid.
   That is powerful, but not Workstation-like. A device/category list with a
   focused detail pane would make CPU, Memory, Disk, Display, Network, Firmware,
   and Advanced hardware easier to reason about.

4. **Power-state action availability should be stricter.**
   Commands should disable or demote when irrelevant. For example, Resume should
   be prominent only for paused VMs; Shut Down Guest should be unavailable for
   stopped VMs; Reset should be guarded as destructive.

5. **Running VM workspace should prioritize console.**
   If a running VM has embedded display enabled, the display should appear as
   the main workspace surface, with Summary still available but secondary. This
   is closer to Workstation, where the selected running VM is primarily its
   console.

6. **Snapshot manager is functionally present but visually under-modeled.**
   The current snapshot dialog lists names and buttons. It should show state,
   timestamps when available, disabled/reasoned actions, and a clearer revert
   warning.

7. **Validation should move closer to fields.**
   Several flows rely on toast/status/backend errors. Workstation-like behavior
   should show inline validation for ports, display/GPU compatibility, MAC
   format, disk paths, ISO paths, and running-VM restrictions.

8. **Menus/context menu should carry advanced actions.**
   The web UI has toolbar and shortcuts, but a VM manager benefits from a
   selected-VM context menu matching the toolbar/VM menu: Power, Removable
   Devices, Snapshot, Clone, Settings, Delete.

9. **Display controls are still minimal.**
   The renderer badge is good, but the console should also expose fit/actual
   size, display-only, reconnect, send Ctrl+Alt+Del, and keyboard capture
   status near the display surface.

10. **Network UX needs VMnet mental model.**
    The VNet editor exists, but Settings/Summary should present NAT, Bridged,
    Host-only/VMnet in Workstation terms first, with QEMU/user-mode terms as
    secondary detail.

### Recommended Next UI Work

1. Rework toolbar into a contextual primary action plus grouped menus:
   Power, Snapshot, Removable/Devices, Tools, More.
2. Replace the flat Settings grid with a two-pane settings layout:
   hardware/device list on the left, detail form on the right.
3. Add first-run empty-state actions for New VM, Import VM, and Catalog.
4. Promote display/console as the default selected view for running embedded
   VMs, with Summary and Settings as tabs beside it.
5. Add inline validation and disabled-action reasons for power, display/GPU,
   ports, MAC, disk, and snapshot operations.


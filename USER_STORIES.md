# Hangar User Stories

> **Historical / archived.** This document dates from the FLTK desktop-GUI era
> (menu bar, toolbar, 800x500 main window, "Export VM as Script" — all removed).
> The current frontends are `hangar-web` (web UI + remote daemon, see
> `docs/DESIGN.md` for the HTTP API and keyboard shortcuts), the `vmrun` CLI,
> and the `hangar-webui` WebView wrapper. Entries below describe removed UI and
> are kept only for history; feature status lives in `docs/GAP-ANALYSIS.md`.

Comprehensive user journey map covering every interaction path in the application.

---

## 1. Application Launch & Main Window

### US-1.1: First Launch (Empty Library)
**As a** new user,
**I want to** see an empty VM Library with a clear "No virtual machine selected" message,
**so that** I know the application is ready and I can start creating VMs.

**Acceptance Criteria:**
- Main window opens at 800x500 centered on screen
- Left panel shows "Library" header with empty list
- Right panel shows "No virtual machine selected." in bold
- All summary labels (State, Guest OS, Hardware) are blank
- Menu bar shows File and VM menus
- Toolbar shows New VM, Power On, Suspend, Power Off, Settings buttons

### US-1.2: Launch with Existing VMs
**As a** returning user,
**I want to** see my previously created VMs loaded from `~/.config/hangar/vms.json`,
**so that** I can continue managing my virtual machines.

**Acceptance Criteria:**
- VMs are loaded from persistent storage on startup
- VM Library list is populated with VM names
- Running VMs show a ">" prefix indicator
- Stopped VMs show a space prefix
- No VM is selected by default

### US-1.3: Select a VM from Library
**As a** user,
**I want to** click on a VM name in the Library list,
**so that** I can see its details in the Summary panel.

**Acceptance Criteria:**
- Clicking a VM highlights it in the list
- Summary panel updates with: VM name (bold, large), State, Guest OS, Processors, Memory, Hard Disk size, CD/DVD status, Network Adapter
- "Commands" section shows "Power on/off this virtual machine" link
- "Edit virtual machine settings" link is visible

### US-1.4: Background Status Polling
**As a** user,
**I want** the application to automatically detect when a VM process exits,
**so that** the UI reflects the true state without manual refresh.

**Acceptance Criteria:**
- A 2-second timer polls all running/paused VMs via `waitpid`
- When a QEMU process exits, VM status updates to "Powered Off"
- VM Library list refreshes (removes ">" prefix)
- Summary panel updates if the exited VM was selected
- Serial console polling occurs on each tick
- Display auto-connect is attempted for running VMs with embed_display enabled

---

## 2. Creating a New Virtual Machine

### US-2.1: Open New VM Wizard
**As a** user,
**I want to** open the New Virtual Machine wizard from the File menu or toolbar,
**so that** I can create a new VM.

**Acceptance Criteria:**
- File > "New Virtual Machine..." menu item opens the wizard
- "New VM" toolbar button opens the wizard
- Only one wizard instance can be open at a time (guard against double-open)
- Wizard opens centered relative to the parent window

### US-2.2: General Tab - Name & OS
**As a** user,
**I want to** set the VM name, guest OS type, and notes,
**so that** the VM is identifiable and categorized.

**Acceptance Criteria:**
- "VM Name" text field defaults to "New VM"
- "Guest OS" dropdown lists: Linux, Microsoft Windows, FreeBSD, Apple macOS, Other
- "Notes" multiline text area for free-form notes
- Tab is labeled "General"

### US-2.3: Hardware Tab - CPU, Memory, Disk, Display, Audio
**As a** user,
**I want to** configure the virtual hardware for my VM,
**so that** it has appropriate resources for the guest OS.

**Acceptance Criteria:**
- "CPUs" numeric field defaults to 2 (unsigned integer mask)
- "Mem (MB)" numeric field defaults to 2048
- "Disk (GB)" numeric field defaults to 20
- "Disk Fmt" dropdown: QCOW2, Raw, VMDK, VDI (defaults to QCOW2)
- "CD/DVD" text field with "Browse..." button that opens a file dialog (ISO filter)
- "Display" dropdown: GTK, SDL, SPICE, VNC, None (headless)
- "Resolution" dropdown: Auto, 800x600, 1024x768, 1280x800, 1920x1080
- "Audio" dropdown: None, Intel HDA, AC97
- Tab is labeled "Hardware"

### US-2.4: Options Tab - Network, Firmware, Boot
**As a** user,
**I want to** configure network, firmware, and boot settings,
**so that** the VM connects correctly and boots from the right device.

**Acceptance Criteria:**
- "Network" dropdown: NAT (User mode), Bridged, None
- "MAC" text field with auto-generated random MAC address and "Generate" button
- "Port Fwd" text field for host:guest port mappings (e.g., "8080:80,2222:22")
- "Firmware" dropdown: BIOS (SeaBIOS), UEFI (OVMF)
- "Boot" dropdown: Hard Disk, CD/DVD, Network (PXE)
- "Virtualize CPU (KVM)" checkbox (default: ON)
- "Embed display (Forces VNC/SPICE)" checkbox (default: ON)
- "Enable Serial Port" checkbox (default: ON)
- Tab is labeled "Options"

### US-2.5: Browse for ISO Image
**As a** user,
**I want to** browse the filesystem for an ISO image,
**so that** I can attach installation media to the VM.

**Acceptance Criteria:**
- "Browse..." button opens a native file dialog
- Filter shows "ISO Files (*.iso)" and "All Files (*.*)"
- Selected file path populates the CD/DVD text field
- Canceling the dialog leaves the field unchanged

### US-2.6: Generate Random MAC Address
**As a** user,
**I want to** generate a random MAC address with one click,
**so that** each VM has a unique network identity.

**Acceptance Criteria:**
- "Generate" button populates the MAC field with a new random address
- MAC format: `XX:XX:XX:XX:XX:XX` with locally-administered bit set
- New address generated on each click

### US-2.7: Finish Creating VM
**As a** user,
**I want to** click "Finish" to create the VM and its disk image,
**so that** the VM is ready to power on.

**Acceptance Criteria:**
- VM name cannot be empty (error dialog shown if blank)
- Disk image is created at `~/VMs/<name>.<format>` via `qemu-img create`
- If disk creation fails, an error dialog is shown and wizard stays open
- If max VM capacity (64) is reached, an error dialog is shown
- On success: VM is added to the library, config is saved to disk, wizard closes
- If "Embed display" is checked and display is not SPICE, display is forced to VNC
- New VM is automatically selected in the library

### US-2.8: Cancel New VM Wizard
**As a** user,
**I want to** click "Cancel" to close the wizard without creating a VM,
**so that** I can abort the creation process.

**Acceptance Criteria:**
- Wizard window is hidden and destroyed
- No VM is created, no disk image is created
- Library state is unchanged

---

## 3. Editing VM Settings

### US-3.1: Open Settings Dialog
**As a** user,
**I want to** edit an existing VM's configuration,
**so that** I can adjust resources or change settings.

**Acceptance Criteria:**
- VM > "Settings..." menu item opens the dialog for the selected VM
- "Settings" toolbar button opens the dialog
- Only one edit dialog can be open at a time
- All fields are pre-populated with the VM's current configuration
- VM name field is read-only (cannot be changed after creation)

### US-3.2: Edit General Settings
**As a** user,
**I want to** change the guest OS type and notes for an existing VM,
**so that** the VM metadata stays accurate.

**Acceptance Criteria:**
- Guest OS dropdown shows current value selected
- Notes field shows existing notes
- Changes are saved when "Save" is clicked

### US-3.3: Edit Hardware Settings
**As a** user,
**I want to** adjust CPU cores, memory, display type, resolution, and audio,
**so that** I can tune performance.

**Acceptance Criteria:**
- CPU and Memory fields are editable with current values
- Disk size is read-only (cannot resize existing disk)
- Disk format is read-only (shows current format, single entry)
- CD/DVD ISO path can be changed (typed manually; no browse button in edit dialog)
- Display, Resolution, and Audio dropdowns show current values

### US-3.4: Edit Options
**As a** user,
**I want to** change network mode, MAC address, port forwarding, firmware, boot order, and feature toggles,
**so that** I can reconfigure connectivity and boot behavior.

**Acceptance Criteria:**
- All dropdowns pre-selected to current values
- MAC address shows current value (no "Generate" button in edit dialog)
- Port forwarding shows current mappings
- KVM, Embed Display, Serial Port toggles reflect current state
- If "Embed display" is enabled and display is not SPICE, display is forced to VNC on save

### US-3.5: Save Settings
**As a** user,
**I want to** click "Save" to apply my changes,
**so that** the VM configuration is updated.

**Acceptance Criteria:**
- All field values are written back to the VmConfig
- VM Library and Summary panel refresh
- Configuration is persisted to `~/.config/hangar/vms.json`
- Dialog closes

### US-3.6: Cancel Edit
**As a** user,
**I want to** click "Cancel" to discard my changes,
**so that** the original configuration is preserved.

**Acceptance Criteria:**
- Dialog closes without modifying the VM configuration
- No persistence write occurs

---

## 4. VM Power Management

### US-4.1: Power On a VM
**As a** user,
**I want to** start a stopped VM,
**so that** the guest OS boots and becomes usable.

**Acceptance Criteria:**
- VM > "Power On" menu item starts the selected VM
- "Power On" toolbar button starts the selected VM
- Summary panel "Power on this virtual machine" link starts the VM
- QEMU process is spawned with configured arguments
- VM status changes to "Powered On" (running)
- PID is stored for lifecycle tracking
- VM Library updates with ">" prefix
- If VM has a saved state file, QEMU starts with `-incoming` to restore state
- KVM acceleration uses host CPU if enabled; TCG fallback otherwise
- Serial console socket and QMP socket are created

### US-4.2: Power Off a VM (Force Stop)
**As a** user,
**I want to** immediately stop a running VM,
**so that** the QEMU process is terminated.

**Acceptance Criteria:**
- VM > "Power Off" menu item sends SIGKILL to the QEMU process
- "Power Off" toolbar button does the same
- Summary panel link toggles to "Power off this virtual machine" when VM is running
- VM status changes to "Powered Off" (stopped)
- VM Library removes ">" prefix
- Warning: This is an ungraceful shutdown (data loss possible)

### US-4.3: Power Toggle via Summary Link
**As a** user,
**I want to** click the power link in the Summary panel,
**so that** I can quickly toggle the VM's power state.

**Acceptance Criteria:**
- When VM is stopped: link reads "Power on this virtual machine" and starts the VM
- When VM is running: link reads "Power off this virtual machine" and force-stops the VM
- Library and summary refresh after action

---

## 5. Snapshot Management

### US-5.1: Open Snapshot Manager
**As a** user,
**I want to** open the Snapshot Manager for a running VM,
**so that** I can manage internal QCOW2 snapshots.

**Acceptance Criteria:**
- VM > "Snapshot Manager..." menu item opens the dialog
- VM must be powered on (error dialog if not)
- Only one snapshot manager can be open at a time
- QMP connection is established automatically
- Current snapshot list is loaded and displayed in a read-only multiline text area (Courier font)

### US-5.2: Take a Snapshot
**As a** user,
**I want to** create a named snapshot of the running VM,
**so that** I can restore to this point later.

**Acceptance Criteria:**
- Enter a name in the "Snapshot name" text field
- Click "Take Snapshot" button
- QMP `savevm` command is executed via HMP tunneling
- Snapshot list refreshes to show the new snapshot
- Error dialog shown if snapshot creation fails
- Empty or whitespace-only names are silently ignored (no action)

### US-5.3: Restore a Snapshot
**As a** user,
**I want to** restore a snapshot by name,
**so that** the VM returns to a previous state.

**Acceptance Criteria:**
- Enter the snapshot name in the text field
- Click "Restore" button
- QMP `loadvm` command is executed
- VM state is restored to the snapshot point
- Error dialog shown if restoration fails

### US-5.4: Delete a Snapshot
**As a** user,
**I want to** delete a snapshot by name,
**so that** I can free disk space.

**Acceptance Criteria:**
- Enter the snapshot name in the text field
- Click "Delete" button
- QMP `delvm` command is executed
- Snapshot list refreshes to show the snapshot removed
- Error dialog shown if deletion fails

### US-5.5: Close Snapshot Manager
**As a** user,
**I want to** close the Snapshot Manager dialog,
**so that** I can return to the main window.

**Acceptance Criteria:**
- "Close" button hides and destroys the dialog
- Dialog state is reset for next opening

---

## 6. Export VM as Script

### US-6.1: Export QEMU Launch Script
**As a** user,
**I want to** export the selected VM's QEMU command line as a bash script,
**so that** I can run it independently or share it.

**Acceptance Criteria:**
- A "Save As" file dialog opens with default name `run_<vmname>.sh`
- Filter: "Bash Scripts (*.sh)" and "All Files (*.*)"
- Generated script includes `#!/bin/bash` header, VM name comment, and full QEMU command
- Arguments containing spaces are quoted
- Multi-line format with backslash continuation for readability
- Error dialogs shown for: script generation failure, file creation failure, write failure

---

## 7. Embedded Display

### US-7.1: VNC Auto-Connect
**As a** user,
**I want to** see the VM's display embedded in the application when using VNC mode,
**so that** I don't need a separate VNC client.

**Acceptance Criteria:**
- When a VM is running with `embed_display=true` and `display=vnc`
- A background display timer auto-connects to `127.0.0.1:<vnc_port>`
- The "Display" tab shows the live framebuffer
- Connection is retried on each timer tick until successful
- VNC display number = port - 5900 (saturated to 0 if port < 5900)

### US-7.2: SPICE Auto-Connect
**As a** user,
**I want to** see the VM's display embedded via SPICE protocol,
**so that** I get a higher-quality display experience.

**Acceptance Criteria:**
- When `embed_display=true` and `display=spice`
- Auto-connects to `127.0.0.1:<spice_port>`
- SPICE ticketing is disabled for local connections
- The "Display" tab shows the live framebuffer

### US-7.3: Display Rendering
**As a** user,
**I want to** see the VM's screen rendered correctly with proper scaling,
**so that** the display is usable within the application window.

**Acceptance Criteria:**
- Cairo renders the framebuffer to the display area
- Mouse coordinates are mapped from widget space to framebuffer space with clamping
- Division-by-zero is prevented when framebuffer dimensions are 0
- Dirty regions are polled and redrawn on timer ticks

### US-7.4: Mouse & Keyboard Input
**As a** user,
**I want to** interact with the VM using mouse and keyboard through the embedded display,
**so that** I can control the guest OS.

**Acceptance Criteria:**
- Mouse movements are translated to VNC/SPICE pointer events
- Mouse clicks are forwarded as button press/release events
- Keyboard events are forwarded as key press/release events
- USB tablet device ensures absolute mouse positioning works correctly

---

## 8. Serial Console

### US-8.1: View Serial Console Output
**As a** user,
**I want to** see serial console output from the VM in the "Console" tab,
**so that** I can monitor boot messages and interact with text-mode applications.

**Acceptance Criteria:**
- "Console" tab shows a multiline text widget
- Serial data is read from a Unix socket (`/tmp/hangar-serial-<name>.sock`)
- Non-ASCII ANSI escape codes are filtered to prevent UI freezing
- Data is appended incrementally (not full refresh)
- Connection is auto-attempted when VM is running, serial is enabled, and not yet connected

### US-8.2: Auto-Connect Serial Console
**As a** user,
**I want** the serial console to connect automatically when the VM is running,
**so that** I don't have to manually initiate the connection.

**Acceptance Criteria:**
- Background timer checks: VM alive + serial enabled + not connected
- Connection is attempted on each tick until successful
- Thread-safe atomic flags (`running`, `connected`) prevent data races
- Polling updates the console widget with new data

---

## 9. Configuration Persistence

### US-9.1: Auto-Save on Changes
**As a** user,
**I want** my VM configurations to be automatically saved,
**so that** changes survive application restarts.

**Acceptance Criteria:**
- Configurations saved to `~/.config/hangar/vms.json`
- Save occurs after: creating a new VM, editing settings, or any `appRefreshAll()` call
- Save failures are silently ignored (non-critical)
- Runtime state (status, PID) is never persisted

### US-9.2: Auto-Load on Startup
**As a** user,
**I want** my VM configurations to be loaded automatically on startup,
**so that** I see my VMs immediately.

**Acceptance Criteria:**
- Configurations loaded from `~/.config/hangar/vms.json`
- Enum fields are stored as QEMU CLI strings (e.g., "qcow2", "user", "gtk")
- Unknown enum values default to safe fallbacks
- Hand-rolled JSON parser (no `std.json` due to f128 linker issues)
- VM count is set to 0 during load, then updated after the table widget exists

---

## 10. QEMU Process Lifecycle

### US-10.1: QEMU Argument Generation
**As a** user,
**I want** the application to generate correct QEMU command-line arguments,
**so that** VMs start with the right configuration.

**Acceptance Criteria:**
- Machine type: `q35` with KVM or TCG acceleration
- CPU: `host` (KVM) or `qemu64` (TCG)
- Zero CPU cores clamped to 1; zero memory clamped to 64 MB
- Disk: `virtio` interface with correct format
- CD-ROM: explicit `ide-cd` backend (supports QMP hot-swap)
- Boot order: configurable priority (disk/cdrom/network)
- Display: embedded (none + VNC/SPICE) or standalone (GTK/SDL/none)
- Resolution: `virtio-vga` with optional `xres`/`yres` parameters
- Serial: Unix socket server (non-blocking)
- QMP: Unix socket server for machine control
- Network: user mode with optional MAC and port forwarding, or bridge mode, or none
- Firmware: SeaBIOS default or OVMF (auto-searched from known paths)
- Audio: Intel HDA or AC97 with SDL backend, or none
- USB: XHCI controller + USB tablet (for absolute mouse positioning)
- Saved state: `-incoming exec:cat <file>` for suspend-resume

### US-10.2: Disk Image Creation
**As a** user,
**I want** disk images to be created automatically when I create a new VM,
**so that** the VM has storage ready.

**Acceptance Criteria:**
- `qemu-img create -f <format> <path> <size>G` is executed
- Supported formats: qcow2, raw, vmdk, vdi
- Path: `~/VMs/<vmname>.<format>`
- Non-zero exit status from `qemu-img` results in an error

### US-10.3: Suspend to Disk
**As a** user,
**I want to** suspend a VM's state to a file,
**so that** I can resume it later without re-booting.

**Acceptance Criteria:**
- QMP `migrate` command saves RAM and device state to a `.state` file
- On next power-on, QEMU uses `-incoming` to restore from the state file
- State file is automatically cleaned up after successful restore

### US-10.4: UEFI Firmware Support
**As a** user,
**I want to** boot VMs with UEFI firmware,
**so that** I can run modern operating systems that require UEFI.

**Acceptance Criteria:**
- OVMF firmware is auto-detected from known system paths
- Searched paths (in order): `/usr/share/edk2/x64/OVMF.fd`, `/usr/share/OVMF/OVMF_CODE.fd`, `/usr/share/edk2-ovmf/x64/OVMF.4m.fd`, `/usr/share/qemu/OVMF.fd`
- Error if UEFI is selected but no OVMF image is found

---

## 11. QMP VM Control

### US-11.1: Pause a Running VM
**As a** user,
**I want to** pause a running VM via QMP,
**so that** the guest is frozen in place.

**Acceptance Criteria:**
- QMP `stop` command is sent
- VM status changes to "Paused"

### US-11.2: Resume a Paused VM
**As a** user,
**I want to** resume a paused VM,
**so that** the guest continues execution.

**Acceptance Criteria:**
- QMP `cont` command is sent
- VM status changes to "Powered On"

### US-11.3: Graceful Shutdown (ACPI Power Button)
**As a** user,
**I want to** send an ACPI power button event,
**so that** the guest OS can shut down gracefully.

**Acceptance Criteria:**
- QMP `system_powerdown` command is sent
- Guest OS receives ACPI event and initiates shutdown
- VM process exits when guest completes shutdown

### US-11.4: Hard Reset
**As a** user,
**I want to** hard-reset a running VM,
**so that** the guest reboots immediately.

**Acceptance Criteria:**
- QMP `system_reset` command is sent
- Guest OS reboots as if power-cycled

### US-11.5: Query VM Status
**As a** user,
**I want to** query the VM's current execution status,
**so that** the UI can show "running", "paused", etc.

**Acceptance Criteria:**
- QMP `query-status` command returns the current state
- JSON response is parsed for the `status` field

---

## 12. Menu Structure

### US-12.1: File Menu
**As a** user,
**I want to** access file operations from the File menu.

**Menu Items:**
| Item | Shortcut | Action |
|------|----------|--------|
| New Virtual Machine... | Ctrl+N | Opens New VM wizard |
| *(separator)* | | |
| Exit | Ctrl+Q | Closes the application |

### US-12.2: VM Menu
**As a** user,
**I want to** access VM operations from the VM menu.

**Menu Items:**
| Item | Action |
|------|--------|
| Power On | Starts the selected VM |
| Power Off | Force-stops the selected VM |
| *(separator)* | |
| Snapshot Manager... | Opens snapshot dialog |
| Settings... | Opens VM edit dialog |

---

## 13. Toolbar

### US-13.1: Toolbar Buttons
**As a** user,
**I want to** access common actions from the toolbar,
**so that** I can perform frequent operations quickly.

**Buttons (left to right):**
| Button | Action | Notes |
|--------|--------|-------|
| New VM | Opens New VM wizard | |
| *separator* | | Visual divider "|" |
| Power On | Starts/stops selected VM | Toggles power state |
| Suspend | Suspend selected VM | |
| Power Off | Force-stops selected VM | |
| *separator* | | Visual divider "|" |
| Settings | Opens VM edit dialog | |

**Styling:** All buttons have 10x5 padding, no border, on light gray (240,240,240) background.

---

## 14. Main Window Layout

### US-14.1: Split Panel Layout
**As a** user,
**I want to** see the VM Library on the left and details on the right,
**so that** I can navigate and view information simultaneously.

**Layout:**
- **Top:** Toolbar (horizontal button bar)
- **Left:** VM Library (vertical list with "Library" header, ~200px wide, adjustable splitter)
- **Right:** Tabbed panel with three tabs:
  - **Summary:** VM name (bold 20pt), state, guest OS, commands section (power/edit links), hardware details (memory, CPU, disk, CD/DVD, network)
  - **Display:** Embedded VNC/SPICE framebuffer viewer
  - **Console:** Serial console output (multiline text)
- Summary tab has white background (255,255,255)
- VM list has near-white background (250,250,250) with 11pt Helvetica font

---

## 15. Error Handling & Edge Cases

### US-15.1: Max VM Capacity
**As a** user,
**I want to** be informed when I've reached the 64-VM limit,
**so that** I know why I can't create more VMs.

**Acceptance Criteria:**
- Error dialog: "Could not add VM (max capacity reached)."
- New VM wizard stays open

### US-15.2: Empty VM Name
**As a** user,
**I want to** be prevented from creating a VM with no name,
**so that** every VM is identifiable.

**Acceptance Criteria:**
- Error dialog: "VM name cannot be empty."
- New VM wizard stays open

### US-15.3: Disk Creation Failure
**As a** user,
**I want to** be informed if disk image creation fails,
**so that** I can troubleshoot the issue.

**Acceptance Criteria:**
- Error dialog: "Failed to create disk image."
- New VM wizard stays open

### US-15.4: QMP Connection Failure
**As a** user,
**I want to** be informed when QMP connection fails,
**so that** I know snapshot/control operations won't work.

**Acceptance Criteria:**
- Snapshot list shows "(QMP connection failed)"
- Snapshot operations silently return without action if QMP is not connected

### US-15.5: Snapshot Manager Requires Running VM
**As a** user,
**I want to** be informed that Snapshot Manager requires a running VM,
**so that** I know to power on the VM first.

**Acceptance Criteria:**
- Error dialog: "Snapshot Manager requires the virtual machine to be powered on."
- Dialog does not open

### US-15.6: OVMF Not Found
**As a** user,
**I want to** be informed if UEFI firmware cannot be found,
**so that** I can install the OVMF package.

**Acceptance Criteria:**
- VM fails to start with `OvmfNotFound` error
- Error should be surfaced to the user

### US-15.7: Script Export Failures
**As a** user,
**I want to** be informed if script export fails at any stage.

**Acceptance Criteria:**
- "Failed to generate script." -- if argument building fails
- "Failed to create script file." -- if file cannot be created
- "Failed to write script file." -- if file write fails

---

## 16. Configuration Options Reference

### Guest OS Types
| Value | UI Label |
|-------|----------|
| linux | Linux |
| windows | Microsoft Windows |
| freebsd | FreeBSD |
| macos | Apple macOS |
| other | Other |

### Disk Formats
| Value | UI Label |
|-------|----------|
| qcow2 | QCOW2 |
| raw | Raw |
| vmdk | VMDK |
| vdi | VDI |

### Display Types
| Value | UI Label |
|-------|----------|
| gtk | GTK |
| sdl | SDL |
| spice-app | SPICE |
| vnc | VNC |
| none | None (headless) |

### Display Resolutions
| Value | UI Label | Dimensions |
|-------|----------|------------|
| auto | Auto | Native |
| 800x600 | 800x600 | 800x600 |
| 1024x768 | 1024x768 | 1024x768 |
| 1280x800 | 1280x800 | 1280x800 |
| 1920x1080 | 1920x1080 | 1920x1080 |

### Network Modes
| Value | UI Label |
|-------|----------|
| user | NAT (User mode) |
| bridge | Bridged |
| none | None |

### Audio Devices
| Value | UI Label |
|-------|----------|
| none | None |
| intel-hda | Intel HDA |
| AC97 | AC97 |

### Boot Order
| Value | UI Label | QEMU order |
|-------|----------|------------|
| disk_first | Hard Disk | cdn |
| cdrom_first | CD/DVD | dcn |
| network_first | Network (PXE) | ncd |

### Boot Firmware
| Value | UI Label |
|-------|----------|
| bios | BIOS (SeaBIOS) |
| uefi | UEFI (OVMF) |

### VM Status
| Value | UI Label |
|-------|----------|
| stopped | Powered Off |
| running | Powered On |
| paused | Paused |
| suspended | Suspended |

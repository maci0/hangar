# VMware Workstation 7 — UI reference

Reference screenshots for matching Hangar to the VMware Workstation 7 (2009/2010)
look & feel. Sourced from period reviews (golem.de, neowin, myego.cz) plus newer
Player shots (lo4d, wikimedia) for layout confirmation.

## Canonical WS7 layout (ws7-golem-win7.jpg, ws7-myego.jpg)

- **Menu bar:** File · Edit · View · VM · Team · Windows · Help
- **Toolbar:** colored power cluster — Power Off (red square), Suspend (pause),
  Power On (green ►), Reset (circular arrows) — then Snapshot take / Snapshot
  manager, then display-mode cluster (Full Screen, Quick Switch, Unity).
- **Left sidebar** titled "Sidebar": a TREE grouping VMs under headers
  **Powered On** and **Favorites** (red heart). Each entry = small OS icon + name,
  with expand/collapse triangles.
- **Tabbed VM area:** a **Home** tab (house icon) plus one tab per open VM
  (OS icon + name + close ✕). Multiple VMs open simultaneously as tabs.
- **Status bar:** hint text ("To direct input to this VM, move the mouse pointer
  inside or press Ctrl+G") + a removable-device tray at bottom-right (NIC, disk,
  USB, sound…).

## Snapshot Manager (ws7-golem-snapshots.jpg)

- A branching **snapshot tree** (not a flat list): nodes connected by arrows show
  lineage, e.g. Windows 7 → Windows Update → Firefox Installed → Flash Player,
  with a branch to Google Chrome / Opera, ending at a highlighted **You Are Here**
  node = current state.
- **Snapshot details** panel below: Name field, Description multiline box, a
  screenshot thumbnail ("No screenshot available").
- Buttons: **Take Snapshot**, Keep, **Clone**, Delete (right column);
  **Go To**, AutoProtect, **Close**, Help (bottom row).
- "Show AutoProtect snapshots" checkbox; status line: `"You Are Here" selected`.

## Feature checklist (WS7 → Hangar status)

| WS7 feature | Hangar |
| --- | --- |
| VM create/clone/delete/import | ✓ |
| Power on/off/suspend/resume/reset | ✓ |
| Multiple snapshots + Snapshot Manager | ✓ (list → upgraded to details panel) |
| Snapshot Go To / Clone / Description | ✓ (added) |
| Virtual Network Editor (VMnet switches) | ✓ |
| Shared folders | ✓ (field) |
| VM hardware settings | ✓ |
| Full screen | ✓ |
| Library grouped by state (Powered On / Off) | ✓ (added) |
| Teams (group start, staggered boot) | ✗ (advanced, not implemented) |
| Unity / Quick Switch display modes | ✗ |
| AutoProtect scheduled snapshots | ✗ |

## Files
- `ws7-golem-win7.jpg` — full UI, sidebar tree + tab + toolbar (BEST reference)
- `ws7-golem-snapshots.jpg` — Snapshot Manager (tree + details)
- `ws7-myego.jpg` — multi-tab (Home + 3 VMs), XP guest
- `ws7-neowin1/2.png` — Home tab + Aero guest
- `ws7-vmguru.gif` — interface thumb
- `lo4d-player-*.png`, `wikimedia-*.png` — newer Player/Pro, layout confirmation

# AGENTS.md: src/web (embedded web UI)

## Purpose
The browser UI: hand-written vanilla JS/CSS/HTML (`app.js`, `app.css`, `index.html`)
plus the Preact + Tailwind source in `ui/`. Bun bundles `ui/` to `dist/` (gitignored) during
`zig build`; every bundle is `@embedFile`'d into the daemon and served by `web_server.zig`.
Targets VMware (vSphere/Workstation) admin conventions.

## Ownership
- `index.html`: page markup and script tags. It holds no dialog and no `style=` attribute (a Tailwind utility or token replaces one; an initially hidden element carries the `hidden` class and app.js toggles its inline `style.display`). The toolbar and its menus are not here: `#toolbar-root` is the mount for the Preact `Toolbar`. The page chrome is Preact too and only its mounts are here: `#banner-root` (connection banner), `#sidebar-head-root` (logo, select toggle, search), `#bulk-root` (bulk bar), `#vmheader-root` (VM emblem, name, tab bar), `#statusbar-root` (status bar and announcer) and `#overlay-root` (toasts and the context menu). Every dialog is Preact, the command palette included: `#dialog-root` is the mount for `Dialogs`. The Summary and Settings tab panels are Preact too: `#tabSummary` holds `#summary-root` (welcome state, host dashboard or the selected VM) and `#tabSettings` holds `#settings-root` (the settings form or its no-VM state). The panels themselves, `#tabConsole` and the display-only bar are static markup. The migration progress bar (`#mig_progress`, `#mig_pct`, `#mig_cancel`) is page markup below the tabs, not part of the Migrate dialog.
- `app.js`: refresh poll, render, action dispatch, console/serial viewers, folders. `showConfirmDialog`, `showPromptDialog`, `openPrefs`, `openAbout`, `showShortcutsModal` and `viewLog` keep their signatures and promise behavior but only call `hangarUi` (`confirm`, `prompt`, `openPrefs`, `openAbout`, `openShortcuts`, `openLog`); the fetches stay in `app.js`. `newVm`, `importGuest`, `cloneGuest`, `openSnapshots` (also `takeSnapshot`) and `migrateGuest` open their dialog through `hangarUi` and hand it the action callbacks: `createVm(values)`, `importConfirm(path, name)`, `doClone(linked)`, `takeSnapshotFromDlg(tag)`, `revertSnapshot(tag)`, `deleteSnapshot(tag)` and `doMigrate(host, port)`. Each takes typed, already validated values and resolves whether the dialog may close; `loadSnapshots` pushes the list with `hangarUi.setSnapshots`. The dialogs own their form state and field validation. `openVnets(select?)` loads `/api/networks` and opens the editor with `save(networks, saved)` and `confirmDiscard`; `openCatalog` opens the catalog as `loading` and pushes the templates with `hangarUi.setCatalog`, its `create` callback is `quickstartVm`; `openTopology` opens the topology and `renderTopology` pushes each step (`loading`, `failed`, `empty`, `ready` with the ELK result as a typed layout) with `hangarUi.setTopology`. Data, fetches and the ELK layout stay in `app.js`.

  Summary and Settings: `renderDetails()` and `showEmptyState()` choose the view and push it with `hangarUi.setSummary(view)` (`welcome`, `dashboard` with the rows in list order, the emblem of each VM and the host size, or `vm` with the VM record, its folder, the `guestIp` and `diskUsage` lookups and the NIC and extra-disk slot counts). `loadGuestInfo` and `loadDiskInfo` fetch the lookups after the draw and store each answer per VM in `vmLookups`, so the poll redraws with the last answer instead of blanking it. `fetchHost()` runs when the dashboard first appears and redraws it when `/api/host` answers; `publishVms()` redraws it on every list change. `editVm()` (also the toolbar Settings entry and `switchTab('settings')`) asks before dropping unsaved edits, then `showSettings()` calls `hangarUi.openSettings({vm, slots, save, onDirty, onInvalid})`; `save` is `persistSettings(body)`, which POSTs the body the form built and then refreshes and returns to Summary. `saveVm()` (Ctrl+S, the Save button's `data-action`) only calls `hangarUi.saveSettings()`. `settingsDirty` mirrors the form's `onDirty`. The disk and CD/ISO buttons in the form keep their `data-action`s (`resizeDisk`, `compactDisk`, `disk2upload`, `disk2download`, `changeCd`, `ejectCd`) and the delegated handlers in `app.js` run them. `syncPanels()` redraws the panel for the current selection; `ui.js` calls it once on load.

  Page chrome state is derived in `app.js` and pushed whole: `syncShell()` builds `hangarUi.setShell({selectMode, checkedCount, searchActive, bannerVisible, header, status, live, announcement})` from `sel`, `activeTab`, `selectMode`, `checkedIds`, `serverDown`, the status text and the event-stream flag, and every code path that changes one of them calls it (`syncTabPanels`, `switchTab`, `updateCommandState`, `updateBulkBar`, `setServerDown`, `setStatus*`). `setStatus(s)` sets the text and announces it; `setStatusLoading(s)` does the same with a pulsing `s…`; the passive list summary goes through `setStatusText` and is never announced. Nothing writes to `#statusmsg`, `#vmname`, `#tabBar` or `#bulkCount` directly. `showToast(msg, type, {duration})` and `toastUndo(msg, onUndo)` call `hangarUi.showToast`. `openCtxMenu(idx, x, y)` builds the entries (label, sprite name, danger, disabled reason, `run`) for `hangarUi.openContextMenu`; Escape goes through `closeCtxMenu(returnFocus)`. `openPalette()` hands `paletteCommands()` (label, optional sprite name, `run`) to `hangarUi.openPalette`. `syncShell` skips until `hangarUi` exists and `ui.js` calls it once on load.
- `app.css`: flat slate theme (`:root` dark default + `:root.light`) + components.
  Logo and empty-state emblems use the shared accent and radius tokens, without
  decorative gradients or colored shadows.
- Vendored libs: `novnc.js`, `spice.js`, `elk.js`, `xterm.js`/`xterm.css`/`xterm-fit.js`/`xterm-webgl.js`
  (@xterm UMD builds). Each is `@embedFile`'d, served at `/novnc.js`
  etc, and listed in `auth.isAuthExempt`. All load on demand
  (see On-demand bundles); none of them is a `<script>` in `index.html`.
  - `favicon.svg` is hand-written, not vendored: it is the same mark as
    the sidebar logo and the About dialog emblem (flat `--accent` fill,
    `--radius-md` corner, one "H"), pinned to a literal color because a favicon
    resolves no page stylesheet. Keep it that mark; a gradient tile or a letter
    in a different face breaks the one surface every window shows.
  - **Provenance:** every bundle starts with a header comment naming package@version
    + license + vendor date. Versions for `elk`/`xterm*` are pinned as exact
    devDependencies in `../../package.json` (+ `bun.lock`); re-vendor by bumping there,
    running `bun install`, copying the dist file in, and updating the header.
    `novnc.js`/`spice.js` have no registry pin (upstream version not recorded at
    vendor time): record upstream + date in their headers when re-vendoring.
    `../../THIRD-PARTY-NOTICES.md` carries the same inventory for every vendored
    and declared dependency, with the license obligations that survive shipping;
    it moves in the same change as any bump or re-vendor.
  - Treat bundles as binary: never hand-edit code inside them; only prepend/adjust
    the metadata header.

## Local Contracts
- **Tokens are the only place a visual value is written.** `:root` and
  `:root.light` each declare the color set: surfaces, `--inset` (the recessed
  fill behind capacity bars, spec chips, and disabled controls). The 5/8/11px
  `--radius-sm` / `--radius-md` / `--radius-lg` scale and `--font-sans` /
  `--font-mono` are declared once in `ui/styles.css` (`@theme static`) and read
  by both sheets. Never hardcode a radius, an inset gray, or a font stack in a
  rule or a `style=` attribute, and never write a fallback like
  `var(--inset,rgba(127,127,127,.18))` for a token that is already declared, and never
  name a token that does not exist (`--mono` is not `--font-mono`).
- **`app.css` is wrapped in `@layer legacy`** so Tailwind utilities from `ui.css`
  outrank it. Do not add unlayered rules to it; an unlayered rule beats every utility.
- **`--text` / `--text-muted` / `--text-dim` are three distinct steps**, not one
  color spelled twice. Keep them ordered by emphasis and at least 4.5:1 against
  every surface the step lands on (`--bg`, `--bg-alt`, `--surface`, `--surface-2`;
  `--surface-3` only ever carries `--text`). Collapsing two steps into the same
  gray removes the hierarchy the type scale depends on, so a change that merges
  them is a regression even when nothing looks wrong.
- **The sans is the platform UI stack on purpose**: this is a desktop-style
  operator console, not a document surface, and a webfont would render unlike the
  surrounding desktop.
- **Iconography is the sprite served at `/icons.svg`.** The source of truth is one
  file per icon in `assets/icons/` (24px grid, 2px round stroke, kebab-case name);
  `scripts/build-icons.ts` validates them and writes `dist/icons.svg` plus the browsable
  `docs/brand/icons.html`. Every control uses a symbol via
  `<svg class="ico"><use href="/icons.svg#i-name"/></svg>`. A control that shows state
  (the theme toggle) swaps the `<use href>` between symbols; it never replaces
  the button contents with text. A platform emoji in a control is a defect: it
  ignores the accent and radius tokens and renders at the platform's whim.
- **Emblem radius follows emblem size**: the 20px inventory `OsBadge` (`ui/components/vm-parts.tsx`, `rounded-sm`) -> `--radius-sm`,
  the 30px VM header emblem (`#vmemblem`, Preact, `rounded-md`) and the 34px snapshot row emblem (Preact, `rounded-md`) -> `--radius-md`, 44px `.cat-emblem` ->
  `--radius-lg`. The four read as one family; never round them independently.
- **Dialog chrome comes from the `Dialog` primitive** (`ui/components/ui/dialog.tsx`), not from a per-dialog inline style. `app.css` has no `dialog` rule. The
  `!important` in the sheet are `#display` stacking overrides and the reduced-motion block; do not add one to win a cascade fight.
- **VM list rows are `role="button"` with `aria-current` on the selected one**, and the favorite star is a sibling inside `.vm-row`, never a child of the row: axe rejects a button (or option) that contains another control. `#vmlist` is a `role="group"`.
- **Stat tiles are not interactive.** `.dash-card` carries no hover or focus state;
  reserve elevation-on-hover for things that can be pressed.
- **Every composite follows the ARIA keyboard pattern.** `role="menu"`
  containers hold `role="menuitem"` children (the toolbar's More popover rows too) and
  move focus with Arrow/Home/End, returning it to the trigger on Escape. The toolbar
  menus are Preact (`ui/components/toolbar.tsx`); `app.js` only calls
  `hangarUi.closeToolbarMenus(returnFocus)` from its Escape handler and `select()`. `role="tablist"` (`#tabBar`; Arrow/Home/End move to the next enabled tab and activate it) and the VM listbox use a roving `tabindex`: exactly
  one item is `0` (the selected one, or the first row when nothing is selected),
  the rest are `-1`. A control that only works by pointer gets a keyboard
  equivalent too: `#serialResize` is a `role="separator"` with Arrow (16px,
  Shift 48px) and Home/End. `renderList` restores focus to the row or folder
  header that had it, because the 5s poll replaces the list wholesale.

- **UI patterns** (keep consistent when adding surfaces): menu items are
  `<button class="menu-item">` with a leading 13px `.ico` sprite svg and trailing `…`
  for dialog-openers; dialog footers are `.btn-row` (right-aligned, primary last,
  destructive `.btn.danger` grouped left when present). Destructive-action rule:
  recoverable deletes use the undo toast (`toastUndo`), irreversible operations
  (snapshot revert and delete, disk ops) use `showConfirmDialog({danger:true})`. Don't mix.
  Status and notification glyphs come from the sprite too (a toast maps
  success/error/info/warn to `check`/`x`/`info`/`alert`); a text
  substitute like `✓` or `＋` is a defect. Preact buttons draw their sprite with `Icon`.
- **Unsaved state**: a dialog with edits the user has not committed passes `guard` to the
  Preact `Dialog`, which runs it for the button, Escape and backdrop paths; the guard may return a promise
  (the VNet editor asks `confirmDiscard`; the Settings tab asks through `showConfirmDialog` when `settingsDirty` is set). A save button either persists (with status
  feedback) or it does not exist: Save Selected writes to the daemon, it is
  not a form-only re-render.

- **Navigation**: Tools stays available without a selected VM; only VM-specific
  entries are disabled. Below 1100px the five menu triggers collapse into the More
  popover; the other toolbar buttons stay. `syncToolbar()` (called from
  `updateCommandState`) pushes `hasVm`, `powered` and the `actionReason(name)`
  callback (`actionAllowed`/`disabledReason`) to `hangarUi.setToolbar`; enabled
  state, titles and the Power On/Off button are props, never DOM edits. Toolbar
  markup is not in `index.html`, so `syncSidebarButton` and `powerToggle` also go
  through `setToolbar` (`sidebarExpanded`, `powerBusy`). Context-menu actions stop when selection is cancelled.
- **Power actions**: toolbar, batch and multi-select requests use `/start` or `/stop`,
  never `/power`, so duplicate delivery cannot reverse the requested state. Capture
  the toolbar's intended state before confirmation and re-resolve its VM afterward.
- **RAM capacity**: compare committed and physical memory in exact MiB; round only
  display labels, never the quantities used for overcommit or gauge ratios. Every
  memory label goes through `memText(mb)` (`ui/lib/format.ts`; `app.js` calls it as `hangarUi.memText`; `memGiB(mb)` gives a bare number in the components):
  the daemon sends MiB, the `/1024` step is binary, so a scaled value is `GiB`.
  Never hand-roll a memory conversion or label a MiB total "GB".
- **Host dashboard** (`ui/components/dashboard.tsx`, logic in `ui/lib/dashboard.ts`): shows while no VM is selected. Host Capacity (`.cap-panel`, hidden while `/api/host` reports neither cores nor RAM) compares committed vCPU and exact MiB with the host; the bar is `bg-danger` past 100% and `.cap-over` says `N× overcommit`. Two rows of `.dash-card` tiles follow (four states, then vCPU, RAM and disk allocated), the "Needs attention" list of VMs with a configuration warning, and the sortable inventory. Sorting is `data-col` on the `th` (Enter and Space work too), `aria-sort` is set on every header, and the default is Name ascending; numbers sort by value, text case-insensitively. A row is `data-action="select"` with `data-vm-index`.
- **Summary tab** (`ui/components/summary.tsx`): `.vm-facts` chips (state, OS, vCPU, RAM, disk, and the guest IP while running, in `#guestIpVal`), then cards for VM Hardware, Guest & Tools, Options, Tags, Folder and Notes; a card with nothing to show is omitted. The primary disk shows the usage bar in `#diskUsageVal` while `/diskinfo` answers, and `unavailable` when it does not. Configuration warnings sit under the cards. `View QEMU Log` and (running) `Screenshot` are `data-action` buttons.
- **Settings tab** (`ui/components/settings.tsx`, field catalogue, validation and payload in `ui/lib/settings.ts`): a left nav (`.settings-nav-item`, `aria-current="page"`, category id in `data-settings-category`) and one `.settings-panel` per category. Inactive panels stay in the page hidden, so every control keeps its `e_<key>` id and error line `err_e_<key>`. Sections: `basic`, `network_and_boot`, `sharing`, `autoprotect`, `display_and_video`, `storage_and_notes`, `extra_disks`, `advanced`; the chosen category survives `editVm` calls. NIC 2..N and extra-disk rows follow `/api/capabilities` (`MAX_NICS`, `MAX_EXTRA_DISKS`): adding a slot in `vm.zig` needs no UI edit. The form owns its values; the request body is `settingsBody`, keys in the fixed order of `BODY_KEYS` (then NICs, then extra disks) and every value URL-encoded, so the payload matches what the daemon has always been sent. A select whose stored value is not one of its options starts on the first option. Validation appears after the first edit or a Save attempt: errors (name required, memory 128-65536, cores 1-256, disk 1-65536, MACs, display ports, port forwards) mark the control `aria-invalid`; warnings (embedded display without SPICE or VNC, virgl over VNC) only colour the message. A refused Save toasts "Fix highlighted settings before saving.", switches to the section of the first bad field and focuses it, and sends nothing. The form is dirty only while a value differs from its start, so putting a value back clears the unsaved-changes prompt. While the VM is running, paused or suspended the hardware controls are disabled with a title and `.settings-runlock` (`role="note"`) explains it; name, notes, tags, vnet, favorite and AutoProtect stay editable and the CD/ISO buttons work live. While a save is pending the whole form is disabled and the button reads "Saving...". Cancel is `data-action="switchTab" data-tab="summary"`.
- **Library search**: list redraws preserve the search input's current query.
- **VM uptime**: display the daemon's monotonic `uptime_sec`, including zero.
  Never subtract `started` from the browser clock; omit unavailable durations.
- **Network saving**: edits live in the editor until saved, across selection changes. Save Selected and Save All both validate every network (name 1-15 characters, IPv4 fields without leading zeros, a contiguous netmask), write the whole set, and reset the dirty state; only Save All closes. Invalid values select the first bad network, show the message under the field (`err_vn_*`), focus it, leave the editor open and send no request. The editor opens only if `/api/networks` loaded, so a failed load can never be saved back as an empty set.
- **Topology loading**: `/elk.js` loads only when the topology opens, never from
  `index.html`. Concurrent opens share the pending load. Loading is visible; failed,
  invalid, or timed-out loads expose Retry (`data-action="openTopology"`, also on Refresh) and clear the pending promise. Nodes are drawn by the dialog as SVG from the typed layout; VM and network nodes are focusable buttons, the host and NIC-mode nodes are not.
- **On-demand bundles**: `index.html` loads only `app.css`, `ui.css`, `app.js` and `ui.js`.
  `ensureAsset(src, isReady)` is the single loader for every other bundle
  (`/novnc.js`, `/spice.js`, `/elk.js`, `/xterm.js`, `/xterm-fit.js`,
  `/xterm-webgl.js`): it caches the pending promise per URL, times out after
  `ASSET_LOAD_TIMEOUT_MS`, removes the failed tag, and clears the entry so the
  surface's Retry starts a fresh attempt. `ensureStylesheet` does the same for
  `/xterm.css`. Console clients load on the first `startFb`; the terminal
  bundles on the first `startSerial`. A bundle that never arrives must leave a
  visible Retry (`reconnectDisplay` / `reconnectSerial`), never a dead pane.
  Adding a bundle means: drop the `<script>` from `index.html`, add an
  `ensureAsset` call at the point of use, and keep the failure path.
- **Reactivity**: `GET /api/events` (SSE) pushes a change event whenever the daemon's
  state version bumps; the client refreshes on it (5s poll stays as fallback). The host
  dashboard is a Preact component (`ui/components/dashboard.tsx`): the list arrives as props and the sort column lives in the bridge, so a poll or SSE redraw keeps focus (a sort header stays focused). Push new state, never write its DOM. The console (`#display` + `#serialpanel`) lives inside
  `#tabConsole`; hints go to `#consoleHint` (renders must not wipe the panel). The serial
  terminal is xterm.js (bidirectional, `onData` → WS → guest; WebGL renderer with
  built-in fallback); export reads the `serialBuf` shadow buffer, not the DOM.
- **Strict CSP** (`script-src 'self'`): NO inline event handlers. All actions go through
  the delegated body click → `el.closest('[data-action]')` → `actionHandlers[action](el)`.
  Keyboard activation for `role=button`/`th[data-action]` is the global keydown delegator.
- **XSS:** every user string passes `escHtml()` before `innerHTML`, including SVG text
  AND attribute values. No exceptions. Preact text and attribute values are escaped by the renderer, so the dialogs pass raw strings.
- **Index-after-await is stale:** the 5s `refresh()` replaces `vms[]` wholesale. Any
  action that resolves a VM after an `await` must re-resolve by stable id (`idxById`,
  survives rename) or name (`idxByName`), never a frozen index. Multi-select keeps
  `checkedIds`; migration tracks `migId`.
- **Toasts, the context menu and the palette.** `#toast-container` is the one live region (`role="log"`, `aria-live="polite"`, additions only) and stays mounted while empty; a toast keeps its own `role` (`alert` for error and warn, `status` otherwise), holds five at most and drops the oldest. The context menu (`.ctx-menu`, `role="menu"` `aria-label="VM actions"`) opens at the pointer or under the focused row (Shift+F10 or the Menu key), focuses its first enabled item, moves with Arrow/Home/End, closes on Escape (focus returns to the row without deselecting the VM), on an outside click and after an item runs. The palette (`#palette`, `#paletteInput` combobox, `#paletteList` listbox of `li[data-pidx]` with `aria-activedescendant`) is a modal `Dialog`; Enter or a click runs the chosen command after the palette has closed, so a dialog it opens keeps focus.
- **Preact dialogs are removed from the DOM when closed**, so `#confirmdlg`, `#promptdlg`,
  `#aboutdlg`, `#shortcutsdlg`, `#logdlg`, `#prefsdlg`, `#newdlg`, `#importdlg`, `#clonedlg`, `#snapdlg`, `#migratedlg`, `#vnetdlg`, `#topodlg`, `#catalogdlg` and `#palette` exist only while open (a test asserts
  `toHaveCount(0)`, not hidden). `dlg.close()` on one still works: the `Dialog` replaces it with
  the guarded, animated close, which is what the `closeDlg` action and the Escape sweep call.
  Preferences applies the theme as it is picked and puts the original back on every close except a
  save; that state is in the component, not in `app.js`.
  New VM, Import and Migrate validate inline (`aria-invalid` on the control, message in `#err_<field id>`),
  focus the first bad field on submit, and disable the submit button while the request is pending;
  none has a dirty guard. The buttons of the VNet editor keep their `data-action` names (`vnetAdd`, `vnetRemove`, `vnetDefaults`, `vnetSaveCurrent`, `vnetSaveAll`) as hooks for tests; the component handles the click and `actionHandlers` has no entry for them. The network list is a `role="listbox"` with a roving tab stop and Arrow/Home/End. The Snapshot Manager reverts only with the VM powered off, and a
  successful revert closes it.
- **Vendored-bundle globals are not their class:** `noVNC` exposes the RFB class as
  `noVNC.default` (NOT `noVNC.RFB`); SPICE uses `SpiceHtml5.SpiceMainConn`; elk is `ELK`.
  Resolve `noVNC.default || noVNC.RFB` so a re-vendor can't silently break the console.
- VM data comes from `GET /api/vms` (the list render); the detail tab uses the same fields.
  A field absent from the list JSON is `undefined` in `app.js`, emit it in `vmrender`.
- UI terminology: VMware Workstation ("Power On/Off", "Take Snapshot", "VM Library", …).

## Work Guidance
- **Every user-facing workflow needs a Playwright e2e** in `../../tests/e2e/workflows.spec.mjs`,
  added alongside the feature. A new flow without one is incomplete.
- Editing `app.js`/`app.css`/`index.html` requires a `zig build` (they are embedded) and a
  binary check if anything looks stale (see root AGENTS.md, Testing).

## Verification
`bun run test` (unit tests of the pure formatting, dashboard and settings logic in `ui/lib`). `zig build web-e2e` (Playwright; standalone, not in `zig build test`). Check the
trailing **failed** count, not just `N passed`. `bun tests/visual/screenshots.mjs`
captures key views to confirm look.

Validate hand-written HTML/CSS before shipping (requires Java and an existing VNU
JAR; not a CI step). Set `VNU_JAR` to its path; do not install global packages or
assume a machine-specific location. Missing prerequisites mean validation is blocked,
not passed. Require zero errors and warnings:

```bash
java -jar "${VNU_JAR:?Set VNU_JAR to an existing vnu.jar}" --format text src/web/index.html
java -jar "${VNU_JAR:?Set VNU_JAR to an existing vnu.jar}" --css --format text src/web/app.css
```

Exclude vendored `xterm.css`: the validator rejects its valid `text-decoration`
shorthand (`overline underline`); do not edit the bundle to satisfy validation.

## Notes
If a WebSocket sticks in CONNECTING under headless Chromium, suspect the server's
101 response before the client: malformed CRLF there breaks every console at once
(`ws.zig` has regression tests for it). The live-console e2e boots a real guest
headlessly and asserts canvas + serial connect.

## Child DOX Index
- [ui/AGENTS.md](ui/AGENTS.md): Preact + Tailwind v4 + shadcn-style source, bundled to `dist/`.

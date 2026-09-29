# AGENTS.md: src/web (embedded web UI)

## Purpose
The browser UI. `ui/` holds the Preact + Tailwind source that Bun bundles into `dist/` (gitignored) during
`zig build`; `index.html`, the favicon and the vendored bundles sit beside it. Every file here is `@embedFile`'d
into the daemon and served by `web_server.zig` (`/`, `/ui.js`, `/ui.css`, `/icons.svg`, `/favicon.svg`, the vendored
bundles). Targets VMware (vSphere/Workstation) admin conventions.

## Ownership
- `index.html`: the document shell only: `lang`, viewport, title, `/ui.css`, the favicon, `<div id="app">` and the
  `/ui.js` tag. Everything visible, the skip link included, is drawn by `ui/`. Keep it free of dialogs, `style=`
  attributes and inline scripts.
- `ui/`: all UI source and logic. See [ui/AGENTS.md](ui/AGENTS.md).
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
- **Tokens are the only place a visual value is written**, in `ui/styles.css` (dark palette under `@theme static`, light
  overrides under `:root.light`). Radii are 5/8/11px (`--radius-sm` / `-md` / `-lg`), fonts `--font-sans` /
  `--font-mono`. Never hardcode a radius, an inset gray or a font stack in a component or a `style=` attribute, never write a
  fallback like `var(--inset,rgba(127,127,127,.18))` for a token that is already declared, and never name a token
  that does not exist (`--mono` is not `--font-mono`).
- **Utilities and components sit above the resets**: layer order is `theme, base, components, utilities`. Do not add
  unlayered rules to `styles.css`; an unlayered rule beats every utility. The only `!important` is the reduced-motion
  block; `display-surface` carries two that beat the size a client sets on its canvas. Do not add one to win a cascade fight.
- **`--text` / `--text-muted` / `--text-dim` are three distinct steps**, not one color spelled twice. Keep them ordered by
  emphasis and at least 4.5:1 against every surface the step lands on (`--bg`, `--bg-alt`, `--surface`, `--surface-2`;
  `--surface-3` only ever carries `--text`). Merging two steps is a regression even when nothing looks wrong.
- **The sans is the platform UI stack on purpose**: this is a desktop-style operator console, not a document surface, and
  a webfont would render unlike the surrounding desktop.
- **Iconography is the sprite served at `/icons.svg`.** The source of truth is one file per icon in `assets/icons/` (24px
  grid, 2px round stroke, kebab-case name); `scripts/build-icons.ts` validates them and writes `dist/icons.svg` plus the
  browsable `docs/brand/icons.html`. Every control uses a symbol via `<Icon name="x"/>`
  (`<svg class="ico"><use href="/icons.svg#i-x"/></svg>`). A control that shows state (the theme toggle) swaps the
  `<use href>`; it never replaces the button contents with text. A platform emoji or a text glyph (`✓`, `＋`) in a control
  is a defect: it ignores the accent and radius tokens.
- **Emblem radius follows emblem size**: the 20px inventory `OsBadge` (`rounded-sm`) -> `--radius-sm`, the 30px VM header
  emblem (`#vmemblem`) and the 34px snapshot row emblem (`rounded-md`) -> `--radius-md`, the 44px catalog emblem ->
  `--radius-lg`. The four read as one family; never round them independently.
- **Dialog chrome comes from the `Dialog` primitive** (`ui/components/ui/dialog.tsx`), not a per-dialog inline style.
- **VM list rows are `role="button"` with `aria-current` on the selected one**, and the favorite star is a sibling inside
  `.vm-row`, never a child of the row: axe rejects a button that contains another control. `#vmlist` is a `role="group"`.
- **Stat tiles are not interactive.** `.dash-card` carries no hover or focus state; reserve elevation-on-hover for things
  that can be pressed.
- **Every composite follows the ARIA keyboard pattern.** `role="menu"` containers hold `role="menuitem"` children (the
  toolbar's More popover rows too) and move focus with Arrow/Home/End, returning it to the trigger on Escape.
  `role="tablist"` (`#tabBar`; Arrow/Home/End move to the next enabled tab and activate it) and the VM listbox use a roving
  `tabindex`: exactly one item is `0` (the selected one, or the first row when nothing is selected). A control that only
  works by pointer gets a keyboard equivalent too: `#serialResize` is a `role="separator"` with Arrow (16px, Shift 48px) and
  Home/End. The 5s poll redraws the list in place, so a focused row keeps focus.
- **UI patterns** (keep consistent when adding surfaces): menu items are `MenuItem` buttons with a leading 13px sprite icon
  and a trailing `…` for dialog-openers; dialog footers are right-aligned with the primary action last and a destructive
  action grouped left when present. Destructive-action rule: recoverable deletes use the undo toast (`toastUndo`),
  irreversible operations (snapshot revert and delete, disk ops) use `ui.confirm(..., {danger: true})`. Don't mix. Status and
  notification glyphs come from the sprite too (a toast maps success/error/info/warn to `check`/`x`/`info`/`alert`).
- **Unsaved state**: a dialog with uncommitted edits passes `guard` to `Dialog`, which runs it for the button, Escape and
  backdrop paths (the VNet editor asks `confirmDiscard`; the Settings tab asks through `confirmDiscard()` in
  `app/session.ts` when `settingsDirty` is set). A save button either persists (with status feedback) or it does not exist:
  Save Selected writes to the daemon, it is not a form-only re-render.
- **Navigation**: Tools stays available without a selected VM; only VM-specific entries are disabled (`actionReason` gives
  the title). Below 1100px the five menu triggers collapse into the More popover; the other toolbar buttons stay. Enabled
  state, titles and the Power On/Off button are props from `app/view.ts`, never DOM edits. Context-menu actions stop when
  the selection is cancelled.
- **Power actions**: toolbar, batch and multi-select requests use `/start` or `/stop`, never `/power`, so duplicate delivery
  cannot reverse the requested state. Capture the intended state before confirmation and re-resolve the VM by id afterward.
- **RAM capacity**: compare committed and physical memory in exact MiB; round only display labels, never the quantities used
  for overcommit or gauge ratios. Every memory label goes through `memText(mb)` (`ui/lib/format.ts`; `memGiB(mb)` gives a bare
  number): the daemon sends MiB and the `/1024` step is binary, so a scaled value is `GiB`. Never hand-roll a memory
  conversion or label a MiB total "GB".
- **Host dashboard** (`ui/components/dashboard.tsx`, logic in `ui/lib/dashboard.ts`): shows while no VM is selected. Host Capacity
  (`.cap-panel`, hidden while `/api/host` reports neither cores nor RAM) compares committed vCPU and exact MiB with the host; the
  bar is `bg-danger` past 100% and `.cap-over` says `N× overcommit`. Two rows of `.dash-card` tiles follow (four states, then vCPU,
  RAM and disk allocated), the "Needs attention" list of VMs with a configuration warning, and the sortable inventory. Sorting is
  on the `th` (Enter and Space work too), `aria-sort` is set on every header, and the default is Name ascending; numbers sort by
  value, text case-insensitively. An inventory row selects its VM on click, Enter and Space.
- **Summary tab** (`ui/components/summary.tsx`): `.vm-facts` chips (state, OS, vCPU, RAM, disk, and the guest IP while running, in
  `#guestIpVal`), then cards for VM Hardware, Guest & Tools, Options, Tags, Folder and Notes; a card with nothing to show is omitted.
  The primary disk shows the usage bar in `#diskUsageVal` while `/diskinfo` answers, and `unavailable` when it does not. Configuration
  warnings sit under the cards. `View QEMU Log` and (running) `Screenshot` are buttons. The guest IP and disk usage load after the
  draw and are kept per VM in `state.lookups`, so the poll redraws with the last answer instead of blanking it.
- **Settings tab** (`ui/components/settings.tsx`, field catalogue, validation and payload in `ui/lib/settings.ts`): a left nav
  (`.settings-nav-item`, `aria-current="page"`, category id in `data-settings-category`) and one `.settings-panel` per category.
  Inactive panels stay in the page hidden, so every control keeps its `e_<key>` id and error line `err_e_<key>`. Sections: `basic`,
  `network_and_boot`, `sharing`, `autoprotect`, `display_and_video`, `storage_and_notes`, `extra_disks`, `advanced`; the chosen category
  survives `editVm` calls. NIC 2..N and extra-disk rows follow `/api/capabilities` (`MAX_NICS`, `MAX_EXTRA_DISKS`): adding a slot in
  `vm.zig` needs no UI edit. The form owns its values; the request body is `settingsBody`, keys in the fixed order of `BODY_KEYS` (then
  NICs, then extra disks) and every value URL-encoded, so the payload matches what the daemon has always been sent. A select whose
  stored value is not one of its options starts on the first option. Validation appears after the first edit or a Save attempt: errors
  (name required, memory 128-65536, cores 1-256, disk 1-65536, MACs, display ports, port forwards) mark the control `aria-invalid`;
  warnings (embedded display without SPICE or VNC, virgl over VNC) only colour the message. A refused Save toasts "Fix highlighted
  settings before saving.", switches to the section of the first bad field and focuses it, and sends nothing. The form is dirty only
  while a value differs from its start. While the VM is running, paused or suspended the hardware controls are disabled with a title
  and `.settings-runlock` (`role="note"`) explains it; name, notes, tags, vnet, favorite and AutoProtect stay editable and the CD/ISO
  buttons work live. While a save is pending the whole form is disabled and the button reads "Saving...". Ctrl+S submits the open form.
- **Library search**: list redraws preserve the search input's current query.
- **VM uptime**: display the daemon's monotonic `uptime_sec`, including zero. Never subtract `started` from the browser clock; omit
  unavailable durations.
- **Network saving**: edits live in the editor until saved, across selection changes. Save Selected and Save All both validate every
  network (name 1-15 characters, IPv4 fields without leading zeros, a contiguous netmask), write the whole set, and reset the dirty
  state; only Save All closes. Invalid values select the first bad network, show the message under the field (`err_vn_*`), focus it,
  leave the editor open and send no request. The editor opens only if `/api/networks` loaded, so a failed load can never be saved back
  as an empty set.
- **Topology loading**: `/elk.js` loads only when the topology opens, never from `index.html`. Concurrent opens share the pending load.
  Loading is visible; failed, invalid, or timed-out loads expose Retry and clear the pending promise. Nodes are drawn by the dialog as
  SVG from the typed layout; VM and network nodes are focusable buttons, the host and NIC-mode nodes are not.
- **On-demand bundles**: `index.html` loads only `ui.css` and `ui.js`. `ensureAsset(src, isReady)` (`ui/lib/assets.ts`) is the single
  loader for every other bundle (`/novnc.js`, `/spice.js`, `/elk.js`, `/xterm.js`, `/xterm-fit.js`, `/xterm-webgl.js`): it caches the pending
  promise per URL, times out after `ASSET_LOAD_TIMEOUT_MS`, removes the failed tag, and clears the entry so the surface's Retry starts a
  fresh attempt. `ensureStylesheet` does the same for `/xterm.css`. Console clients load on the first `startDisplay`; the terminal bundles
  on the first `startSerial`. A bundle that never arrives must leave a visible Retry (the `reconnectDisplay` button in the message over the
  display, the `reconnectSerial` button in the serial status line), never a dead pane. Adding a bundle means an `ensureAsset` call at the
  point of use and the failure path; never a `<script>` in `index.html`.
- **Reactivity**: `GET /api/events` (SSE) pushes a change event whenever the daemon's state version bumps; the client refreshes on it (the
  5s poll stays as fallback). Push new state, never write its DOM. The console (`#display`, `#serialpanel`, `#consoleHint`) is a Preact panel
  inside `#tabConsole`. `#display` and `#serialterm` are Preact-owned elements the vendored clients mount into by ref: Preact keeps its own
  children (badge, buttons, message) and never touches the canvases the clients and the presenter append, and every state (visible, spinner,
  renderer, video overlay, badge, message) is a prop, never a class edit. The message over the display says `Loading VNC client…` while a
  bundle loads, `VNC client failed to load.` with Retry when it does not, and names a native display. The serial terminal is xterm.js
  (bidirectional, `onData` → WS → guest; WebGL renderer where the GPU allows, else xterm's DOM renderer; colors come from the `--serial-*`
  tokens, so a theme change reaches it); export reads the shadow buffer (the last 256 KiB), not the DOM. Relay URLs come from `relayUrl`
  (`ui/lib/console.ts`): `ws` or `wss` by page protocol, `/ws/<vnc|spice|serial|video>/<vm index>`.
- **Strict CSP** (`script-src 'self'`): no inline event handlers and no inline scripts. Every action is a direct handler prop or a
  listener added in code; keyboard activation of `role=button` rows and headers is an `onKeyDown` on the element.
- **XSS:** Preact escapes every text and attribute value, so user strings (VM names, tags, notes, paths, daemon messages) are passed
  raw and `innerHTML` is not used. No exceptions.
- **Index-after-await is stale:** the 5s `refresh()` replaces the VM list wholesale. Any action that resolves a VM after an `await`
  re-resolves it by stable id (`indexOfId`, survives rename) or name (`indexOfName`), never a frozen index. Multi-select keeps `checkedIds`;
  the migration controller follows its VM by id.
- **Toasts, the context menu and the palette.** `#toast-container` is the one live region (`role="log"`, `aria-live="polite"`, additions
  only) and stays mounted while empty; a toast keeps its own `role` (`alert` for error and warn, `status` otherwise), holds five at most and
  drops the oldest. The context menu (`.ctx-menu`, `role="menu"` `aria-label="VM actions"`) opens at the pointer or under the focused row
  (Shift+F10 or the Menu key), focuses its first enabled item, moves with Arrow/Home/End, closes on Escape (focus returns to the row without
  deselecting the VM), on an outside click and after an item runs. The palette (`#palette`, `#paletteInput` combobox, `#paletteList`
  listbox of `li[data-pidx]` with `aria-activedescendant`) is a modal `Dialog`; Enter or a click runs the chosen command after the palette
  has closed, so a dialog it opens keeps focus.
- **Preact dialogs are removed from the DOM when closed**, so `#confirmdlg`, `#promptdlg`, `#aboutdlg`, `#shortcutsdlg`, `#logdlg`,
  `#prefsdlg`, `#newdlg`, `#importdlg`, `#clonedlg`, `#snapdlg`, `#migratedlg`, `#vnetdlg`, `#topodlg`, `#catalogdlg` and `#palette` exist only
  while open (a test asserts `toHaveCount(0)`, not hidden). `dlg.close()` on one still works: the `Dialog` replaces it with the guarded,
  animated close, which is what the Escape sweep calls. Preferences applies the theme as it is picked and puts the original back on every
  close except a save. New VM, Import and Migrate validate inline (`aria-invalid` on the control, message in `#err_<field id>`), focus the
  first bad field on submit, and disable the submit button while the request is pending; none has a dirty guard. The network list is a
  `role="listbox"` with a roving tab stop and Arrow/Home/End. The Snapshot Manager reverts only with the VM powered off, and a successful
  revert closes it.
- **Vendored-bundle globals are not their class:** `noVNC` exposes the RFB class as `noVNC.default` (NOT `noVNC.RFB`); SPICE uses
  `SpiceHtml5.SpiceMainConn`; elk is `ELK`. Resolve `noVNC.default ?? noVNC.RFB` (`ui/lib/display.ts`) so a re-vendor can't silently
  break the console.
- VM data comes from `GET /api/vms`; a field absent from the list JSON is not on the `Vm` record, emit it in `vmrender`.
- UI terminology: VMware Workstation ("Power On/Off", "Take Snapshot", "VM Library", …).

## Work Guidance
- **Every user-facing workflow needs a Playwright e2e** in `../../tests/e2e/*.test.ts`, added alongside the feature. A new flow
  without one is incomplete.
- Any change under this folder needs a `zig build` (the bundle is embedded) and a binary check if anything looks stale (see root
  AGENTS.md, Testing).

## Verification
`bun run test` (pure logic in `ui/lib`), `bun run lint`, `bun run typecheck`, `bun run check:contrast`, `zig build web-e2e` (Playwright;
standalone, not in `zig build test`). Check the trailing **failed** count, not just `N passed`. `bun tests/visual/screenshots.ts` captures
key views to confirm look.

Validate the hand-written HTML/CSS before shipping (requires the `vnu` validator; not a CI step). Missing prerequisites mean validation is
blocked, not passed. Require zero errors and warnings:

```bash
vnu --format text src/web/index.html docs/brand/icons.html
vnu --css --format text docs/brand/brand.css
```

Tailwind output (`dist/ui.css`) and the vendored `xterm.css` are not validated: the validator rejects xterm's valid `text-decoration`
shorthand (`overline underline`); do not edit the bundle to satisfy validation.

## Notes
If a WebSocket sticks in CONNECTING under headless Chromium, suspect the server's 101 response before the client: malformed CRLF there
breaks every console at once (`ws.zig` has regression tests for it). The live-console e2e boots a real guest headlessly and asserts
canvas + serial connect.

## Child DOX Index
- [ui/AGENTS.md](ui/AGENTS.md): Preact + Tailwind v4 + shadcn-style source, session logic and tokens, bundled to `dist/`.

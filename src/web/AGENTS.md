# AGENTS.md: src/web (embedded web UI)

## Purpose
The browser UI, hand-written vanilla JS/CSS/HTML (no framework, no build step),
`@embedFile`'d into the daemon and served by `web_server.zig`. Targets VMware
(vSphere/Workstation) admin conventions.

## Ownership
- `index.html`: markup, dialogs, the inline SVG icon sprite (`#i-*`), script tags.
- `app.js`: refresh poll, render, action dispatch, dialogs,
  console/serial viewers, command palette, folders, topology.
- `app.css`: flat slate theme (`:root` dark default + `:root.light`) + components.
  Logo and empty-state emblems use the shared accent and radius tokens, without
  decorative gradients or colored shadows.
- Vendored libs: `novnc.js`, `spice.js`, `elk.js`, `van.js` (vanjs-core, ESM export
  converted to `window.van`), `xterm.js`/`xterm.css`/`xterm-fit.js`/`xterm-webgl.js`
  (@xterm UMD builds), `favicon.svg`. Each is `@embedFile`'d, served at `/novnc.js`
  etc, and listed in `auth.isAuthExempt`.
  - **Provenance:** every bundle starts with a header comment naming package@version
    + license + vendor date. Versions for `elk`/`van`/`xterm*` are pinned as exact
    devDependencies in `../../package.json` (+ `bun.lock`); re-vendor by bumping there,
    running `bun install`, copying the dist file in, and updating the header.
    `novnc.js`/`spice.js` have no registry pin (upstream version not recorded at
    vendor time): record upstream + date in their headers when re-vendoring.
  - Treat bundles as binary: never hand-edit code inside them; only prepend/adjust
    the metadata header.

## Local Contracts
- **Tokens are the only place a visual value is written.** `:root` and
  `:root.light` each declare the full set: surfaces, `--inset` (the recessed
  fill behind capacity bars, spec chips, and disabled controls), `--font-sans` /
  `--font-mono`, and the 5/8/11px `--radius-sm` / `--radius` / `--radius-lg`
  scale. Never hardcode a radius, an inset gray, or a font stack in a rule or a
  `style=` attribute, and never write a fallback like
  `var(--inset,rgba(127,127,127,.18))` for a token `:root` already owns. The sans
  is the platform UI stack on purpose: this is a desktop-style operator console,
  not a document surface, and a webfont would render unlike the surrounding
  desktop.
- **Iconography is the inline sprite set.** Every control uses a `#i-*` symbol
  via `<svg class="ico"><use href="#..."/></svg>`. A control that shows state
  (the theme toggle) swaps the `<use href>` between symbols; it never replaces
  the button contents with text. A platform emoji in a control is a defect: it
  ignores the accent and radius tokens and renders at the platform's whim.
- **Emblem radius follows emblem size**: 20px `.os-badge` -> `--radius-sm`,
  30px `.vm-emblem` and 34px `.snap-emblem` -> `--radius`, 44px `.cat-emblem` ->
  `--radius-lg`. The four read as one family; never round them independently.
- **Dialog chrome comes from the `dialog h3` / `.dialog-body` rules**, not from
  a per-dialog inline style. Do not add `!important` to the dialog rules to win
  a cascade fight; the remaining `!important` in the sheet are `#display`
  stacking overrides and the reduced-motion block.
- **Stat tiles are not interactive.** `.dash-card` carries no hover transform;
  reserve elevation-on-hover for things that can be pressed.

- **UI patterns** (keep consistent when adding surfaces): menu items are
  `<button class="menu-item">` with a leading 13px `.ico` sprite svg and trailing `…`
  for dialog-openers; dialog footers are `.btn-row` (right-aligned, primary last,
  destructive `.btn.danger` grouped left when present). Destructive-action rule:
  recoverable deletes use the undo toast (`toastUndo`), irreversible operations
  (snapshot revert, disk ops) use `showConfirmDialog({danger:true})`. Don't mix.

- **Navigation**: Tools stays available without a selected VM; only VM-specific
  entries are disabled. Responsive toolbar hiding applies to direct toolbar buttons,
  not the buttons inside More. Context-menu actions stop when selection is cancelled.
- **Power actions**: toolbar, batch and multi-select requests use `/start` or `/stop`,
  never `/power`, so duplicate delivery cannot reverse the requested state. Capture
  the toolbar's intended state before confirmation and re-resolve its VM afterward.
- **RAM capacity**: compare committed and physical memory in exact MiB; round only
  display labels, never the quantities used for overcommit or gauge ratios. Every
  memory label goes through `memText(mb)` (or `memGiB(mb)` for a bare number):
  the daemon sends MiB, the `/1024` step is binary, so a scaled value is `GiB`.
  Never hand-roll a memory conversion or label a MiB total "GB".
- **Library search**: list redraws preserve the search input's current query.
- **VM uptime**: display the daemon's monotonic `uptime_sec`, including zero.
  Never subtract `started` from the browser clock; omit unavailable durations.
- **Network saving**: Save All validates and includes the selected network's current
  form values without requiring Save Selected first. Invalid values leave the editor
  open and do not send a save request.
- **Topology loading**: `/elk.js` loads only when the topology opens, never from
  `index.html`. Concurrent opens share the pending load. Loading is visible; failed,
  invalid, or timed-out loads expose Retry and clear the pending promise.
- **Reactivity**: `GET /api/events` (SSE) pushes a change event whenever the daemon's
  state version bumps; the client refreshes on it (5s poll stays as fallback). The host
  dashboard is a VanJS component driven by `vmsState`/`dashSortState`. Update state,
  never rebuild its innerHTML. The console (`#display` + `#serialpanel`) lives inside
  `#tabConsole`; hints go to `#consoleHint` (renders must not wipe the panel). The serial
  terminal is xterm.js (bidirectional, `onData` → WS → guest; WebGL renderer with
  built-in fallback); export reads the `serialBuf` shadow buffer, not the DOM.
- **Strict CSP** (`script-src 'self'`): NO inline event handlers. All actions go through
  the delegated body click → `el.closest('[data-action]')` → `actionHandlers[action](el)`.
  Keyboard activation for `role=button`/`th[data-action]` is the global keydown delegator.
- **XSS:** every user string passes `escHtml()` before `innerHTML`, including SVG text
  AND attribute values (the topology builds `data-*` from VM/network names). No exceptions.
- **Index-after-await is stale:** the 5s `refresh()` replaces `vms[]` wholesale. Any
  action that resolves a VM after an `await` must re-resolve by stable id (`idxById`,
  survives rename) or name (`idxByName`), never a frozen index. Multi-select keeps
  `checkedIds`; migration tracks `migId`.
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
`zig build web-e2e` (Playwright; standalone, not in `zig build test`). Check the
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

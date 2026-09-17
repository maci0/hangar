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
  display labels, never the quantities used for overcommit or gauge ratios.
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
Headless Chromium completes WebSockets to the daemon fine, if a WS sticks in
CONNECTING, suspect the server's 101 response first (a Zig multiline literal once
emitted literal `\r` text instead of CRLF and broke every console; `ws.zig` has
regression tests). The live-console e2e boots a real guest headlessly and asserts
canvas + serial connect.

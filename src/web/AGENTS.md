# AGENTS.md: src/web (embedded web UI)

## Purpose
The browser UI, hand-written vanilla JS/CSS/HTML (no framework, no build step),
`@embedFile`'d into the daemon and served by `web_server.zig`. Targets VMware
(vSphere/Workstation) admin conventions.

## Ownership
- `index.html`: markup, dialogs, the inline SVG icon sprite (`#i-*`), script tags.
- `app.js` (~1750 lines), all behavior: refresh poll, render, action dispatch, dialogs,
  console/serial viewers, command palette, folders, topology.
- `app.css` (~1150 lines): theme (`:root` dark default + `:root.light`) + components;
  a trailing "serious flat reskin" override block wins by cascade order.
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
  binary check if anything looks stale (see src/AGENTS.md cache note).

## Verification
`zig build web-e2e` (Playwright; standalone, not in the hermetic `test`). Check the
trailing **failed** count, not just `N passed`. `bun tests/visual/screenshots.mjs`
captures key views to confirm look.

Markup and stylesheet validation (no CI gate: it needs a JVM, run it before shipping
a change to these files):

```bash
bun add -g vnu-jar   # once
java -jar ~/.bun/install/global/node_modules/vnu-jar/build/dist/vnu.jar --format text src/web/index.html
java -jar ~/.bun/install/global/node_modules/vnu-jar/build/dist/vnu.jar --css --format text src/web/app.css
```

`index.html` and `app.css` are clean. Do **not** run it over `xterm.css`: vnu's CSS
profile is CSS 2.1 and rejects the valid Level 3 `text-decoration` shorthand
(`overline underline`) the vendored bundle uses; the bundle is not ours to edit.

## Notes
Headless Chromium completes WebSockets to the daemon fine, if a WS sticks in
CONNECTING, suspect the server's 101 response first (a Zig multiline literal once
emitted literal `\r` text instead of CRLF and broke every console; `ws.zig` has
regression tests). The live-console e2e boots a real guest headlessly and asserts
canvas + serial connect.

# AGENTS.md — src/web (embedded web UI)

## Purpose
The browser UI, hand-written vanilla JS/CSS/HTML (no framework, no build step),
`@embedFile`'d into the daemon and served by `web_server.zig`. Targets VMware
(vSphere/Workstation) admin conventions.

## Ownership
- `index.html` — markup, dialogs, the inline SVG icon sprite (`#i-*`), script tags.
- `app.js` (~1200 lines) — all behavior: refresh poll, render, action dispatch, dialogs,
  console/serial viewers, command palette, folders, topology.
- `app.css` (~1150 lines) — theme (`:root` dark default + `:root.light`) + components;
  a trailing "serious flat reskin" override block wins by cascade order.
- Vendored libs (do not hand-edit; treat as binary): `novnc.js`, `spice.js`, `elk.js`,
  `favicon.svg`. Each is `@embedFile`'d, served at `/novnc.js` etc, and listed in
  `auth.isAuthExempt`.

## Local Contracts
- **Strict CSP** (`script-src 'self'`): NO inline event handlers. All actions go through
  the delegated body click → `el.closest('[data-action]')` → `actionHandlers[action](el)`.
  Keyboard activation for `role=button`/`th[data-action]` is the global keydown delegator.
- **XSS:** every user string passes `escHtml()` before `innerHTML` — including SVG text
  AND attribute values (the topology builds `data-*` from VM/network names). No exceptions.
- **Index-after-await is stale:** the 5s `refresh()` replaces `vms[]` wholesale. Any
  action that resolves a VM after an `await` must re-resolve by stable id (`idxById`,
  survives rename) or name (`idxByName`) — never a frozen index. Multi-select keeps
  `checkedIds`; migration tracks `migId`.
- **Vendored-bundle globals are not their class:** `noVNC` exposes the RFB class as
  `noVNC.default` (NOT `noVNC.RFB`); SPICE uses `SpiceHtml5.SpiceMainConn`; elk is `ELK`.
  Resolve `noVNC.default || noVNC.RFB` so a re-vendor can't silently break the console.
- VM data comes from `GET /api/vms` (the list render); the detail tab uses the same fields.
  A field absent from the list JSON is `undefined` in `app.js` — emit it in `vmrender`.
- UI terminology: VMware Workstation ("Power On/Off", "Take Snapshot", "VM Library", …).

## Work Guidance
- **Every user-facing workflow needs a Playwright e2e** in `../../tests/e2e/workflows.spec.mjs`,
  added alongside the feature. A new flow without one is incomplete.
- Editing `app.js`/`app.css`/`index.html` requires a `zig build` (they are embedded) and a
  binary check if anything looks stale (see src/AGENTS.md cache note).

## Verification
`zig build web-e2e` (Playwright; standalone, not in the hermetic `test`). Check the
trailing **failed** count, not just `N passed`. Screenshot key views to confirm look.

## Notes
Headless Chromium completes WebSockets to the daemon fine — if a WS sticks in
CONNECTING, suspect the server's 101 response first (a Zig multiline literal once
emitted literal `\r` text instead of CRLF and broke every console; `ws.zig` has
regression tests). The live-console e2e boots a real guest headlessly and asserts
canvas + serial connect.

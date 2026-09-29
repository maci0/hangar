# AGENTS.md: src/web/ui (Preact + Tailwind source)

## Purpose
The whole browser UI as typed source: the page, the session logic that talks to the daemon,
Preact components, shadcn-style primitives and the Tailwind v4 entry sheet. Bundled by
`scripts/build-web.ts` into `src/web/dist/ui.js` and `ui.css` (gitignored), which
`web_server.zig` embeds and serves as `/ui.js` and `/ui.css`. `../index.html` is only the
`#app` mount and the two tags.

## Ownership
- `main.tsx`: entry, one call to `app/start.ts`.
- `bridge.tsx`: `ui`, the one object from app code to the components. It merges the surface bridges
  (`shell.tsx`, `panels.tsx`, `console-bridge.tsx`, the dialog store) and `ui.mount(handlers)` draws
  the page. Components never import `app/`; the app never renders JSX. State goes down as props
  (`ui.setShell`, `setToolbar`, `setSummary`, `setConsole`, `openX(request)`), and the callbacks a
  surface needs travel in `UiHandlers` (bound once by `mount`) or inside the request that opens it.
- `app/`: the session, one module per concern, no import cycles (lower layers first):
  - `state.ts`: the `state` record (VM list, selection, active tab, select mode, status text, flags)
    and `indexOfId`, `indexOfName`, `selectedVm`. The poll replaces `vms` wholesale, so any code that
    resolves a VM after an `await` looks it up again by id (`indexOfId`, survives rename) or name; never
    trust a frozen index. Multi-select keeps `checkedIds`; the migration controller follows its VM by id.
  - `feedback.ts`: `syncShell` (derives the chrome state from `state` and pushes it), status text
    (`setStatus` announces, `setStatusText` is passive, `setStatusLoading` pulses), `showToast`, `toastUndo`,
    the load bar. `api.ts`: `apiPost` (adds `X-API-Key`, one write at a time, status and toast on failure).
    `console-host.ts`: what the console controllers use from the session (`sendCad`, `consoleHost`).
  - `view.ts`: pushes state to the surfaces: `renderList`, `renderDetails`, `showEmptyState`, `syncToolbar`,
    `syncConsole`, `updateCommandState`, and the guest-IP, disk-usage and host lookups.
  - `poll.ts`: `refresh` (poll, connection banner, follows a status change of the selected VM), `reloadList`,
    `showTab`. `settings-tools.ts`: the CD/ISO and disk buttons of the Settings tab.
    `session.ts`: `select`, `deselectVm`, `switchTab`, `editVm`, the Settings save, `confirmDiscard`.
    `sidebar.ts`: sidebar overlay and collapse.
  - `vm-actions.ts`: power, guest control, rename, export, screenshot. `library.ts`: create, import, clone,
    delete with undo, favorites, folders, reorder, search, select mode, bulk and batch operations.
    `dialogs.ts`: snapshots, log, preferences, about, catalog, virtual networks and topology.
  - `menus.ts`: context menu, command palette, theme toggle. `keyboard.ts`: global shortcuts.
    `handlers.ts`: builds `UiHandlers` (the only place that wires components to actions).
    `start.ts`: theme and folder state, mount, first draw, key handlers, poll, SSE.
  - Refresh loop: `refresh()` on load, every 5 s, on tab visibility and 120 ms after each `/api/events`
    `change`; `#livebadge` follows the stream, the poll is the fallback. A network or 5xx failure shows
    `#connbanner` (a 4xx does not). It stands still while a write, a Settings save, a reorder or a power
    change is running.
- `components/ui/`: shadcn-style primitives (cva variants, `cn` merge): `button.tsx`, `textarea.tsx`, `menu.tsx`
  (`Menu` positions under an anchor and handles Arrow/Home/End; `MenuItem`; `MenuSeparator`), `dialog.tsx`, and
  the form controls `input.tsx` (takes `inputRef`, not `ref`: Preact binds `ref` on a function component to the
  component), `select.tsx`, `label.tsx`, `field.tsx` (`Field`, `FieldError`, `InputField` with its `err_<id>` line,
  `invalidProps`, `focusFirstInvalid`). `Dialog` is a native `<dialog>` opened with `showModal()`: Escape, backdrop
  click and `dlg.close()` all run the optional `guard` (may return a promise; false keeps it open), then the exit
  animation, then close; focus returns to the opener. `DialogClose` (a `data-action="closeDlg"` test hook),
  `useDialogClose()` and `useDialogTask()` (busy flag; closes when the task resolves true) compose it. Build a
  dialog from these, never a bare `<dialog>`. `components.json` at the repo root maps the shadcn CLI aliases here.
- `components/app-shell.tsx`: the page grid: skip link, banner, sidebar (`SidebarPane`), toolbar, VM header, the
  three tab panels, status bar. Panels the other bridges draw are empty mounts (`#console-root`, `#summary-root`,
  `#settings-root`, `#mig_bar_container`, `#overlay-root`, `#displayonly-root`, `#dialog-root`); Preact leaves
  foreign children alone. The sidebar is `collapsed` (wide) or `overlayOpen` (below 900px) from `ShellState`.
  `shell.tsx` holds `ShellState` and draws `AppShell` into `#app`; `createOverlayBridge` owns toasts and the context
  menu. Tab panels hide with the `hidden` class from `header.activeTab`, and `displayonly:` utilities reshape the
  page for display-only mode (a `displayonly` class on `body`).
- `components/`: `vm-list.tsx` (rows, folders, favorites, roving tab stop; `vm-list-reorder.ts` is mouse and touch
  drag), `sidebar.tsx`, `vm-header.tsx`, `status-bar.tsx`, `toolbar.tsx` (five action menus plus the More popover;
  every entry is a typed `MenuAction` with a handler in `ToolbarHandlers.menu` and keeps `data-action=<name>` as a test
  hook), `theme-toggle.tsx`, `toasts.tsx`, `context-menu.tsx`, `dashboard.tsx`, `summary.tsx`, `settings.tsx`,
  `console.tsx`, `display-only-bar.tsx`, `migration-bar.tsx`, `empty-state.tsx`, `library-actions.tsx`, `vm-parts.tsx`,
  `icon.tsx` (sprite symbol). `panels.tsx` draws the Summary (welcome, dashboard, VM) and the Settings form with
  `PanelHandlers`. `console-bridge.tsx` draws the Console tab, display-only bar and migration bar and owns the
  display, serial and migration controllers (`initConsole(host)` once, then `setConsole({vm, actionReason, sendCad})`).
- `components/dialogs/`: `confirm`, `prompt`, `about`, `shortcuts`, `log`, `prefs`, `new-vm`, `import`, `clone`,
  `snapshots`, `migrate`, `vnets`, `topology`, `catalog`, `palette` and `host.tsx` (`Dialogs`, drawn into `#dialog-root`).
  `bridge.tsx` keeps which are open. Every action callback resolves whether the dialog may close; dialogs own their form
  state and validation. `ui.confirm(message, {danger, okLabel})` and `ui.prompt(label, initial, suggestions)` return
  promises (a newer call resolves the older one as cancelled). Dialogs are removed from the DOM when closed.
- Buttons whose `data-action` stays: toolbar menu entries, `deselectVm`, `editVm`, `toggleSelectMode`, `bulkPower`
  (with `data-on`), `bulkDelete`, `closeDlg`, `openTopology`, the `vnet*` editor buttons, `refreshLog`, `viewLog`,
  `takeScreenshot`, the Settings tools (`resizeDisk`, `compactDisk`, `changeCd`, `ejectCd`, `disk2upload`,
  `disk2download`), the console buttons (`enterDisplayOnly`, `reconnectDisplay`, `reconnectSerial`, `exitDisplayOnly`),
  `cancelMigrate`, `openCatalog`, `sortInv` and `setSettingsCategory`. They exist for the e2e tests and are never read by the
  app; every click is a direct handler.
- `lib/`: pure logic, each with a `*.test.ts`: `format` (memory, bytes, labels), `vm` (the `Vm` record as `GET /api/vms`
  returns it, config flags as `"true"`/`"false"` strings), `inventory` (`parseVmList`, `buildVmList`, status line,
  uptime), `actions` (`actionAllowed`, `disabledReason`, `actionReason`), `folders`, `snapshots`, `topology` (elk input
  graph and layout), `catalog`, `prefs`, `wire` (decoders for the small JSON documents; wrong-typed fields read as
  absent), `api` (`API_KEY`, `errorText`, `responseError`), `os-brand`, `theme` (`system`/`light`/`dark`, class on
  `<html>`, `localStorage` `hangar-theme`), `dashboard`, `settings` (field catalogue, `settingsBody` payload and key
  order, validation), `vnet`, `network`, `console`, `migration`, `assets` (`ensureAsset`, `ensureStylesheet`),
  `vendor.d.ts` (globals of the vendored bundles), `cn`. Display, serial, presenter and video controllers are plain state
  records plus small functions that publish a typed state and touch no Preact node except through refs. Storage access
  goes through promises so a blocked `localStorage` never breaks the page.
- `styles.css`: the Tailwind entry and the single home of design tokens. The first `@theme static` block is the
  dark palette (`--bg`, `--surface`, `--text`, `--accent`, `--danger`, shadows, `--backdrop` ...); `:root.light`
  in `@layer base` overrides the same names; `bun run check:contrast` reads both. The second `@theme static` block
  holds radii, fonts, breakpoints (`compact` 1100px, `narrow` 900px, `phone` 520px), animations, the type steps
  `text-caption` (11px), `text-field` (13px), `text-title` (15px), `text-heading` (17px) and `--blur-dialog`.
  `@theme inline` exposes tokens as colors and shadows (`bg-surface`, `text-fg-muted`, `shadow-card` ...). Preflight
  is the reset, `@layer base` holds the body defaults, scrollbars and the reduced-motion rule, `@layer components`
  the `.ico` sprite size. Custom utilities: `grid-cols-app*`, `grid-cols-vm-row*`, `grid-cols-catalog`, `-summary`, `-tiles`,
  `-fields`, `-settings`, `-gauge` (the shadcn lint rejects arbitrary values), `scrollbar-quiet`, `scrollbar-gutter-auto`,
  `display-surface` (canvases the vendored clients append to `#display`), `xterm-host`, `empty-hint`, `no-search-cancel`;
  variants `displayonly` and `no-hover`. Class names are scanned from this folder only (`@source "./"`).

## Local Contracts
- Tokens are written only in `styles.css`. No hex, px radius or font stack in a component (an OS brand color from
  `lib/os-brand.ts` is data, not a token).
- `cn` is `twMerge`: it reads the custom type steps (`text-caption`) as text colors and drops one of a pair. Where a type
  step and a `text-fg-*` color must both apply, write the class string without `cn` (`vm-list.tsx` uses `clsx`).
- Strict CSP (`script-src 'self'`): no inline handlers; every action is a direct handler prop or a listener added in code.
- XSS: user strings reach the DOM only through Preact text and attribute nodes, which escape them. No `innerHTML`.
- Daemon payloads: bodies stay form-encoded exactly as before (`settingsBody` key order; `/api/networks` is JSON);
  power actions from the toolbar, batch and bulk use `/start` and `/stop`, never `/power`.
- Toolchain is Bun only. `bun run lint` (oxlint strict preset, Rika anti-slop, `@shadcn/lint`), `bun run typecheck`,
  `bun run build:web` and `bun run test` pass with no disabled rules. oxlint is pinned to 1.57.0 because the Rika 0.8.1
  preset names rules that later oxlint versions dropped; move both together. Function components and helpers are `const`
  arrow functions. Decode daemon JSON with explicit checks (`lib/wire.ts`, type guards), not casts.

## Work Guidance
- New surface: build the component with its handlers as props, push its state through `ui`, wire the handler in
  `app/handlers.ts` (or the request that opens it), add the e2e in the matching `tests/e2e/*.test.ts` in the same change.
- New daemon call: use `apiPost` for writes so the gate, status text and error toast apply.
- Pure logic goes in `lib/` with a test beside it.

## Verification
`bun run lint && bun run typecheck && bun run test && zig build web-e2e`.

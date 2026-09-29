# AGENTS.md: tests

## Purpose
Integration + end-to-end suites that exercise the real built binary. Distinct from
the in-module unit/fuzz tests (those live at the bottom of each `src/*.zig` and run
under `zig build test`, and the `*.test.ts` files beside `src/web/ui` sources that run
under `bun run test`).

## Ownership
- `e2e/*.test.ts`: Playwright UI e2e, TypeScript, linted and type-checked with the rest of the
  repo (`bun run lint`, `bun run typecheck`). Drive the built `hangar-web` on a dedicated port
  against a temp `$HOME` (config: `../playwright.config.ts`, fresh `.scratch/hangar-e2e-<uuid>`
  HOME per run under the repo's gitignored `.scratch/`, never the OS temp dir, which is tmpfs).
  One file per area:
  - `web.test.ts`: page load, create VM, dialogs open, shortcuts, theme cycle, reorder API.
  - `lifecycle.test.ts`: VM lifecycle over the API and the toolbar (power, clone, rename, delete and
    undo, snapshots, disk and CD tools, OVF export, tags, auth), the uptime line against a mocked
    inventory, the `/ui.js` bundle check, Tools from Home at desktop and phone width.
  - `networks.test.ts`: Virtual Network Editor, Network Topology (lazy `elk.js`), VM Catalog.
  - `dialogs.test.ts`: confirm and prompt dialogs driven through real delete, compact, move and
    rename flows, preferences, About, QEMU log, New VM, Import, Clone, Snapshot Manager, Migrate.
  - `settings.test.ts`: Settings tab (validation, dirty guard, disk and CD tools) and Summary tab.
  - `library.test.ts`: folders, inventory table sorting, host capacity gauges.
  - `shell.test.ts`: VM header tabs, search clear, select mode, status bar, connection banner,
    toasts, context menu, command palette, toolbar menu keyboard use.
  - `console.test.ts`: real guests: VNC and serial connect, SPICE, the H.264 overlay (skipped
    without ffmpeg), noVNC failure and Retry, reconnect, display-only mode, serial resize keys and
    Disconnect. The console empty-state message and the migration bar run against mocked routes.
  - `a11y.test.ts`: axe WCAG 2.2 AA gate over dashboard, VM summary, every settings section (with a
    validation error and a warning showing), the command palette, the context menu and a stack of
    real toasts, plus the New VM, Import, Clone, Snapshot Manager, Migrate, Virtual Network Editor
    (validation error showing), Network Topology and VM Catalog dialogs, in both themes. A live
    console test boots a guest and scans the Console tab and display-only mode in both themes.
  - `config.test.ts`: checks Playwright daemon environment isolation; `print-config.ts` is the child
    script it runs to load the config under a synthetic environment.
  - `daemon-api.ts`: `api()` (fetch from inside the page with the API key), `listVms`, `createVm`,
    `removeVms`, `vmField` and JSON decoding. `app-ui.ts`: the real UI paths the specs share
    (toolbar menus, F5 refresh, themes, the topology dialog, a mocked inventory via `overrideVm`).
    Neither is a spec.
- `test_web_api.sh`: HTTP API integration (spawns a real daemon). Its
  `--startup-only` mode checks invalid runtime settings in both executables before
  VM configuration reads or backend spawning, without starting a listener.
- `test_vmrun.sh`: `vmrun` CLI integration (spawns a real daemon). A failed build
  aborts before checking or launching binaries, even when stale artifacts exist.
- `visual/screenshots.ts`: screenshot capture for the README and eyeballing a visual
  change. Images only, no assertions, so it is not a gate.

## Local Contracts
- These are **standalone** steps, NOT part of `zig build test`. They spawn real
  daemons / launch Chromium. The unit/fuzz suite uses local sockets and optional
  QEMU subprocesses, but no browser.
- One-time setup before first Playwright run: `bun install --frozen-lockfile` + `bun run e2e:install` (Chromium). The build requires the repository-local Playwright CLI; it never downloads a fallback runner. The `web-e2e` step preflights `node_modules/@playwright/test/cli.js` and names those two commands instead of failing with a bare module-not-found.
- Playwright runs under Bun (`bun ./node_modules/@playwright/test/cli.js test`, which `bun run e2e` and `zig build web-e2e` both use); the config and specs read `Bun.env`, `Bun.file` and `Bun.spawnSync`, never `node:` modules. Spec files are named `*.test.ts` (the lint preset requires it). Do not run a bare `bun test` from the repo root: it would load these specs into Bun's own runner.
- `bun run lint` covers `tests/` and `playwright.config.ts` with the same strict rules as `src/web/ui`, with no blanket disables. Keep each test function under 60 lines by moving steps into named helpers; type `page.evaluate` results and narrow JSON from `unknown` instead of casting.
- **Every user-facing web workflow gets an e2e here** (project rule). Add it with the feature.
- **Drive the real UI.** The app exposes no test-only globals and no `window` action functions. Specs use the real controls: toolbar menus by `[data-menu="<id>"]:visible` then `#<id> [data-action="<name>"]`, F5 (blur first, wait for `GET /api/vms`) for a refresh, Delete, F11, Shift+F10, `?` and Ctrl+K shortcuts, the Tools menu for dialogs, and the theme toggle or `localStorage["hangar-theme"]` plus a reload for themes. A state the daemon cannot produce cheaply (a running guest, an uptime, a server error) is mocked with `page.route` on the daemon response, never by patching the page.
- Hooks the specs rely on: `data-action` on toolbar menu items, `deselectVm`, `editVm`, `toggleSelectMode`, `bulkPower` (with `data-on`), `bulkDelete`, `closeDlg`, `openTopology`, `vnet*`, `refreshLog`, `viewLog`, the settings tools, `enterDisplayOnly`/`reconnectDisplay`, `cancelMigrate`, `openCatalog`, `sortInv`, `setSettingsCategory`. Everything else is reached by id, class or role (`#powerbtn`, `#savevmbtn`, `#tab-btn-<tab>`, `.vm-item`, `.vm-row .star`, `.folder-hdr[data-folder]`, `#search`, `#searchClear`, `.vm-check`, `.theme-toggle-btn`, `.new-vm-btn`, dialogs as `#<name>dlg`, removed from the DOM when closed).
- The shared daemon holds 64 VMs at most (`MAX_VMS`), so a test deletes the VMs it creates (`removeVms` in `daemon-api.ts`); tests that open the palette wait for the VM list first because it lists the VMs loaded when it opens.
- The toast stack overlays the right end of the toolbar, so a spec that needs a toolbar menu raises its toasts after the menu steps, or uses a keyboard shortcut.
- Status text asserted after an action reads `#statusannounce`; `#statusmsg` is overwritten by the passive VM count on every refresh.
- When reading results, check the **failed** line, not only the trailing `N passed`
  (a "1 failed" line prints above the pass count).

## Work Guidance
Commands (from repo root):
- `zig build web-e2e`: Playwright suite (builds first).
- `bun run e2e -- tests/e2e/<file>.test.ts`: one spec file against an already built binary (`-g <title>` filters by title).
- `bun tests/visual/screenshots.ts [--port N]`: screenshots into `tests/visual/screenshots/`.
- `KV_PORT=<p> bash tests/test_web_api.sh`: API plus startup validation.
- `bash tests/test_web_api.sh --startup-only`: startup validation only, no daemon.
- `bash tests/test_vmrun.sh`: vmrun integration.
Before daemon-backed commands, satisfy the root Safety rules: a non-default port
alone does not isolate `/tmp/hangar-daemon.sock`. The shell harnesses do not all override
inherited configuration; supply temporary `HOME` and `HANGAR_CONFIG_HOME` with
`KV_API_KEY=hangar`. The Playwright config and the screenshot script do this themselves.
Never blanket-`pkill hangar-web`. Scope cleanup to this run's PIDs. QEMU children can
outlive the daemon and hold VNC ports; track them before stopping it, never kill by
guest name alone.

## Verification
Require exit code 0 and zero failures from each requested suite. Check Playwright's
skipped tests too: the video-stream test skips without ffmpeg. Pass counts change
as tests are added; a historical count is not an acceptance criterion.
Inspect `git status` for unintended artifacts; do not discard pre-existing changes.

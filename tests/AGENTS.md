# AGENTS.md — tests

## Purpose
Integration + end-to-end suites that exercise the real built binary. Distinct from
the in-module unit/fuzz tests (those live at the bottom of each `src/*.zig` and run
under `zig build test`).

## Ownership
- `e2e/workflows.spec.mjs`, `e2e/web.spec.mjs` — Playwright UI e2e. Drive the built
  `hangar-web` on a dedicated port against a temp `$HOME` (config: `../playwright.config.mjs`,
  fresh `mkdtemp` HOME per run).
- `test_web_api.sh` — HTTP API integration (spawns a real daemon).
- `test_vmrun.sh` — `vmrun` CLI integration (spawns a real daemon).
- `visual/e2e_web_screenshots.mjs` — screenshot capture flow.

## Local Contracts
- These are **standalone** steps, NOT part of the hermetic umbrella `zig build test`
  (which stays network/browser-free). They spawn real daemons / launch Chromium.
- One-time setup before first Playwright run: `npm install` + `npm run e2e:install` (Chromium).
- **Every user-facing web workflow gets an e2e here** (project rule) — add it with the feature.
- When reading results, check the **failed** line, not only the trailing `N passed`
  (a "1 failed" line prints above the pass count).

## Work Guidance
Commands (from repo root):
- `zig build web-e2e` — Playwright suite.
- `KV_PORT=<p> bash tests/test_web_api.sh` — API (expect 23 passed).
- `bash tests/test_vmrun.sh` — vmrun (expect 25 passed).
Run real daemons on a non-default `KV_PORT`; never blanket-`pkill hangar-web` (kills a
user's running daemon) — scope cleanup to the test port/PID. Killing a test daemon
orphans its QEMU children, which keep holding VNC ports; clean those by guest name.

## Verification
Green = `zig build test` RC 0 · api 23/0 · vmrun 25/0 · Playwright 0 failed · tree clean.

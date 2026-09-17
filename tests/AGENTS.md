# AGENTS.md: tests

## Purpose
Integration + end-to-end suites that exercise the real built binary. Distinct from
the in-module unit/fuzz tests (those live at the bottom of each `src/*.zig` and run
under `zig build test`).

## Ownership
- `e2e/workflows.spec.mjs`, `e2e/web.spec.mjs`: Playwright UI e2e. Drive the built
  `hangar-web` on a dedicated port against a temp `$HOME` (config: `../playwright.config.mjs`,
  fresh `mkdtemp` HOME per run, created under the repo's gitignored `.scratch/`, never
  `os.tmpdir()`, which is tmpfs).
- `e2e/config.spec.mjs`: checks Playwright daemon environment isolation. The
  daemon pins `HANGAR_CONFIG_HOME` to its test HOME and `KV_API_KEY` to `hangar`,
  overriding operator settings while preserving the `KV_PORT` selector.
- `test_web_api.sh`: HTTP API integration (spawns a real daemon). Its
  `--startup-only` mode checks invalid runtime settings in both executables before
  VM configuration reads or backend spawning, without starting a listener.
- `test_vmrun.sh`: `vmrun` CLI integration (spawns a real daemon).
- `visual/screenshots.mjs`: screenshot capture for the README and eyeballing a visual
  change. Images only, no assertions, so it is not a gate.

## Local Contracts
- These are **standalone** steps, NOT part of `zig build test`. They spawn real
  daemons / launch Chromium. The unit/fuzz suite uses local sockets and optional
  QEMU subprocesses, but no browser.
- One-time setup before first Playwright run: `bun install --frozen-lockfile` + `bun run e2e:install` (Chromium). The build requires the repository-local Playwright CLI; it never downloads a fallback runner.
- **Every user-facing web workflow gets an e2e here** (project rule). Add it with the feature.
- When reading results, check the **failed** line, not only the trailing `N passed`
  (a "1 failed" line prints above the pass count).

## Work Guidance
Commands (from repo root):
- `zig build web-e2e`: Playwright suite.
- `KV_PORT=<p> bash tests/test_web_api.sh`: API plus startup validation.
- `bash tests/test_web_api.sh --startup-only`: 10 startup validation checks.
- `bash tests/test_vmrun.sh`: vmrun integration.
Run real daemons on a non-default `KV_PORT`; never blanket-`pkill hangar-web`.
Scope cleanup to PIDs owned by this run. QEMU children can outlive a killed daemon
and hold VNC ports; track them before stopping the daemon, never kill by guest name
alone (another session may use the same name).

## Verification
Require exit code 0 and zero failures from each requested suite. Check Playwright's
skipped tests too: the video-stream test skips without ffmpeg. Pass counts change
as tests are added; a historical count is not an acceptance criterion.
Inspect `git status` for unintended artifacts; do not discard pre-existing changes.

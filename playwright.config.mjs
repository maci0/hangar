// Playwright e2e config for the Hangar web UI.
//
// Launches the real built `hangar-web` binary on a dedicated port against a
// throwaway $HOME (same isolation model as tests/web_smoke.mjs), then runs the
// specs in tests/e2e against it. Build the binary first: `zig build` (the
// `web-e2e` build step does this for you).
import { defineConfig } from '@playwright/test';
import { mkdirSync, mkdtempSync } from 'fs';
import { resolve } from 'path';

const ROOT = import.meta.dirname;
const BINARY = resolve(ROOT, 'zig-out/bin/hangar-web');
const PORT = process.env.KV_PORT || '19087';
// A throwaway HOME so test runs never touch real ~/.config/hangar state. The
// child server inherits it via the webServer env below. Kept under the repo's
// gitignored .scratch/ rather than os.tmpdir(), which is tmpfs (RAM-backed).
const SCRATCH = resolve(ROOT, '.scratch');
mkdirSync(SCRATCH, { recursive: true });
const TMP_HOME = process.env.HANGAR_E2E_HOME || mkdtempSync(resolve(SCRATCH, 'hangar-e2e-'));
const BASE = `http://127.0.0.1:${PORT}`;

export default defineConfig({
    testDir: './tests/e2e',
    timeout: 30_000,
    expect: { timeout: 8_000 },
    // The UI mutates shared server state (the VM list), so the specs must run
    // serially against the single shared daemon.
    fullyParallel: false,
    workers: 1,
    forbidOnly: !!process.env.CI,
    reporter: [['list']],
    use: {
        baseURL: BASE,
        headless: true,
        actionTimeout: 8_000,
    },
    webServer: {
        command: BINARY,
        url: `${BASE}/api/health`,
        timeout: 20_000,
        reuseExistingServer: false,
        env: { ...process.env, KV_PORT: PORT, HOME: TMP_HOME },
        stdout: 'pipe',
        stderr: 'pipe',
    },
});

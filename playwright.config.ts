/**
 * Playwright e2e config for the Hangar web UI. Launches the real built `hangar-web` binary on a
 * dedicated port against a throwaway $HOME, then runs the specs in tests/e2e against it. Build the
 * binary first: `zig build` (the `web-e2e` build step does this for you).
 */
import { defineConfig } from '@playwright/test';

const ROOT = import.meta.dirname;
const DEFAULT_PORT = '19087';
const DEFAULT_TIMEOUT_MS = 30_000;
const EXPECT_TIMEOUT_MS = 8000;
const ACTION_TIMEOUT_MS = 8000;
const SERVER_START_TIMEOUT_MS = 20_000;

/** The environment variable's value, or `fallback` when it is unset or empty. */
const envOr = (name: string, fallback: string): string => {
    const configured = Bun.env[name];
    return configured === undefined || configured === '' ? fallback : configured;
};

const PORT = envOr('KV_PORT', DEFAULT_PORT);
/**
 * A throwaway HOME so test runs never touch real ~/.config/hangar state. The child server inherits it
 * via the webServer env below. Kept under the repo's gitignored .scratch/ rather than the OS temp
 * dir, which is tmpfs (RAM-backed).
 */
const makeScratchHome = async (): Promise<string> => {
    const home = `${ROOT}/.scratch/hangar-e2e-${Bun.randomUUIDv7()}`;
    await Bun.write(`${home}/.keep`, '');
    return home;
};

const configuredHome = envOr('HANGAR_E2E_HOME', '');
const TMP_HOME = configuredHome === '' ? await makeScratchHome() : configuredHome;
const BASE = `http://127.0.0.1:${PORT}`;

export default defineConfig({
    testDir: './tests/e2e',
    timeout: DEFAULT_TIMEOUT_MS,
    expect: { timeout: EXPECT_TIMEOUT_MS },
    /* The UI mutates shared server state (the VM list), so the specs run serially against one daemon. */
    fullyParallel: false,
    workers: 1,
    forbidOnly: envOr('CI', '') !== '',
    reporter: [['list']],
    use: {
        baseURL: BASE,
        headless: true,
        actionTimeout: ACTION_TIMEOUT_MS,
    },
    webServer: {
        command: `${ROOT}/zig-out/bin/hangar-web`,
        url: `${BASE}/api/health`,
        timeout: SERVER_START_TIMEOUT_MS,
        reuseExistingServer: false,
        env: {
            ...Bun.env,
            KV_PORT: PORT,
            HOME: TMP_HOME,
            HANGAR_CONFIG_HOME: TMP_HOME,
            KV_API_KEY: 'hangar',
        },
        stdout: 'pipe',
        stderr: 'pipe',
    },
});

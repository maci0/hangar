import { expect, test } from '@playwright/test';

const PRINT_CONFIG = new URL('print-config.ts', import.meta.url).pathname;
const CHILD_TIMEOUT_MS = 10_000;

test('daemon config isolates operator state and credentials while preserving the test port', () => {
    const child = Bun.spawnSync([Bun.argv[0] ?? 'bun', PRINT_CONFIG], {
        env: {
            ...Bun.env,
            KV_API_KEY: 'synthetic-operator-key',
            KV_PORT: '19123',
            HANGAR_CONFIG_HOME: '/unused-operator-state',
            HANGAR_E2E_HOME: '',
        },
        timeout: CHILD_TIMEOUT_MS,
    });
    expect(child.exitCode, child.stderr.toString()).toBe(0);
    const printed: unknown = JSON.parse(child.stdout.toString());
    expect(printed).toMatchObject({
        home: expect.stringMatching(/[/\\]\.scratch[/\\]hangar-e2e-/),
        configHomeIsHome: true,
        key: 'hangar',
        port: '19123',
        url: 'http://127.0.0.1:19123/api/health',
    });
});

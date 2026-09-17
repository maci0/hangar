import { test, expect } from '@playwright/test';
import { execFileSync } from 'child_process';

const CONFIG = new URL('../../playwright.config.mjs', import.meta.url);

test('daemon config isolates operator state and credentials while preserving the test port', () => {
    const output = execFileSync(process.execPath, ['--input-type=module', '-e', `
        import config from ${JSON.stringify(CONFIG.href)};
        import { rmSync } from 'fs';
        const env = { ...process.env, ...config.webServer.env };
        try {
            process.stdout.write(JSON.stringify({
                home: env.HOME,
                configHome: env.HANGAR_CONFIG_HOME,
                key: env.KV_API_KEY,
                port: env.KV_PORT,
                url: config.webServer.url,
            }));
        } finally {
            rmSync(config.webServer.env.HOME, { recursive: true, force: true });
        }
    `], {
        env: {
            ...process.env,
            KV_API_KEY: 'synthetic-operator-key',
            KV_PORT: '19123',
            HANGAR_CONFIG_HOME: '/unused-operator-state',
            HANGAR_E2E_HOME: '',
        },
        encoding: 'utf8',
        timeout: 10_000,
    });
    const env = JSON.parse(output);
    expect(env.home).toMatch(/[/\\]\.scratch[/\\]hangar-e2e-/);
    expect(env.configHome).toBe(env.home);
    expect(env.key).toBe('hangar');
    expect(env.port).toBe('19123');
    expect(env.url).toBe('http://127.0.0.1:19123/api/health');
});

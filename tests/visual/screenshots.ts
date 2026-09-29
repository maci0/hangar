#!/usr/bin/env bun
/**
 * Capture web UI screenshots from the real built binary, for the README and for eyeballing a visual
 * change. Not a gate: `zig build web-e2e` (tests/e2e) is the assertion suite; this only produces images.
 *
 * Usage: bun tests/visual/screenshots.ts [--port PORT]
 * Output: tests/visual/screenshots/*.png (gitignored)
 */
import { chromium, type Page } from '@playwright/test';

const ROOT = import.meta.dirname.replace('/tests/visual', '');
const BINARY = `${ROOT}/zig-out/bin/hangar-web`;
const OUT_DIR = `${ROOT}/tests/visual/screenshots`;
const DEFAULT_PORT = '9877';
const READY_TRIES = 30;
const READY_DELAY_MS = 300;
const VIEWPORT = { width: 1440, height: 900 };
const HTTP_CLIENT_ERROR = 400;

const portArgument = (): string | undefined => {
    const flag = Bun.argv.indexOf('--port');
    return flag === -1 ? undefined : Bun.argv[flag + 1];
};

const PORT = Bun.env.KV_PORT ?? portArgument() ?? DEFAULT_PORT;
const BASE = `http://127.0.0.1:${PORT}`;

/**
 * Seeded so the images show a populated library rather than the empty state.
 * `guest_os` is a combobox index (vm.GuestOs): 0 linux, 1 windows.
 */
const SEED_VMS = [
    'name=web-01&mem=4096&cpu=4&disk=40&guest_os=0',
    'name=db-primary&mem=8192&cpu=8&disk=120&guest_os=0',
    'name=win11-lab&mem=8192&cpu=4&disk=80&guest_os=1',
    'name=build-runner&mem=2048&cpu=2&disk=20&guest_os=0',
];

const answersHealth = (): Promise<boolean> => fetch(`${BASE}/api/health`).then((response) => response.ok).catch(() => false);

const waitForHealth = async (): Promise<boolean> => {
    for (let attempt = 0; attempt < READY_TRIES; attempt += 1) {
        await Bun.sleep(READY_DELAY_MS);
        if (await answersHealth()) {
            return true;
        }
    }
    return false;
};

const shoot = async (page: Page, name: string): Promise<void> => {
    await page.screenshot({ path: `${OUT_DIR}/${name}.png` });
    await Bun.write(Bun.stdout, `  ${name}.png\n`);
};

const seedVm = async (page: Page, body: string): Promise<void> => {
    const status = await page.evaluate(async (form) => {
        const response = await fetch('/api/vms', { method: 'POST', headers: { 'X-API-Key': 'hangar' }, body: form });
        return response.status;
    }, body);
    if (status >= HTTP_CLIENT_ERROR) {
        throw new Error(`seed failed (${status}): ${body}`);
    }
};

const capture = async (page: Page): Promise<void> => {
    /* Not 'networkidle': the UI holds a permanently open SSE stream (/api/events). */
    await page.goto(BASE, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#vmlist');
    for (const body of SEED_VMS) {
        await seedVm(page, body);
    }
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#vmlist .vm-item');

    await page.waitForSelector('#tabSummary .dash');
    await shoot(page, 'dashboard');

    await page.click('#vmlist .vm-item');
    await page.waitForSelector('.vm-facts');
    await shoot(page, 'vm-summary');

    await page.click('#tab-btn-settings');
    await page.waitForSelector('#tabSettings');
    await shoot(page, 'vm-settings');

    await page.click('#tab-btn-summary');
    await page.click('[data-menu="toolsMenu"]:visible');
    await page.click('#toolsMenu [data-action="openVnets"]');
    await page.click('#vnetdlg [data-action="openTopology"]');
    await page.waitForSelector('.topo-svg .topo-node');
    await shoot(page, 'topology');
};

if (!(await Bun.file(BINARY).exists())) {
    throw new Error(`Binary not found: ${BINARY}. Run 'zig build' first.`);
}

/**
 * Throwaway HOME so a run never touches real ~/.config/hangar state. Under the repo's gitignored
 * .scratch/, not the OS temp dir, which is tmpfs (RAM-backed).
 */
const home = `${ROOT}/.scratch/hangar-shots-${Bun.randomUUIDv7()}`;
await Bun.write(`${home}/.keep`, '');
const server = Bun.spawn([BINARY], {
    cwd: ROOT,
    env: { ...Bun.env, KV_PORT: PORT, HOME: home, HANGAR_CONFIG_HOME: home, KV_API_KEY: 'hangar' },
    stdout: 'ignore',
    stderr: 'ignore',
});
try {
    if (!(await waitForHealth())) {
        throw new Error(`server did not answer on ${BASE}`);
    }
    const browser = await chromium.launch({ headless: true });
    try {
        await capture(await browser.newPage({ viewport: VIEWPORT }));
    } finally {
        await browser.close();
    }
} finally {
    server.kill('SIGTERM');
}

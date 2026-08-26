#!/usr/bin/env bun
// Capture web UI screenshots from the real built binary, for the README and for
// eyeballing a visual change. Not a gate: `zig build web-e2e` (tests/e2e) is the
// assertion suite; this only produces images.
//
// Usage: bun tests/visual/screenshots.mjs [--port PORT]
// Output: tests/visual/screenshots/*.png (gitignored)

import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdirSync, mkdtempSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const BINARY = resolve(ROOT, 'zig-out/bin/hangar-web');
const OUT_DIR = resolve(ROOT, 'tests/visual/screenshots');
const SCRATCH = resolve(ROOT, '.scratch');
const PORT = process.env.KV_PORT
    || (process.argv.includes('--port') ? process.argv[process.argv.indexOf('--port') + 1] : '9877');
const BASE = `http://127.0.0.1:${PORT}`;
const READY_TRIES = 30;
const READY_DELAY_MS = 300;

// Seeded so the images show a populated library rather than the empty state.
// `guest_os` is a combobox index (vm.GuestOs): 0 linux, 1 windows.
const SEED_VMS = [
    'name=web-01&mem=4096&cpu=4&disk=40&guest_os=0',
    'name=db-primary&mem=8192&cpu=8&disk=120&guest_os=0',
    'name=win11-lab&mem=8192&cpu=4&disk=80&guest_os=1',
    'name=build-runner&mem=2048&cpu=2&disk=20&guest_os=0',
];

async function waitForHealth() {
    for (let i = 0; i < READY_TRIES; i++) {
        await new Promise((r) => setTimeout(r, READY_DELAY_MS));
        try {
            if ((await fetch(`${BASE}/api/health`)).ok) return true;
        } catch { /* not listening yet */ }
    }
    return false;
}

async function shoot(page, name) {
    await page.screenshot({ path: resolve(OUT_DIR, `${name}.png`) });
    console.log(`  ${name}.png`);
}

if (!existsSync(BINARY)) {
    console.error(`Binary not found: ${BINARY}. Run 'zig build' first.`);
    process.exit(1);
}
mkdirSync(OUT_DIR, { recursive: true });
mkdirSync(SCRATCH, { recursive: true });

// Throwaway HOME so a run never touches real ~/.config/hangar state. Under the
// repo's gitignored .scratch/, not os.tmpdir(), which is tmpfs (RAM-backed).
const home = mkdtempSync(resolve(SCRATCH, 'hangar-shots-'));
const server = spawn(BINARY, [], { cwd: ROOT, env: { ...process.env, KV_PORT: PORT, HOME: home }, stdio: 'pipe' });
let browser = null;
try {
    if (!await waitForHealth()) throw new Error(`server did not answer on ${BASE}`);

    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    // Not 'networkidle': the UI holds a permanently open SSE stream (/api/events).
    await page.goto(BASE, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#vmlist');

    for (const body of SEED_VMS) {
        const r = await page.evaluate(
            async (b) => (await fetch('/api/vms', { method: 'POST', headers: { 'X-API-Key': 'hangar' }, body: b })).status,
            body,
        );
        if (r >= 400) throw new Error(`seed failed (${r}): ${body}`);
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
    await page.evaluate(() => openTopology());
    await page.waitForSelector('.topo-svg .topo-node');
    await shoot(page, 'topology');
} finally {
    if (browser) await browser.close();
    server.kill('SIGTERM');
}

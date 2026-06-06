#!/usr/bin/env node
// Web UI end-to-end smoke test — drives key interaction paths.
// Requires: puppeteer
// Usage: node tests/web_smoke.mjs [--port PORT]

import puppeteer from 'puppeteer';
import { spawn } from 'child_process';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { createServer } from 'net';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const BINARY = resolve(ROOT, 'zig-out/bin/hangar-web');

// Use a temp HOME so test data doesn't bleed across runs.
const TMP_HOME = mkdtempSync(resolve(tmpdir(), 'hangar-smoke-'));

async function getFreePort() {
    return await new Promise((resolvePort, reject) => {
        const srv = createServer();
        srv.listen(0, '127.0.0.1', () => {
            const addr = srv.address();
            const port = String(addr.port);
            srv.close(() => resolvePort(port));
        });
        srv.on('error', reject);
    });
}

const cliPort = process.argv.includes('--port') ? process.argv[process.argv.indexOf('--port') + 1] : null;
const PORT = process.env.KV_PORT || cliPort || await getFreePort();
const BASE = `http://127.0.0.1:${PORT}`;

let serverPid = null;
let pass = 0, fail = 0;
let serverOutput = '';

function result(ok, msg) {
    if (ok) { pass++; console.log(`  PASS: ${msg}`); }
    else     { fail++; console.log(`  FAIL: ${msg}`); }
    return ok;
}

async function pageLoaded(page, timeout = 8000) {
    try {
        await page.waitForSelector('#vmlist', { timeout });
        return true;
    } catch { return false; }
}

function sleep(ms) {
    return new Promise(r => setTimeout(r, ms));
}

async function waitForServerReady(timeout = 8000) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
        try {
            const r = await fetch(`${BASE}/api/health`);
            if (r.ok) return true;
        } catch {}
        await sleep(150);
    }
    return false;
}

function exitStartupFailed(reason) {
    console.log(`  FAIL: ${reason}`);
    if (serverOutput.trim()) {
        console.log('  Server output:');
        console.log(serverOutput.trim().split('\n').slice(-8).map(s => `    ${s}`).join('\n'));
    }
    if (serverPid) serverPid.kill('SIGTERM');
    try { rmSync(TMP_HOME, { recursive: true, force: true }); } catch {}
    process.exit(1);
}

async function invokeFn(page, fnName) {
    return await page.evaluate(async (name) => {
        if (typeof window[name] === 'function') {
            await window[name]();
            return true;
        }
        return false;
    }, fnName);
}

async function waitForDialogOpen(page, dialogId, timeout = 3000) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
        const open = await page.evaluate((id) => {
            const d = document.getElementById(id);
            return d ? d.open : false;
        }, dialogId);
        if (open) return true;
        await new Promise(r => setTimeout(r, 100));
    }
    return false;
}

async function isDialogOpen(page, dialogId) {
    return await page.evaluate((id) => {
        const d = document.getElementById(id);
        return d ? d.open : false;
    }, dialogId);
}

async function closeDialog(page, dialogId) {
    const open = await isDialogOpen(page, dialogId);
    if (!open) return;
    await page.keyboard.press('Escape');
    await new Promise(r => setTimeout(r, 300));
}

async function vmCount(page) {
    return await page.evaluate(() => {
        const items = document.querySelectorAll('#vmlist .vm-item');
        return items.length;
    });
}

async function selectVm(page, index) {
    await page.evaluate((idx) => {
        const items = document.querySelectorAll('#vmlist .vm-item');
        if (items[idx]) items[idx].click();
    }, index);
}

async function run() {
    console.log('=== Hangar Web E2E Smoke Test ===\n');

    // Spawn web server
    console.log(`Starting web server on port ${PORT}...`);
    serverPid = spawn(BINARY, [], {
        env: { ...process.env, KV_PORT: PORT, HOME: TMP_HOME },
        stdio: ['ignore', 'pipe', 'pipe'],
    });

    serverPid.stdout.on('data', (d) => { serverOutput += d.toString(); });
    serverPid.stderr.on('data', (d) => { serverOutput += d.toString(); });
    serverPid.on('error', (err) => { serverOutput += `\nspawn error: ${err.message}\n`; });

    const ready = await waitForServerReady();
    if (!ready) {
        exitStartupFailed('web server did not become reachable on 127.0.0.1');
    }
    console.log('  Server started');

    const browser = await puppeteer.launch({
        headless: 'new',
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu'],
    });

    try {
        const page = await browser.newPage();
        page.on('dialog', async (dialog) => { await dialog.accept(); });
        await page.setViewport({ width: 1280, height: 800 });

        // ── 1. Load page ──
        console.log('--- 1. Page load ---');
        await page.goto(BASE, { waitUntil: 'networkidle2', timeout: 10000 });
        result(await pageLoaded(page), 'page loads and renders VM list');
        const initialCount = await vmCount(page);
        console.log(`  Initial VM count: ${initialCount}`);

        // ── 2. Create VM by clicking New VM ──
        console.log('--- 2. Create VM ---');
        await page.evaluate(() => {
            const btns = document.querySelectorAll('.btn.primary');
            for (const b of btns) {
                if (b.textContent.includes('New VM') || b.textContent.includes('+ New VM')) {
                    b.click();
                    break;
                }
            }
        });
        if (!await waitForDialogOpen(page, 'newdlg')) {
            await invokeFn(page, 'newVm');
            await waitForDialogOpen(page, 'newdlg');
        }
        result(await isDialogOpen(page, 'newdlg'), 'New VM dialog opens');

        // Fill in New VM form
        await page.evaluate(() => {
            const n = document.getElementById('n_name');
            const m = document.getElementById('n_mem');
            const c = document.getElementById('n_cpu');
            const d = document.getElementById('n_disk');
            if (n) n.value = 'SmokeTest VM';
            if (m) m.value = '4096';
            if (c) c.value = '4';
            if (d) d.value = '30';
        });

        // Click Create
        await page.evaluate(() => {
            const btns = document.querySelectorAll('#newdlg .btn');
            for (const b of btns) {
                if (b.textContent === 'Create') { b.click(); break; }
            }
        });
        await new Promise(r => setTimeout(r, 1500));

        const countAfterCreate = await vmCount(page);
        result(countAfterCreate === initialCount + 1, `VM created (count: ${initialCount} -> ${countAfterCreate})`);

        // ── 3. Select VM and verify summary ──
        console.log('--- 3. VM Summary ---');
        await selectVm(page, 0);
        await new Promise(r => setTimeout(r, 500));

        const summaryVisible = await page.evaluate(() => {
            const el = document.getElementById('tabSummary');
            return el && el.style.display !== 'none' && el.textContent.length > 20;
        });
        result(summaryVisible, 'summary tab shows VM details');

        // ── 4. Edit Settings ──
        console.log('--- 4. Edit Settings ---');
        await invokeFn(page, 'editVm');
        await new Promise(r => setTimeout(r, 800));

        const settingsTabVisible = await page.evaluate(() => {
            const el = document.getElementById('tabSettings');
            return el && el.style.display !== 'none';
        });
        result(settingsTabVisible, 'settings tab opens');

        // Change memory in settings
        await page.evaluate(() => {
            const m = document.querySelector('#tabSettings input[id*="mem"], #tabSettings [id$="_mem"]');
            if (m) { m.value = '8192'; m.dispatchEvent(new Event('input', { bubbles: true })); }
        });

        // Save settings
        await invokeFn(page, 'saveVm');
        await new Promise(r => setTimeout(r, 1000));

        const nameUpdated = await page.evaluate(() => {
            const el = document.getElementById('vmname');
            return el && el.textContent.includes('SmokeTest');
        });
        result(nameUpdated, 'VM name still visible after save');

        // ── 5. Snapshot dialog ──
        console.log('--- 5. Snapshot dialog ---');
        await invokeFn(page, 'openSnapshots');
        await waitForDialogOpen(page, 'snapdlg');
        result(await isDialogOpen(page, 'snapdlg'), 'snapshot dialog opens');
        await closeDialog(page, 'snapdlg');

        // ── 6. Preferences dialog ──
        console.log('--- 6. Preferences ---');
        await invokeFn(page, 'openPrefs');
        await waitForDialogOpen(page, 'prefsdlg');
        result(await isDialogOpen(page, 'prefsdlg'), 'preferences dialog opens');
        await closeDialog(page, 'prefsdlg');

        // ── 7. VNet Editor dialog ──
        console.log('--- 7. VNet Editor ---');
        await invokeFn(page, 'openVnets');
        await waitForDialogOpen(page, 'vnetdlg');
        result(await isDialogOpen(page, 'vnetdlg'), 'VNet editor dialog opens');
        await closeDialog(page, 'vnetdlg');

        // ── 8. About dialog ──
        console.log('--- 8. About ---');
        await invokeFn(page, 'openAbout');
        await waitForDialogOpen(page, 'aboutdlg');
        result(await isDialogOpen(page, 'aboutdlg'), 'about dialog opens');
        await closeDialog(page, 'aboutdlg');

        // ── 9. Keyboard Shortcuts dialog ──
        console.log('--- 9. Shortcuts ---');
        await page.keyboard.press('?');
        await waitForDialogOpen(page, 'shortcutsdlg');
        result(await isDialogOpen(page, 'shortcutsdlg'), 'shortcuts dialog opens on ?');
        await closeDialog(page, 'shortcutsdlg');

        // ── 10. Light theme toggle ──
        console.log('--- 10. Light theme ---');
        await invokeFn(page, 'openPrefs');
        await waitForDialogOpen(page, 'prefsdlg');
        await page.evaluate(() => {
            const sel = document.getElementById('p_theme');
            if (sel) { sel.value = 'light'; sel.dispatchEvent(new Event('change', { bubbles: true })); }
        });
        await new Promise(r => setTimeout(r, 300));
        await invokeFn(page, 'savePrefs');
        await new Promise(r => setTimeout(r, 600));
        const isLight = await page.evaluate(() => document.documentElement.classList.contains('light'));
        result(isLight, 'light theme applied');

        // Switch back to dark
        await invokeFn(page, 'openPrefs');
        await waitForDialogOpen(page, 'prefsdlg');
        await page.evaluate(() => {
            const sel = document.getElementById('p_theme');
            if (sel) { sel.value = 'dark'; sel.dispatchEvent(new Event('change', { bubbles: true })); }
        });
        await new Promise(r => setTimeout(r, 300));
        await invokeFn(page, 'savePrefs');
        await new Promise(r => setTimeout(r, 600));

        // ── 11. Connection banner visibility check ──
        console.log('--- 11. Connection banner ---');
        const bannerExists = await page.evaluate(() => {
            const b = document.getElementById('connbanner');
            return b !== null;
        });
        result(bannerExists, 'connection banner element exists');

        // ── 12. Drag-to-reorder (check API endpoint exists) ──
        console.log('--- 12. Reorder ---');
        const reorderResult = await page.evaluate(async () => {
            try {
                const r = await fetch('/api/reorder', {
                    method: 'POST',
                    headers: { 'X-API-Key': 'hangar' },
                    body: 'from=0&to=0',
                });
                return { ok: r.ok, body: await r.text() };
            } catch (e) {
                return { ok: false, body: String(e) };
            }
        });
        result(reorderResult.ok && reorderResult.body.trim() === 'ok', 'reorder API returns ok for no-op reorder');

        // ── 13. Rename VM ──
        console.log('--- 13. Rename VM ---');
        const renameTriggered = await page.evaluate(() => {
            return typeof window.renameGuest === 'function';
        });
        result(renameTriggered, 'renameGuest function exists');
        // Fire renameGuest without awaiting — it blocks on the custom prompt dialog
        page.evaluate(() => { window.renameGuest(); });
        await waitForDialogOpen(page, 'promptdlg');
        const promptOpen = await isDialogOpen(page, 'promptdlg');
        result(promptOpen, 'prompt dialog opens for rename');
        // Fill in new name and click OK
        await page.evaluate(() => {
            const inp = document.getElementById('promptInput');
            const okBtn = document.getElementById('promptOkBtn');
            if (inp) inp.value = 'SmokeTest Renamed';
            if (okBtn) okBtn.click();
        });
        await new Promise(r => setTimeout(r, 800));
        // VM name should now reflect the rename
        const nameAfterRename = await page.evaluate(() => {
            const el = document.getElementById('vmname');
            return el && el.textContent.includes('SmokeTest Renamed');
        });
        result(nameAfterRename, 'VM header reflects renamed VM');

        // ── 14. Clone VM dialog ──
        console.log('--- 14. Clone VM ---');
        await invokeFn(page, 'cloneGuest');
        await waitForDialogOpen(page, 'clonedlg');
        const cloneDialogOpen = await isDialogOpen(page, 'clonedlg');
        result(cloneDialogOpen, 'clone dialog opens');
        if (cloneDialogOpen) {
            const countBeforeClone = await vmCount(page);
            // Click Full Clone button
            await page.evaluate(() => {
                const btns = document.querySelectorAll('#clonedlg .btn');
                for (const b of btns) {
                    if (b.textContent.includes('Full')) { b.click(); break; }
                }
            });
            await page.waitForFunction((prev) => {
                return document.querySelectorAll('#vmlist .vm-item').length === prev + 1;
            }, { timeout: 5000 }, countBeforeClone);
            const countAfterClone = await vmCount(page);
            const hasCloneName = await page.evaluate(() => {
                return Array.from(document.querySelectorAll('#vmlist .vm-item'))
                    .some(item => item.textContent.includes('(clone)'));
            });
            result(countAfterClone === countBeforeClone + 1 && hasCloneName, `full clone creates one VM (count: ${countBeforeClone} -> ${countAfterClone})`);
            await closeDialog(page, 'clonedlg');
        }

        // ── 15. Toggle favorite ──
        console.log('--- 15. Favorite ---');
        await selectVm(page, 0);
        await new Promise(r => setTimeout(r, 300));
        const favoriteBefore = await page.evaluate(async () => {
            const r = await fetch('/api/vms');
            const rows = await r.json();
            return rows[0] ? rows[0].favorite : null;
        });
        await page.click('#vmlist .vm-item[data-vm-index="0"] [data-action="toggleFavorite"]');
        await page.waitForFunction((before) => {
            const item = document.querySelector('#vmlist .vm-item[data-vm-index="0"]');
            const star = item && item.querySelector('.star');
            if (!star) return false;
            return before === 'true' ? !star.classList.contains('fav') : star.classList.contains('fav');
        }, { timeout: 5000 }, favoriteBefore);
        const favoriteAfter = await page.evaluate(async () => {
            const r = await fetch('/api/vms');
            const rows = await r.json();
            return rows[0] ? rows[0].favorite : null;
        });
        result(favoriteBefore !== null && favoriteAfter !== favoriteBefore, 'favorite toggle persists changed favorite state');

        // ── 16. Search / filter ──
        console.log('--- 16. Search ---');
        await page.evaluate(() => {
            const inp = document.getElementById('search');
            if (inp) { inp.value = 'SmokeTest'; inp.dispatchEvent(new Event('input', { bubbles: true })); }
        });
        await new Promise(r => setTimeout(r, 300));
        const filteredCount = await vmCount(page);
        result(filteredCount > 0, `search filter shows results (${filteredCount} item(s))`);
        // Clear search
        await page.evaluate(() => {
            const inp = document.getElementById('search');
            if (inp) { inp.value = ''; inp.dispatchEvent(new Event('input', { bubbles: true })); }
        });
        await new Promise(r => setTimeout(r, 200));

        // ── 17. Deselect / reselect VM ──
        console.log('--- 17. Deselect ---');
        await invokeFn(page, 'deselectVm');
        await new Promise(r => setTimeout(r, 300));
        const emptyState = await page.evaluate(() => {
            const el = document.querySelector('.empty-state');
            return el !== null;
        });
        result(emptyState, 'empty state visible after deselect');
        await selectVm(page, 0);
        await new Promise(r => setTimeout(r, 300));

        // ── 18. Send Ctrl+Alt+Del ──
        console.log('--- 18. Send Cad ---');
        const cadFnExists = await page.evaluate(() => typeof window.sendCad === 'function');
        result(cadFnExists, 'sendCad function exists');
        // On stopped VM this will fail gracefully (toast expected)
        await invokeFn(page, 'sendCad');
        await new Promise(r => setTimeout(r, 500));

        // ── 19. Migrate dialog ──
        console.log('--- 19. Migrate ---');
        await invokeFn(page, 'migrateGuest');
        const migrateOpen = await waitForDialogOpen(page, 'migratedlg', 2000).catch(() => false);
        result(migrateOpen, 'migrate dialog opens for selected VM');
        if (await isDialogOpen(page, 'migratedlg')) {
            await closeDialog(page, 'migratedlg');
        }

        // ── 20. Snapshot list (with VM selected) ──
        console.log('--- 20. Snapshots ---');
        await invokeFn(page, 'openSnapshots');
        await waitForDialogOpen(page, 'snapdlg');
        const snapOpen = await isDialogOpen(page, 'snapdlg');
        result(snapOpen, 'snapshot dialog opens with VM selected');
        // Check that Take Snapshot UI elements exist
        if (snapOpen) {
            const snapUiReady = await page.evaluate(() => {
                const tag = document.getElementById('s_tag');
                const takeBtn = document.querySelector('#snapdlg [data-action="takeSnapshotFromDlg"]');
                return tag !== null && takeBtn !== null;
            });
            result(snapUiReady, 'snapshot Take form elements present');
            await closeDialog(page, 'snapdlg');
        }

        // ── 21. Serial console panel ──
        console.log('--- 21. Serial ---');
        const serialFnExists = await page.evaluate(() => typeof window.startSerial === 'function');
        result(serialFnExists, 'startSerial function exists');

        // ── 22. Batch operations ──
        console.log('--- 22. Batch Ops ---');
        const batchStartFn = await page.evaluate(() => typeof window.batchStart === 'function');
        const batchStopFn = await page.evaluate(() => typeof window.batchStop === 'function');
        result(batchStartFn && batchStopFn, 'batch start/stop functions exist');

        // ── 23. Export OVF button ──
        console.log('--- 23. Export OVF ---');
        const exportFn = await page.evaluate(() => typeof window.exportOvf === 'function');
        result(exportFn, 'exportOvf function exists');
        // Don't actually export (creates large files), just verify the button works
        await invokeFn(page, 'exportOvf');
        await new Promise(r => setTimeout(r, 500));

        // ── 24. Delete VM cleanup ──
        console.log('--- 24. Delete VM ---');
        // Delete all VMs — fire deleteVm without awaiting so the
        // custom confirm dialog opens, then click OK to proceed.
        while (await vmCount(page) > 0) {
            await selectVm(page, 0);
            await new Promise(r => setTimeout(r, 200));
            const delDone = page.evaluate(() => { deleteVm(); }).catch(() => {});
            await waitForDialogOpen(page, 'confirmdlg');
            await page.evaluate(() => {
                const btn = document.getElementById('confirmOkBtn');
                if (btn) btn.click();
            });
            await new Promise(r => setTimeout(r, 800));
            await delDone;
        }
        const countAfterDelete = await vmCount(page);
        result(countAfterDelete === 0, 'all VMs deleted');

        // ── 25. Server connectivity maintained ──
        console.log('--- 25. Server still responsive ---');
        const stillAlive = await page.evaluate(async () => {
            try {
                const r = await fetch('/api/vms');
                return r.ok;
            } catch { return false; }
        });
        result(stillAlive, 'server responds after all operations');

    } finally {
        await browser.close();
    }

    // Stop server
    if (serverPid) {
        serverPid.kill('SIGTERM');
        try { await new Promise(r => { serverPid.on('close', r); setTimeout(r, 2000); }); } catch {}
    }

    // Clean up temp HOME
    try { rmSync(TMP_HOME, { recursive: true, force: true }); } catch {}

    console.log(`\n============================================`);
    console.log(`Results: ${pass} passed, ${fail} failed`);
    console.log(`============================================`);
    process.exit(fail > 0 ? 1 : 0);
}

run().catch(err => {
    console.error('FATAL:', err.message);
    if (serverPid) serverPid.kill('SIGTERM');
    try { rmSync(TMP_HOME, { recursive: true, force: true }); } catch {}
    process.exit(1);
});

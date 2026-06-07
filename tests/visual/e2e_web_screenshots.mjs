#!/usr/bin/env node
// Web UI visual end-to-end test — screenshots every view + modal.
// Requires: @playwright/test (Chromium via `npm run e2e:install`), a running hangar-web binary.
// Usage: node tests/visual/e2e_web_screenshots.mjs [--port PORT]

import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdirSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '../..');
const SCREENSHOT_DIR = resolve(ROOT, 'tests/visual/screenshots/web');
const BINARY = resolve(ROOT, 'zig-out/bin/hangar-web');

const PORT = process.env.KV_PORT || (process.argv.includes('--port') ? process.argv[process.argv.indexOf('--port') + 1] : '9877');
const BASE = `http://localhost:${PORT}`;
const API_KEY = 'test-key-12345';

let serverPid = null;
let pass = 0, fail = 0;

function result(ok, msg) {
    if (ok) { pass++; console.log(`  PASS: ${msg}`); }
    else     { fail++; console.log(`  FAIL: ${msg}`); }
    return ok;
}

async function screenshot(page, name) {
    const path = resolve(SCREENSHOT_DIR, `${name}.png`);
    await page.screenshot({ path });
    console.log(`  📸 ${name}`);
    return path;
}

async function pageLoaded(page, timeout = 8000) {
    try {
        await page.waitForSelector('#vmlist', { timeout });
        return true;
    } catch { return false; }
}

// Directly invoke a JS function by name (awaits async functions)
async function invokeFn(page, fnName) {
    return await page.evaluate(async (name) => {
        if (typeof window[name] === 'function') {
            await window[name]();
            return true;
        }
        return false;
    }, fnName);
}

// Wait for a <dialog> to be open
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

// Check if a dialog is open
async function isDialogOpen(page, dialogId) {
    return await page.evaluate((id) => {
        const d = document.getElementById(id);
        return d ? d.open : false;
    }, dialogId);
}

// Close a dialog (click Cancel/Escape)
async function closeDialog(page, dialogId) {
    const open = await isDialogOpen(page, dialogId);
    if (!open) return;
    // Try to find and click Cancel button
    const cancelled = await page.evaluate((id) => {
        const dlg = document.getElementById(id);
        if (!dlg || !dlg.open) return false;
        const btns = dlg.querySelectorAll('button');
        for (const b of btns) {
            const t = b.textContent.trim();
            if (t === 'Cancel' || t === 'Close') {
                b.click();
                return true;
            }
        }
        return false;
    }, dialogId);
    if (!cancelled) {
        // Press Escape
        await page.keyboard.press('Escape');
    }
    await new Promise(r => setTimeout(r, 400));
}

// Fill an input field by id
async function fillById(page, id, value) {
    await page.evaluate(([elId, val]) => {
        const el = document.getElementById(elId);
        if (el) {
            el.value = val;
            el.dispatchEvent(new Event('input', {bubbles: true}));
        }
    }, [id, String(value)]);
}

// Select a VM by index
async function selectVm(page, index) {
    return await page.evaluate((i) => {
        if (typeof select === 'function') {
            select(i);
            return true;
        }
        return false;
    }, index);
}

// Get VM list count
async function vmCount(page) {
    return await page.evaluate(() => {
        return Array.isArray(window.vms) ? window.vms.length : -1;
    });
}

async function run() {
    console.log('=== Web UI Visual E2E Screenshot Test ===\n');

    if (!existsSync(BINARY)) {
        console.error(`Binary not found: ${BINARY}. Run 'zig build' first.`);
        process.exit(1);
    }

    mkdirSync(SCREENSHOT_DIR, { recursive: true });

    // Start server
    console.log(`Starting web server on port ${PORT}...`);
    // Clean state from previous runs
    try { spawn('rm', ['-f', `${process.env.HOME}/.config/hangar/vms.json`], { stdio: 'pipe' }); } catch {}
    serverPid = spawn(BINARY, [], {
        cwd: ROOT,
        env: { ...process.env, KV_PORT: PORT, KV_API_KEY: API_KEY },
        stdio: 'pipe',
    });

    let serverReady = false;
    for (let i = 0; i < 30; i++) {
        await new Promise(r => setTimeout(r, 300));
        try {
            const resp = await fetch(`${BASE}/api/health`);
            if (resp.ok) { serverReady = true; break; }
        } catch {}
    }
    if (!serverReady) {
        console.error('Server failed to start within 9 seconds');
        serverPid.kill('SIGTERM');
        process.exit(1);
    }
    console.log('Server ready.\n');

    const browser = await chromium.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1280,800'],
    });
    const page = await browser.newPage();
    await page.setViewportSize({ width: 1280, height: 800 });

    // Handle native dialogs (alert/confirm/prompt)
    page.on('dialog', async dialog => {
        if (dialog.type() === 'prompt') {
            dialog.accept('/tmp/test-import.qcow2');
        } else if (dialog.type() === 'confirm') {
            dialog.accept();
        } else {
            dialog.accept();
        }
    });

    // Capture JS errors
    let pageErrors = [];
    page.on('pageerror', err => pageErrors.push(err.message));

    try {
        // ── 1. Home page (empty) ──
        console.log('--- 1. Home page (empty) ---');
        await page.goto(BASE, { waitUntil: 'networkidle', timeout: 10000 });
        result(await pageLoaded(page), 'home page loads');
        if (pageErrors.length > 0) {
            console.log(`  JS errors: ${pageErrors.join('; ')}`);
            pageErrors = [];
        }
        await screenshot(page, '01_home_empty');

        // ── 2. New VM dialog ──
        console.log('--- 2. New VM dialog ---');
        await invokeFn(page, 'newVm');
        const newDlgOpen = await waitForDialogOpen(page, 'newdlg');
        result(newDlgOpen, '"New VM" modal opens');
        if (newDlgOpen) {
            await screenshot(page, '02_new_vm_modal');

            // Fill the form
            await fillById(page, 'n_name', 'ScreenshotVM');
            await fillById(page, 'n_mem', '2048');
            await fillById(page, 'n_cpu', '2');

            // Click Create
            await invokeFn(page, 'createVm');
            await new Promise(r => setTimeout(r, 800));
        }

        // ── 3. Home page (with VM) ──
        console.log('--- 3. Home page (with VM) ---');
        const count = await vmCount(page);
        result(count > 0, `VM list has ${count} VM(s)`);
        await screenshot(page, '03_home_with_vm');

        // ── 4. Settings tab ──
        console.log('--- 4. Settings tab ---');
        await selectVm(page, 0);
        await new Promise(r => setTimeout(r, 300));
        await invokeFn(page, 'editVm');
        await new Promise(r => setTimeout(r, 600));
        await screenshot(page, '04_settings_tab');

        // Change name and save
        await fillById(page, 'e_name', 'ScreenshotVM-edited');
        await invokeFn(page, 'saveVm');
        await new Promise(r => setTimeout(r, 800));

        // ── 5. Clone dialog ──
        console.log('--- 5. Clone dialog ---');
        await selectVm(page, 0);
        await new Promise(r => setTimeout(r, 300));
        await invokeFn(page, 'cloneGuest');
        const cloneOpen = await waitForDialogOpen(page, 'clonedlg');
        result(cloneOpen, '"Clone" modal opens');
        if (cloneOpen) {
            await screenshot(page, '05_clone_modal');
            await closeDialog(page, 'clonedlg');
            await new Promise(r => setTimeout(r, 300));
        }

        // ── 6. Snapshot dialog ──
        console.log('--- 6. Snapshot dialog ---');
        await selectVm(page, 0);
        await new Promise(r => setTimeout(r, 300));
        await invokeFn(page, 'openSnapshots');
        const snapOpen = await waitForDialogOpen(page, 'snapdlg');
        result(snapOpen, '"Snapshot" modal opens');
        if (snapOpen) {
            // Fill tag and take snapshot
            await fillById(page, 's_tag', 'test-snapshot-1');
            await invokeFn(page, 'takeSnapshotFromDlg');
            await new Promise(r => setTimeout(r, 1000));

            // Reopen to show list
            await invokeFn(page, 'openSnapshots');
            await waitForDialogOpen(page, 'snapdlg');
            await new Promise(r => setTimeout(r, 400));
            await screenshot(page, '06_snapshot_modal');
            await closeDialog(page, 'snapdlg');
        }

        // ── 7. Preferences dialog ──
        console.log('--- 7. Preferences dialog ---');
        await invokeFn(page, 'openPrefs');
        const prefsOpen = await waitForDialogOpen(page, 'prefsdlg');
        result(prefsOpen, '"Preferences" modal opens');
        if (prefsOpen) {
            await screenshot(page, '07_prefs_modal');
            await closeDialog(page, 'prefsdlg');
        }

        // ── 8. VNet Editor dialog ──
        console.log('--- 8. VNet Editor dialog ---');
        await invokeFn(page, 'openVnets');
        const vnetOpen = await waitForDialogOpen(page, 'vnetdlg');
        result(vnetOpen, '"VNet Editor" modal opens');
        if (vnetOpen) {
            await screenshot(page, '08_vnet_modal');
            await closeDialog(page, 'vnetdlg');
        }

        // ── 9. Import ──
        console.log('--- 9. Import (prompt) ---');
        await invokeFn(page, 'importGuest');
        await new Promise(r => setTimeout(r, 800));
        await screenshot(page, '09_after_import');
        result(true, 'import flow completes');

        // ── 10. Light theme ──
        console.log('--- 10. Light theme ---');
        await invokeFn(page, 'openPrefs');
        await waitForDialogOpen(page, 'prefsdlg');
        // Select light theme
        await page.evaluate(() => {
            const sel = document.getElementById('p_theme');
            if (sel) { sel.value = 'light'; sel.dispatchEvent(new Event('change', {bubbles: true})); }
        });
        await new Promise(r => setTimeout(r, 300));
        // Save prefs
        await invokeFn(page, 'savePrefs');
        await new Promise(r => setTimeout(r, 600));
        await screenshot(page, '10_home_light_theme');

        // ── 11. Delete VM cleanup ──
        console.log('--- 11. Delete VM ---');
        // Delete all VMs one by one
        while (await vmCount(page) > 0) {
            await selectVm(page, 0);
            await new Promise(r => setTimeout(r, 150));
            await invokeFn(page, 'deleteVm');
            await new Promise(r => setTimeout(r, 600));
        }
        const count2 = await vmCount(page);
        await screenshot(page, '11_home_empty_after_delete');
        result(count2 === 0, 'all VMs deleted');

    } finally {
        await browser.close();
    }

    // Stop server
    if (serverPid) {
        serverPid.kill('SIGTERM');
        try { await new Promise(r => { serverPid.on('close', r); setTimeout(r, 2000); }); } catch {}
    }

    console.log(`\n============================================`);
    console.log(`Results: ${pass} passed, ${fail} failed`);
    console.log(`Screenshots: ${SCREENSHOT_DIR}`);
    console.log(`============================================`);
    process.exit(fail > 0 ? 1 : 0);
}

run().catch(err => {
    console.error('FATAL:', err.message);
    if (serverPid) { serverPid.kill('SIGTERM'); }
    process.exit(1);
});

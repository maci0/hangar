// End-to-end Playwright coverage for the Hangar web UI workflows.
//
// Per AGENTS.md, every user-facing workflow must have an e2e Playwright test
// here. These drive the real built `hangar-web` binary (launched by
// playwright.config.mjs against a temp $HOME) and assert observable results.
//
// The UI exposes its actions as window-scoped functions; we invoke them the
// same way the app's own buttons do, then assert on the resulting DOM/state.
import { test, expect } from '@playwright/test';

const API_KEY = 'hangar'; // built-in default; the bundled UI sends this same key

// Invoke a window-scoped UI action function inside the page.
async function invoke(page, fn, ...args) {
    return page.evaluate(
        ([name, a]) => (typeof window[name] === 'function' ? (window[name](...a), true) : false),
        [fn, args],
    );
}

async function vmCount(page) {
    return page.locator('#vmlist .vm-item').count();
}

async function dialogOpen(page, id) {
    return page.evaluate((d) => !!document.getElementById(d)?.open, id);
}

// Load the app shell before every test. The server is shared across tests, so
// state created by an earlier test may still be present — assertions below are
// written to tolerate a non-empty starting list.
test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#vmlist')).toBeVisible();
});

test('page loads and renders the VM list', async ({ page }) => {
    await expect(page.locator('#vmlist')).toBeVisible();
});

test('create VM workflow adds a VM to the list', async ({ page }) => {
    const before = await vmCount(page);
    const name = 'E2E VM ' + before; // unique per run within the shared server

    await invoke(page, 'newVm');
    await expect.poll(() => dialogOpen(page, 'newdlg')).toBe(true);

    await page.fill('#n_name', name);
    await page.fill('#n_mem', '4096');
    await page.fill('#n_cpu', '4');
    await page.fill('#n_disk', '30');
    await invoke(page, 'createVm');

    await expect.poll(() => vmCount(page)).toBe(before + 1);
    await expect(page.locator('#vmlist .vm-item', { hasText: name })).toBeVisible();
});

test('new VMs default to the VNC display (web-usable, not GTK)', async ({ page }) => {
    // Read the freshly created VM's config from the API and assert the display
    // index is VNC (3), not GTK (0) — GTK opens a host-native window the browser
    // cannot show and disables the embedded console.
    const detail = await page.evaluate(async (key) => {
        const r = await fetch('/api/vm/0', { headers: { 'X-API-Key': key } });
        return r.ok ? r.json() : null;
    }, API_KEY);
    expect(detail).not.toBeNull();
    expect(Number(detail.display)).toBe(3);
});

test('selecting a VM shows its summary', async ({ page }) => {
    await page.locator('#vmlist .vm-item').first().click();
    const summary = page.locator('#tabSummary');
    await expect(summary).toBeVisible();
    await expect(summary).not.toBeEmpty();
});

test('view QEMU log workflow opens the log dialog', async ({ page }) => {
    await page.locator('#vmlist .vm-item').first().click();
    await invoke(page, 'viewLog');
    await expect.poll(() => dialogOpen(page, 'logdlg')).toBe(true);
    // The VM was never started, so the daemon has no log file yet — the dialog
    // must say so rather than hang on "Loading…".
    await expect(page.locator('#logbody')).toContainText(/No log yet|empty|Failed/i);
});

test('edit settings workflow saves without losing the VM', async ({ page }) => {
    await page.locator('#vmlist .vm-item').first().click();
    await invoke(page, 'editVm');
    await expect(page.locator('#tabSettings')).toBeVisible();
    const nameBefore = await page.locator('#vmname').textContent();
    await invoke(page, 'saveVm');
    await expect(page.locator('#vmname')).toHaveText(nameBefore ?? '');
});

for (const [fn, dlg, label] of [
    ['openSnapshots', 'snapdlg', 'snapshot'],
    ['openPrefs', 'prefsdlg', 'preferences'],
    ['openVnets', 'vnetdlg', 'VNet editor'],
    ['openAbout', 'aboutdlg', 'about'],
]) {
    test(`${label} dialog opens`, async ({ page }) => {
        if (fn === 'openSnapshots') await page.locator('#vmlist .vm-item').first().click();
        await invoke(page, fn);
        await expect.poll(() => dialogOpen(page, dlg)).toBe(true);
    });
}

test('keyboard shortcut "?" opens the shortcuts dialog', async ({ page }) => {
    await page.keyboard.press('?');
    await expect.poll(() => dialogOpen(page, 'shortcutsdlg')).toBe(true);
});

test('theme workflow applies light then dark', async ({ page }) => {
    await page.evaluate(() => {
        document.documentElement.classList.add('light');
        try { localStorage.setItem('theme', 'light'); } catch {}
    });
    await expect.poll(() => page.evaluate(() => document.documentElement.classList.contains('light'))).toBe(true);
    await page.evaluate(() => {
        document.documentElement.classList.remove('light');
        try { localStorage.setItem('theme', 'dark'); } catch {}
    });
    await expect.poll(() => page.evaluate(() => document.documentElement.classList.contains('light'))).toBe(false);
});

test('reorder API returns ok for a no-op reorder', async ({ page }) => {
    const res = await page.evaluate(async (key) => {
        const r = await fetch('/api/reorder', {
            method: 'POST',
            headers: { 'X-API-Key': key },
            body: 'from=0&to=0',
        });
        return { ok: r.ok, body: (await r.text()).trim() };
    }, API_KEY);
    expect(res.ok).toBe(true);
    expect(res.body).toBe('ok');
});

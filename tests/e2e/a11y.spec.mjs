// WCAG 2.2 AA gate: axe must report zero violations on the main views in both themes.
import AxeBuilder from '@axe-core/playwright';
import { test, expect } from '@playwright/test';

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'];
const SETTLE_MS = 600; // view transitions fade in; axe reads mid-fade colors otherwise

async function scan(page, step) {
    const { violations } = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze();
    expect(violations.map((v) => `${step}: ${v.id} ${v.nodes[0].target}`)).toEqual([]);
}

for (const theme of ['dark', 'light']) {
    test(`axe finds no WCAG AA violations (${theme})`, async ({ page }) => {
        await page.addInitScript((t) => localStorage.setItem('hangar-theme', t), theme);
        await page.goto('/', { waitUntil: 'domcontentloaded' });
        await page.waitForSelector('#vmlist');
        const created = await page.evaluate(async () => (await fetch('/api/vms', {
            method: 'POST',
            headers: { 'X-API-Key': 'hangar' },
            body: 'name=a11y-vm&mem=1024&cpu=1&disk=1&guest_os=0',
        })).status);
        expect(created).toBeLessThan(400);
        await page.reload({ waitUntil: 'domcontentloaded' });
        const row = page.locator('#vmlist .vm-item', { hasText: 'a11y-vm' });
        await row.waitFor();
        try {
            for (const step of ['dashboard', 'summary', 'settings', 'palette', 'context menu', 'toasts']) {
                if (step === 'summary') await row.click();
                if (step === 'settings') await page.locator('#tab-btn-settings').click();
                if (step === 'palette') {
                    await page.keyboard.press('Control+k');
                    await page.locator('#palette').waitFor();
                }
                if (step === 'context menu') await row.click({ button: 'right' });
                if (step === 'toasts') {
                    await page.evaluate(() => {
                        for (const type of ['success', 'error', 'warn', 'info']) showToast(`${type} toast`, type, { duration: 60000 });
                        toastUndo('Deleted "a11y-vm"', () => {});
                    });
                }
                await page.waitForTimeout(SETTLE_MS);
                await scan(page, step);
                if (step === 'settings') {
                    // Each settings section is its own panel; scan them all, with the validation states showing.
                    await page.locator('#e_mem').fill('64');
                    await page.locator('[data-settings-category="display_and_video"]').click();
                    await page.locator('#e_embed_display').selectOption('1');
                    await page.locator('#e_display').selectOption('0');
                    for (const id of await page.locator('[data-settings-category]').evaluateAll((els) => els.map((e) => e.getAttribute('data-settings-category')))) {
                        await page.locator(`[data-settings-category="${id}"]`).click();
                        await page.waitForTimeout(SETTLE_MS);
                        await scan(page, `settings/${id}`);
                    }
                }
                if (step === 'palette') {
                    await page.keyboard.press('Escape');
                    await expect(page.locator('#palette')).toHaveCount(0);
                }
                if (step === 'context menu') {
                    await page.keyboard.press('Escape');
                    await expect(page.locator('.ctx-menu')).toHaveCount(0);
                }
            }
        } finally {
            const idx = await page.evaluate(() => vms.findIndex((v) => v.name === 'a11y-vm'));
            await page.evaluate(async (i) => fetch(`/api/vms/${i}/delete`, { method: 'POST', headers: { 'X-API-Key': 'hangar' } }), idx);
        }
    });
}

// Dialogs open over the page (native modal), so each is scanned on its own with its error state showing.
const DIALOGS = [
    ['newVm', 'newdlg', async (page) => page.locator('#n_mem').fill('64')],
    ['importGuest', 'importdlg', async (page) => page.locator('#importdlg button[type="submit"]').click()],
    ['cloneGuest', 'clonedlg', async () => {}],
    ['openSnapshots', 'snapdlg', async (page) => page.locator('#snapdlg button[type="submit"]').click()],
    ['migrateGuest', 'migratedlg', async (page) => page.locator('#migratedlg button[type="submit"]').click()],
    ['openVnets', 'vnetdlg', async (page) => {
        await page.locator('[data-action="vnetAdd"]').click();
        await page.locator('#vn_subnet').fill('bad');
        await page.locator('[data-action="vnetSaveAll"]').click();
        await page.locator('#err_vn_subnet').waitFor();
    }],
    ['openTopology', 'topodlg', async (page) => page.waitForSelector('.topo-svg .topo-node')],
    ['openCatalog', 'catalogdlg', async (page) => page.waitForSelector('.cat-card')],
];

for (const theme of ['dark', 'light']) {
    test(`axe finds no violations in the VM and network dialogs (${theme})`, async ({ page }) => {
        await page.addInitScript((t) => localStorage.setItem('hangar-theme', t), theme);
        await page.goto('/', { waitUntil: 'domcontentloaded' });
        await page.waitForSelector('#vmlist');
        const created = await page.evaluate(async () => (await fetch('/api/vms', {
            method: 'POST',
            headers: { 'X-API-Key': 'hangar' },
            body: 'name=a11y-dlg-vm&mem=1024&cpu=1&disk=1&guest_os=0',
        })).status);
        expect(created).toBeLessThan(400);
        await page.reload({ waitUntil: 'domcontentloaded' });
        const row = page.locator('#vmlist .vm-item', { hasText: 'a11y-dlg-vm' });
        await row.waitFor();
        await row.click();
        try {
            for (const [fn, id, prepare] of DIALOGS) {
                await page.evaluate((name) => window[name](), fn);
                await page.locator(`#${id}`).waitFor();
                await prepare(page);
                await page.waitForTimeout(SETTLE_MS);
                const { violations } = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze();
                expect(violations.map((v) => `${id}: ${v.id} ${v.nodes[0].target}`)).toEqual([]);
                await page.keyboard.press('Escape');
                if (id === 'vnetdlg') await page.locator('#confirmOkBtn').click();
                await expect(page.locator(`#${id}`)).toHaveCount(0);
            }
        } finally {
            const idx = await page.evaluate(() => vms.findIndex((v) => v.name === 'a11y-dlg-vm'));
            await page.evaluate(async (i) => fetch(`/api/vms/${i}/delete`, { method: 'POST', headers: { 'X-API-Key': 'hangar' } }), idx);
        }
    });
}

// The console tab needs a running guest: scan it with the display and serial panels showing, then display-only mode.
test('axe finds no violations on the live console (dark and light)', async ({ page }) => {
    test.setTimeout(150_000);
    await page.goto('/', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#vmlist');
    const api = (method, path) => page.evaluate(async ([m, p, b]) => (await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body: b })).status,
        [method, path, method === 'POST' ? '' : undefined]);
    const created = await page.evaluate(async () => (await fetch('/api/vms', {
        method: 'POST',
        headers: { 'X-API-Key': 'hangar' },
        body: 'name=a11y-live&mem=1024&cpu=1&disk=1&display=vnc&embed_display=true&enable_serial=true&firmware=bios',
    })).status);
    expect(created).toBeLessThan(400);
    await page.reload({ waitUntil: 'domcontentloaded' });
    const index = () => page.evaluate(() => vms.findIndex((v) => v.name === 'a11y-live'));
    await page.locator('#vmlist .vm-item', { hasText: 'a11y-live' }).waitFor();
    await api('POST', `/api/vms/${await index()}/power`);
    try {
        await expect.poll(() => page.evaluate(() => vms.find((v) => v.name === 'a11y-live')?.status), { timeout: 25000 }).toBe('running');
        for (const theme of ['dark', 'light']) {
            await page.evaluate((t) => localStorage.setItem('hangar-theme', t), theme);
            await page.reload({ waitUntil: 'domcontentloaded' });
            await page.locator('#vmlist .vm-item', { hasText: 'a11y-live' }).click();
            await expect.poll(() => page.evaluate(() => { const c = document.querySelector('#display canvas'); return c ? c.width : 0; }), { timeout: 20000 }).toBeGreaterThan(0);
            await expect(page.locator('#serialpanel')).toBeVisible({ timeout: 10000 });
            await page.waitForTimeout(SETTLE_MS);
            await scan(page, `console (${theme})`);
            await page.locator('#display [data-action="enterDisplayOnly"]').click();
            await expect(page.locator('body')).toHaveClass(/displayonly/);
            await page.waitForTimeout(SETTLE_MS);
            await scan(page, `display-only (${theme})`);
            await page.keyboard.press('Escape');
            await expect(page.locator('body')).not.toHaveClass(/displayonly/);
        }
    } finally {
        const i = await index();
        await api('POST', `/api/vms/${i}/power`);
        await expect.poll(() => page.evaluate(() => vms.find((v) => v.name === 'a11y-live')?.status), { timeout: 20000 }).not.toBe('running');
        await api('POST', `/api/vms/${await index()}/delete`);
    }
});

/**
 * End-to-end Playwright coverage for the Hangar web UI workflows.
 *
 * Per AGENTS.md, every user-facing workflow must have an e2e Playwright test here. These drive the
 * real built `hangar-web` binary (launched by playwright.config.ts against a temp $HOME) through
 * the page's own controls and assert observable results.
 */
import { expect, test, type Page } from '@playwright/test';
import { chooseFromMenu, chooseTool, setTheme } from './app-ui';
import { api, createVm, parseJson, removeVms } from './daemon-api';

const SETTINGS_BUTTON = '.toolbar > [data-action="editVm"]';
const DEFAULT_DISPLAY_VNC = 3;

const vmCount = (page: Page): Promise<number> => page.locator('#vmlist .vm-item').count();

/** Load the app shell before every test. The server is shared, so earlier tests may have left VMs behind. */
test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#vmlist')).toBeVisible();
});

test('page loads and renders the VM list', async ({ page }) => {
    await expect(page.locator('#vmlist')).toBeVisible();
});

test('create VM workflow adds a VM to the list', async ({ page }) => {
    const before = await vmCount(page);
    const name = `E2E VM ${before}`;

    await page.locator('.new-vm-btn').click();
    await expect(page.locator('#newdlg')).toBeVisible();

    await page.fill('#n_name', name);
    await page.fill('#n_mem', '4096');
    await page.fill('#n_cpu', '4');
    await page.fill('#n_disk', '30');
    await page.locator('#newdlg button[type="submit"]').click();
    await expect(page.locator('#newdlg')).toHaveCount(0);

    await expect.poll(() => vmCount(page)).toBe(before + 1);
    await expect(page.locator('#vmlist .vm-item', { hasText: name })).toBeVisible();
});

test('new VMs default to the VNC display (web-usable, not GTK)', async ({ page }) => {
    /* GTK opens a host-native window the browser cannot show and disables the embedded console. */
    const index = await createVm(page, 'wf-default-display');
    const detail = await api(page, 'GET', `/api/vms/${index}`);
    expect(detail.ok).toBe(true);
    expect(parseJson(detail.text)).toMatchObject({ display: DEFAULT_DISPLAY_VNC });
    await removeVms(page, 'wf-default-display');
});

test('selecting a VM shows its summary', async ({ page }) => {
    await page.locator('#vmlist .vm-item').first().click();
    const summary = page.locator('#tabSummary');
    await expect(summary).toBeVisible();
    await expect(summary).not.toBeEmpty();
});

test('view QEMU log workflow opens the log dialog', async ({ page }) => {
    for (const theme of ['light', 'dark'] as const) {
        await setTheme(page, theme);
        await page.locator('#vmlist .vm-item').first().click();
        await page.locator('#tabSummary [data-action="viewLog"]').click();
        await expect(page.locator('#logdlg')).toBeVisible();
        /* The VM was never started, so the daemon has no log file yet; the dialog must say so, not hang on "Loading…". */
        await expect(page.locator('#logbody')).toContainText(/No log output yet|empty|Failed/i);
        const search = page.locator('#search');
        await expect(page.locator('#logbody')).toHaveCSS('background-color', await search.evaluate((el) => getComputedStyle(el).backgroundColor));
        await expect(page.locator('#logbody')).toHaveCSS('color', await search.evaluate((el) => getComputedStyle(el).color));
    }
});

test('edit settings workflow saves without losing the VM', async ({ page }) => {
    await page.locator('#vmlist .vm-item').first().click();
    await page.locator(SETTINGS_BUTTON).click();
    await expect(page.locator('#tabSettings')).toBeVisible();
    const nameBefore = await page.locator('#vmname').textContent();
    await page.locator('#savevmbtn').click();
    await expect(page.locator('#vmname')).toHaveText(nameBefore ?? '');
});

test('snapshot dialog opens', async ({ page }) => {
    await page.locator('#vmlist .vm-item').first().click();
    await chooseFromMenu(page, 'snapshotMenu', 'openSnapshots');
    await expect(page.locator('#snapdlg')).toBeVisible();
});

for (const [action, dialog, label] of [
    ['openPrefs', 'prefsdlg', 'preferences'],
    ['openVnets', 'vnetdlg', 'VNet editor'],
    ['openAbout', 'aboutdlg', 'about'],
] as const) {
    test(`${label} dialog opens`, async ({ page }) => {
        await chooseTool(page, action);
        await expect(page.locator(`#${dialog}`)).toBeVisible();
    });
}

test('keyboard shortcut "?" opens the shortcuts dialog', async ({ page }) => {
    for (const theme of ['light', 'dark'] as const) {
        await setTheme(page, theme);
        await page.keyboard.press('?');
        await expect(page.locator('#shortcutsdlg')).toBeVisible();
        await expect.poll(() => page.locator('#shortcutsdlg kbd').evaluateAll((keys) => {
            const shared = getComputedStyle(document.querySelector('#shortcutsdlg button') ?? document.body);
            return keys.length > 0 && keys.every((key) => {
                const style = getComputedStyle(key);
                return style.backgroundColor === shared.backgroundColor && style.borderRadius === shared.borderRadius;
            });
        })).toBe(true);
    }
});

test('theme workflow applies light then dark', async ({ page }) => {
    const toggle = page.locator('.theme-toggle-btn');
    /* The cycle runs system, light, dark, and a fresh profile starts on dark. */
    await toggle.click();
    await toggle.click();
    await expect(page.locator('html')).toHaveClass(/light/);
    await expect.poll(() => page.evaluate(() => localStorage.getItem('hangar-theme'))).toBe('light');
    await toggle.click();
    await expect(page.locator('html')).not.toHaveClass(/light/);
    await expect.poll(() => page.evaluate(() => localStorage.getItem('hangar-theme'))).toBe('dark');
});

test('reorder API returns ok for a no-op reorder', async ({ page }) => {
    const reply = await api(page, 'POST', '/api/vms/reorder', 'from=0&to=0');
    expect(reply.ok).toBe(true);
    expect(reply.text.trim()).toBe('ok');
});

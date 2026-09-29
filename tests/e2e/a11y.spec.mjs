// WCAG 2.2 AA gate: axe must report zero violations on the main views in both themes.
import AxeBuilder from '@axe-core/playwright';
import { test, expect } from '@playwright/test';

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'];
const SETTLE_MS = 600; // view transitions fade in; axe reads mid-fade colors otherwise

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
            for (const step of ['dashboard', 'summary', 'settings']) {
                if (step === 'summary') await row.click();
                if (step === 'settings') await page.locator('#tab-btn-settings').click();
                await page.waitForTimeout(SETTLE_MS);
                const { violations } = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze();
                expect(violations.map((v) => `${step}: ${v.id} ${v.nodes[0].target}`)).toEqual([]);
            }
        } finally {
            const idx = await page.evaluate(() => vms.findIndex((v) => v.name === 'a11y-vm'));
            await page.evaluate(async (i) => fetch(`/api/vms/${i}/delete`, { method: 'POST', headers: { 'X-API-Key': 'hangar' } }), idx);
        }
    });
}

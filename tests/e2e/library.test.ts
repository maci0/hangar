/** The VM library and host overview: folders, the inventory table and the capacity gauges. */
import { expect, test } from '@playwright/test';
import { loadApp } from './app-ui';
import { api, createVm, indexOf, listVms, removeVms, vmField } from './daemon-api';

const PERCENT = 100;
const CAPACITY_TIMEOUT_MS = 8000;

/** Orders names the way the dashboard does: by lower-cased text, code unit by code unit. */
const byLowerCase = (left: string, right: string): number => {
    const lowerLeft = left.toLowerCase();
    const lowerRight = right.toLowerCase();
    if (lowerLeft < lowerRight) {
        return -1;
    }
    return lowerLeft > lowerRight ? 1 : 0;
};

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

test('VM folders: the folder field groups the VM in a collapsible sidebar tree', async ({ page }) => {
    await createVm(page, 'wf-fld-a');
    const index = await indexOf(page, 'wf-fld-a');
    await api(page, 'POST', `/api/vms/${index}`, 'folder=TestFolder&tags=prod');
    /* The folder field round-trips through the list JSON. */
    await expect.poll(() => vmField(page, 'wf-fld-a', 'folder')).toBe('TestFolder');
    await page.reload();
    const header = page.locator('.folder-hdr[data-folder="TestFolder"]');
    await expect(header).toBeVisible();
    await expect(header).toHaveClass(/open/);
    await expect(page.locator('.folder-body')).toContainText('wf-fld-a');
    /* Collapsing the folder hides its rows. */
    await header.click();
    await expect(page.locator('.folder-hdr[data-folder="TestFolder"]')).not.toHaveClass(/open/);
    await expect(page.locator('.folder-body', { hasText: 'wf-fld-a' })).toHaveCount(0);
});

test('keyboard activates folder headers and sort headers (a11y)', async ({ page }) => {
    await createVm(page, 'wf-kbd-vm');
    const index = await indexOf(page, 'wf-kbd-vm');
    await api(page, 'POST', `/api/vms/${index}`, 'folder=KbdFolder');
    await page.reload();
    const header = page.locator('.folder-hdr[data-folder="KbdFolder"]');
    await expect(header).toHaveClass(/open/);
    await header.focus();
    /* Enter collapses the folder. */
    await page.keyboard.press('Enter');
    await expect(page.locator('.folder-hdr[data-folder="KbdFolder"]')).not.toHaveClass(/open/);
    /* A sort header activates by keyboard without error, and the table stays rendered. */
    const nameColumn = page.locator('.inv thead th[data-col="name"]');
    await nameColumn.focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('.inv tbody tr').first()).toBeVisible();
});

test('inventory table lists VMs, sorts by a column, and selects a row', async ({ page }) => {
    await createVm(page, 'wf-inv-zzz');
    await createVm(page, 'wf-inv-aaa');
    await page.reload();
    const rows = page.locator('.inv tbody tr');
    await expect.poll(() => rows.count()).toBeGreaterThanOrEqual(2);
    const nameRows = () => page.locator('.inv tbody tr td.inv-name').allTextContents();
    /* The dashboard sorts case-insensitively; match that (the shared daemon accumulates VMs across tests). */
    const ascending = await nameRows();
    expect(ascending).toEqual(ascending.toSorted(byLowerCase));
    /* The Name header toggles to descending. */
    await page.click('.inv thead th[data-col="name"]');
    expect(await nameRows()).toEqual(ascending.toReversed());
    /* Clicking a row selects that VM and leaves the dashboard for the detail view. */
    await page.click('.inv tbody tr');
    await expect(page.locator('#tabSummary .dash')).toHaveCount(0);
    await expect(page.locator('.vm-facts')).toBeVisible();
});

test('inventory sorts numeric columns by value and reports aria-sort', async ({ page }) => {
    try {
        await api(page, 'POST', '/api/vms', 'name=wf-ram-small&mem=256&cpu=1&disk=1');
        await api(page, 'POST', '/api/vms', 'name=wf-ram-big&mem=2048&cpu=1&disk=1');
        await page.reload();
        const header = page.locator('.inv thead th[data-col="mem"]');
        await expect(header).toHaveAttribute('aria-sort', 'none');
        await header.click();
        await expect(header).toHaveAttribute('aria-sort', 'ascending');
        const order = async () => {
            const names = await page.locator('.inv tbody tr td.inv-name').allTextContents();
            return names.filter((name) => name.startsWith('wf-ram-'));
        };
        expect(await order()).toEqual(['wf-ram-small', 'wf-ram-big']);
        await header.click();
        await expect(header).toHaveAttribute('aria-sort', 'descending');
        expect(await order()).toEqual(['wf-ram-big', 'wf-ram-small']);
        await expect(page.locator('.inv thead th[data-col="name"]')).toHaveAttribute('aria-sort', 'none');
    } finally {
        await removeVms(page, 'wf-ram-small', 'wf-ram-big');
    }
});

test('dashboard shows host capacity (committed vs physical)', async ({ page }) => {
    await api(page, 'POST', '/api/vms', 'name=cap-a&mem=2048&cpu=2&disk=10');
    await page.reload();
    /* No VM selected: the dashboard's host panel fetches /api/host and renders committed-vs-physical gauges. */
    const panel = page.locator('.cap-panel');
    await expect(panel).toContainText('Host Capacity', { timeout: CAPACITY_TIMEOUT_MS });
    await expect(panel).toContainText(/cores/);
    await expect(panel).toContainText(/vCPU committed/);
    await expect(panel).toContainText(/RAM committed/);
});

test('RAM capacity compares exact MiB at the overcommit boundary', async ({ page }) => {
    const created = await api(page, 'POST', '/api/vms', 'name=cap-boundary&mem=512&cpu=1&disk=1');
    expect(created.ok).toBe(true);
    const vms = await listVms(page);
    const committed = vms.reduce((sum, vm) => sum + Number(vm.mem), 0);
    let physical = committed - 1;
    await page.route('**/api/host', (route) => route.fulfill({ json: { cpu_cores: 4, ram_mb: physical } }));
    for (const capacity of [committed - 1, committed, committed + 1, 0]) {
        physical = capacity;
        await page.reload();
        const ram = page.locator('.cap-row').filter({ hasText: 'RAM committed' });
        await expect(ram.locator('.cap-val')).toHaveText(capacity > 0 ? `${committed} / ${capacity} MiB` : `${committed} MiB`);
        const overcommitted = capacity > 0 && committed > capacity;
        await expect(ram.locator('.cap-over')).toHaveText(overcommitted ? `${Math.round((committed / capacity) * PERCENT) / PERCENT}× overcommit` : '');
        await expect(ram.locator('.cap-fill')).toHaveClass(overcommitted ? /\bbg-danger\b/ : /\bbg-accent\b/);
    }
});

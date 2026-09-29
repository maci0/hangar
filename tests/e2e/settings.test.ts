/** The Settings tab (form, validation, dirty tracking, disk and CD tools) and the Summary tab. */
import { expect, test, type Page } from '@playwright/test';
import { loadApp, selectVm } from './app-ui';
import { api, createVm, indexOf, removeVms, vmField } from './daemon-api';

const POWER_ON_TIMEOUT_MS = 25_000;
const SAVED_MEMORY_MIB = 2048;

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

/** Opens the Settings tab of the VM called `name`. */
const openSettings = async (page: Page, name: string): Promise<void> => {
    await page.reload();
    await selectVm(page, name);
    await page.click('#tab-btn-settings');
    await expect(page.locator('.settings-panel.active')).toBeVisible();
};

const settingsCategory = (page: Page, category: string) => page.locator(`.settings-nav-item[data-settings-category="${category}"]`);

test('settings lock virtual hardware while the VM is running, metadata stays editable', async ({ page }) => {
    const name = 'wf-lock';
    await api(page, 'POST', '/api/vms', `name=${name}&mem=1024&cpu=1&disk=1&display=vnc&firmware=bios`);
    const index = await indexOf(page, name);
    await api(page, 'POST', `/api/vms/${index}/power`, '');
    try {
        await expect.poll(() => vmField(page, name, 'status'), { timeout: POWER_ON_TIMEOUT_MS }).toBe('running');
        await page.reload();
        await selectVm(page, name);
        await page.click('#tab-btn-settings');
        await expect(page.locator('.settings-runlock')).toBeVisible();
        await expect(page.locator('#e_mem')).toBeDisabled();
        await expect(page.locator('#e_cpu')).toBeDisabled();
        await expect(page.locator('#e_notes')).toBeEnabled();
        await expect(page.locator('#e_tags')).toBeEnabled();
    } finally {
        await api(page, 'POST', `/api/vms/${await indexOf(page, name)}/power`, '');
        await expect.poll(() => vmField(page, name, 'status'), { timeout: POWER_ON_TIMEOUT_MS }).not.toBe('running');
        await removeVms(page, name);
    }
});

test('settings nav shows one panel at a time and marks the current category', async ({ page }) => {
    try {
        await createVm(page, 'wf-set-nav');
        await openSettings(page, 'wf-set-nav');
        await expect(settingsCategory(page, 'basic')).toHaveAttribute('aria-current', 'page');
        await expect(page.locator('[data-settings-panel="basic"]')).toBeVisible();
        await expect(page.locator('[data-settings-panel="network_and_boot"]')).toBeHidden();
        await settingsCategory(page, 'network_and_boot').click();
        await expect(settingsCategory(page, 'network_and_boot')).toHaveAttribute('aria-current', 'page');
        await expect(settingsCategory(page, 'basic')).not.toHaveAttribute('aria-current', 'page');
        await expect(page.locator('[data-settings-panel="network_and_boot"]')).toBeVisible();
        await expect(page.locator('[data-settings-panel="basic"]')).toBeHidden();
        /* Every section of the form is reachable and every field keeps its e_<key> id. */
        for (const id of ['sharing', 'autoprotect', 'display_and_video', 'storage_and_notes', 'extra_disks', 'advanced']) {
            await settingsCategory(page, id).click();
            await expect(page.locator(`[data-settings-panel="${id}"]`)).toBeVisible();
            await expect(page.locator(`[data-settings-panel="${id}"] .settings-form > *`).first()).toBeVisible();
        }
        await expect(page.locator('#e_nic8_vnet')).toHaveCount(1);
        await expect(page.locator('#e_extra3_format')).toHaveCount(1);
    } finally {
        await removeVms(page, 'wf-set-nav');
    }
});

/** Puts a bad memory value and a bad MAC (in a section that is not showing) into the form, and checks the save is refused. */
const attemptInvalidSave = async (page: Page, index: number): Promise<void> => {
    const posts: Array<string | null> = [];
    page.on('request', (request) => {
        if (request.method() === 'POST' && request.url().endsWith(`/api/vms/${index}`)) {
            posts.push(request.postData());
        }
    });
    await page.locator('#e_mem').fill('64');
    await expect(page.locator('#err_e_mem')).toHaveText('Memory must be 128-65536 MB.');
    await expect(page.locator('#e_mem')).toHaveAttribute('aria-invalid', 'true');
    await settingsCategory(page, 'network_and_boot').click();
    await page.locator('#e_mac_address').fill('zz');
    await expect(page.locator('#err_e_mac_address')).toHaveText('Use XX:XX:XX:XX:XX:XX.');
    await settingsCategory(page, 'storage_and_notes').click();
    await page.click('#savevmbtn');
    await expect(page.locator('#toast-container')).toContainText('Fix highlighted settings before saving.');
    expect(posts, 'no request while a field is invalid').toHaveLength(0);
    /* The first bad field in nav order is memory, in Basic. */
    await expect(page.locator('.settings-nav-item.active')).toHaveAttribute('data-settings-category', 'basic');
    await expect(page.locator('#e_mem')).toBeFocused();
    await page.locator('#e_mem').fill(String(SAVED_MEMORY_MIB));
    await page.click('#savevmbtn');
    await expect(page.locator('.settings-nav-item.active')).toHaveAttribute('data-settings-category', 'network_and_boot');
    await expect(page.locator('#e_mac_address')).toBeFocused();
    expect(posts).toHaveLength(0);
};

test('settings validation blocks the save, lands on the first bad field, and the fixed form saves the exact edits', async ({ page }) => {
    try {
        const index = await createVm(page, 'wf-set-save');
        await openSettings(page, 'wf-set-save');
        await attemptInvalidSave(page, index);
        await page.locator('#e_mac_address').fill('52:54:00:12:34:56');
        await settingsCategory(page, 'basic').click();
        await page.locator('#e_name').fill('wf-set-saved');
        const sent = page.waitForRequest((request) => request.method() === 'POST' && request.url().endsWith(`/api/vms/${index}`));
        await page.click('#savevmbtn');
        const request = await sent;
        const body = request.postData() ?? '';
        expect(body.startsWith('name=wf-set-saved&mem=2048&cpu=1&cpu_sockets=1&')).toBe(true);
        expect(body).toContain('&mac_address=52%3A54%3A00%3A12%3A34%3A56&');
        await expect(page.locator('#tabSummary')).toBeVisible();
        await expect(page.locator('#statusannounce')).toHaveText('Settings saved.');
        await expect.poll(() => vmField(page, 'wf-set-saved', 'mac')).toBe('52:54:00:12:34:56');
        expect(await vmField(page, 'wf-set-saved', 'mem')).toBe(SAVED_MEMORY_MIB);
    } finally {
        await removeVms(page, 'wf-set-save', 'wf-set-saved');
    }
});

test('settings track unsaved edits: leaving asks, putting the value back does not', async ({ page }) => {
    try {
        await createVm(page, 'wf-set-dirty');
        await openSettings(page, 'wf-set-dirty');
        await settingsCategory(page, 'storage_and_notes').click();
        await page.locator('#e_notes').fill('draft');
        await page.click('#tab-btn-summary');
        await expect(page.locator('#confirmdlg')).toBeVisible();
        await page.locator('#confirmCancelBtn').click();
        await expect(page.locator('#confirmdlg')).toHaveCount(0);
        await expect(page.locator('#tabSettings')).toBeVisible();
        await expect(page.locator('#e_notes')).toHaveValue('draft');
        await page.locator('#e_notes').fill('');
        await page.click('#tab-btn-summary');
        await expect(page.locator('#confirmdlg')).toHaveCount(0);
        await expect(page.locator('#tabSummary')).toBeVisible();
        /* Discard drops the edit: the form opens again from the saved VM. */
        await page.click('#tab-btn-settings');
        await settingsCategory(page, 'storage_and_notes').click();
        await page.locator('#e_notes').fill('again');
        await page.click('#tab-btn-summary');
        await page.locator('#confirmOkBtn').click();
        await expect(page.locator('#tabSummary')).toBeVisible();
        await page.click('#tab-btn-settings');
        await settingsCategory(page, 'storage_and_notes').click();
        await expect(page.locator('#e_notes')).toHaveValue('');
    } finally {
        await removeVms(page, 'wf-set-dirty');
    }
});

test('settings disk tools resize and compact the primary disk', async ({ page }) => {
    try {
        await createVm(page, 'wf-set-disk');
        await openSettings(page, 'wf-set-disk');
        await page.locator('#tabSettings [data-action="resizeDisk"]').click();
        await expect(page.locator('#promptdlg')).toBeVisible();
        await page.locator('#promptInput').fill('1');
        await page.locator('#promptOkBtn').click();
        await expect(page.locator('#toast-container')).toContainText('Enter a size larger than 1 GB');
        await page.locator('#tabSettings [data-action="resizeDisk"]').click();
        await page.locator('#promptInput').fill('3');
        await page.locator('#promptOkBtn').click();
        await expect.poll(() => vmField(page, 'wf-set-disk', 'disk')).toBe(3);
        await expect(page.locator('#statusannounce')).toHaveText('Primary disk resized to 3 GB.');
        await page.locator('#tabSettings [data-action="compactDisk"]').click();
        await page.locator('#confirmOkBtn').click();
        await expect(page.locator('#statusannounce')).toHaveText('Primary disk compacted.');
    } finally {
        await removeVms(page, 'wf-set-disk');
    }
});

test('settings CD/ISO tools change then eject the ISO', async ({ page }) => {
    try {
        await createVm(page, 'wf-set-cd');
        await openSettings(page, 'wf-set-cd');
        await page.locator('#tabSettings [data-action="changeCd"]').click();
        await page.locator('#promptInput').fill('/tmp/wf-ui.iso');
        await page.locator('#promptOkBtn').click();
        await expect.poll(() => vmField(page, 'wf-set-cd', 'iso_path')).toBe('/tmp/wf-ui.iso');
        await page.locator('#tabSettings [data-action="ejectCd"]').click();
        await expect.poll(() => vmField(page, 'wf-set-cd', 'iso_path')).toBe('');
    } finally {
        await removeVms(page, 'wf-set-cd');
    }
});

test('summary shows facts, hardware, disk usage, tags, folder, notes and warnings', async ({ page }) => {
    try {
        const index = await createVm(page, 'wf-sum');
        const saved = await api(page, 'POST', `/api/vms/${index}`, 'notes=line%20one&tags=prod%2Cweb&folder=Lab&network=none');
        expect(saved.ok).toBe(true);
        await page.reload();
        await selectVm(page, 'wf-sum');
        const facts = page.locator('.vm-facts');
        await expect(facts).toContainText('Stopped');
        await expect(facts).toContainText('1 vCPU');
        await expect(facts).toContainText('1 GiB RAM');
        await expect(facts).toContainText('1 GB disk');
        await expect(facts).not.toContainText('IP');
        await expect(page.locator('.srow', { hasText: 'Hard Disk' })).toContainText('1 GB');
        await expect(page.locator('#diskUsageVal')).toContainText(/used \/ 1\.0 GiB \(\d+%\)/);
        await expect(page.locator('.srow', { hasText: 'Network' })).toContainText('Disconnected');
        await expect(page.locator('.srow', { hasText: 'Guest Tools' })).toContainText('not installed');
        await expect(page.locator('#tabSummary section', { hasText: 'Tags' })).toContainText('prod');
        await expect(page.locator('#tabSummary section', { hasText: 'Tags' })).toContainText('web');
        await expect(page.locator('#tabSummary section', { hasText: 'Folder' })).toContainText('Lab');
        await expect(page.locator('#tabSummary section', { hasText: 'Notes' })).toContainText('line one');
        await expect(page.locator('#tabSummary')).toContainText('Network adapter is disconnected.');
        await expect(page.locator('#tabSummary [data-action="takeScreenshot"]')).toHaveCount(0);
        await page.locator('#tabSummary [data-action="viewLog"]').click();
        await expect(page.locator('#logdlg')).toBeVisible();
        await page.keyboard.press('Escape');
        await expect(page.locator('#logdlg')).toHaveCount(0);
        /* With nothing selected the dashboard lists the same VM under "Needs attention". */
        await page.locator('.toolbar > [data-action="deselectVm"]').click();
        await expect(page.locator('.dash-attention')).toContainText('wf-sum');
    } finally {
        await removeVms(page, 'wf-sum');
    }
});

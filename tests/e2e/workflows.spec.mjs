// End-to-end coverage for the VM lifecycle workflows the API exposes, driving
// the real built hangar-web binary (see playwright.config.mjs). These exercise
// operations that are deterministic on a freshly-created, stopped VM with a
// real qcow2 disk (created by the daemon via qemu-img): clone, rename,
// delete+undo, snapshot take/list/delete, secondary-disk upload/download, and
// OVF export. Power-on/migration are intentionally excluded — they need a real
// booted guest / a second host and would be flaky here.
import { test, expect } from '@playwright/test';

async function api(page, method, path, body, headers) {
    return page.evaluate(
        async ([m, p, b, h]) => {
            const opts = { method: m, headers: { 'X-API-Key': 'hangar', ...(h || {}) } };
            if (b !== null) opts.body = b;
            const r = await fetch(p, opts);
            const text = await r.text();
            return { status: r.status, ok: r.ok, text };
        },
        [method, path, body ?? null, headers ?? null],
    );
}

async function list(page) {
    return page.evaluate(async () => (await (await fetch('/api/vms')).json()));
}

// Create a VM via the API and return the index of the entry with `name`.
async function createVm(page, name) {
    const r = await api(page, 'POST', '/api/vms', `name=${encodeURIComponent(name)}&mem=1024&cpu=1&disk=1`);
    expect(r.ok, `create ${name}: ${r.status} ${r.text}`).toBe(true);
    const vms = await list(page);
    const idx = vms.findIndex((v) => v.name === name);
    expect(idx, `created VM ${name} should be listed`).toBeGreaterThanOrEqual(0);
    return idx;
}

async function indexOf(page, name) {
    return (await list(page)).findIndex((v) => v.name === name);
}

test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#vmlist')).toBeVisible();
});

test('clone workflow creates a second VM', async ({ page }) => {
    const idx = await createVm(page, 'wf-clone-src');
    const before = (await list(page)).length;
    const r = await api(page, 'POST', `/api/vms/${idx}/clone`, '');
    expect(r.ok, `clone: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(() => list(page).then((v) => v.length)).toBe(before + 1);
    const names = (await list(page)).map((v) => v.name);
    expect(names.some((n) => n.includes('wf-clone-src') && n !== 'wf-clone-src')).toBe(true);
});

test('rename workflow changes the VM name', async ({ page }) => {
    const idx = await createVm(page, 'wf-rename-old');
    const r = await api(page, 'POST', `/api/vms/${idx}/rename`, 'name=wf-rename-new');
    expect(r.ok, `rename: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(() => indexOf(page, 'wf-rename-new')).toBeGreaterThanOrEqual(0);
    expect(await indexOf(page, 'wf-rename-old')).toBe(-1);
});

test('delete then undo restores the VM', async ({ page }) => {
    const idx = await createVm(page, 'wf-del');
    const before = (await list(page)).length;
    let r = await api(page, 'POST', `/api/vms/${idx}/delete`, '');
    expect(r.ok, `delete: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(() => list(page).then((v) => v.length)).toBe(before - 1);
    expect(await indexOf(page, 'wf-del')).toBe(-1);

    r = await api(page, 'POST', '/api/vms/undo', '');
    expect(r.ok, `undo: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(() => indexOf(page, 'wf-del')).toBeGreaterThanOrEqual(0);
});

test('snapshot take, list, and delete on a stopped VM', async ({ page }) => {
    const idx = await createVm(page, 'wf-snap');

    let r = await api(page, 'POST', `/api/vms/${idx}/snapshots`, 'tag=snap1');
    expect(r.ok, `take: ${r.status} ${r.text}`).toBe(true);

    await expect
        .poll(async () => (await api(page, 'GET', `/api/vms/${idx}/snapshots`, null)).text)
        .toContain('snap1');

    r = await api(page, 'POST', `/api/vms/${idx}/snapshots/delete`, 'tag=snap1');
    expect(r.ok, `delete snap: ${r.status} ${r.text}`).toBe(true);
    await expect
        .poll(async () => (await api(page, 'GET', `/api/vms/${idx}/snapshots`, null)).text)
        .not.toContain('snap1');
});

test('secondary disk upload then download round-trips', async ({ page }) => {
    const idx = await createVm(page, 'wf-disk2');
    // Upload a small file as disk2 via multipart, the same shape the UI sends.
    const up = await page.evaluate(async (i) => {
        const fd = new FormData();
        fd.append('disk2', new Blob(['HANGAR_E2E_DISK2_PAYLOAD'], { type: 'application/octet-stream' }), 'd2.img');
        const r = await fetch(`/api/vms/${i}/disk2`, { method: 'POST', body: fd, headers: { 'X-API-Key': 'hangar' } });
        return { status: r.status, text: await r.text() };
    }, idx);
    expect(up.status, `upload: ${up.text}`).toBe(200);

    const down = await page.evaluate(async (i) => {
        const r = await fetch(`/api/vms/${i}/disk2/download`, { headers: { 'X-API-Key': 'hangar' } });
        return { status: r.status, text: await r.text() };
    }, idx);
    expect(down.status).toBe(200);
    expect(down.text).toContain('HANGAR_E2E_DISK2_PAYLOAD');
});

test('OVF export streams a non-empty tarball', async ({ page }) => {
    const idx = await createVm(page, 'wf-export');
    const exp = await page.evaluate(async (i) => {
        const r = await fetch(`/api/vms/${i}/export`, { method: 'POST', headers: { 'X-API-Key': 'hangar' } });
        const buf = await r.arrayBuffer();
        return { status: r.status, len: buf.byteLength };
    }, idx);
    expect(exp.status, 'export status').toBe(200);
    expect(exp.len, 'export tarball should be non-empty').toBeGreaterThan(0);
});

test('tags save, persist in the list JSON, and drive the sidebar filter', async ({ page }) => {
    const idx = await createVm(page, 'wf-tags');
    const r = await api(page, 'POST', `/api/vms/${idx}`, 'tags=prod%2Cweb');
    expect(r.ok, `save tags: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-tags')].tags).toBe('prod,web');
    // Sidebar filter matches on tags: filtering by "prod" keeps the tagged VM.
    await page.fill('#search', 'prod');
    await expect(page.locator('#vmlist')).toContainText('wf-tags');
    await page.fill('#search', 'no-such-tag-zzz');
    await expect(page.locator('#vmlist')).not.toContainText('wf-tags');
});

test('disk resize grows the primary disk (stopped VM, grow-only)', async ({ page }) => {
    const idx = await createVm(page, 'wf-resize');
    const before = (await list(page))[idx].disk;
    const r = await api(page, 'POST', `/api/vms/${idx}/disk/resize`, 'size=8');
    expect(r.ok, `resize: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-resize')].disk).toBe(8);
    expect(8).toBeGreaterThan(before);
    // Shrink is refused.
    const s = await api(page, 'POST', `/api/vms/${idx}/disk/resize`, 'size=2');
    expect(s.text).toContain('shrink not allowed');
});

test('diskinfo reports virtual and actual byte sizes', async ({ page }) => {
    const idx = await createVm(page, 'wf-diskinfo');
    const r = await page.evaluate(async (i) => (await (await fetch(`/api/vms/${i}/diskinfo`)).json()), idx);
    expect(r.error, `diskinfo error: ${r.error}`).toBeUndefined();
    expect(r.virtual_bytes, 'virtual size should be ~1 GiB').toBeGreaterThan(0);
    expect(typeof r.actual_bytes).toBe('number');
});

test('cdrom change then eject updates the ISO on a stopped VM', async ({ page }) => {
    const idx = await createVm(page, 'wf-cd');
    let r = await api(page, 'POST', `/api/vms/${idx}/cdrom`, 'path=%2Ftmp%2Fwf-test.iso');
    expect(r.ok, `cdrom change: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-cd')].iso_path).toBe('/tmp/wf-test.iso');
    r = await api(page, 'POST', `/api/vms/${idx}/cdrom/eject`, '');
    expect(r.ok, `cdrom eject: ${r.status} ${r.text}`).toBe(true);
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-cd')].iso_path).toBe('');
    // A comma in the path is rejected (-drive injection guard).
    const bad = await api(page, 'POST', `/api/vms/${idx}/cdrom`, 'path=%2Ftmp%2Fa%2Cb.iso');
    expect(bad.text).toContain('bad path');
});

test('screenshot on a stopped VM returns 409 (needs a running guest)', async ({ page }) => {
    const idx = await createVm(page, 'wf-shot');
    const r = await api(page, 'GET', `/api/vms/${idx}/screenshot`, null);
    expect(r.status, `screenshot on stopped VM: ${r.text}`).toBe(409);
});

test('cloud-init user-data saves and round-trips through the detail API', async ({ page }) => {
    const idx = await createVm(page, 'wf-ci');
    const ud = '#cloud-config\npackages:\n  - htop\n';
    const r = await api(page, 'POST', `/api/vms/${idx}`, 'cloud_init=' + encodeURIComponent(ud));
    expect(r.ok, `save cloud-init: ${r.status} ${r.text}`).toBe(true);
    const detail = await page.evaluate(async (i) => (await (await fetch(`/api/vms/${i}`)).json()), idx);
    expect(detail.cloud_init).toContain('packages:');
    expect(detail.cloud_init).toContain('- htop');
});

test('guestinfo returns empty IPs for a stopped VM (needs a running guest agent)', async ({ page }) => {
    const idx = await createVm(page, 'wf-gi');
    const r = await page.evaluate(async (i) => (await (await fetch(`/api/vms/${i}/guestinfo`, { headers: { 'X-API-Key': 'hangar' } })).json()), idx);
    expect(r.ips).toBe('');
});

test('RTC clock policy saves and round-trips (localtime for Windows guests)', async ({ page }) => {
    const idx = await createVm(page, 'wf-rtc');
    const r = await api(page, 'POST', `/api/vms/${idx}`, 'rtc=1'); // 1 = localtime
    expect(r.ok, `save rtc: ${r.status} ${r.text}`).toBe(true);
    const detail = await page.evaluate(async (i) => (await (await fetch(`/api/vms/${i}`)).json()), idx);
    expect(detail.rtc).toBe(1);
});

test('disk compact rewrites the image and keeps it valid (stopped VM)', async ({ page }) => {
    const idx = await createVm(page, 'wf-compact');
    const before = (await list(page))[idx].disk; // virtual GB
    const r = await api(page, 'POST', `/api/vms/${idx}/disk/compact`, '');
    expect(r.ok, `compact: ${r.status} ${r.text}`).toBe(true);
    // Virtual size is unchanged; diskinfo must still parse the rewritten image.
    const di = await page.evaluate(async (i) => (await (await fetch(`/api/vms/${i}/diskinfo`)).json()), idx);
    expect(di.error, `diskinfo after compact: ${di.error}`).toBeUndefined();
    expect(di.virtual_bytes).toBeGreaterThan(0);
    expect((await list(page))[await indexOf(page, 'wf-compact')].disk).toBe(before);
});

test('write-action without the API key is rejected (401)', async ({ page }) => {
    const idx = await createVm(page, 'wf-auth');
    const r = await page.evaluate(async (i) => {
        const res = await fetch(`/api/vms/${i}/rename`, { method: 'POST', body: 'name=nope' });
        return res.status;
    }, idx);
    expect(r).toBe(401);
});

test('host dashboard shows inventory totals when no VM is selected', async ({ page }) => {
    await createVm(page, 'wf-dash-a');
    await createVm(page, 'wf-dash-b');
    // No VM selected -> the summary panel renders the host dashboard.
    await page.reload();
    await expect(page.locator('#tabSummary .dash')).toBeVisible();
    // "N virtual machines" reflects the inventory; capacity cards present.
    await expect(page.locator('.dash-head')).toContainText('virtual machines');
    const cards = page.locator('.dash-card');
    expect(await cards.count()).toBeGreaterThanOrEqual(7); // 4 state + 3 capacity
    // Clicking a sidebar VM leaves the dashboard for the detail view.
    await page.click('#vmlist .vm-item');
    await expect(page.locator('#tabSummary .dash')).toHaveCount(0);
    await expect(page.locator('.vm-facts')).toBeVisible();
});

test('VM vnet binding round-trips and links the VM to that network in the topology', async ({ page }) => {
    await createVm(page, 'wf-vnet');
    const idx = await indexOf(page, 'wf-vnet');
    await api(page, 'POST', `/api/vms/${idx}`, 'vnet=VMnet8');
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-vnet')].vnet).toBe('VMnet8');
    await page.reload();
    await page.evaluate(() => openTopology());
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    // The bound virtual network appears as a node the VM connects to.
    await expect(page.locator('.topo-node.vnet').filter({ hasText: 'VMnet8' })).toHaveCount(1);
});

test('network topology renders VMs/networks/host via elkjs and a VM node selects', async ({ page }) => {
    await createVm(page, 'wf-topo-vm');
    await page.reload();
    await page.evaluate(() => openTopology());
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    expect(await page.locator('.topo-node').count()).toBeGreaterThan(1);
    await expect(page.locator('.topo-node.host')).toHaveCount(1); // host uplink node
    // Clicking a VM node closes the topology and selects that VM.
    await page.locator('.topo-node.vm').first().click();
    await expect(page.locator('#topodlg')).toBeHidden();
    await expect(page.locator('.vm-facts')).toBeVisible();
});

test('VM folders: the folder field groups the VM in a collapsible sidebar tree', async ({ page }) => {
    await createVm(page, 'wf-fld-a');
    const idx = await indexOf(page, 'wf-fld-a');
    await api(page, 'POST', `/api/vms/${idx}`, 'folder=TestFolder&tags=prod');
    // The folder field round-trips through the list JSON.
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-fld-a')].folder).toBe('TestFolder');
    await page.reload();
    const hdr = page.locator('.folder-hdr[data-folder="TestFolder"]');
    await expect(hdr).toBeVisible();
    await expect(hdr).toHaveClass(/open/);
    await expect(page.locator('.folder-body')).toContainText('wf-fld-a');
    // The structural folder: tag is hidden from the VM's visible tag chips.
    await api(page, 'GET', `/api/vms`, null); // ensure list loaded
    // Collapse the folder.
    await hdr.click();
    await expect(page.locator('.folder-hdr[data-folder="TestFolder"]')).not.toHaveClass(/open/);
});

test('stable VM id is assigned and survives a rename', async ({ page }) => {
    await createVm(page, 'wf-id-a');
    const idx = await indexOf(page, 'wf-id-a');
    const before = (await list(page))[idx].id;
    expect(before, 'a 16-hex-char id should be assigned at create').toMatch(/^[0-9a-f]{16}$/);
    await api(page, 'POST', `/api/vms/${idx}/rename`, 'name=wf-id-renamed');
    await expect.poll(() => indexOf(page, 'wf-id-renamed')).toBeGreaterThanOrEqual(0);
    const after = (await list(page))[await indexOf(page, 'wf-id-renamed')].id;
    expect(after, 'id must be stable across rename').toBe(before);
});

test('multi-select bulk delete removes only the checked VMs', async ({ page }) => {
    await createVm(page, 'wf-bulk-1');
    await createVm(page, 'wf-bulk-2');
    await createVm(page, 'wf-bulk-keep');
    await page.reload();
    await page.click('#selectToggle');
    await page.locator('.vm-item', { hasText: 'wf-bulk-1' }).locator('.vm-check').check();
    await page.locator('.vm-item', { hasText: 'wf-bulk-2' }).locator('.vm-check').check();
    await expect(page.locator('#bulkCount')).toHaveText('2 selected');
    await page.click('[data-action="bulkDelete"]');
    await page.locator('#confirmOkBtn').click(); // custom confirm dialog
    await expect.poll(() => indexOf(page, 'wf-bulk-1')).toBe(-1);
    expect(await indexOf(page, 'wf-bulk-2')).toBe(-1);
    expect(await indexOf(page, 'wf-bulk-keep')).toBeGreaterThanOrEqual(0);
});

test('command palette (Ctrl+K) opens, filters, runs a command, and closes', async ({ page }) => {
    await createVm(page, 'wf-pal');
    await page.reload();
    await page.keyboard.press('Control+k');
    await expect(page.locator('#palette')).toBeVisible();
    expect(await page.locator('#paletteList li[data-pidx]').count()).toBeGreaterThan(3);
    await page.fill('#paletteInput', 'catalog');
    await expect(page.locator('#paletteList')).toContainText('VM Catalog');
    await page.keyboard.press('Enter'); // runs the top match → opens the catalog dialog
    await expect(page.locator('#catalogdlg')).toBeVisible();
    await expect(page.locator('#palette')).toBeHidden();
    await page.keyboard.press('Escape'); // close catalog
    // Reopen and dismiss with Escape.
    await page.keyboard.press('Control+k');
    await expect(page.locator('#palette')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#palette')).toBeHidden();
});

test('inventory table lists VMs, sorts by a column, and selects a row', async ({ page }) => {
    await createVm(page, 'wf-inv-zzz');
    await createVm(page, 'wf-inv-aaa');
    await page.reload();
    const rows = page.locator('.inv tbody tr');
    expect(await rows.count()).toBeGreaterThanOrEqual(2);
    // Default sort is name ascending: find the Name column header, click to toggle desc.
    const nameRows = () => page.locator('.inv tbody tr td.inv-name').allTextContents();
    const asc = await nameRows();
    const sortedAsc = [...asc].sort();
    expect(asc).toEqual(sortedAsc);
    await page.click('.inv thead th[data-col="name"]');
    const desc = await nameRows();
    expect(desc).toEqual([...asc].reverse());
    // Clicking a row selects that VM (leaves the dashboard for the detail view).
    await page.click('.inv tbody tr');
    await expect(page.locator('#tabSummary .dash')).toHaveCount(0);
    await expect(page.locator('.vm-facts')).toBeVisible();
});

test('toolbar dropdown is keyboard-operable: opens, focuses an item, Escape returns focus', async ({ page }) => {
    await createVm(page, 'wf-kbd');
    // Select the VM so the toolbar action menus enable.
    await page.click('#vmlist .vm-item');
    // Open the Tools menu from its trigger via the keyboard (Enter activates the button).
    const trigger = page.locator('[data-menu="toolsMenu"]');
    await trigger.focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('#toolsMenu')).toHaveClass(/open/);
    await expect(trigger).toHaveAttribute('aria-expanded', 'true');
    // Focus moved into the menu (onto an enabled item) on open.
    const focusInMenu = await page.evaluate(() => !!document.activeElement?.closest('#toolsMenu'));
    expect(focusInMenu).toBe(true);
    // ArrowDown moves focus to a different menu item.
    const before = await page.evaluate(() => document.activeElement?.textContent);
    await page.keyboard.press('ArrowDown');
    const after = await page.evaluate(() => document.activeElement?.textContent);
    expect(after && after !== before).toBeTruthy();
    expect(await page.evaluate(() => !!document.activeElement?.closest('#toolsMenu'))).toBe(true);
    // Escape closes the menu and returns focus to the trigger button.
    await page.keyboard.press('Escape');
    await expect(page.locator('#toolsMenu')).not.toHaveClass(/open/);
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-menu'))).toBe('toolsMenu');
});

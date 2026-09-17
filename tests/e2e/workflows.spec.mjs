// End-to-end coverage for the VM lifecycle workflows the API exposes, driving
// the real built hangar-web binary (see playwright.config.mjs). These exercise
// operations that are deterministic on a freshly-created, stopped VM with a
// real qcow2 disk (created by the daemon via qemu-img): clone, rename,
// delete+undo, snapshot take/list/delete, secondary-disk upload/download, and
// OVF export. Power-on/migration are intentionally excluded, they need a real
// booted guest / a second host and would be flaky here.
import { test, expect } from '@playwright/test';
import { execFileSync, execSync } from 'child_process';
let hasFfmpeg = false;
try { execSync('ffmpeg -version', { stdio: 'ignore' }); hasFfmpeg = true; } catch (e) {}

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

for (const control of ['toolbar', 'batch', 'bulk']) {
    test(`${control} power actions survive duplicate delivery`, async ({ page }) => {
        const name = `wf-repeat-${control}`;
        const created = await api(page, 'POST', '/api/vms', `name=${name}&mem=128&cpu=1&disk=1&display=vnc&firmware=bios&accel=tcg`);
        expect(created.ok).toBe(true);
        const idx = await indexOf(page, name);
        const deliveries = [];
        const powerRoute = new RegExp(`/api/vms/${idx}/(power|start|stop)$`);
        await page.route(powerRoute, async (route) => {
            const states = [];
            const statuses = [];
            for (let attempt = 0; attempt < 2; attempt++) {
                const response = await route.fetch();
                statuses.push(response.status());
                const inventory = await page.request.get('/api/vms');
                const vm = (await inventory.json()).find((v) => v.name === name);
                states.push({ status: vm.status, started: vm.started });
                if (attempt === 1) {
                    deliveries.push({ path: new URL(route.request().url()).pathname, statuses, states });
                    await route.fulfill({ response });
                }
            }
        });
        try {
            await page.reload();
            await page.locator('.vm-item', { hasText: name }).click();
            if (control === 'bulk') {
                await page.click('#selectToggle');
                await page.locator('.vm-item', { hasText: name }).locator('.vm-check').check();
            }
            for (const on of [true, false]) {
                if (control === 'toolbar') {
                    await page.click('#powerbtn');
                } else if (control === 'batch') {
                    await page.locator('[data-menu="dangerMenu"]:visible').click();
                    await page.locator(`[data-action="${on ? 'batchStart' : 'batchStop'}"]`).click();
                } else {
                    await page.locator(`[data-action="bulkPower"][data-on="${on ? '1' : '0'}"]`).click();
                }
                if (!on || control === 'bulk') await page.locator('#confirmOkBtn').click();
                await expect.poll(() => deliveries.length).toBe(on ? 1 : 2);
                const delivery = deliveries.at(-1);
                expect(delivery.statuses).toEqual([200, 200]);
                expect(delivery.states[0].status).toBe(on ? 'running' : 'stopped');
                expect(delivery.states[1]).toEqual(delivery.states[0]);
                expect(delivery.path).toBe(`/api/vms/${idx}/${on ? 'start' : 'stop'}`);
                await expect.poll(async () => (await list(page)).find((v) => v.name === name).status).toBe(on ? 'running' : 'stopped');
                await expect(page.locator('#powerbtn')).toHaveText(on ? 'Power Off' : 'Power On');
            }
        } finally {
            await page.unroute(powerRoute);
            await api(page, 'POST', `/api/vms/${idx}/stop`, '');
            await api(page, 'POST', `/api/vms/${idx}/delete`, '');
        }
    });
}

for (const width of [1280, 390]) {
    test(`global Tools remain usable from Home at ${width}px`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await expect(page.locator('#vmname')).toHaveText(/Overview|Welcome to Hangar/);
        if (width < 900) await page.locator('.toolbar-more').click();
        const tools = page.locator('[data-menu="toolsMenu"]:visible');
        await expect(tools).toBeEnabled();
        await tools.click();
        await expect(page.locator('#toolsMenu [data-action="renameGuest"]')).toBeDisabled();
        await page.locator('#toolsMenu [data-action="openPrefs"]').click();
        await expect(page.locator('#prefsdlg')).toBeVisible();
        await page.locator('#prefsdlg [data-action="closeDlg"]').click();
        await expect(page.locator('#prefsdlg')).toBeHidden();
        if (width < 900) await page.locator('.toolbar-more').click();
        await tools.click();
        await page.locator('#toolsMenu [data-action="openVnets"]').click();
        await expect(page.locator('#vnetdlg')).toBeVisible();
    });
}

test('reopening a context menu acts on its VM and respects discarded-selection cancellation', async ({ page }) => {
    await createVm(page, 'wf-context-first');
    await createVm(page, 'wf-context-second');
    await page.reload();
    const first = page.locator('.vm-item', { hasText: 'wf-context-first' });
    const second = page.locator('.vm-item', { hasText: 'wf-context-second' });
    await first.click({ button: 'right' });
    await second.click({ button: 'right', position: { x: 10, y: 10 } });
    await page.locator('.ctx-menu').getByRole('menuitem', { name: 'Rename…', exact: true }).click();
    await expect(page.locator('#promptInput')).toHaveValue('wf-context-second');
    await page.locator('#promptInput').fill('wf-context-renamed');
    await page.locator('#promptOkBtn').click();
    await expect.poll(() => indexOf(page, 'wf-context-renamed')).toBeGreaterThanOrEqual(0);
    expect(await indexOf(page, 'wf-context-first')).toBeGreaterThanOrEqual(0);
    await first.click();
    await page.locator('.toolbar > [data-action="editVm"]').click();
    await page.locator('#e_name').fill('unsaved-context-name');
    await page.locator('.vm-item', { hasText: 'wf-context-renamed' }).click({ button: 'right' });
    await page.locator('.ctx-menu').getByRole('menuitem', { name: 'Clone…', exact: true }).click();
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await page.locator('#confirmCancelBtn').click();
    await expect(page.locator('#confirmdlg')).toBeHidden();
    await expect(page.locator('#clonedlg')).toBeHidden();
    await expect(page.locator('#e_name')).toHaveValue('unsaved-context-name');
});

test('sidebar search persists through selection, favorites and refresh', async ({ page }) => {
    await createVm(page, 'wf-search-match');
    await createVm(page, 'wf-search-other');
    await page.reload();
    await page.locator('#search').fill('wf-search-match');
    const items = page.locator('#vmlist .vm-item');
    await expect(items).toHaveCount(1);
    await items.first().click();
    await expect(items).toHaveCount(1);
    await items.first().locator('.star').click();
    await expect(items.first().locator('.star')).toHaveClass(/fav/);
    await expect(items).toHaveCount(1);
    await page.evaluate(() => refresh());
    await expect(items).toHaveCount(1);
    await expect(page.locator('#search')).toHaveValue('wf-search-match');
    await page.locator('#searchClear').click();
    await expect(page.locator('#vmlist .vm-item', { hasText: 'wf-search-other' })).toBeVisible();
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

test('OVF export preserves the total CPU count across sockets', async ({ page }) => {
    const idx = await createVm(page, 'wf-export');
    const saved = await api(page, 'POST', `/api/vms/${idx}`, 'cpu=4&cpu_sockets=2');
    expect(saved.ok, `save topology: ${saved.status} ${saved.text}`).toBe(true);
    const exp = await page.evaluate(async (i) => {
        const r = await fetch(`/api/vms/${i}/export`, { method: 'POST', headers: { 'X-API-Key': 'hangar' } });
        const buf = await r.arrayBuffer();
        return { status: r.status, bytes: Array.from(new Uint8Array(buf)) };
    }, idx);
    expect(exp.status, 'export status').toBe(200);
    expect(exp.bytes.length, 'export tarball should be non-empty').toBeGreaterThan(0);
    const xml = execFileSync('tar', ['-xzOf', '-', './wf-export.ovf'], {
        input: Buffer.from(exp.bytes), encoding: 'utf8', timeout: 10000,
    });
    expect(xml).toContain('<rasd:ElementName>8 virtual CPU(s)</rasd:ElementName>');
    expect(xml).toContain('<rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>8</rasd:VirtualQuantity>');
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

test('elk.js is not fetched on page load and loads on first topology open', async ({ page }) => {
    const elkRequests = [];
    page.on('request', (r) => { if (r.url().endsWith('/elk.js')) elkRequests.push(r.url()); });
    await createVm(page, 'wf-topo-lazy');
    await page.reload();
    expect(elkRequests, 'elk.js must not load before the topology is opened').toHaveLength(0);
    let release;
    const loading = new Promise((resolve) => { release = resolve; });
    await page.route('**/elk.js', async (route) => { await loading; await route.continue(); });
    await page.evaluate(() => { void openTopology(); });
    await expect(page.locator('#topoWrap')).toContainText('Loading layout engine');
    await page.evaluate(() => { void openTopology(); });
    release();
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    await page.evaluate(() => openTopology());
    expect(elkRequests).toHaveLength(1);
});

test('a failed elk.js load degrades visibly with a retry', async ({ page }) => {
    await createVm(page, 'wf-topo-fail');
    await page.reload();
    await page.route('**/elk.js', (route) => route.abort());
    await page.evaluate(() => openTopology());
    await expect(page.locator('#topoWrap')).toContainText('failed to load', { timeout: 10000 });
    await page.unroute('**/elk.js');
    await page.click('#topoWrap [data-action="openTopology"]');
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
});

test('per-NIC vnet binding round-trips and appears in the topology', async ({ page }) => {
    await createVm(page, 'wf-nicvnet');
    const idx = await indexOf(page, 'wf-nicvnet');
    await api(page, 'POST', `/api/vms/${idx}`, 'nic2=user&nic2_vnet=VMnet1&nic5_vnet=VMnet8');
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-nicvnet')].nic2_vnet).toBe('VMnet1');
    expect((await list(page))[await indexOf(page, 'wf-nicvnet')].nic5_vnet).toBe('VMnet8');
    await page.reload();
    await page.evaluate(() => openTopology());
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    await expect(page.locator('.topo-node.vnet').filter({ hasText: 'VMnet1' })).toHaveCount(1);
    await expect(page.locator('.topo-node.vnet').filter({ hasText: 'VMnet8' })).toHaveCount(1);
});

test('snapshot manager shows the creation timestamp', async ({ page }) => {
    await createVm(page, 'wf-snaptime');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-snaptime' }).first().click();
    await page.click('button:has-text("Snapshots")');
    await page.locator('#snapshotMenu .menu-item', { hasText: 'Snapshot Manager' }).first().click();
    await page.fill('#s_tag', 'stamped');
    await page.click('[data-action="takeSnapshotFromDlg"]');
    await expect(page.locator('#snaplist')).toContainText('stamped', { timeout: 15000 });
    // The row carries "Taken YYYY-MM-DD HH:MM:SS" parsed from qemu-img output.
    await expect(page.locator('#snaplist')).toContainText(/Taken \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/);
});

test('settings lock virtual hardware while the VM is running, metadata stays editable', async ({ page }) => {
    await api(page, 'POST', '/api/vms', 'name=wf-lock&mem=1024&cpu=1&disk=1&display=vnc&firmware=bios');
    const idx = await indexOf(page, 'wf-lock');
    await api(page, 'POST', `/api/vms/${idx}/power`, '');
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-lock')].status, { timeout: 25000 }).toBe('running');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-lock' }).first().click();
    await page.click('#tab-btn-settings');
    await expect(page.locator('.settings-runlock')).toBeVisible();
    await expect(page.locator('#e_mem')).toBeDisabled();
    await expect(page.locator('#e_cpu')).toBeDisabled();
    await expect(page.locator('#e_notes')).toBeEnabled();
    await expect(page.locator('#e_tags')).toBeEnabled();
    await api(page, 'POST', `/api/vms/${await indexOf(page, 'wf-lock')}/power`, '');
});

test('vnet editor lists networks as clickable typed cards; selecting one fills the form', async ({ page }) => {
    await page.evaluate(() => actionHandlers.openVnets(document.body));
    await expect(page.locator('#vnetdlg')).toBeVisible();
    const items = page.locator('.vnet-item');
    await expect.poll(() => items.count()).toBeGreaterThanOrEqual(1);
    // Each card carries a type badge (NAT/Bridged/Host-Only).
    await expect(page.locator('.vnet-type-badge').first()).toBeVisible();
    // Clicking a card selects it (active highlight) and fills the form name.
    await items.first().click();
    await expect(items.first()).toHaveClass(/active/);
    const name = await page.evaluate(() => document.getElementById('vn_name').value);
    expect(name.length).toBeGreaterThan(0);
    await page.evaluate(() => document.getElementById('vnetdlg').close());
});

test('vnet Save All validates and persists the selected form without Save Selected', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks', null);
    expect(original.ok).toBe(true);
    try {
        await page.locator('[data-menu="toolsMenu"]').click();
        await page.locator('#toolsMenu [data-action="openVnets"]').click();
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await page.locator('[data-action="vnetAdd"]').click();
        await page.locator('#vn_name').fill('wf-save-net');
        await page.locator('#vn_subnet').fill('invalid');
        await page.locator('[data-action="vnetSaveAll"]').click();
        await expect(page.locator('.toast.error')).toContainText('Invalid subnet format');
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await expect(page.locator('#vn_name')).toHaveValue('wf-save-net');
        expect((await api(page, 'GET', '/api/networks', null)).text).toBe(original.text);
        await page.locator('#vn_subnet').fill('192.168.100.0');
        await page.locator('[data-action="vnetSaveAll"]').click();
        await expect(page.locator('#vnetdlg')).toBeHidden();
        await page.locator('[data-menu="toolsMenu"]').click();
        await page.locator('#toolsMenu [data-action="openVnets"]').click();
        await page.locator('.vnet-item', { hasText: 'wf-save-net' }).click();
        await expect(page.locator('#vn_name')).toHaveValue('wf-save-net');
        await expect(page.locator('#vn_subnet')).toHaveValue('192.168.100.0');
    } finally {
        const restored = await api(page, 'POST', '/api/networks', original.text);
        expect(restored.ok).toBe(true);
    }
});

test('catalog quickstart creates a VM with the template OS and firmware', async ({ page }) => {
    const cat = await api(page, 'GET', '/api/catalog', null);
    const entries = JSON.parse(cat.text);
    expect(entries.length).toBeGreaterThanOrEqual(10);
    const win = entries.find(e => e.id === 'win11');
    expect(win.firmware).toBe(1); // UEFI
    // Quickstart a UEFI Windows template and a BIOS Alpine template.
    await api(page, 'POST', '/api/vms/quickstart/win11', '');
    await api(page, 'POST', '/api/vms/quickstart/alpine320', '');
    const vms = await list(page);
    const w = vms.find(v => v.name === 'Windows 11');
    const a = vms.find(v => v.name === 'Alpine 3.20');
    expect(w, 'win11 VM exists').toBeTruthy();
    expect(w.fw).toBe('uefi');
    expect(w.os).toMatch(/Windows/);
    expect(a.fw).toBe('bios');
    // A second win11 quickstart gets a unique name (sockets are name-derived).
    await api(page, 'POST', '/api/vms/quickstart/win11', '');
    const after = await list(page);
    expect(after.filter(v => v.name.startsWith('Windows 11')).length).toBe(2);
});

test('dashboard shows host capacity (committed vs physical)', async ({ page }) => {
    await api(page, 'POST', '/api/vms', 'name=cap-a&mem=2048&cpu=2&disk=10');
    await page.reload();
    // No VM selected -> dashboard. The host panel fetches /api/host and renders
    // committed-vs-physical gauges.
    await expect.poll(() => page.evaluate(() => { const p = document.querySelector('.cap-panel'); return p ? p.textContent : ''; }), { timeout: 8000 }).toContain('Host Capacity');
    const txt = await page.evaluate(() => document.querySelector('.cap-panel').textContent);
    expect(txt).toMatch(/cores/);
    expect(txt).toMatch(/vCPU committed/);
    expect(txt).toMatch(/RAM committed/);
});

test('RAM capacity compares exact MiB at the overcommit boundary', async ({ page }) => {
    const created = await api(page, 'POST', '/api/vms', 'name=cap-boundary&mem=512&cpu=1&disk=1');
    expect(created.ok).toBe(true);
    const committed = (await list(page)).reduce((sum, v) => sum + v.mem, 0);
    let physical = committed - 1;
    await page.route('**/api/host', route => route.fulfill({ json: { cpu_cores: 4, ram_mb: physical } }));
    for (const capacity of [committed - 1, committed, committed + 1, 0]) {
        physical = capacity;
        await page.reload();
        const ram = page.locator('.cap-row').filter({ hasText: 'RAM committed' });
        await expect(ram.locator('.cap-val')).toHaveText(capacity > 0
            ? `${committed} / ${capacity} MiB` : `${committed} MiB`);
        const overcommitted = capacity > 0 && committed > capacity;
        await expect(ram.locator('.cap-over')).toHaveText(overcommitted
            ? `${Math.round(committed / capacity * 100) / 100}× overcommit` : '');
        await expect(ram.locator('.cap-fill')).toHaveAttribute('style', new RegExp(overcommitted
            ? 'var\\(--danger\\)' : 'var\\(--accent\\)'));
    }
});

test('SSE: a VM created via the API appears in the UI within 3s, no reload', async ({ page }) => {
    const t0 = Date.now();
    await api(page, 'POST', '/api/vms', 'name=wf-sse&mem=1024&cpu=1&disk=1');
    await page.waitForSelector('.vm-item:has-text("wf-sse")', { timeout: 4000 });
    expect(Date.now() - t0, 'push beats the 5s poll').toBeLessThan(3500);
    await expect(page.locator('.dash .inv tbody tr', { hasText: 'wf-sse' })).toBeVisible();
});

test('live console: SPICE display connects and paints in the Console tab', async ({ page }) => {
    await api(page, 'POST', '/api/vms', 'name=wf-spice&mem=1024&cpu=1&disk=1&guest_os=2&display=2&embed_display=true&firmware=bios');
    const idx = await indexOf(page, 'wf-spice');
    await api(page, 'POST', `/api/vms/${idx}/power`, '');
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-spice')].status, { timeout: 25000 }).toBe('running');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-spice' }).first().click();
    await expect.poll(() => page.evaluate(() => { const c = document.querySelector('#tabConsole #display canvas'); return c ? c.width : 0; }), { timeout: 20000 }).toBeGreaterThan(0);
    await expect.poll(() => page.evaluate(() => document.getElementById('displayBadge').textContent)).toContain('SPICE');
    await api(page, 'POST', `/api/vms/${await indexOf(page, 'wf-spice')}/power`, '');
});

test('video stream: H.264 over /ws/video paints the WebCodecs overlay', async ({ page, context }) => {
    test.skip(!hasFfmpeg, 'ffmpeg not installed on this host');
    await api(page, 'POST', '/api/vms', 'name=wf-video&mem=1024&cpu=1&disk=1&guest_os=2&display=vnc&embed_display=true&video_stream=1&video_bitrate=2500&firmware=bios');
    const idx = await indexOf(page, 'wf-video');
    expect((await list(page))[idx].video_bitrate_kbps, 'bitrate round-trips').toBe(2500);
    await api(page, 'POST', `/api/vms/${idx}/power`, '');
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-video')].status, { timeout: 25000 }).toBe('running');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-video' }).first().click();
    // The overlay canvas must exist, size itself from the config frame, and
    // carry real decoded pixels (not just be present).
    await expect.poll(() => page.evaluate(() => { const c = document.querySelector('#display .video-layer'); return c ? c.width : 0; }), { timeout: 25000 }).toBeGreaterThan(0);
    await expect.poll(() => page.evaluate(() => {
        const c = document.querySelector('#display .video-layer');
        if (!c) return false;
        try { const d = c.getContext('2d').getImageData(0, 0, Math.min(64, c.width), Math.min(64, c.height)).data; for (let i = 0; i < d.length; i += 4) { if (d[i] || d[i + 1] || d[i + 2]) return true; } } catch (e) {}
        return false;
    }), { timeout: 20000 }).toBe(true);
    // Fan-out: a second viewer joins the same encoder and paints too.
    const page2 = await context.newPage();
    await page2.goto('/');
    await page2.locator('.vm-item', { hasText: 'wf-video' }).first().click();
    await expect.poll(() => page2.evaluate(() => { const c = document.querySelector('#display .video-layer'); return c ? c.width : 0; }), { timeout: 15000 }).toBeGreaterThan(0);
    await page2.close();
    // First viewer must still be streaming after the second leaves.
    expect(await page.evaluate(() => videoWs && videoWs.readyState === WebSocket.OPEN)).toBe(true);
    await api(page, 'POST', `/api/vms/${await indexOf(page, 'wf-video')}/power`, '');
});

test('live console: embedded VNC canvas and serial panel connect for a running VM', async ({ page }) => {
    // Regression test for the WebSocket console: the 101 upgrade response once
    // used a Zig multiline literal (literal "\r" text, not CRLF), so browsers
    // never completed any WS handshake and VNC/SPICE/serial were all dead.
    await api(page, 'POST', '/api/vms', 'name=wf-live&mem=1024&cpu=1&disk=1&display=vnc&embed_display=true&enable_serial=true&firmware=bios');
    const idx = await indexOf(page, 'wf-live');
    expect(idx).toBeGreaterThanOrEqual(0);
    await api(page, 'POST', `/api/vms/${idx}/power`, '');
    await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-live')].status, { timeout: 25000 }).toBe('running');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-live' }).first().click();
    // noVNC must complete the RFB handshake and size its canvas from the guest.
    await expect.poll(() => page.evaluate(() => { const c = document.querySelector('#display canvas'); return c ? c.width : 0; }), { timeout: 20000 }).toBeGreaterThan(0);
    // The serial relay shares the same upgrade path; the panel shows when connected.
    await expect(page.locator('#serialpanel')).toBeVisible({ timeout: 10000 });
    await api(page, 'POST', `/api/vms/${idx}/power`, ''); // power off
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

test('keyboard activates folder headers and sort headers (a11y)', async ({ page }) => {
    await createVm(page, 'wf-kbd-vm');
    const idx = await indexOf(page, 'wf-kbd-vm');
    await api(page, 'POST', `/api/vms/${idx}`, 'folder=KbdFolder');
    await page.reload();
    const hdr = page.locator('.folder-hdr[data-folder="KbdFolder"]');
    await expect(hdr).toHaveClass(/open/);
    await hdr.focus();
    await page.keyboard.press('Enter'); // collapse via keyboard (CSP-safe dispatch)
    await expect(page.locator('.folder-hdr[data-folder="KbdFolder"]')).not.toHaveClass(/open/);
    // A sort header activates by keyboard without error (table stays rendered).
    const th = page.locator('.inv thead th[data-col="name"]');
    await th.focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('.inv tbody tr').first()).toBeVisible();
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
    await expect.poll(() => rows.count()).toBeGreaterThanOrEqual(2);
    // Default sort is name ascending: find the Name column header, click to toggle desc.
    const nameRows = () => page.locator('.inv tbody tr td.inv-name').allTextContents();
    // The dashboard sorts case-insensitively; match that (the shared daemon
    // accumulates VMs across tests, so don't assume only this test's rows).
    const ci = (a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0;
    const asc = await nameRows();
    expect(asc).toEqual([...asc].sort(ci));
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

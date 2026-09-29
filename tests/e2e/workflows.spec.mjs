// End-to-end coverage for the VM lifecycle workflows the API exposes, driving
// the real built hangar-web binary (see playwright.config.mjs). These exercise
// operations that are deterministic on a freshly-created, stopped VM with a
// real qcow2 disk (created by the daemon via qemu-img): clone, rename,
// delete+undo, snapshot take/list/delete, secondary-disk upload/download, and
// OVF export. Power-on/migration are intentionally excluded, they need a real
// booted guest / a second host and would be flaky here.
import { test, expect } from '@playwright/test';
import { execFileSync, execSync } from 'child_process';
import { mkdirSync, mkdtempSync, readFileSync } from 'fs';
import { resolve } from 'path';
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

test('uptime uses daemon elapsed seconds across browser clock changes', async ({ page }) => {
    const asset = await page.request.get('/app.js');
    expect(await asset.text()).toBe(readFileSync(new URL('../../src/web/app.js', import.meta.url), 'utf8'));
    const name = 'wf-uptime-clock';
    const idx = await createVm(page, name);
    let elapsed = 90061;
    let started = 1789680000;
    await page.route('**/api/vms', async (route) => {
        const response = await route.fetch();
        const inventory = await response.json();
        const vm = inventory.find((v) => v.name === name);
        Object.assign(vm, { status: 'running', started, uptime_sec: elapsed });
        await route.fulfill({ response, json: inventory });
    });
    try {
        await page.reload();
        await page.locator('.vm-item', { hasText: name }).click();
        for (const instant of ['2024-03-10T06:59:59Z', '2024-11-03T06:00:00Z', '2100-01-01T00:00:00Z']) {
            await page.clock.setFixedTime(new Date(instant));
            await page.evaluate(() => renderList());
            await expect(page.locator('#statusmsg')).toContainText('Uptime: 1d 1:01:01');
        }
        elapsed = 0;
        started = 0;
        await page.evaluate(() => refresh());
        await expect(page.locator('#statusmsg')).toContainText('Uptime: 0:00:00');
        for (const invalid of [null, -1, 'not-a-duration']) {
            elapsed = invalid;
            await page.evaluate(() => refresh());
            await expect(page.locator('#statusmsg')).not.toContainText('Uptime:');
        }
    } finally {
        await page.unroute('**/api/vms');
        await api(page, 'POST', `/api/vms/${idx}/delete`, '');
    }
});

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
    const star = page.locator('#vmlist .vm-row .star');
    await star.click();
    await expect(star).toHaveClass(/fav/);
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
    // Node accents come from theme tokens, never hard-coded hex.
    const strokeColors = await page.evaluate(() =>
        [...document.querySelectorAll('.topo-node')].map((n) => getComputedStyle(n.querySelector('rect')).stroke),
    );
    expect(strokeColors.length).toBeGreaterThan(0);
    for (const c of strokeColors) expect(c).not.toMatch(/rgb\(16,\s*185,\s*129\)|#10B981/i);
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

test('topology shows a computing state, Refresh recomputes and a network node opens the editor on it', async ({ page }) => {
    await createVm(page, 'wf-topo-net');
    const idx = await indexOf(page, 'wf-topo-net');
    await api(page, 'POST', `/api/vms/${idx}`, 'vnet=VMnet8');
    await page.reload();
    await page.evaluate(() => openTopology());
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    let computes = 0;
    await page.route('**/api/networks', async (route) => { computes += 1; await route.continue(); });
    await page.locator('#topodlg [data-action="openTopology"]', { hasText: 'Refresh' }).click();
    await expect.poll(() => computes).toBeGreaterThan(0);
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    // Clicking a network node closes the topology and opens the editor with that network selected.
    await page.locator('.topo-node.vnet[role="button"]').filter({ hasText: 'VMnet8' }).first().click();
    await expect(page.locator('#topodlg')).toHaveCount(0);
    await expect(page.locator('#vnetdlg')).toBeVisible();
    await expect(page.locator('#vn_name')).toHaveValue('VMnet8');
    await page.keyboard.press('Escape');
    await expect(page.locator('#vnetdlg')).toHaveCount(0);
});

test('topology nodes activate from the keyboard', async ({ page }) => {
    await createVm(page, 'wf-topo-key');
    await page.reload();
    await page.evaluate(() => openTopology());
    await page.waitForSelector('.topo-svg .topo-node', { timeout: 10000 });
    const node = page.locator('.topo-node.vm[role="button"]').filter({ hasText: 'wf-topo-key' });
    await node.focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('#topodlg')).toHaveCount(0);
    await expect(page.locator('#vmname')).toHaveText('wf-topo-key');
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
    await page.locator('#snapdlg button[type="submit"]').click();
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
        await expect(page.locator('#err_vn_subnet')).toHaveText('Invalid subnet format.');
        await expect(page.locator('#vn_subnet')).toBeFocused();
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

test('vnet Save Selected persists without closing and unsaved edits are confirmed on close', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks', null);
    expect(original.ok).toBe(true);
    try {
        await page.evaluate(() => actionHandlers.openVnets(document.body));
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await page.locator('[data-action="vnetAdd"]').click();
        await page.locator('#vn_name').fill('wf-save-sel');
        await page.locator('[data-action="vnetSaveCurrent"]').click();
        // Saved in place: the editor stays open and the network is on disk.
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await expect(page.locator('#statusmsg')).toContainText('wf-save-sel');
        const saved = JSON.parse((await api(page, 'GET', '/api/networks', null)).text);
        expect(saved.networks.map((n) => n.name)).toContain('wf-save-sel');
        // Editing again and closing asks before the edit is thrown away.
        await page.locator('#vn_gw').fill('192.168.100.2');
        await page.locator('#vnetdlg [data-action="closeDlg"]').click();
        await expect(page.locator('#confirmdlg')).toBeVisible();
        await page.locator('#confirmCancelBtn').click();
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await expect(page.locator('#vn_gw')).toHaveValue('192.168.100.2');
    } finally {
        const restored = await api(page, 'POST', '/api/networks', original.text);
        expect(restored.ok).toBe(true);
    }
});

test('vnet editor rejects names over 15 characters inline and saves nothing', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks', null);
    let posts = 0;
    await page.route('**/api/networks', async (route) => {
        if (route.request().method() === 'POST') posts += 1;
        await route.continue();
    });
    await page.evaluate(() => actionHandlers.openVnets(document.body));
    await expect(page.locator('#vnetdlg')).toBeVisible();
    await page.locator('[data-action="vnetAdd"]').click();
    await page.locator('#vn_name').fill('a-network-name-16');
    await page.locator('[data-action="vnetSaveAll"]').click();
    await expect(page.locator('#err_vn_name')).toHaveText('Network name is at most 15 characters.');
    await expect(page.locator('#vn_name')).toHaveAttribute('aria-invalid', 'true');
    await page.locator('#vn_name').fill('a-network-name');
    await expect(page.locator('#err_vn_name')).toHaveText('');
    await page.locator('#vn_name').fill('');
    await page.locator('[data-action="vnetSaveAll"]').click();
    await expect(page.locator('#err_vn_name')).toHaveText('Network name is required.');
    await page.locator('#vn_mask').fill('255.0.255.0');
    await page.locator('[data-action="vnetSaveAll"]').click();
    await expect(page.locator('#err_vn_mask')).toHaveText('Invalid mask format.');
    expect(posts, 'no save request while a field is invalid').toBe(0);
    expect((await api(page, 'GET', '/api/networks', null)).text).toBe(original.text);
    // Escape asks before discarding the edits, and Discard closes it.
    await page.keyboard.press('Escape');
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#vnetdlg')).toHaveCount(0);
});

test('vnet editor keeps edits across selection, moves with arrow keys and persists every field', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks', null);
    expect(original.ok).toBe(true);
    try {
        await page.evaluate(() => actionHandlers.openVnets(document.body));
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await page.locator('[data-action="vnetAdd"]').click();
        await page.locator('#vn_name').fill('wf-fields');
        await page.locator('#vn_type').selectOption('bridged');
        await page.locator('#vn_dhcp').selectOption('1');
        await page.locator('#vn_dstart').fill('192.168.100.10');
        await page.locator('#vn_dend').fill('192.168.100.20');
        await page.locator('#vn_iface').fill('eth9');
        await page.locator('#vn_gw').fill('192.168.100.1');
        await page.locator('#vn_pf').fill('8080:192.168.100.10:80');
        await expect(page.locator('.vnet-item.active .vnet-type-badge')).toHaveText('Bridged');
        // Selecting another network and coming back keeps the unsaved edits.
        const items = page.locator('.vnet-item');
        await items.first().click();
        await expect(items.first()).toHaveClass(/active/);
        await expect(page.locator('#vn_name')).not.toHaveValue('wf-fields');
        await items.last().click();
        await expect(page.locator('#vn_name')).toHaveValue('wf-fields');
        await expect(page.locator('#vn_pf')).toHaveValue('8080:192.168.100.10:80');
        // Arrow keys move the selection and focus (roving tab stop).
        await items.last().focus();
        await page.keyboard.press('ArrowUp');
        await expect(items.nth((await items.count()) - 2)).toBeFocused();
        await expect(items.nth((await items.count()) - 2)).toHaveClass(/active/);
        await page.keyboard.press('End');
        await expect(items.last()).toHaveClass(/active/);
        await page.keyboard.press('Home');
        await expect(items.first()).toHaveClass(/active/);
        await page.locator('.vnet-item', { hasText: 'wf-fields' }).click();
        await page.locator('[data-action="vnetSaveAll"]').click();
        await expect(page.locator('#vnetdlg')).toHaveCount(0);
        const saved = JSON.parse((await api(page, 'GET', '/api/networks', null)).text).networks.find((n) => n.name === 'wf-fields');
        expect(saved).toMatchObject({ type: 'bridged', dhcp: true, dhcp_start: '192.168.100.10', dhcp_end: '192.168.100.20', host_iface: 'eth9', gateway: '192.168.100.1', port_forwards: '8080:192.168.100.10:80' });
    } finally {
        const restored = await api(page, 'POST', '/api/networks', original.text);
        expect(restored.ok).toBe(true);
    }
});

test('vnet Remove and Defaults edit the set and close without saving discards them', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks', null);
    await page.evaluate(() => actionHandlers.openVnets(document.body));
    await expect(page.locator('#vnetdlg')).toBeVisible();
    await page.locator('[data-action="vnetDefaults"]').click();
    await expect(page.locator('.vnet-item')).toHaveText([/VMnet0/, /VMnet1/, /VMnet8/]);
    await page.locator('[data-action="vnetRemove"]').click();
    await expect(page.locator('.vnet-item')).toHaveCount(2);
    await page.locator('#vnetdlg [data-action="closeDlg"]').click();
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#vnetdlg')).toHaveCount(0);
    expect((await api(page, 'GET', '/api/networks', null)).text).toBe(original.text);
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

test('catalog dialog lists templates and Create makes a VM and closes', async ({ page }) => {
    await page.locator('[data-action="openCatalog"]:visible').first().click();
    await expect(page.locator('#catalogdlg')).toBeVisible();
    const cards = page.locator('#catalogList .cat-card');
    await expect.poll(() => cards.count()).toBeGreaterThanOrEqual(10);
    const debian = cards.filter({ hasText: 'Debian 12' });
    await expect(debian).toContainText('2 vCPU');
    await expect(debian).toContainText('2 GiB RAM');
    await expect(debian).toContainText('20 GB disk');
    await debian.getByRole('button', { name: 'Create VM from Debian 12' }).click();
    await expect(page.locator('#catalogdlg')).toHaveCount(0);
    await expect.poll(async () => (await list(page)).some((v) => v.name === 'Debian 12')).toBe(true);
    await expect(page.locator('#vmlist .vm-item', { hasText: 'Debian 12' })).toBeVisible();
});

test('catalog dialog shows loading, failure and empty states', async ({ page }) => {
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    await page.route('**/api/catalog', async (route) => { await gate; await route.abort(); });
    await page.evaluate(() => { void openCatalog(); });
    await expect(page.locator('#catalogList')).toHaveText('Loading catalog…');
    release();
    await expect(page.locator('#catalogList')).toHaveText('Failed to load catalog.');
    await page.keyboard.press('Escape');
    await expect(page.locator('#catalogdlg')).toHaveCount(0);
    await page.unroute('**/api/catalog');
    await page.route('**/api/catalog', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
    await page.evaluate(() => { void openCatalog(); });
    await expect(page.locator('#catalogList')).toHaveText('No templates available.');
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
        await expect(ram.locator('.cap-fill')).toHaveClass(overcommitted ? /\bbg-danger\b/ : /\bbg-accent\b/);
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
    const videoSockets = [];
    page.on('websocket', (socket) => { if (socket.url().includes('/ws/video/')) videoSockets.push(socket); });
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
    expect(videoSockets.some((socket) => !socket.isClosed()), 'the first viewer keeps its video socket').toBe(true);
    await expect(page.locator('#displayBadge')).toHaveText('H264 · WEBCODECS');
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

test('live console: client Retry, reconnect, display-only mode and the serial panel', async ({ page }) => {
    test.setTimeout(120_000);
    await api(page, 'POST', '/api/vms', 'name=wf-console&mem=1024&cpu=1&disk=1&display=vnc&embed_display=true&enable_serial=true&firmware=bios');
    const idx = await indexOf(page, 'wf-console');
    await api(page, 'POST', `/api/vms/${idx}/power`, '');
    try {
        await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-console')].status, { timeout: 25000 }).toBe('running');
        const canvasWidth = () => page.evaluate(() => { const c = document.querySelector('#display canvas'); return c ? c.width : 0; });

        // A client bundle that never arrives leaves a visible message and a Retry, not a dead pane.
        await page.route('**/novnc.js', (route) => route.abort());
        await page.reload();
        await page.locator('.vm-item', { hasText: 'wf-console' }).first().click();
        await expect(page.locator('#displayHint')).toContainText('VNC client failed to load.');
        await expect(page.locator('#displayBadge')).toHaveText('Disconnected');
        await page.unroute('**/novnc.js');
        await page.locator('#displayHint').getByRole('button', { name: 'Retry' }).click();
        await expect.poll(canvasWidth, { timeout: 20000 }).toBeGreaterThan(0);
        await expect(page.locator('#displayHint button')).toHaveCount(0);
        await expect(page.locator('#displayBadge')).toContainText('VNC');

        // Reconnect drops the client and opens a fresh one.
        await page.locator('#display [data-action="reconnectDisplay"]').click();
        await expect.poll(canvasWidth, { timeout: 20000 }).toBeGreaterThan(0);

        // Display-only: F11 enters, the bar names the way out, Escape and the Exit button leave.
        const bar = page.getByRole('button', { name: 'Exit display-only mode' });
        await page.keyboard.press('F11');
        await expect(page.locator('body')).toHaveClass(/displayonly/);
        await expect(bar).toHaveCSS('opacity', '1');
        const viewport = page.viewportSize();
        expect((await page.locator('#display').boundingBox()).height).toBe(viewport.height);
        await page.keyboard.press('Escape');
        await expect(page.locator('body')).not.toHaveClass(/displayonly/);
        await page.locator('#display [data-action="enterDisplayOnly"]').click();
        await expect(page.locator('body')).toHaveClass(/displayonly/);
        await bar.click();
        await expect(page.locator('body')).not.toHaveClass(/displayonly/);

        // The serial handle resizes with the keyboard: arrows by 16px, Shift by 48px, Home and End to the limits.
        await expect(page.locator('#serialpanel')).toBeVisible({ timeout: 10000 });
        const handle = page.locator('#serialResize');
        await expect(handle).toHaveAttribute('aria-valuenow', '170');
        await handle.focus();
        await page.keyboard.press('ArrowDown');
        await expect(handle).toHaveAttribute('aria-valuenow', '186');
        await page.keyboard.press('Shift+ArrowDown');
        await expect(handle).toHaveAttribute('aria-valuenow', '234');
        await page.keyboard.press('ArrowUp');
        await expect(handle).toHaveAttribute('aria-valuenow', '218');
        await page.keyboard.press('Home');
        await expect(handle).toHaveAttribute('aria-valuenow', '600');
        await expect(page.locator('#serialterm')).toHaveCSS('height', '600px');
        await page.keyboard.press('End');
        await expect(handle).toHaveAttribute('aria-valuenow', '60');

        // Disconnect closes the panel and it stays closed.
        await page.locator('#serialpanel').getByRole('button', { name: 'Disconnect' }).click();
        await expect(page.locator('#serialpanel')).toBeHidden();
    } finally {
        await api(page, 'POST', `/api/vms/${await indexOf(page, 'wf-console')}/power`, '');
    }
});

test('console tab says why it is empty', async ({ page }) => {
    await api(page, 'POST', '/api/vms', 'name=wf-notice&mem=1024&cpu=1&disk=1&display=vnc&embed_display=true');
    await api(page, 'POST', '/api/vms', 'name=wf-notice-native&mem=1024&cpu=1&disk=1&display=0');
    await page.reload();
    await expect(page.locator('.vm-item', { hasText: 'wf-notice' }).first()).toBeVisible();
    // The tab is disabled for both VMs, so the panel is unreachable by click; drive the bridge the app uses.
    const notice = (name) => page.evaluate((n) => {
        hangarUi.setConsole({ vm: vms.find((v) => v.name === n) ?? null, actionReason: () => null });
        return document.getElementById('consoleHint').textContent;
    }, name);
    expect(await notice('wf-notice')).toContain('wf-notice is powered off.');
    expect(await notice('wf-notice-native')).toContain('No embedded browser console for this display.');
    expect(await notice('wf-notice-native')).toContain('native GTK QEMU window');
    expect(await notice('nobody')).toContain('No VM selected.');
    await removeVms(page, 'wf-notice', 'wf-notice-native');
});

test('migration bar follows the status poll, cancels and clears itself', async ({ page }) => {
    await createVm(page, 'wf-migbar');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-migbar' }).first().click();
    const poll = { body: { status: 'active', pct: 40 } };
    let cancels = 0;
    await page.route(/\/api\/vms\/\d+\/migrate$/, (route) =>
        route.request().method() === 'POST' ? route.fulfill({ json: { status: 'started' } }) : route.fulfill({ json: poll.body }));
    await page.route(/\/api\/vms\/\d+\/migrate\/cancel$/, (route) => { cancels += 1; return route.fulfill({ json: {} }); });
    await expect(page.locator('#mig_progress')).toBeHidden();
    await invoke(page, 'migrateGuest');
    await page.locator('#mig_host').fill('192.0.2.7');
    await page.locator('#migratedlg button[type="submit"]').click();
    await expect(page.locator('#migratedlg')).toHaveCount(0);

    const bar = page.locator('#mig_progress');
    await expect(bar).toBeVisible();
    await expect(bar).toHaveAttribute('aria-valuenow', '40');
    await expect(page.locator('#mig_pct')).toContainText('Migration');
    await page.locator('#mig_cancel').click();
    await expect.poll(() => cancels).toBe(1);
    await expect(page.locator('#statusannounce')).toHaveText('Migration cancel requested');

    poll.body = { status: 'completed' };
    await expect(page.locator('#mig_pct')).toHaveText('Migration completed.');
    await expect(bar).toHaveAttribute('aria-valuenow', '100');
    await expect(bar.locator('div')).toHaveClass(/bg-success/);
    await expect(page.locator('#statusannounce')).toHaveText('Migration completed');
    await expect(bar).toBeHidden({ timeout: 8000 });
    await removeVms(page, 'wf-migbar');
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
    // The dialog stays modal (page inert) through its exit animation; wait it out before reopening the palette.
    await expect(page.locator('#catalogdlg')).toHaveCount(0);
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

// Call a window-scoped dialog function and record its eventual answer on window.
async function ask(page, fn, ...args) {
    await page.evaluate(([name, a]) => {
        window.__answer = 'pending';
        window[name](...a).then((v) => { window.__answer = v; });
    }, [fn, args]);
}

async function invoke(page, fn, ...args) {
    await page.evaluate(([name, a]) => window[name](...a), [fn, args]);
}

const answer = (page) => page.evaluate(() => window.__answer);

for (const [how, expected] of [['OK button', true], ['Cancel button', false], ['Escape', false], ['backdrop click', false]]) {
    test(`confirm dialog resolves ${expected} on ${how} and returns focus`, async ({ page }) => {
        await page.locator('#search').focus();
        await ask(page, 'showConfirmDialog', 'Really?\nSecond line', { danger: true, okLabel: 'Delete' });
        const dlg = page.locator('#confirmdlg');
        await expect(dlg).toBeVisible();
        await expect(dlg).toHaveAttribute('aria-labelledby', 'confirmmsg');
        await expect(page.locator('#confirmmsg')).toContainText('Second line');
        await expect(page.locator('#confirmOkBtn')).toHaveText('Delete');
        await expect(page.locator('#confirmOkBtn')).toHaveClass(/text-danger-text/);
        await expect(page.locator('#confirmCancelBtn')).toBeFocused();
        if (how === 'OK button') await page.locator('#confirmOkBtn').click();
        else if (how === 'Cancel button') await page.locator('#confirmCancelBtn').click();
        else if (how === 'Escape') await page.keyboard.press('Escape');
        else await page.mouse.click(4, 4);
        await expect(dlg).toHaveCount(0);
        expect(await answer(page)).toBe(expected);
        await expect(page.locator('#search')).toBeFocused();
    });
}

test('confirm dialog without danger uses the primary button and OK label', async ({ page }) => {
    await ask(page, 'showConfirmDialog', 'Proceed?');
    await expect(page.locator('#confirmOkBtn')).toHaveText('OK');
    await expect(page.locator('#confirmOkBtn')).not.toHaveClass(/text-danger-text/);
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#confirmdlg')).toHaveCount(0);
    expect(await answer(page)).toBe(true);
});

test('prompt dialog offers suggestions, submits on Enter and cancels with Escape', async ({ page }) => {
    await ask(page, 'showPromptDialog', 'Move to folder:', 'start', ['alpha', 'beta']);
    await expect(page.locator('#promptdlg')).toBeVisible();
    await expect(page.locator('#promptLabel')).toHaveText('Move to folder:');
    await expect(page.locator('#promptInput')).toHaveValue('start');
    await expect(page.locator('#promptInput')).toBeFocused();
    await expect(page.locator('#promptOptions option')).toHaveCount(2);
    await page.locator('#promptInput').fill('gamma');
    await page.keyboard.press('Enter');
    await expect(page.locator('#promptdlg')).toHaveCount(0);
    expect(await answer(page)).toBe('gamma');

    await ask(page, 'showPromptDialog', 'Name:', 'x');
    await expect(page.locator('#promptInput')).toBeFocused();
    await expect(page.locator('#promptInput')).not.toHaveAttribute('list', /.+/);
    await page.keyboard.press('Escape');
    await expect(page.locator('#promptdlg')).toHaveCount(0);
    expect(await answer(page)).toBeNull();
});

test('preferences preview the theme, revert it on cancel and keep it on save', async ({ page }) => {
    const before = await api(page, 'GET', '/api/config', null);
    expect(before.ok).toBe(true);
    const original = JSON.parse(before.text);
    try {
        await invoke(page, 'applyTheme', 'light');
        await invoke(page, 'openPrefs');
        await expect(page.locator('#prefsdlg')).toBeVisible();
        await page.locator('#p_theme').selectOption('dark');
        await expect(page.locator('html')).not.toHaveClass(/light/);
        await page.locator('#prefsdlg [data-action="closeDlg"]').click();
        await expect(page.locator('#prefsdlg')).toHaveCount(0);
        await expect(page.locator('html')).toHaveClass(/light/);

        await invoke(page, 'openPrefs');
        await page.locator('#p_theme').selectOption('dark');
        await page.locator('#p_default_memory_mb').fill('3072');
        await page.locator('#p_default_cpu_cores').fill('3');
        await page.locator('#p_autoprotect_enabled').selectOption('1');
        await page.locator('#prefsdlg button[type="submit"]').click();
        await expect(page.locator('#prefsdlg')).toHaveCount(0);
        await expect(page.locator('html')).not.toHaveClass(/light/);
        const saved = JSON.parse((await api(page, 'GET', '/api/config', null)).text);
        expect(saved.theme).toBe('dark');
        expect(saved.prefs.default_memory_mb).toBe(3072);
        expect(saved.prefs.default_cpu_cores).toBe(3);
        expect(saved.prefs.autoprotect_enabled_default).toBe(true);

        // Reopening shows the saved values.
        await invoke(page, 'openPrefs');
        await expect(page.locator('#p_default_memory_mb')).toHaveValue('3072');
        await expect(page.locator('#p_theme')).toHaveValue('dark');
        // Enter in a field submits the form.
        await page.locator('#p_default_cpu_cores').press('Enter');
        await expect(page.locator('#prefsdlg')).toHaveCount(0);
    } finally {
        // A fresh daemon has no saved config yet, so fall back to the built-in defaults.
        const prefs = original.prefs ?? {};
        const body = `theme=${original.theme ?? 'system'}&default_vm_dir=${encodeURIComponent(prefs.default_vm_dir ?? '')}`
            + `&default_memory_mb=${prefs.default_memory_mb ?? 2048}&default_cpu_cores=${prefs.default_cpu_cores ?? 2}`
            + `&autoprotect_enabled=${prefs.autoprotect_enabled_default ? 1 : 0}`
            + `&autoprotect_interval=${prefs.autoprotect_interval_min_default ?? 60}&autoprotect_max=${prefs.autoprotect_max_default ?? 10}`;
        expect((await api(page, 'POST', '/api/config', body)).ok).toBe(true);
    }
});

test('about dialog shows the daemon version and closes with its button', async ({ page }) => {
    await page.evaluate(() => actionHandlers.openAbout(document.body));
    await expect(page.locator('#aboutdlg')).toBeVisible();
    await expect(page.locator('#aboutVersion')).toContainText('Version');
    await page.locator('#aboutdlg [data-action="closeDlg"]').click();
    await expect(page.locator('#aboutdlg')).toHaveCount(0);
});

test('QEMU log dialog refreshes in place and closes with Escape', async ({ page }) => {
    await createVm(page, 'wf-log');
    await page.locator('.vm-item', { hasText: 'wf-log' }).click();
    await page.evaluate(() => viewLog());
    await expect(page.locator('#log_vmname')).toHaveText('wf-log');
    await expect(page.locator('#logbody')).toContainText(/No log output yet/);
    await page.locator('#logdlg [data-action="refreshLog"]').click();
    await expect(page.locator('#logbody')).toContainText(/No log output yet/);
    await page.keyboard.press('Escape');
    await expect(page.locator('#logdlg')).toHaveCount(0);
});

test('new VM dialog validates inline, then creates the VM and selects it', async ({ page }) => {
    await invoke(page, 'newVm');
    await expect(page.locator('#newdlg')).toBeVisible();
    await expect(page.locator('#n_name')).toBeFocused();
    await expect(page.locator('#newdlg [aria-invalid]')).toHaveCount(0);

    await page.locator('#n_mem').fill('64');
    await expect(page.locator('#err_n_name')).toHaveText('Name is required.');
    await expect(page.locator('#err_n_mem')).toHaveText('Memory must be 128-65536 MB.');
    await expect(page.locator('#n_mem')).toHaveAttribute('aria-invalid', 'true');
    // Enter with invalid fields submits nothing and lands on the first bad field.
    await page.locator('#n_mem').press('Enter');
    await expect(page.locator('#newdlg')).toBeVisible();
    await expect(page.locator('#n_name')).toBeFocused();

    await page.locator('#n_name').fill('wf-newvm-ui');
    await page.locator('#n_mem').fill('512');
    await page.locator('#n_cpu').fill('0');
    await expect(page.locator('#err_n_cpu')).toHaveText('CPU cores must be 1-256.');
    await page.locator('#n_cpu').fill('1');
    await page.locator('#n_disk').fill('1');
    await page.locator('#n_guest_os').selectOption('2');
    await page.locator('#n_firmware').selectOption('uefi');
    await page.locator('#n_disk').press('Enter');
    await expect(page.locator('#newdlg')).toHaveCount(0);

    const vm = (await list(page)).find((v) => v.name === 'wf-newvm-ui');
    expect(vm).toBeTruthy();
    expect(vm.mem).toBe(512);
    await expect(page.locator('.vm-item[aria-current="true"]', { hasText: 'wf-newvm-ui' })).toBeVisible();
});

test('import dialog rejects bad paths inline and imports a disk image in place', async ({ page }) => {
    // A real image to import; kept under the repo's gitignored .scratch, never tmpfs.
    const scratch = resolve(import.meta.dirname, '../../.scratch');
    mkdirSync(scratch, { recursive: true });
    const image = resolve(mkdtempSync(resolve(scratch, 'wf-import-')), 'guest.qcow2');
    execFileSync('qemu-img', ['create', '-f', 'qcow2', image, '1M'], { stdio: 'ignore' });

    await invoke(page, 'importGuest');
    await expect(page.locator('#importdlg')).toBeVisible();
    await expect(page.locator('#imp_path')).toBeFocused();
    await page.locator('#importdlg button[type="submit"]').click();
    await expect(page.locator('#err_imp_path')).toHaveText('A file path is required.');
    await page.locator('#imp_path').fill('/x/../guest.qcow2');
    await page.locator('#importdlg button[type="submit"]').click();
    await expect(page.locator('#err_imp_path')).toHaveText('Parent directory traversal is not allowed.');
    await page.locator('#imp_path').fill('/x/guest.txt');
    await page.locator('#importdlg button[type="submit"]').click();
    await expect(page.locator('#err_imp_path')).toContainText('disk image extension');
    await expect(page.locator('#imp_path')).toHaveAttribute('aria-invalid', 'true');

    await page.locator('#imp_path').fill(image);
    await expect(page.locator('#err_imp_path')).toHaveText('');
    await page.locator('#imp_name').fill('wf-imported');
    await page.locator('#imp_name').press('Enter');
    await expect(page.locator('#importdlg')).toHaveCount(0);
    await expect.poll(() => indexOf(page, 'wf-imported')).toBeGreaterThanOrEqual(0);
});

test('clone dialog offers full and linked clones', async ({ page }) => {
    await createVm(page, 'wf-clone-ui');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-clone-ui' }).first().click();
    await invoke(page, 'cloneGuest');
    await expect(page.locator('#clone_name')).toHaveText('wf-clone-ui');
    await page.locator('#clonedlg').getByRole('button', { name: 'Full Clone' }).click();
    await expect(page.locator('#clonedlg')).toHaveCount(0);
    await expect.poll(async () => (await list(page)).filter((v) => v.name.includes('wf-clone-ui')).length).toBe(2);

    await invoke(page, 'cloneGuest');
    await page.locator('#clonedlg').getByRole('button', { name: 'Linked Clone' }).click();
    await expect(page.locator('#clonedlg')).toHaveCount(0);
    await expect.poll(async () => (await list(page)).filter((v) => v.name.includes('wf-clone-ui')).length).toBe(3);
});

test('snapshot manager validates names, reverts and deletes behind confirmations', async ({ page }) => {
    const idx = await createVm(page, 'wf-snap-ui');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-snap-ui' }).first().click();
    await invoke(page, 'openSnapshots');
    await expect(page.locator('#snapMeta')).toContainText('wf-snap-ui');
    await expect(page.locator('#snaplist')).toContainText('No snapshots yet');

    const take = page.locator('#snapdlg button[type="submit"]');
    await take.click();
    await expect(page.locator('#err_s_tag')).toHaveText('Enter a snapshot name.');
    await page.locator('#s_tag').fill('a..b');
    await take.click();
    await expect(page.locator('#err_s_tag')).toHaveText('Snapshot name is invalid.');

    await page.locator('#s_tag').fill('first');
    await page.locator('#s_tag').press('Enter');
    await expect(page.locator('#snaplist')).toContainText('first', { timeout: 15000 });
    await expect(page.locator('#s_tag')).toHaveValue('');

    // Cancelling the delete confirmation keeps the snapshot.
    await page.getByRole('button', { name: 'Delete snapshot first' }).click();
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await expect(page.locator('#confirmOkBtn')).toHaveClass(/danger|bg-danger|text-danger/);
    await page.locator('#confirmCancelBtn').click();
    await expect(page.locator('#confirmdlg')).toHaveCount(0);
    await expect(page.locator('#snaplist')).toContainText('first');
    expect((await api(page, 'GET', `/api/vms/${idx}/snapshots`, null)).text).toContain('first');

    // Reverting closes the manager once confirmed.
    await page.getByRole('button', { name: 'Revert to snapshot first' }).click();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#snapdlg')).toHaveCount(0);

    await invoke(page, 'openSnapshots');
    await page.getByRole('button', { name: 'Delete snapshot first' }).click();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#snaplist')).toContainText('No snapshots yet');
});

test('migrate dialog builds the URI live and validates the target', async ({ page }) => {
    await createVm(page, 'wf-migrate-ui');
    await page.reload();
    await page.locator('.vm-item', { hasText: 'wf-migrate-ui' }).first().click();
    await invoke(page, 'migrateGuest');
    await expect(page.locator('#migrate_vmname')).toHaveText('wf-migrate-ui');
    await expect(page.locator('#mig_port')).toHaveValue('4444');
    await expect(page.locator('#mig_uri')).toHaveValue('');

    await page.locator('#migratedlg button[type="submit"]').click();
    await expect(page.locator('#err_mig_host')).toHaveText('Target host is required.');
    await expect(page.locator('#mig_host')).toBeFocused();

    await page.locator('#mig_host').fill('192.0.2.7');
    await page.locator('#mig_port').fill('5555');
    await expect(page.locator('#mig_uri')).toHaveValue('tcp:192.0.2.7:5555');
    await expect(page.locator('#mig_uri')).toHaveJSProperty('readOnly', true);
    await page.locator('#mig_port').fill('70000');
    await page.locator('#migratedlg button[type="submit"]').click();
    await expect(page.locator('#err_mig_port')).toHaveText('Port must be 1-65535.');
    await page.keyboard.press('Escape');
    await expect(page.locator('#migratedlg')).toHaveCount(0);
});

// ── App shell chrome: sidebar head, VM header and tabs, status bar, toasts, context menu, palette ──

// These tests create wf-shell-* VMs; remove them so the daemon's VM limit is not reached by later tests.
test.afterEach(async ({ page }) => {
    const vms = await list(page);
    for (let i = vms.length - 1; i >= 0; i--) {
        if (vms[i].name.startsWith('wf-shell-')) await api(page, 'POST', `/api/vms/${i}/delete`, '');
    }
});

test('VM header follows the selection and the tab bar roves with the arrow keys', async ({ page }) => {
    await createVm(page, 'wf-shell-tabs');
    await page.reload();
    await expect(page.locator('#tabBar')).toHaveCount(0);
    await expect(page.locator('#vmemblem')).toHaveCount(0);
    await page.locator('.vm-item', { hasText: 'wf-shell-tabs' }).first().click();
    await expect(page.locator('#vmname')).toHaveText('wf-shell-tabs');
    await expect(page.locator('#vmemblem')).toBeVisible();
    const tablist = page.getByRole('tablist', { name: 'VM views' });
    await expect(tablist).toBeVisible();
    // A stopped VM has no console: that tab is disabled and skipped by the keys.
    const consoleTab = page.locator('#tab-btn-console');
    await expect(consoleTab).toBeDisabled();
    await expect(consoleTab).toHaveAttribute('title', /running embedded VNC or SPICE display/);
    const summary = page.locator('#tab-btn-summary');
    const settings = page.locator('#tab-btn-settings');
    await expect(summary).toHaveAttribute('aria-selected', 'true');
    await expect(summary).toHaveAttribute('tabindex', '0');
    await expect(settings).toHaveAttribute('tabindex', '-1');
    await summary.focus();
    await page.keyboard.press('ArrowRight');
    await expect(settings).toBeFocused();
    await expect(settings).toHaveAttribute('aria-selected', 'true');
    await expect(settings).toHaveAttribute('tabindex', '0');
    await expect(summary).toHaveAttribute('tabindex', '-1');
    await expect(page.locator('#tabSettings')).toBeVisible();
    await page.keyboard.press('ArrowRight'); // wraps past the disabled console tab
    await expect(summary).toBeFocused();
    await expect(page.locator('#tabSummary')).toBeVisible();
    await page.keyboard.press('End');
    await expect(settings).toBeFocused();
    await page.keyboard.press('Home');
    await expect(summary).toBeFocused();
    await expect(summary).toHaveAttribute('aria-selected', 'true');
    // Home in the toolbar returns to the overview and hides the VM-only parts.
    await page.locator('.toolbar [data-action="deselectVm"]').click();
    await expect(page.locator('#vmname')).toHaveText(/Overview|Welcome to Hangar/);
    await expect(page.locator('#tabBar')).toHaveCount(0);
    await expect(page.locator('#vmemblem')).toHaveCount(0);
});

test('sidebar search shows a clear button only while it holds text', async ({ page }) => {
    await createVm(page, 'wf-shell-clear-a');
    await createVm(page, 'wf-shell-clear-b');
    await page.reload();
    await expect(page.locator('#searchClear')).toHaveCount(0);
    await page.locator('#search').fill('wf-shell-clear-a');
    await expect(page.locator('#searchClear')).toBeVisible();
    await expect(page.locator('#vmlist .vm-item')).toHaveCount(1);
    await page.locator('#searchClear').click();
    await expect(page.locator('#search')).toHaveValue('');
    await expect(page.locator('#searchClear')).toHaveCount(0);
    await expect(page.locator('#vmlist .vm-item', { hasText: 'wf-shell-clear-b' })).toBeVisible();
    await page.locator('#search').fill('nothing-matches-this');
    await page.getByRole('button', { name: 'Clear search' }).last().click(); // the empty-list button
    await expect(page.locator('#search')).toHaveValue('');
});

test('select mode toggles the bulk bar and its pressed state', async ({ page }) => {
    await createVm(page, 'wf-shell-select-mode');
    await page.reload();
    const toggle = page.locator('#selectToggle');
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
    await expect(page.locator('#bulkBar')).toHaveCount(0);
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('toolbar', { name: 'Bulk actions' })).toBeVisible();
    await expect(page.locator('#bulkCount')).toHaveText('0 selected');
    await page.locator('.vm-item', { hasText: 'wf-shell-select-mode' }).locator('.vm-check').check();
    await expect(page.locator('#bulkCount')).toHaveText('1 selected');
    await page.locator('#bulkBar [data-action="toggleSelectMode"]').click(); // Done
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
    await expect(page.locator('#bulkBar')).toHaveCount(0);
});

test('status bar shows the message, pulses while working and announces only intentional text', async ({ page }) => {
    await expect(page.locator('#statusannounce')).toHaveAttribute('role', 'status');
    await expect(page.locator('#livebadge')).toBeVisible(); // the event stream connected
    await invoke(page, 'setStatusLoading', 'Crunching');
    await expect(page.locator('#statusmsg')).toHaveText('Crunching…');
    await expect(page.locator('#statusmsg')).toHaveClass(/loading/);
    await expect(page.locator('#statusannounce')).toHaveText('Crunching');
    await invoke(page, 'setStatus', 'All done');
    await expect(page.locator('#statusmsg')).toHaveText('All done');
    await expect(page.locator('#statusmsg')).not.toHaveClass(/loading/);
    await expect(page.locator('#statusannounce')).toHaveText('All done');
    // A passive redraw (list render) rewrites the bar but leaves the announcer alone.
    await page.evaluate(() => refresh());
    await expect(page.locator('#statusmsg')).toContainText('virtual machine');
    await expect(page.locator('#statusannounce')).toHaveText('All done');
});

test('connection banner alerts while the server is down and Dismiss hides it', async ({ page }) => {
    const banner = page.locator('#connbanner');
    await expect(banner).toHaveAttribute('role', 'alert');
    await expect(banner).toBeHidden();
    await page.evaluate(() => setServerDown(true));
    await expect(banner).toBeVisible();
    await expect(banner).toContainText('Connection lost');
    await banner.getByRole('button', { name: 'Dismiss' }).click();
    await expect(banner).toBeHidden();
});

test('toasts live in one log region, cap at five, expire, and Undo runs its callback', async ({ page }) => {
    const region = page.locator('#toast-container');
    await expect(region).toHaveAttribute('role', 'log');
    await expect(region).toHaveAttribute('aria-live', 'polite');
    await page.evaluate(() => {
        window.__undone = 0;
        showToast('saved fine', 'success');
        showToast('it broke', 'error');
        showToast('mind the gap', 'warn');
    });
    await expect(region.locator('.toast')).toHaveCount(3);
    await expect(region.locator('.toast', { hasText: 'saved fine' })).toHaveAttribute('role', 'status');
    await expect(region.locator('.toast', { hasText: 'it broke' })).toHaveAttribute('role', 'alert');
    await expect(region.locator('.toast', { hasText: 'mind the gap' })).toHaveAttribute('role', 'alert');
    await expect(region.locator('.toast svg use').first()).toHaveAttribute('href', /icons\.svg#i-/);
    await page.evaluate(() => {
        for (let i = 0; i < 4; i++) showToast(`filler ${i}`, 'info', { duration: 60000 });
    });
    await expect(region.locator('.toast')).toHaveCount(5);
    await expect(region.locator('.toast', { hasText: 'saved fine' })).toHaveCount(0); // oldest dropped
    await page.evaluate(() => toastUndo('Deleted "x"', () => { window.__undone += 1; }));
    const undo = region.locator('.toast', { hasText: 'Deleted "x"' });
    await undo.getByRole('button', { name: 'Undo' }).click();
    await expect(undo).toHaveCount(0);
    expect(await page.evaluate(() => window.__undone)).toBe(1);
    await page.evaluate(() => showToast('short lived', 'info', { duration: 200 }));
    await expect(region.locator('.toast', { hasText: 'short lived' })).toHaveCount(0);
});

test('context menu opens from the keyboard, roves, and Escape returns focus to the row', async ({ page }) => {
    await createVm(page, 'wf-shell-ctx-kbd');
    await page.reload();
    const row = page.locator('.vm-item', { hasText: 'wf-shell-ctx-kbd' }).first();
    await row.focus();
    await page.keyboard.press('Shift+F10');
    const menu = page.getByRole('menu', { name: 'VM actions' });
    await expect(menu).toBeVisible();
    const items = menu.getByRole('menuitem');
    await expect(items.first()).toBeFocused(); // Power On, the first enabled item
    await expect(items.first()).toHaveText('Power On');
    await expect(menu.getByRole('menuitem', { name: 'Shut Down Guest' })).toBeDisabled();
    await expect(menu.getByRole('menuitem', { name: 'Shut Down Guest' })).toHaveAttribute('title', /running/);
    await page.keyboard.press('ArrowDown');
    await expect(menu.getByRole('menuitem', { name: 'Take Snapshot…' })).toBeFocused(); // skips disabled items
    await page.keyboard.press('End');
    await expect(menu.getByRole('menuitem', { name: 'Delete' })).toBeFocused();
    await page.keyboard.press('Home');
    await expect(items.first()).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(menu).toHaveCount(0);
    await expect(row).toBeFocused();
    await expect(page.locator('.vm-item.active')).toHaveCount(0); // Escape only closed the menu
    await row.click({ button: 'right' });
    await expect(menu).toBeVisible();
    await page.mouse.click(700, 500); // outside
    await expect(menu).toHaveCount(0);
});

test('command palette navigates with the arrow keys, filters, and jumps to a VM', async ({ page }) => {
    await createVm(page, 'wf-shell-pal-jump');
    await page.reload();
    // The palette lists the VMs loaded when it opens, so wait for the list first.
    await expect(page.locator('.vm-item', { hasText: 'wf-shell-pal-jump' })).toBeVisible();
    await page.keyboard.press('Control+k');
    const input = page.locator('#paletteInput');
    await expect(input).toBeFocused();
    await expect(input).toHaveAttribute('role', 'combobox');
    await expect(input).toHaveAttribute('aria-activedescendant', 'paletteOpt0');
    await expect(page.locator('#paletteOpt0')).toHaveAttribute('aria-selected', 'true');
    await page.keyboard.press('ArrowDown');
    await expect(input).toHaveAttribute('aria-activedescendant', 'paletteOpt1');
    await expect(page.locator('#paletteOpt1')).toHaveAttribute('aria-selected', 'true');
    await expect(page.locator('#paletteOpt0')).toHaveAttribute('aria-selected', 'false');
    await page.keyboard.press('ArrowUp');
    await page.keyboard.press('ArrowUp'); // wraps to the last option
    const count = await page.locator('#paletteList li[data-pidx]').count();
    await expect(input).toHaveAttribute('aria-activedescendant', `paletteOpt${count - 1}`);
    await page.fill('#paletteInput', 'zzzz-no-such-command');
    await expect(page.locator('#paletteList')).toContainText('No matches');
    await expect(input).not.toHaveAttribute('aria-activedescendant', /.+/);
    await page.keyboard.press('Enter'); // nothing to run, stays open
    await expect(page.locator('#palette')).toBeVisible();
    await page.fill('#paletteInput', 'go to wf-shell-pal-jump');
    await expect(page.locator('#paletteList li[data-pidx]')).toHaveCount(1);
    await page.keyboard.press('Enter');
    await expect(page.locator('#palette')).toHaveCount(0);
    await expect(page.locator('#vmname')).toHaveText('wf-shell-pal-jump');
    // Backdrop click closes without running anything and gives focus back.
    await page.locator('.vm-item.active').focus();
    await page.keyboard.press('Control+k');
    await expect(page.locator('#palette')).toBeVisible();
    await page.mouse.click(4, 4);
    await expect(page.locator('#palette')).toHaveCount(0);
    await expect(page.locator('.vm-item.active')).toBeFocused();
});

// Settings tab: the form is Preact; these drive it through the real controls.
// The shared daemon holds 64 VMs at most, so a test removes the VMs it made.
async function removeVms(page, ...names) {
    for (const name of names) {
        const idx = await indexOf(page, name);
        if (idx >= 0) await api(page, 'POST', `/api/vms/${idx}/delete`, '');
    }
}

async function openSettings(page, name) {
    await page.reload();
    await page.locator('.vm-item', { hasText: name }).first().click();
    await page.click('#tab-btn-settings');
    await expect(page.locator('.settings-panel.active')).toBeVisible();
}

test('settings nav shows one panel at a time and marks the current category', async ({ page }) => {
    try {
        await createVm(page, 'wf-set-nav');
        await openSettings(page, 'wf-set-nav');
        const nav = (id) => page.locator(`.settings-nav-item[data-settings-category="${id}"]`);
        await expect(nav('basic')).toHaveAttribute('aria-current', 'page');
        await expect(page.locator('[data-settings-panel="basic"]')).toBeVisible();
        await expect(page.locator('[data-settings-panel="network_and_boot"]')).toBeHidden();
        await nav('network_and_boot').click();
        await expect(nav('network_and_boot')).toHaveAttribute('aria-current', 'page');
        await expect(nav('basic')).not.toHaveAttribute('aria-current', 'page');
        await expect(page.locator('[data-settings-panel="network_and_boot"]')).toBeVisible();
        await expect(page.locator('[data-settings-panel="basic"]')).toBeHidden();
        // Every section of the form is reachable and every field keeps its e_<key> id.
        for (const id of ['sharing', 'autoprotect', 'display_and_video', 'storage_and_notes', 'extra_disks', 'advanced']) {
            await nav(id).click();
            await expect(page.locator(`[data-settings-panel="${id}"]`)).toBeVisible();
            await expect(page.locator(`[data-settings-panel="${id}"] .settings-form > *`).first()).toBeVisible();
        }
        await expect(page.locator('#e_nic8_vnet')).toHaveCount(1);
        await expect(page.locator('#e_extra3_format')).toHaveCount(1);
    } finally {
        await removeVms(page, 'wf-set-nav');
    }
});

test('settings validation blocks the save, lands on the first bad field, and the fixed form saves the exact edits', async ({ page }) => {
    try {
        const idx = await createVm(page, 'wf-set-save');
        await openSettings(page, 'wf-set-save');
        const posts = [];
        page.on('request', (r) => { if (r.method() === 'POST' && r.url().endsWith(`/api/vms/${idx}`)) posts.push(r.postData()); });
        await page.locator('#e_mem').fill('64');
        await expect(page.locator('#err_e_mem')).toHaveText('Memory must be 128-65536 MB.');
        await expect(page.locator('#e_mem')).toHaveAttribute('aria-invalid', 'true');
        // A bad MAC in a section that is not showing.
        await page.locator('.settings-nav-item[data-settings-category="network_and_boot"]').click();
        await page.locator('#e_mac_address').fill('zz');
        await expect(page.locator('#err_e_mac_address')).toHaveText('Use XX:XX:XX:XX:XX:XX.');
        await page.locator('.settings-nav-item[data-settings-category="storage_and_notes"]').click();
        await page.click('#savevmbtn');
        await expect(page.locator('#toast-container')).toContainText('Fix highlighted settings before saving.');
        expect(posts, 'no request while a field is invalid').toHaveLength(0);
        // First bad field in nav order: memory, in Basic.
        await expect(page.locator('.settings-nav-item.active')).toHaveAttribute('data-settings-category', 'basic');
        await expect(page.locator('#e_mem')).toBeFocused();
        await page.locator('#e_mem').fill('2048');
        await page.click('#savevmbtn');
        await expect(page.locator('.settings-nav-item.active')).toHaveAttribute('data-settings-category', 'network_and_boot');
        await expect(page.locator('#e_mac_address')).toBeFocused();
        expect(posts).toHaveLength(0);
        await page.locator('#e_mac_address').fill('52:54:00:12:34:56');
        await page.locator('.settings-nav-item[data-settings-category="basic"]').click();
        await page.locator('#e_name').fill('wf-set-saved');
        const sent = page.waitForRequest((r) => r.method() === 'POST' && r.url().endsWith(`/api/vms/${idx}`));
        await page.click('#savevmbtn');
        const body = (await sent).postData() ?? '';
        expect(body.startsWith('name=wf-set-saved&mem=2048&cpu=1&cpu_sockets=1&')).toBe(true);
        expect(body).toContain('&mac_address=52%3A54%3A00%3A12%3A34%3A56&');
        await expect(page.locator('#tabSummary')).toBeVisible();
        await expect(page.locator('#statusannounce')).toHaveText('Settings saved.');
        await expect.poll(async () => (await list(page)).find((v) => v.name === 'wf-set-saved')?.mac).toBe('52:54:00:12:34:56');
        expect((await list(page)).find((v) => v.name === 'wf-set-saved').mem).toBe(2048);
    } finally {
        await removeVms(page, 'wf-set-save', 'wf-set-saved');
    }
});

test('settings track unsaved edits: leaving asks, putting the value back does not', async ({ page }) => {
    try {
        await createVm(page, 'wf-set-dirty');
        await openSettings(page, 'wf-set-dirty');
        await page.locator('.settings-nav-item[data-settings-category="storage_and_notes"]').click();
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
        // Discard drops the edit: the form opens again from the saved VM.
        await page.click('#tab-btn-settings');
        await page.locator('.settings-nav-item[data-settings-category="storage_and_notes"]').click();
        await page.locator('#e_notes').fill('again');
        await page.click('#tab-btn-summary');
        await page.locator('#confirmOkBtn').click();
        await expect(page.locator('#tabSummary')).toBeVisible();
        await page.click('#tab-btn-settings');
        await page.locator('.settings-nav-item[data-settings-category="storage_and_notes"]').click();
        await expect(page.locator('#e_notes')).toHaveValue('');
    } finally {
        await removeVms(page, 'wf-set-dirty');
    }
});

test('settings disk tools resize and compact the primary disk', async ({ page }) => {
    try {
        const idx = await createVm(page, 'wf-set-disk');
        await openSettings(page, 'wf-set-disk');
        await page.locator('#tabSettings [data-action="resizeDisk"]').click();
        await expect(page.locator('#promptdlg')).toBeVisible();
        await page.locator('#promptInput').fill('1');
        await page.locator('#promptOkBtn').click();
        await expect(page.locator('#toast-container')).toContainText('Enter a size larger than 1 GB');
        await page.locator('#tabSettings [data-action="resizeDisk"]').click();
        await page.locator('#promptInput').fill('3');
        await page.locator('#promptOkBtn').click();
        await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-set-disk')].disk).toBe(3);
        await expect(page.locator('#statusannounce')).toHaveText('Primary disk resized to 3 GB.');
        await page.locator('#tabSettings [data-action="compactDisk"]').click();
        await page.locator('#confirmOkBtn').click();
        await expect(page.locator('#statusannounce')).toHaveText('Primary disk compacted.');
        expect(idx).toBeGreaterThanOrEqual(0);
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
        await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-set-cd')].iso_path).toBe('/tmp/wf-ui.iso');
        await page.locator('#tabSettings [data-action="ejectCd"]').click();
        await expect.poll(async () => (await list(page))[await indexOf(page, 'wf-set-cd')].iso_path).toBe('');
    } finally {
        await removeVms(page, 'wf-set-cd');
    }
});

test('summary shows facts, hardware, disk usage, tags, folder, notes and warnings', async ({ page }) => {
    try {
        const idx = await createVm(page, 'wf-sum');
        const r = await api(page, 'POST', `/api/vms/${idx}`, 'notes=line%20one&tags=prod%2Cweb&folder=Lab&network=none');
        expect(r.ok).toBe(true);
        await page.reload();
        await page.locator('.vm-item', { hasText: 'wf-sum' }).first().click();
        const facts = page.locator('.vm-facts');
        await expect(facts).toContainText('Stopped');
        await expect(facts).toContainText('1 vCPU');
        await expect(facts).toContainText('1 GiB RAM');
        await expect(facts).toContainText('1 GB disk');
        await expect(facts).not.toContainText('IP');
        const disk = page.locator('.srow', { hasText: 'Hard Disk' });
        await expect(disk).toContainText('1 GB');
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
        // With nothing selected the dashboard lists the same VM under "Needs attention".
        await page.locator('.toolbar > [data-action="deselectVm"]').click();
        await expect(page.locator('.dash-attention')).toContainText('wf-sum');
    } finally {
        await removeVms(page, 'wf-sum');
    }
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
        const order = async () => (await page.locator('.inv tbody tr td.inv-name').allTextContents())
            .filter((n) => n.startsWith('wf-ram-'));
        expect(await order()).toEqual(['wf-ram-small', 'wf-ram-big']);
        await header.click();
        await expect(header).toHaveAttribute('aria-sort', 'descending');
        expect(await order()).toEqual(['wf-ram-big', 'wf-ram-small']);
        await expect(page.locator('.inv thead th[data-col="name"]')).toHaveAttribute('aria-sort', 'none');
    } finally {
        await removeVms(page, 'wf-ram-small', 'wf-ram-big');
    }
});

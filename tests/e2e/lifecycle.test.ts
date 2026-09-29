/**
 * End-to-end coverage for the VM lifecycle workflows the API exposes, driving the real built hangar-web
 * binary (see playwright.config.ts). These exercise operations that are deterministic on a freshly created,
 * stopped VM with a real qcow2 disk (created by the daemon via qemu-img): clone, rename, delete and undo,
 * snapshots, secondary-disk upload and download, and OVF export. Power-on and migration need a real booted
 * guest or a second host, so they live in console.test.ts.
 */
import { expect, test, type Page } from '@playwright/test';
import { loadApp, overrideVm, refreshList, selectVm } from './app-ui';
import { api, countVms, createVm, indexOf, listVms, parseJson, parseJsonList, removeVms, vmField, vmNamed } from './daemon-api';

const UPTIME_SECONDS = 90_061;
const UPTIME_START = 1_789_680_000;
const CLOCK_INSTANTS = ['2024-03-10T06:59:59Z', '2024-11-03T06:00:00Z', '2100-01-01T00:00:00Z'];

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

type Delivery = { readonly path: string; readonly statuses: Array<number>; readonly states: Array<{ readonly status: unknown; readonly started: unknown }> };

/** Sends every matching power request to the daemon twice and records what the daemon reported after each delivery. */
const duplicatePowerRequests = async (page: Page, name: string, index: number, deliveries: Array<Delivery>): Promise<RegExp> => {
    const powerRoute = new RegExp(`/api/vms/${index}/(power|start|stop)$`);
    await page.route(powerRoute, async (route) => {
        const statuses: Array<number> = [];
        const states: Delivery['states'] = [];
        for (const attempt of [0, 1]) {
            const response = await route.fetch();
            statuses.push(response.status());
            const vm = await vmNamed(page, name);
            states.push({ status: vm.status, started: vm.started });
            if (attempt === 1) {
                deliveries.push({ path: new URL(route.request().url()).pathname, statuses, states });
                await route.fulfill({ response });
            }
        }
    });
    return powerRoute;
};

type PowerControl = 'toolbar' | 'batch' | 'bulk';

const pressPower = async (page: Page, control: PowerControl, on: boolean): Promise<void> => {
    if (control === 'toolbar') {
        await page.click('#powerbtn');
    } else if (control === 'batch') {
        await page.locator('[data-menu="dangerMenu"]:visible').click();
        await page.locator(`[data-action="${on ? 'batchStart' : 'batchStop'}"]`).click();
    } else {
        await page.locator(`[data-action="bulkPower"][data-on="${on ? '1' : '0'}"]`).click();
    }
    if (!on || control === 'bulk') {
        await page.locator('#confirmOkBtn').click();
    }
};

for (const control of ['toolbar', 'batch', 'bulk'] as const) {
    test(`${control} power actions survive duplicate delivery`, async ({ page }) => {
        const name = `wf-repeat-${control}`;
        const created = await api(page, 'POST', '/api/vms', `name=${name}&mem=128&cpu=1&disk=1&display=vnc&firmware=bios&accel=tcg`);
        expect(created.ok).toBe(true);
        const index = await indexOf(page, name);
        const deliveries: Array<Delivery> = [];
        const powerRoute = await duplicatePowerRequests(page, name, index, deliveries);
        try {
            await page.reload();
            await selectVm(page, name);
            if (control === 'bulk') {
                await page.click('#selectToggle');
                await page.locator('.vm-item', { hasText: name }).locator('.vm-check').check();
            }
            for (const on of [true, false]) {
                await pressPower(page, control, on);
                await expect.poll(() => deliveries.length).toBe(on ? 1 : 2);
                const delivery = deliveries.at(-1);
                expect(delivery?.statuses).toEqual([200, 200]);
                expect(delivery?.states[0]?.status).toBe(on ? 'running' : 'stopped');
                expect(delivery?.states[1]).toEqual(delivery?.states[0]);
                expect(delivery?.path).toBe(`/api/vms/${index}/${on ? 'start' : 'stop'}`);
                await expect.poll(() => vmField(page, name, 'status')).toBe(on ? 'running' : 'stopped');
                await expect(page.locator('#powerbtn')).toHaveText(on ? 'Power Off' : 'Power On');
            }
        } finally {
            await page.unroute(powerRoute);
            await api(page, 'POST', `/api/vms/${index}/stop`, '');
            await api(page, 'POST', `/api/vms/${index}/delete`, '');
        }
    });
}

test('uptime uses daemon elapsed seconds across browser clock changes', async ({ page }) => {
    const bundle = await page.request.get('/ui.js');
    expect(bundle.status()).toBe(200);
    expect(bundle.headers()['content-type']).toContain('javascript');
    expect(await bundle.text()).toBe(await Bun.file(new URL('../../src/web/dist/ui.js', import.meta.url)).text());
    const name = 'wf-uptime-clock';
    await createVm(page, name);
    let elapsed: unknown = UPTIME_SECONDS;
    let started = UPTIME_START;
    const restore = await overrideVm(page, name, () => ({ status: 'running', started, uptime_sec: elapsed }));
    try {
        await page.reload();
        await selectVm(page, name);
        for (const instant of CLOCK_INSTANTS) {
            await page.clock.setFixedTime(new Date(instant));
            await refreshList(page);
            await expect(page.locator('#statusmsg')).toContainText('Uptime: 1d 1:01:01');
        }
        elapsed = 0;
        started = 0;
        await refreshList(page);
        await expect(page.locator('#statusmsg')).toContainText('Uptime: 0:00:00');
        for (const invalid of [null, -1, 'not-a-duration']) {
            elapsed = invalid;
            await refreshList(page);
            await expect(page.locator('#statusmsg')).not.toContainText('Uptime:');
        }
    } finally {
        await restore();
        await removeVms(page, name);
    }
});

for (const width of [1280, 390]) {
    test(`global Tools remain usable from Home at ${width}px`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await expect(page.locator('#vmname')).toHaveText(/Overview|Welcome to Hangar/);
        if (width < 900) {
            await page.locator('.toolbar-more').click();
        }
        const tools = page.locator('[data-menu="toolsMenu"]:visible');
        await expect(tools).toBeEnabled();
        await tools.click();
        await expect(page.locator('#toolsMenu [data-action="renameGuest"]')).toBeDisabled();
        await page.locator('#toolsMenu [data-action="openPrefs"]').click();
        await expect(page.locator('#prefsdlg')).toBeVisible();
        await page.locator('#prefsdlg [data-action="closeDlg"]').click();
        await expect(page.locator('#prefsdlg')).toBeHidden();
        if (width < 900) {
            await page.locator('.toolbar-more').click();
        }
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
    await refreshList(page);
    await expect(items).toHaveCount(1);
    await expect(page.locator('#search')).toHaveValue('wf-search-match');
    await page.locator('#searchClear').click();
    await expect(page.locator('#vmlist .vm-item', { hasText: 'wf-search-other' })).toBeVisible();
});

test('clone workflow creates a second VM', async ({ page }) => {
    const index = await createVm(page, 'wf-clone-src');
    const before = await countVms(page);
    const reply = await api(page, 'POST', `/api/vms/${index}/clone`, '');
    expect(reply.ok, `clone: ${reply.status} ${reply.text}`).toBe(true);
    await expect.poll(() => countVms(page)).toBe(before + 1);
    const vms = await listVms(page);
    expect(vms.some((vm) => vm.name.includes('wf-clone-src') && vm.name !== 'wf-clone-src')).toBe(true);
});

test('rename workflow changes the VM name', async ({ page }) => {
    const index = await createVm(page, 'wf-rename-old');
    const reply = await api(page, 'POST', `/api/vms/${index}/rename`, 'name=wf-rename-new');
    expect(reply.ok, `rename: ${reply.status} ${reply.text}`).toBe(true);
    await expect.poll(() => indexOf(page, 'wf-rename-new')).toBeGreaterThanOrEqual(0);
    expect(await indexOf(page, 'wf-rename-old')).toBe(-1);
});

test('delete then undo restores the VM', async ({ page }) => {
    const index = await createVm(page, 'wf-del');
    const before = await countVms(page);
    const deleted = await api(page, 'POST', `/api/vms/${index}/delete`, '');
    expect(deleted.ok, `delete: ${deleted.status} ${deleted.text}`).toBe(true);
    await expect.poll(() => countVms(page)).toBe(before - 1);
    expect(await indexOf(page, 'wf-del')).toBe(-1);

    const undone = await api(page, 'POST', '/api/vms/undo', '');
    expect(undone.ok, `undo: ${undone.status} ${undone.text}`).toBe(true);
    await expect.poll(() => indexOf(page, 'wf-del')).toBeGreaterThanOrEqual(0);
});

test('snapshot take, list, and delete on a stopped VM', async ({ page }) => {
    const index = await createVm(page, 'wf-snap');
    const taken = await api(page, 'POST', `/api/vms/${index}/snapshots`, 'tag=snap1');
    expect(taken.ok, `take: ${taken.status} ${taken.text}`).toBe(true);
    const snapshots = async (): Promise<string> => {
        const listed = await api(page, 'GET', `/api/vms/${index}/snapshots`);
        return listed.text;
    };
    await expect.poll(snapshots).toContain('snap1');
    const removed = await api(page, 'POST', `/api/vms/${index}/snapshots/delete`, 'tag=snap1');
    expect(removed.ok, `delete snap: ${removed.status} ${removed.text}`).toBe(true);
    await expect.poll(snapshots).not.toContain('snap1');
});

test('secondary disk upload then download round-trips', async ({ page }) => {
    const index = await createVm(page, 'wf-disk2');
    /* Upload a small file as disk2 via multipart, the same shape the UI sends. */
    const upload = await page.evaluate(async (target) => {
        const form = new FormData();
        form.append('disk2', new Blob(['HANGAR_E2E_DISK2_PAYLOAD'], { type: 'application/octet-stream' }), 'd2.img');
        const response = await fetch(`/api/vms/${target}/disk2`, { method: 'POST', body: form, headers: { 'X-API-Key': 'hangar' } });
        return { status: response.status, text: await response.text() };
    }, index);
    expect(upload.status, `upload: ${upload.text}`).toBe(200);
    const download = await api(page, 'GET', `/api/vms/${index}/disk2/download`);
    expect(download.status).toBe(200);
    expect(download.text).toContain('HANGAR_E2E_DISK2_PAYLOAD');
});

test('OVF export preserves the total CPU count across sockets', async ({ page }) => {
    const index = await createVm(page, 'wf-export');
    const saved = await api(page, 'POST', `/api/vms/${index}`, 'cpu=4&cpu_sockets=2');
    expect(saved.ok, `save topology: ${saved.status} ${saved.text}`).toBe(true);
    const exported = await page.evaluate(async (target) => {
        const response = await fetch(`/api/vms/${target}/export`, { method: 'POST', headers: { 'X-API-Key': 'hangar' } });
        return { status: response.status, bytes: [...new Uint8Array(await response.arrayBuffer())] };
    }, index);
    expect(exported.status, 'export status').toBe(200);
    expect(exported.bytes.length, 'export tarball should be non-empty').toBeGreaterThan(0);
    const members = await new Bun.Archive(new Uint8Array(exported.bytes)).files('**/*.ovf');
    const descriptor = members.get('./wf-export.ovf');
    expect(descriptor, 'the tarball holds the OVF descriptor').toBeDefined();
    const xml = await descriptor?.text();
    expect(xml).toContain('<rasd:ElementName>8 virtual CPU(s)</rasd:ElementName>');
    expect(xml).toContain('<rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>8</rasd:VirtualQuantity>');
});

test('tags save, persist in the list JSON, and drive the sidebar filter', async ({ page }) => {
    const index = await createVm(page, 'wf-tags');
    const reply = await api(page, 'POST', `/api/vms/${index}`, 'tags=prod%2Cweb');
    expect(reply.ok, `save tags: ${reply.status} ${reply.text}`).toBe(true);
    await expect.poll(() => vmField(page, 'wf-tags', 'tags')).toBe('prod,web');
    /* The sidebar filter matches on tags: filtering by "prod" keeps the tagged VM. */
    await page.fill('#search', 'prod');
    await expect(page.locator('#vmlist')).toContainText('wf-tags');
    await page.fill('#search', 'no-such-tag-zzz');
    await expect(page.locator('#vmlist')).not.toContainText('wf-tags');
});

test('disk resize grows the primary disk (stopped VM, grow-only)', async ({ page }) => {
    const index = await createVm(page, 'wf-resize');
    const before = await vmField(page, 'wf-resize', 'disk');
    expect(Number(before)).toBeLessThan(8);
    const grown = await api(page, 'POST', `/api/vms/${index}/disk/resize`, 'size=8');
    expect(grown.ok, `resize: ${grown.status} ${grown.text}`).toBe(true);
    await expect.poll(() => vmField(page, 'wf-resize', 'disk')).toBe(8);
    const shrunk = await api(page, 'POST', `/api/vms/${index}/disk/resize`, 'size=2');
    expect(shrunk.text).toContain('shrink not allowed');
});

test('diskinfo reports virtual and actual byte sizes', async ({ page }) => {
    const index = await createVm(page, 'wf-diskinfo');
    const reply = await api(page, 'GET', `/api/vms/${index}/diskinfo`);
    const info = parseJson(reply.text);
    expect(info).not.toHaveProperty('error');
    expect(info).toMatchObject({ virtual_bytes: expect.any(Number), actual_bytes: expect.any(Number) });
    expect(info).not.toMatchObject({ virtual_bytes: 0 });
});

test('cdrom change then eject updates the ISO on a stopped VM', async ({ page }) => {
    const index = await createVm(page, 'wf-cd');
    const changed = await api(page, 'POST', `/api/vms/${index}/cdrom`, 'path=%2Ftmp%2Fwf-test.iso');
    expect(changed.ok, `cdrom change: ${changed.status} ${changed.text}`).toBe(true);
    await expect.poll(() => vmField(page, 'wf-cd', 'iso_path')).toBe('/tmp/wf-test.iso');
    const ejected = await api(page, 'POST', `/api/vms/${index}/cdrom/eject`, '');
    expect(ejected.ok, `cdrom eject: ${ejected.status} ${ejected.text}`).toBe(true);
    await expect.poll(() => vmField(page, 'wf-cd', 'iso_path')).toBe('');
    /* A comma in the path is rejected (-drive injection guard). */
    const bad = await api(page, 'POST', `/api/vms/${index}/cdrom`, 'path=%2Ftmp%2Fa%2Cb.iso');
    expect(bad.text).toContain('bad path');
});

test('screenshot on a stopped VM returns 409 (needs a running guest)', async ({ page }) => {
    const index = await createVm(page, 'wf-shot');
    const reply = await api(page, 'GET', `/api/vms/${index}/screenshot`);
    expect(reply.status, `screenshot on stopped VM: ${reply.text}`).toBe(409);
});

test('cloud-init user-data saves and round-trips through the detail API', async ({ page }) => {
    const index = await createVm(page, 'wf-ci');
    const userData = '#cloud-config\npackages:\n  - htop\n';
    const saved = await api(page, 'POST', `/api/vms/${index}`, `cloud_init=${encodeURIComponent(userData)}`);
    expect(saved.ok, `save cloud-init: ${saved.status} ${saved.text}`).toBe(true);
    const detail = await api(page, 'GET', `/api/vms/${index}`);
    expect(detail.text).toContain('packages:');
    expect(detail.text).toContain('- htop');
});

test('guestinfo returns empty IPs for a stopped VM (needs a running guest agent)', async ({ page }) => {
    const index = await createVm(page, 'wf-gi');
    const reply = await api(page, 'GET', `/api/vms/${index}/guestinfo`);
    expect(parseJson(reply.text)).toMatchObject({ ips: '' });
});

test('RTC clock policy saves and round-trips (localtime for Windows guests)', async ({ page }) => {
    const index = await createVm(page, 'wf-rtc');
    /* The policy value 1 is localtime. */
    const saved = await api(page, 'POST', `/api/vms/${index}`, 'rtc=1');
    expect(saved.ok, `save rtc: ${saved.status} ${saved.text}`).toBe(true);
    const detail = await api(page, 'GET', `/api/vms/${index}`);
    expect(parseJson(detail.text)).toMatchObject({ rtc: 1 });
});

test('disk compact rewrites the image and keeps it valid (stopped VM)', async ({ page }) => {
    const index = await createVm(page, 'wf-compact');
    const before = await vmField(page, 'wf-compact', 'disk');
    const compacted = await api(page, 'POST', `/api/vms/${index}/disk/compact`, '');
    expect(compacted.ok, `compact: ${compacted.status} ${compacted.text}`).toBe(true);
    /* The virtual size is unchanged; diskinfo must still parse the rewritten image. */
    const diskinfo = await api(page, 'GET', `/api/vms/${index}/diskinfo`);
    const info = parseJson(diskinfo.text);
    expect(info).not.toHaveProperty('error');
    expect(info).not.toMatchObject({ virtual_bytes: 0 });
    expect(await vmField(page, 'wf-compact', 'disk')).toBe(before);
});

test('write-action without the API key is rejected (401)', async ({ page }) => {
    const index = await createVm(page, 'wf-auth');
    const status = await page.evaluate(async (target) => {
        const response = await fetch(`/api/vms/${target}/rename`, { method: 'POST', body: 'name=nope' });
        return response.status;
    }, index);
    expect(status).toBe(401);
});

test('host dashboard shows inventory totals when no VM is selected', async ({ page }) => {
    await createVm(page, 'wf-dash-a');
    await createVm(page, 'wf-dash-b');
    /* No VM selected: the summary panel renders the host dashboard. */
    await page.reload();
    await expect(page.locator('#tabSummary .dash')).toBeVisible();
    /* "N virtual machines" reflects the inventory, with the capacity cards beside it. */
    await expect(page.locator('.dash-head')).toContainText('virtual machines');
    /* Four state cards and three capacity cards. */
    expect(await page.locator('.dash-card').count()).toBeGreaterThanOrEqual(7);
    /* Clicking a sidebar VM leaves the dashboard for the detail view. */
    await page.click('#vmlist .vm-item');
    await expect(page.locator('#tabSummary .dash')).toHaveCount(0);
    await expect(page.locator('.vm-facts')).toBeVisible();
});

test('catalog quickstart creates a VM with the template OS and firmware', async ({ page }) => {
    const catalog = await api(page, 'GET', '/api/catalog');
    const entries = parseJsonList(catalog.text);
    expect(entries.length).toBeGreaterThanOrEqual(10);
    /* Firmware 1 is UEFI. */
    expect(entries).toContainEqual(expect.objectContaining({ id: 'win11', firmware: 1 }));
    /* Quickstart a UEFI Windows template and a BIOS Alpine template. */
    await api(page, 'POST', '/api/vms/quickstart/win11', '');
    await api(page, 'POST', '/api/vms/quickstart/alpine320', '');
    const windows = await vmNamed(page, 'Windows 11');
    const alpine = await vmNamed(page, 'Alpine 3.20');
    expect(windows.fw).toBe('uefi');
    expect(windows.os).toMatch(/Windows/);
    expect(alpine.fw).toBe('bios');
    /* A second win11 quickstart gets a unique name (sockets are name-derived). */
    await api(page, 'POST', '/api/vms/quickstart/win11', '');
    const after = await listVms(page);
    expect(after.filter((vm) => vm.name.startsWith('Windows 11'))).toHaveLength(2);
});

test('SSE: a VM created via the API appears in the UI within 3s, no reload', async ({ page }) => {
    const started = Date.now();
    await api(page, 'POST', '/api/vms', 'name=wf-sse&mem=1024&cpu=1&disk=1');
    await page.waitForSelector('.vm-item:has-text("wf-sse")', { timeout: 4000 });
    expect(Date.now() - started, 'push beats the 5s poll').toBeLessThan(3500);
    await expect(page.locator('.dash .inv tbody tr', { hasText: 'wf-sse' })).toBeVisible();
});

test('stable VM id is assigned and survives a rename', async ({ page }) => {
    const index = await createVm(page, 'wf-id-a');
    const before = await vmField(page, 'wf-id-a', 'id');
    expect(before, 'a 16-hex-char id should be assigned at create').toMatch(/^[0-9a-f]{16}$/);
    await api(page, 'POST', `/api/vms/${index}/rename`, 'name=wf-id-renamed');
    await expect.poll(() => indexOf(page, 'wf-id-renamed')).toBeGreaterThanOrEqual(0);
    expect(await vmField(page, 'wf-id-renamed', 'id'), 'id must be stable across rename').toBe(before);
});

test('bulk delete removes only the checked VMs', async ({ page }) => {
    await createVm(page, 'wf-bulk-1');
    await createVm(page, 'wf-bulk-2');
    await createVm(page, 'wf-bulk-keep');
    await page.reload();
    await page.click('#selectToggle');
    await page.locator('.vm-item', { hasText: 'wf-bulk-1' }).locator('.vm-check').check();
    await page.locator('.vm-item', { hasText: 'wf-bulk-2' }).locator('.vm-check').check();
    await expect(page.locator('#bulkCount')).toHaveText('2 selected');
    await page.click('[data-action="bulkDelete"]');
    await page.locator('#confirmOkBtn').click();
    await expect.poll(() => indexOf(page, 'wf-bulk-1')).toBe(-1);
    expect(await indexOf(page, 'wf-bulk-2')).toBe(-1);
    expect(await indexOf(page, 'wf-bulk-keep')).toBeGreaterThanOrEqual(0);
});

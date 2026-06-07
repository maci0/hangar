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

test('write-action without the API key is rejected (401)', async ({ page }) => {
    const idx = await createVm(page, 'wf-auth');
    const r = await page.evaluate(async (i) => {
        const res = await fetch(`/api/vms/${i}/rename`, { method: 'POST', body: 'name=nope' });
        return res.status;
    }, idx);
    expect(r).toBe(401);
});

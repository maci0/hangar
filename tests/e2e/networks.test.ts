/** Virtual network editor, network topology and VM catalog workflows. */
import { expect, test, type Page } from '@playwright/test';
import { chooseTool, createLatch, loadApp, openTopology, openVnetEditor, TOPOLOGY_NODE } from './app-ui';
import { api, createVm, indexOf, parseJson, removeVms, vmField } from './daemon-api';

const TOPOLOGY_TIMEOUT_MS = 10_000;
const CATALOG_MIN_ENTRIES = 10;

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

/** Wraps a test body that edits the network set: the original set is restored afterwards. */
const withNetworksRestored = async (page: Page, body: () => Promise<void>): Promise<void> => {
    const original = await api(page, 'GET', '/api/networks');
    expect(original.ok).toBe(true);
    try {
        await body();
    } finally {
        const restored = await api(page, 'POST', '/api/networks', original.text);
        expect(restored.ok).toBe(true);
    }
};

/** Network names the daemon stores. */
const storedNetworkNames = async (page: Page): Promise<Array<unknown>> => {
    const stored = await api(page, 'GET', '/api/networks');
    const networks = parseJson(stored.text);
    return typeof networks === 'object' && networks !== null && 'networks' in networks && typeof networks.networks === 'object' && networks.networks !== null
        ? Object.values(networks.networks).flatMap((net: unknown) => (typeof net === 'object' && net !== null && 'name' in net ? [net.name] : []))
        : [];
};

test('VM vnet binding round-trips and links the VM to that network in the topology', async ({ page }) => {
    await createVm(page, 'wf-vnet');
    const index = await indexOf(page, 'wf-vnet');
    await api(page, 'POST', `/api/vms/${index}`, 'vnet=VMnet8');
    await expect.poll(() => vmField(page, 'wf-vnet', 'vnet')).toBe('VMnet8');
    await page.reload();
    await openTopology(page);
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    /* The bound virtual network appears as a node the VM connects to. */
    await expect(page.locator('.topo-node.vnet').filter({ hasText: 'VMnet8' })).toHaveCount(1);
    /* Node accents come from theme tokens, never hard-coded hex. */
    const strokeColors = await page.locator('.topo-node rect').evaluateAll((rects) => rects.map((rect) => getComputedStyle(rect).stroke));
    expect(strokeColors.length).toBeGreaterThan(0);
    for (const color of strokeColors) {
        expect(color).not.toMatch(/rgb\(16,\s*185,\s*129\)|#10B981/i);
    }
});

test('network topology renders VMs/networks/host via elkjs and a VM node selects', async ({ page }) => {
    await createVm(page, 'wf-topo-vm');
    await page.reload();
    await openTopology(page);
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    expect(await page.locator('.topo-node').count()).toBeGreaterThan(1);
    /* The host uplink node. */
    await expect(page.locator('.topo-node.host')).toHaveCount(1);
    /* Clicking a VM node closes the topology and selects that VM. */
    await page.locator('.topo-node.vm').first().click();
    await expect(page.locator('#topodlg')).toBeHidden();
    await expect(page.locator('.vm-facts')).toBeVisible();
});

test('elk.js is not fetched on page load and loads on first topology open', async ({ page }) => {
    const elkRequests: Array<string> = [];
    page.on('request', (request) => {
        if (request.url().endsWith('/elk.js')) {
            elkRequests.push(request.url());
        }
    });
    await createVm(page, 'wf-topo-lazy');
    await page.reload();
    expect(elkRequests, 'elk.js must not load before the topology is opened').toHaveLength(0);
    const engine = createLatch();
    await page.route('**/elk.js', async (route) => {
        await engine.opened;
        await route.continue();
    });
    await openTopology(page);
    await expect(page.locator('#topoWrap')).toContainText('Loading layout engine');
    /* A second open while the engine loads joins the pending load. */
    await page.locator('#topodlg [data-action="openTopology"]').click();
    engine.open();
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    await page.locator('#topodlg [data-action="openTopology"]').click();
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    expect(elkRequests).toHaveLength(1);
});

test('a failed elk.js load degrades visibly with a retry', async ({ page }) => {
    await createVm(page, 'wf-topo-fail');
    await page.reload();
    await page.route('**/elk.js', (route) => route.abort());
    await openTopology(page);
    await expect(page.locator('#topoWrap')).toContainText('failed to load', { timeout: TOPOLOGY_TIMEOUT_MS });
    await page.unroute('**/elk.js');
    await page.click('#topoWrap [data-action="openTopology"]');
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
});

test('topology shows a computing state, Refresh recomputes and a network node opens the editor on it', async ({ page }) => {
    await createVm(page, 'wf-topo-net');
    const index = await indexOf(page, 'wf-topo-net');
    await api(page, 'POST', `/api/vms/${index}`, 'vnet=VMnet8');
    await page.reload();
    await openTopology(page);
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    let computes = 0;
    await page.route('**/api/networks', async (route) => {
        computes += 1;
        await route.continue();
    });
    await page.locator('#topodlg [data-action="openTopology"]', { hasText: 'Refresh' }).click();
    await expect.poll(() => computes).toBeGreaterThan(0);
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    /* Clicking a network node closes the topology and opens the editor with that network selected. */
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
    await openTopology(page);
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    const node = page.locator('.topo-node.vm[role="button"]').filter({ hasText: 'wf-topo-key' });
    await node.focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('#topodlg')).toHaveCount(0);
    await expect(page.locator('#vmname')).toHaveText('wf-topo-key');
});

test('per-NIC vnet binding round-trips and appears in the topology', async ({ page }) => {
    await createVm(page, 'wf-nicvnet');
    const index = await indexOf(page, 'wf-nicvnet');
    await api(page, 'POST', `/api/vms/${index}`, 'nic2=user&nic2_vnet=VMnet1&nic5_vnet=VMnet8');
    await expect.poll(() => vmField(page, 'wf-nicvnet', 'nic2_vnet')).toBe('VMnet1');
    expect(await vmField(page, 'wf-nicvnet', 'nic5_vnet')).toBe('VMnet8');
    await page.reload();
    await openTopology(page);
    await page.waitForSelector(TOPOLOGY_NODE, { timeout: TOPOLOGY_TIMEOUT_MS });
    await expect(page.locator('.topo-node.vnet').filter({ hasText: 'VMnet1' })).toHaveCount(1);
    await expect(page.locator('.topo-node.vnet').filter({ hasText: 'VMnet8' })).toHaveCount(1);
});

test('vnet editor lists networks as clickable typed cards; selecting one fills the form', async ({ page }) => {
    await openVnetEditor(page);
    const cards = page.locator('.vnet-item');
    await expect.poll(() => cards.count()).toBeGreaterThanOrEqual(1);
    /* Each card carries a type badge (NAT/Bridged/Host-Only). */
    await expect(page.locator('.vnet-type-badge').first()).toBeVisible();
    /* Clicking a card selects it (active highlight) and fills the form name. */
    await cards.first().click();
    await expect(cards.first()).toHaveClass(/active/);
    await expect(page.locator('#vn_name')).not.toHaveValue('');
    await page.locator('#vnetdlg [data-action="closeDlg"]').click();
    await expect(page.locator('#vnetdlg')).toHaveCount(0);
});

test('vnet Save All validates and persists the selected form without Save Selected', async ({ page }) => {
    await withNetworksRestored(page, async () => {
        const original = await api(page, 'GET', '/api/networks');
        await openVnetEditor(page);
        await page.locator('[data-action="vnetAdd"]').click();
        await page.locator('#vn_name').fill('wf-save-net');
        await page.locator('#vn_subnet').fill('invalid');
        await page.locator('[data-action="vnetSaveAll"]').click();
        await expect(page.locator('#err_vn_subnet')).toHaveText('Invalid subnet format.');
        await expect(page.locator('#vn_subnet')).toBeFocused();
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await expect(page.locator('#vn_name')).toHaveValue('wf-save-net');
        const unchanged = await api(page, 'GET', '/api/networks');
        expect(unchanged.text).toBe(original.text);
        await page.locator('#vn_subnet').fill('192.168.100.0');
        await page.locator('[data-action="vnetSaveAll"]').click();
        await expect(page.locator('#vnetdlg')).toBeHidden();
        await openVnetEditor(page);
        await page.locator('.vnet-item', { hasText: 'wf-save-net' }).click();
        await expect(page.locator('#vn_name')).toHaveValue('wf-save-net');
        await expect(page.locator('#vn_subnet')).toHaveValue('192.168.100.0');
    });
});

test('vnet Save Selected persists without closing and unsaved edits are confirmed on close', async ({ page }) => {
    await withNetworksRestored(page, async () => {
        await openVnetEditor(page);
        await page.locator('[data-action="vnetAdd"]').click();
        await page.locator('#vn_name').fill('wf-save-sel');
        await page.locator('[data-action="vnetSaveCurrent"]').click();
        /* Saved in place: the editor stays open and the network is on disk. */
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await expect(page.locator('#statusmsg')).toContainText('wf-save-sel');
        expect(await storedNetworkNames(page)).toContain('wf-save-sel');
        /* Editing again and closing asks before the edit is thrown away. */
        await page.locator('#vn_gw').fill('192.168.100.2');
        await page.locator('#vnetdlg [data-action="closeDlg"]').click();
        await expect(page.locator('#confirmdlg')).toBeVisible();
        await page.locator('#confirmCancelBtn').click();
        await expect(page.locator('#vnetdlg')).toBeVisible();
        await expect(page.locator('#vn_gw')).toHaveValue('192.168.100.2');
    });
});

test('vnet editor rejects names over 15 characters inline and saves nothing', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks');
    let posts = 0;
    await page.route('**/api/networks', async (route) => {
        if (route.request().method() === 'POST') {
            posts += 1;
        }
        await route.continue();
    });
    await openVnetEditor(page);
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
    const unchanged = await api(page, 'GET', '/api/networks');
    expect(unchanged.text).toBe(original.text);
    /* Escape asks before discarding the edits, and Discard closes it. */
    await page.keyboard.press('Escape');
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#vnetdlg')).toHaveCount(0);
});

/** Fills a new bridged network with a value in every field. */
const fillAllNetworkFields = async (page: Page): Promise<void> => {
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
};

test('vnet editor keeps edits across selection, moves with arrow keys and persists every field', async ({ page }) => {
    await withNetworksRestored(page, async () => {
        await openVnetEditor(page);
        await fillAllNetworkFields(page);
        /* Selecting another network and coming back keeps the unsaved edits. */
        const cards = page.locator('.vnet-item');
        await cards.first().click();
        await expect(cards.first()).toHaveClass(/active/);
        await expect(page.locator('#vn_name')).not.toHaveValue('wf-fields');
        await cards.last().click();
        await expect(page.locator('#vn_name')).toHaveValue('wf-fields');
        await expect(page.locator('#vn_pf')).toHaveValue('8080:192.168.100.10:80');
        /* Arrow keys move the selection and focus (roving tab stop). */
        await cards.last().focus();
        await page.keyboard.press('ArrowUp');
        const beforeLast = cards.nth((await cards.count()) - 2);
        await expect(beforeLast).toBeFocused();
        await expect(beforeLast).toHaveClass(/active/);
        await page.keyboard.press('End');
        await expect(cards.last()).toHaveClass(/active/);
        await page.keyboard.press('Home');
        await expect(cards.first()).toHaveClass(/active/);
        await page.locator('.vnet-item', { hasText: 'wf-fields' }).click();
        await page.locator('[data-action="vnetSaveAll"]').click();
        await expect(page.locator('#vnetdlg')).toHaveCount(0);
        const stored = await api(page, 'GET', '/api/networks');
        expect(parseJson(stored.text)).toMatchObject({
            networks: expect.arrayContaining([
                expect.objectContaining({
                    name: 'wf-fields',
                    type: 'bridged',
                    dhcp: true,
                    dhcp_start: '192.168.100.10',
                    dhcp_end: '192.168.100.20',
                    host_iface: 'eth9',
                    gateway: '192.168.100.1',
                    port_forwards: '8080:192.168.100.10:80',
                }),
            ]),
        });
    });
});

test('vnet Remove and Defaults edit the set and close without saving discards them', async ({ page }) => {
    const original = await api(page, 'GET', '/api/networks');
    await openVnetEditor(page);
    await page.locator('[data-action="vnetDefaults"]').click();
    await expect(page.locator('.vnet-item')).toHaveText([/VMnet0/, /VMnet1/, /VMnet8/]);
    await page.locator('[data-action="vnetRemove"]').click();
    await expect(page.locator('.vnet-item')).toHaveCount(2);
    await page.locator('#vnetdlg [data-action="closeDlg"]').click();
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#vnetdlg')).toHaveCount(0);
    const unchanged = await api(page, 'GET', '/api/networks');
    expect(unchanged.text).toBe(original.text);
});

test('catalog dialog lists templates and Create makes a VM and closes', async ({ page }) => {
    await page.locator('[data-action="openCatalog"]:visible').first().click();
    await expect(page.locator('#catalogdlg')).toBeVisible();
    const cards = page.locator('#catalogList .cat-card');
    await expect.poll(() => cards.count()).toBeGreaterThanOrEqual(CATALOG_MIN_ENTRIES);
    const debian = cards.filter({ hasText: 'Debian 12' });
    await expect(debian).toContainText('2 vCPU');
    await expect(debian).toContainText('2 GiB RAM');
    await expect(debian).toContainText('20 GB disk');
    await debian.getByRole('button', { name: 'Create VM from Debian 12' }).click();
    await expect(page.locator('#catalogdlg')).toHaveCount(0);
    await expect.poll(() => indexOf(page, 'Debian 12')).toBeGreaterThanOrEqual(0);
    await expect(page.locator('#vmlist .vm-item', { hasText: 'Debian 12' })).toBeVisible();
    await removeVms(page, 'Debian 12');
});

test('catalog dialog shows loading, failure and empty states', async ({ page }) => {
    const catalog = createLatch();
    await page.route('**/api/catalog', async (route) => {
        await catalog.opened;
        await route.abort();
    });
    await chooseTool(page, 'openCatalog');
    await expect(page.locator('#catalogList')).toHaveText('Loading catalog…');
    catalog.open();
    await expect(page.locator('#catalogList')).toHaveText('Failed to load catalog.');
    await page.keyboard.press('Escape');
    await expect(page.locator('#catalogdlg')).toHaveCount(0);
    await page.unroute('**/api/catalog');
    await page.route('**/api/catalog', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
    await chooseTool(page, 'openCatalog');
    await expect(page.locator('#catalogList')).toHaveText('No templates available.');
});

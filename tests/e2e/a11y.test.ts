/** WCAG 2.2 AA gate: axe must report zero violations on the main views in both themes. */
import { AxeBuilder } from '@axe-core/playwright';
import { expect, test, type Locator, type Page } from '@playwright/test';
import { canvasWidth, chooseFromMenu, chooseTool, openTopology, overrideVm, pressGlobalKey, refreshList, selectVm, setTheme, type MenuId } from './app-ui';
import { api, indexOf, removeVms, vmField } from './daemon-api';

const WCAG_TAGS = ['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'];
/** View transitions fade in; axe reads mid-fade colors otherwise. */
const SETTLE_MS = 600;
const THEMES = ['dark', 'light'] as const;
const POWER_ON_TIMEOUT_MS = 25_000;
const CANVAS_TIMEOUT_MS = 20_000;
const SERIAL_TIMEOUT_MS = 10_000;
const LIVE_TEST_TIMEOUT_MS = 150_000;

const scan = async (page: Page, step: string): Promise<void> => {
    const { violations } = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze();
    expect(violations.map((found) => `${step}: ${found.id} ${JSON.stringify(found.nodes[0]?.target)}`)).toEqual([]);
};

/** Starts on `theme`, creates the VM `name` through the API and waits for its row. */
const openWithVm = async (page: Page, theme: (typeof THEMES)[number], name: string): Promise<Locator> => {
    await page.addInitScript((chosen) => localStorage.setItem('hangar-theme', chosen), theme);
    await page.goto('/', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#vmlist');
    const created = await api(page, 'POST', '/api/vms', `name=${name}&mem=1024&cpu=1&disk=1&guest_os=0`);
    expect(created.status).toBeLessThan(400);
    await page.reload({ waitUntil: 'domcontentloaded' });
    const row = page.locator('#vmlist .vm-item', { hasText: name });
    await row.waitFor();
    return row;
};

/** Scans every settings section, with the validation states showing. */
const scanSettingsSections = async (page: Page): Promise<void> => {
    await page.locator('#e_mem').fill('64');
    await page.locator('[data-settings-category="display_and_video"]').click();
    await page.locator('#e_embed_display').selectOption('1');
    await page.locator('#e_display').selectOption('0');
    const sections = await page.locator('[data-settings-category]').evaluateAll<Array<string>, HTMLElement>((els) => els.flatMap((el) => el.dataset.settingsCategory ?? []));
    for (const section of sections) {
        await page.locator(`[data-settings-category="${section}"]`).click();
        await page.waitForTimeout(SETTLE_MS);
        await scan(page, `settings/${section}`);
    }
};

/**
 * Real toasts of each kind: an error (blank rename), an Undo toast (delete) and a warning (bulk power with
 * nothing checked). The toast stack covers the toolbar menus, so the menu-driven steps come first.
 */
const stackToasts = async (page: Page, row: Locator): Promise<void> => {
    await row.click();
    await chooseTool(page, 'renameGuest');
    await page.locator('#promptInput').fill(' ');
    await page.locator('#promptOkBtn').click();
    await pressGlobalKey(page, 'Delete');
    await page.locator('#confirmOkBtn').click();
    await page.locator('#selectToggle').click();
    await page.locator('[data-action="bulkPower"][data-on="1"]').click();
    await expect(page.locator('#toast-container .toast')).toHaveCount(3);
};

type Stage = {
    readonly name: string;
    readonly enter: (page: Page, row: Locator) => Promise<void>;
    readonly leave?: (page: Page) => Promise<void>;
};

const STAGES: ReadonlyArray<Stage> = [
    { name: 'dashboard', enter: () => Promise.resolve() },
    { name: 'summary', enter: (_page, row) => row.click() },
    { name: 'settings', enter: (page) => page.locator('#tab-btn-settings').click() },
    {
        name: 'palette',
        enter: async (page) => {
            await page.keyboard.press('Control+k');
            await page.locator('#palette').waitFor();
        },
        leave: async (page) => {
            await page.keyboard.press('Escape');
            await expect(page.locator('#palette')).toHaveCount(0);
        },
    },
    {
        name: 'context menu',
        enter: (_page, row) => row.click({ button: 'right' }),
        leave: async (page) => {
            await page.keyboard.press('Escape');
            await expect(page.locator('.ctx-menu')).toHaveCount(0);
        },
    },
    { name: 'toasts', enter: stackToasts },
];

for (const theme of THEMES) {
    test(`axe finds no WCAG AA violations (${theme})`, async ({ page }) => {
        const row = await openWithVm(page, theme, 'a11y-vm');
        try {
            for (const stage of STAGES) {
                await stage.enter(page, row);
                await page.waitForTimeout(SETTLE_MS);
                await scan(page, stage.name);
                if (stage.name === 'settings') {
                    await scanSettingsSections(page);
                }
                await stage.leave?.(page);
            }
        } finally {
            await removeVms(page, 'a11y-vm');
        }
    });
}

type DialogStep = {
    readonly id: string;
    readonly open: (page: Page) => Promise<void>;
    /** Puts the dialog's error state on screen. */
    readonly prepare: (page: Page) => Promise<void>;
};

const openTool = (action: string) => (page: Page) => chooseTool(page, action);
const clickSubmit = (id: string) => (page: Page) => page.locator(`#${id} button[type="submit"]`).click();
const nothingToPrepare = (): Promise<void> => Promise.resolve();

const DIALOGS: ReadonlyArray<DialogStep> = [
    { id: 'newdlg', open: (page) => page.locator('.new-vm-btn').click(), prepare: (page) => page.locator('#n_mem').fill('64') },
    { id: 'importdlg', open: openTool('importGuest'), prepare: clickSubmit('importdlg') },
    { id: 'clonedlg', open: openTool('cloneGuest'), prepare: nothingToPrepare },
    { id: 'snapdlg', open: (page) => chooseFromMenu(page, 'snapshotMenu' satisfies MenuId, 'openSnapshots'), prepare: clickSubmit('snapdlg') },
    {
        id: 'vnetdlg',
        open: openTool('openVnets'),
        prepare: async (page) => {
            await page.locator('[data-action="vnetAdd"]').click();
            await page.locator('#vn_subnet').fill('bad');
            await page.locator('[data-action="vnetSaveAll"]').click();
            await page.locator('#err_vn_subnet').waitFor();
        },
    },
    { id: 'topodlg', open: openTopology, prepare: (page) => page.waitForSelector('.topo-svg .topo-node').then(nothingToPrepare) },
    { id: 'catalogdlg', open: openTool('openCatalog'), prepare: (page) => page.waitForSelector('.cat-card').then(nothingToPrepare) },
];

/** The migration dialog needs a running guest; the list reports one while `scanned` runs. */
const withRunningGuest = async (page: Page, name: string, scanned: () => Promise<void>): Promise<void> => {
    const restore = await overrideVm(page, name, () => ({ status: 'running', embed_display: false }));
    try {
        await refreshList(page);
        await selectVm(page, name);
        await scanned();
    } finally {
        await restore();
        await refreshList(page);
    }
};

const scanDialog = async (page: Page, step: DialogStep): Promise<void> => {
    await step.open(page);
    await page.locator(`#${step.id}`).waitFor();
    await step.prepare(page);
    await page.waitForTimeout(SETTLE_MS);
    await scan(page, step.id);
    await page.keyboard.press('Escape');
    if (step.id === 'vnetdlg') {
        await page.locator('#confirmOkBtn').click();
    }
    await expect(page.locator(`#${step.id}`)).toHaveCount(0);
};

for (const theme of THEMES) {
    test(`axe finds no violations in the VM and network dialogs (${theme})`, async ({ page }) => {
        const name = 'a11y-dlg-vm';
        const row = await openWithVm(page, theme, name);
        await row.click();
        try {
            for (const step of DIALOGS) {
                await scanDialog(page, step);
            }
            await withRunningGuest(page, name, async () => {
                await scanDialog(page, { id: 'migratedlg', open: openTool('migrateGuest'), prepare: clickSubmit('migratedlg') });
            });
        } finally {
            await removeVms(page, name);
        }
    });
}

/** Creates and boots a guest with VNC and a serial port, then waits until the daemon calls it running. */
const bootLiveGuest = async (page: Page, name: string): Promise<void> => {
    const created = await api(page, 'POST', '/api/vms', `name=${name}&mem=1024&cpu=1&disk=1&display=vnc&embed_display=true&enable_serial=true&firmware=bios`);
    expect(created.status).toBeLessThan(400);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.locator('#vmlist .vm-item', { hasText: name }).waitFor();
    await api(page, 'POST', `/api/vms/${await indexOf(page, name)}/power`, '');
    await expect.poll(() => vmField(page, name, 'status'), { timeout: POWER_ON_TIMEOUT_MS }).toBe('running');
};

const scanLiveConsole = async (page: Page, name: string, theme: (typeof THEMES)[number]): Promise<void> => {
    await setTheme(page, theme);
    await page.locator('#vmlist .vm-item', { hasText: name }).click();
    await expect.poll(() => canvasWidth(page, '#display canvas'), { timeout: CANVAS_TIMEOUT_MS }).toBeGreaterThan(0);
    await expect(page.locator('#serialpanel')).toBeVisible({ timeout: SERIAL_TIMEOUT_MS });
    await page.waitForTimeout(SETTLE_MS);
    await scan(page, `console (${theme})`);
    await page.locator('#display [data-action="enterDisplayOnly"]').click();
    await expect(page.locator('body')).toHaveClass(/displayonly/);
    await page.waitForTimeout(SETTLE_MS);
    await scan(page, `display-only (${theme})`);
    await page.keyboard.press('Escape');
    await expect(page.locator('body')).not.toHaveClass(/displayonly/);
};

/** The console tab needs a running guest: scan it with the display and serial panels showing, then display-only mode. */
test('axe finds no violations on the live console (dark and light)', async ({ page }) => {
    test.setTimeout(LIVE_TEST_TIMEOUT_MS);
    const name = 'a11y-live';
    await page.goto('/', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#vmlist');
    try {
        await bootLiveGuest(page, name);
        for (const theme of THEMES) {
            await scanLiveConsole(page, name, theme);
        }
    } finally {
        await api(page, 'POST', `/api/vms/${await indexOf(page, name)}/power`, '');
        await expect.poll(() => vmField(page, name, 'status'), { timeout: CANVAS_TIMEOUT_MS }).not.toBe('running');
        await removeVms(page, name);
    }
});

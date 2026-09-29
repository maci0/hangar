/** Paths through the real UI that the specs share: the toolbar menus, refresh, themes and the network dialogs. */
import { expect, type Page } from '@playwright/test';
import { parseJsonList } from './daemon-api';

export type MenuId = 'powerMenu' | 'snapshotMenu' | 'devicesMenu' | 'toolsMenu' | 'dangerMenu';

const THEME_KEY = 'hangar-theme';

/** Presses a shortcut key with focus outside any control, the way a user does after clicking the page background. */
export const pressGlobalKey = async (page: Page, key: string): Promise<void> => {
    await page.evaluate(() => {
        if (document.activeElement instanceof HTMLElement) {
            document.activeElement.blur();
        }
    });
    await page.keyboard.press(key);
};

/** Reloads the VM list the way F5 does and waits for the daemon's answer. */
export const refreshList = async (page: Page): Promise<void> => {
    const listed = page.waitForResponse((response) => response.url().endsWith('/api/vms') && response.request().method() === 'GET');
    await pressGlobalKey(page, 'F5');
    await listed;
};

/** Picks a toolbar menu entry by its `data-action` (the More popover copy of a trigger stays hidden at desktop width). */
export const chooseFromMenu = async (page: Page, menu: MenuId, action: string): Promise<void> => {
    await page.locator(`[data-menu="${menu}"]:visible`).click();
    await page.locator(`#${menu} [data-action="${action}"]`).click();
};

export const chooseTool = (page: Page, action: string): Promise<void> => chooseFromMenu(page, 'toolsMenu', action);

/** Selects the first sidebar row whose text contains `name`. */
export const selectVm = async (page: Page, name: string): Promise<void> => {
    await page.locator('.vm-item', { hasText: name }).first().click();
};

/** Stores the theme and reloads, so the next page load paints it before any dialog is open. */
export const setTheme = async (page: Page, theme: 'system' | 'light' | 'dark'): Promise<void> => {
    await page.evaluate((stored) => localStorage.setItem(stored.key, stored.theme), { key: THEME_KEY, theme });
    await page.reload();
    await expect(page.locator('#vmlist')).toBeVisible();
};

export const openVnetEditor = async (page: Page): Promise<void> => {
    await chooseTool(page, 'openVnets');
    await expect(page.locator('#vnetdlg')).toBeVisible();
};

/** Opens the topology dialog from the network editor's Topology button. */
export const openTopology = async (page: Page): Promise<void> => {
    await openVnetEditor(page);
    await page.locator('#vnetdlg [data-action="openTopology"]').click();
    await expect(page.locator('#topodlg')).toBeVisible();
};

export const TOPOLOGY_NODE = '.topo-svg .topo-node';

const INVENTORY_URL = '**/api/vms';

/**
 * Makes the daemon's VM list report `overrides()` merged into the VM called `name`, so the UI sees a state
 * the daemon does not have (a running guest, an uptime). `overrides` is read on every list request.
 * Returns the function that removes the mock.
 */
export const overrideVm = async (page: Page, name: string, overrides: () => Readonly<Record<string, unknown>>): Promise<() => Promise<void>> => {
    await page.route(INVENTORY_URL, async (route) => {
        const response = await route.fetch();
        const entries = parseJsonList(await response.text());
        const patched = entries.map((entry) => (typeof entry === 'object' && entry !== null && 'name' in entry && entry.name === name ? { ...entry, ...overrides() } : entry));
        await route.fulfill({ response, json: patched });
    });
    return () => page.unroute(INVENTORY_URL);
};

/** Pixel width of the first canvas matching `selector` in the page, or 0 while there is none. */
export const canvasWidth = (page: Page, selector: string): Promise<number> =>
    page.evaluate((query) => document.querySelector<HTMLCanvasElement>(query)?.width ?? 0, selector);

/** Opens the app and waits for the sidebar list. */
export const loadApp = async (page: Page): Promise<void> => {
    await page.goto('/');
    await expect(page.locator('#vmlist')).toBeVisible();
};

/** A promise that stays pending until `open()` runs, for holding a mocked response back. */
export const createLatch = (): { readonly opened: Promise<undefined>; readonly open: () => void } => {
    const { promise, resolve } = Promise.withResolvers<undefined>();
    return { opened: promise, open: () => resolve(undefined) };
};

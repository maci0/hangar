/** App shell chrome: sidebar head, VM header and tabs, status bar, connection banner, toasts, context menu, palette and toolbar menus. */
import { expect, test, type Page } from '@playwright/test';
import { chooseTool, createLatch, loadApp, pressGlobalKey, refreshList, selectVm } from './app-ui';
import { createVm, indexOf, listVms, removeVms } from './daemon-api';

const TOAST_CAP = 5;
const THEME_TOAST_EXPIRY_MS = 6000;
const SHELL_VM_PREFIX = 'wf-shell-';

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

/** These tests create wf-shell-* VMs; remove them so the daemon's VM limit is not reached by later tests. */
test.afterEach(async ({ page }) => {
    const vms = await listVms(page);
    const leftovers = vms.filter((vm) => vm.name.startsWith(SHELL_VM_PREFIX)).map((vm) => vm.name);
    await removeVms(page, ...leftovers);
});

test('VM header follows the selection and the tab bar roves with the arrow keys', async ({ page }) => {
    await createVm(page, 'wf-shell-tabs');
    await page.reload();
    await expect(page.locator('#tabBar')).toHaveCount(0);
    await expect(page.locator('#vmemblem')).toHaveCount(0);
    await selectVm(page, 'wf-shell-tabs');
    await expect(page.locator('#vmname')).toHaveText('wf-shell-tabs');
    await expect(page.locator('#vmemblem')).toBeVisible();
    await expect(page.getByRole('tablist', { name: 'VM views' })).toBeVisible();
    /* A stopped VM has no console: that tab is disabled and skipped by the keys. */
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
    /* The arrow wraps past the disabled console tab. */
    await page.keyboard.press('ArrowRight');
    await expect(summary).toBeFocused();
    await expect(page.locator('#tabSummary')).toBeVisible();
    await page.keyboard.press('End');
    await expect(settings).toBeFocused();
    await page.keyboard.press('Home');
    await expect(summary).toBeFocused();
    await expect(summary).toHaveAttribute('aria-selected', 'true');
    /* Home in the toolbar returns to the overview and hides the VM-only parts. */
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
    /* The empty list offers its own clear button. */
    await page.getByRole('button', { name: 'Clear search' }).last().click();
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
    /* The Done button leaves select mode. */
    await page.locator('#bulkBar [data-action="toggleSelectMode"]').click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
    await expect(page.locator('#bulkBar')).toHaveCount(0);
});

test('status bar shows the message, pulses while working and announces only intentional text', async ({ page }) => {
    const name = 'wf-shell-status';
    await createVm(page, name);
    await page.reload();
    await expect(page.locator('#statusannounce')).toHaveAttribute('role', 'status');
    /* The event stream connected. */
    await expect(page.locator('#livebadge')).toBeVisible();
    await selectVm(page, name);
    const renameRequest = createLatch();
    await page.route('**/api/vms/*/rename', async (route) => {
        await renameRequest.opened;
        await route.continue();
    });
    await chooseTool(page, 'renameGuest');
    await page.locator('#promptInput').fill('wf-shell-status-done');
    await page.locator('#promptOkBtn').click();
    await expect(page.locator('#statusmsg')).toHaveText(/^Working/);
    await expect(page.locator('#statusmsg')).toHaveClass(/loading/);
    await expect(page.locator('#statusannounce')).toHaveText('Working...');
    renameRequest.open();
    await expect(page.locator('#statusmsg')).toHaveText('VM renamed.');
    await expect(page.locator('#statusmsg')).not.toHaveClass(/loading/);
    await expect(page.locator('#statusannounce')).toHaveText('VM renamed.');
    /* A passive redraw (list refresh) rewrites the bar but leaves the announcer alone. */
    await refreshList(page);
    await expect(page.locator('#statusmsg')).toContainText('virtual machine');
    await expect(page.locator('#statusannounce')).toHaveText('VM renamed.');
});

test('connection banner alerts while the server is down and Dismiss hides it', async ({ page }) => {
    const banner = page.locator('#connbanner');
    await expect(banner).toHaveAttribute('role', 'alert');
    await expect(banner).toBeHidden();
    await page.route('**/api/vms', (route) => route.fulfill({ status: 500, body: 'daemon down' }));
    await pressGlobalKey(page, 'F5');
    await expect(banner).toBeVisible();
    await expect(banner).toContainText('Connection lost');
    await banner.getByRole('button', { name: 'Dismiss' }).click();
    await expect(banner).toBeHidden();
    await page.unroute('**/api/vms');
});

/** An error toast (blank rename), an Undo toast (delete) and a warning toast (bulk power with nothing checked). */
const raiseThreeToasts = async (page: Page, name: string): Promise<void> => {
    await selectVm(page, name);
    await chooseTool(page, 'renameGuest');
    await page.locator('#promptInput').fill(' ');
    await page.locator('#promptOkBtn').click();
    await pressGlobalKey(page, 'Delete');
    await page.locator('#confirmOkBtn').click();
    await page.locator('#selectToggle').click();
    await page.locator('[data-action="bulkPower"][data-on="1"]').click();
};

test('toasts live in one log region, cap at five, expire, and Undo runs its action', async ({ page }) => {
    const name = 'wf-shell-toasts';
    await createVm(page, name);
    await page.reload();
    const region = page.locator('#toast-container');
    await expect(region).toHaveAttribute('role', 'log');
    await expect(region).toHaveAttribute('aria-live', 'polite');
    await raiseThreeToasts(page, name);
    await expect(region.locator('.toast')).toHaveCount(3);
    await expect(region.locator('.toast', { hasText: 'Name cannot be empty' })).toHaveAttribute('role', 'alert');
    await expect(region.locator('.toast', { hasText: 'No VMs selected' })).toHaveAttribute('role', 'alert');
    const undo = region.locator('.toast', { hasText: `Deleted "${name}"` });
    await expect(undo).toHaveAttribute('role', 'status');
    await expect(region.locator('.toast svg use').first()).toHaveAttribute('href', /icons\.svg#i-/);
    /* Undo restores the deleted VM and dismisses its toast. */
    expect(await indexOf(page, name)).toBe(-1);
    await undo.getByRole('button', { name: 'Undo' }).click();
    await expect(undo).toHaveCount(0);
    await expect.poll(() => indexOf(page, name)).toBeGreaterThanOrEqual(0);
    /* Six theme changes make six toasts; the stack keeps the newest five. */
    for (let change = 0; change < TOAST_CAP + 1; change += 1) {
        await page.locator('.theme-toggle-btn').click();
    }
    await expect(region.locator('.toast')).toHaveCount(TOAST_CAP);
    await expect(region.locator('.toast', { hasText: 'Name cannot be empty' })).toHaveCount(0);
    await expect(region.locator('.toast')).toHaveCount(0, { timeout: THEME_TOAST_EXPIRY_MS });
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
    /* Power On, the first enabled item. */
    await expect(items.first()).toBeFocused();
    await expect(items.first()).toHaveText('Power On');
    await expect(menu.getByRole('menuitem', { name: 'Shut Down Guest' })).toBeDisabled();
    await expect(menu.getByRole('menuitem', { name: 'Shut Down Guest' })).toHaveAttribute('title', /running/);
    await page.keyboard.press('ArrowDown');
    /* The arrow skips disabled items. */
    await expect(menu.getByRole('menuitem', { name: 'Take Snapshot…' })).toBeFocused();
    await page.keyboard.press('End');
    await expect(menu.getByRole('menuitem', { name: 'Delete' })).toBeFocused();
    await page.keyboard.press('Home');
    await expect(items.first()).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(menu).toHaveCount(0);
    await expect(row).toBeFocused();
    /* Escape only closed the menu. */
    await expect(page.locator('.vm-item.active')).toHaveCount(0);
    await row.click({ button: 'right' });
    await expect(menu).toBeVisible();
    await page.mouse.click(700, 500);
    await expect(menu).toHaveCount(0);
});

test('command palette (Ctrl+K) opens, filters, runs a command, and closes', async ({ page }) => {
    await createVm(page, 'wf-shell-pal');
    await page.reload();
    await page.keyboard.press('Control+k');
    await expect(page.locator('#palette')).toBeVisible();
    expect(await page.locator('#paletteList li[data-pidx]').count()).toBeGreaterThan(3);
    await page.fill('#paletteInput', 'catalog');
    await expect(page.locator('#paletteList')).toContainText('VM Catalog');
    /* Enter runs the top match, which opens the catalog dialog. */
    await page.keyboard.press('Enter');
    await expect(page.locator('#catalogdlg')).toBeVisible();
    await expect(page.locator('#palette')).toBeHidden();
    await page.keyboard.press('Escape');
    /* The dialog stays modal (page inert) through its exit animation; wait it out before reopening the palette. */
    await expect(page.locator('#catalogdlg')).toHaveCount(0);
    await page.keyboard.press('Control+k');
    await expect(page.locator('#palette')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#palette')).toBeHidden();
});

test('command palette navigates with the arrow keys, filters, and jumps to a VM', async ({ page }) => {
    await createVm(page, 'wf-shell-pal-jump');
    await page.reload();
    /* The palette lists the VMs loaded when it opens, so wait for the list first. */
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
    /* The second ArrowUp wraps to the last option. */
    await page.keyboard.press('ArrowUp');
    const count = await page.locator('#paletteList li[data-pidx]').count();
    await expect(input).toHaveAttribute('aria-activedescendant', `paletteOpt${count - 1}`);
    await page.fill('#paletteInput', 'zzzz-no-such-command');
    await expect(page.locator('#paletteList')).toContainText('No matches');
    await expect(input).not.toHaveAttribute('aria-activedescendant', /.+/);
    /* With nothing to run, Enter leaves the palette open. */
    await page.keyboard.press('Enter');
    await expect(page.locator('#palette')).toBeVisible();
    await page.fill('#paletteInput', 'go to wf-shell-pal-jump');
    await expect(page.locator('#paletteList li[data-pidx]')).toHaveCount(1);
    await page.keyboard.press('Enter');
    await expect(page.locator('#palette')).toHaveCount(0);
    await expect(page.locator('#vmname')).toHaveText('wf-shell-pal-jump');
    /* A backdrop click closes without running anything and gives focus back. */
    await page.locator('.vm-item.active').focus();
    await page.keyboard.press('Control+k');
    await expect(page.locator('#palette')).toBeVisible();
    await page.mouse.click(4, 4);
    await expect(page.locator('#palette')).toHaveCount(0);
    await expect(page.locator('.vm-item.active')).toBeFocused();
});

test('toolbar dropdown is keyboard-operable: opens, focuses an item, Escape returns focus', async ({ page }) => {
    await createVm(page, 'wf-shell-kbd');
    /* Selecting the VM enables the toolbar action menus. */
    await selectVm(page, 'wf-shell-kbd');
    const trigger = page.locator('[data-menu="toolsMenu"]');
    await trigger.focus();
    /* Enter activates the trigger button. */
    await page.keyboard.press('Enter');
    await expect(page.locator('#toolsMenu')).toHaveClass(/open/);
    await expect(trigger).toHaveAttribute('aria-expanded', 'true');
    /* Focus moved into the menu, onto an enabled item. */
    expect(await page.evaluate(() => document.activeElement?.closest('#toolsMenu') !== null)).toBe(true);
    const before = await page.evaluate(() => document.activeElement?.textContent);
    await page.keyboard.press('ArrowDown');
    const after = await page.evaluate(() => document.activeElement?.textContent);
    expect(after).toBeDefined();
    expect(after).not.toBe(before);
    expect(await page.evaluate(() => document.activeElement?.closest('#toolsMenu') !== null)).toBe(true);
    /* Escape closes the menu and returns focus to the trigger button. */
    await page.keyboard.press('Escape');
    await expect(page.locator('#toolsMenu')).not.toHaveClass(/open/);
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
    await expect(trigger).toBeFocused();
});

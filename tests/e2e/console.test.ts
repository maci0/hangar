/** The Console tab with real guests (VNC, SPICE, serial, the H.264 overlay), display-only mode and the migration bar. */
import { expect, test, type Page } from '@playwright/test';
import { canvasWidth, chooseTool, loadApp, overrideVm, selectVm } from './app-ui';
import { api, createVm, indexOf, removeVms, vmField } from './daemon-api';

const POWER_ON_TIMEOUT_MS = 25_000;
const CANVAS_TIMEOUT_MS = 20_000;
const SERIAL_TIMEOUT_MS = 10_000;
const VIDEO_TIMEOUT_MS = 25_000;
const CONSOLE_TEST_TIMEOUT_MS = 120_000;
const MIGRATION_CLEAR_TIMEOUT_MS = 8000;
const SERIAL_STEP_PX = 16;
const SERIAL_SHIFT_STEP_PX = 48;
const SERIAL_DEFAULT_PX = 170;
const SERIAL_MAX_PX = 600;
const SERIAL_MIN_PX = 60;

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

/** Creates a guest from `settings`, powers it on and waits until the daemon calls it running. */
const bootGuest = async (page: Page, name: string, settings: string): Promise<void> => {
    await api(page, 'POST', '/api/vms', `name=${name}&mem=1024&cpu=1&disk=1&${settings}&firmware=bios`);
    const index = await indexOf(page, name);
    expect(index).toBeGreaterThanOrEqual(0);
    await api(page, 'POST', `/api/vms/${index}/power`, '');
    await expect.poll(() => vmField(page, name, 'status'), { timeout: POWER_ON_TIMEOUT_MS }).toBe('running');
};

/** Powers the guest off if it is still on. */
const powerOff = async (page: Page, name: string): Promise<void> => {
    await api(page, 'POST', `/api/vms/${await indexOf(page, name)}/power`, '');
};

test('live console: SPICE display connects and paints in the Console tab', async ({ page }) => {
    await bootGuest(page, 'wf-spice', 'guest_os=2&display=2&embed_display=true');
    await page.reload();
    await selectVm(page, 'wf-spice');
    await expect.poll(() => canvasWidth(page, '#tabConsole #display canvas'), { timeout: CANVAS_TIMEOUT_MS }).toBeGreaterThan(0);
    await expect(page.locator('#displayBadge')).toContainText('SPICE');
    await powerOff(page, 'wf-spice');
});

/** True once the H.264 overlay canvas holds a non-black pixel in its top-left corner. */
const overlayHasPixels = (page: Page): Promise<boolean> =>
    page.evaluate(() => {
        const layer = document.querySelector<HTMLCanvasElement>('#display .video-layer');
        const context = layer?.getContext('2d');
        if (!layer || !context) {
            return false;
        }
        const corner = context.getImageData(0, 0, Math.min(64, layer.width), Math.min(64, layer.height)).data;
        return corner.some((channel, offset) => offset % 4 !== 3 && channel !== 0);
    });

test('video stream: H.264 over /ws/video paints the WebCodecs overlay', async ({ page, context }) => {
    test.skip(Bun.which('ffmpeg') === null, 'ffmpeg not installed on this host');
    const name = 'wf-video';
    await bootGuest(page, name, 'guest_os=2&display=vnc&embed_display=true&video_stream=1&video_bitrate=2500');
    expect(await vmField(page, name, 'video_bitrate_kbps'), 'bitrate round-trips').toBe(2500);
    const videoSockets: Array<{ readonly isClosed: () => boolean }> = [];
    page.on('websocket', (socket) => {
        if (socket.url().includes('/ws/video/')) {
            videoSockets.push(socket);
        }
    });
    await page.reload();
    await selectVm(page, name);
    /* The overlay canvas must exist, size itself from the config frame, and carry real decoded pixels. */
    await expect.poll(() => canvasWidth(page, '#display .video-layer'), { timeout: VIDEO_TIMEOUT_MS }).toBeGreaterThan(0);
    await expect.poll(() => overlayHasPixels(page), { timeout: CANVAS_TIMEOUT_MS }).toBe(true);
    /* Fan-out: a second viewer joins the same encoder and paints too. */
    const second = await context.newPage();
    await second.goto('/');
    await selectVm(second, name);
    await expect.poll(() => canvasWidth(second, '#display .video-layer'), { timeout: VIDEO_TIMEOUT_MS }).toBeGreaterThan(0);
    await second.close();
    /* The first viewer must still be streaming after the second leaves. */
    expect(videoSockets.some((socket) => !socket.isClosed()), 'the first viewer keeps its video socket').toBe(true);
    await expect(page.locator('#displayBadge')).toHaveText('H264 · WEBCODECS');
    await powerOff(page, name);
});

/**
 * Regression test for the WebSocket console: the 101 upgrade response once used a Zig multiline literal
 * (literal "\r" text, not CRLF), so browsers never completed any WS handshake and VNC, SPICE and serial were all dead.
 */
test('live console: embedded VNC canvas and serial panel connect for a running VM', async ({ page }) => {
    await bootGuest(page, 'wf-live', 'display=vnc&embed_display=true&enable_serial=true');
    await page.reload();
    await selectVm(page, 'wf-live');
    /* The RFB handshake must complete and size the canvas from the guest. */
    await expect.poll(() => canvasWidth(page, '#display canvas'), { timeout: CANVAS_TIMEOUT_MS }).toBeGreaterThan(0);
    /* The serial relay shares the same upgrade path; the panel shows when connected. */
    await expect(page.locator('#serialpanel')).toBeVisible({ timeout: SERIAL_TIMEOUT_MS });
    await powerOff(page, 'wf-live');
});

/** A client bundle that never arrives leaves a visible message and a Retry, not a dead pane. */
const retryAfterFailedClient = async (page: Page, name: string): Promise<void> => {
    await page.route('**/novnc.js', (route) => route.abort());
    await page.reload();
    await selectVm(page, name);
    await expect(page.locator('#displayHint')).toContainText('VNC client failed to load.');
    await expect(page.locator('#displayBadge')).toHaveText('Disconnected');
    await page.unroute('**/novnc.js');
    await page.locator('#displayHint').getByRole('button', { name: 'Retry' }).click();
    await expect.poll(() => canvasWidth(page, '#display canvas'), { timeout: CANVAS_TIMEOUT_MS }).toBeGreaterThan(0);
    await expect(page.locator('#displayHint button')).toHaveCount(0);
    await expect(page.locator('#displayBadge')).toContainText('VNC');
    /* Reconnect drops the client and opens a fresh one. */
    await page.locator('#display [data-action="reconnectDisplay"]').click();
    await expect.poll(() => canvasWidth(page, '#display canvas'), { timeout: CANVAS_TIMEOUT_MS }).toBeGreaterThan(0);
};

/** F11 enters, the bar names the way out, Escape and the Exit button leave. */
const driveDisplayOnly = async (page: Page): Promise<void> => {
    const bar = page.getByRole('button', { name: 'Exit display-only mode' });
    await page.keyboard.press('F11');
    await expect(page.locator('body')).toHaveClass(/displayonly/);
    await expect(bar).toHaveCSS('opacity', '1');
    const viewport = page.viewportSize();
    const display = await page.locator('#display').boundingBox();
    expect(display?.height).toBe(viewport?.height);
    await page.keyboard.press('Escape');
    await expect(page.locator('body')).not.toHaveClass(/displayonly/);
    await page.locator('#display [data-action="enterDisplayOnly"]').click();
    await expect(page.locator('body')).toHaveClass(/displayonly/);
    await bar.click();
    await expect(page.locator('body')).not.toHaveClass(/displayonly/);
};

/** The serial handle resizes with the keyboard: arrows by 16px, Shift by 48px, Home and End to the limits. */
const driveSerialPanel = async (page: Page): Promise<void> => {
    await expect(page.locator('#serialpanel')).toBeVisible({ timeout: SERIAL_TIMEOUT_MS });
    const handle = page.locator('#serialResize');
    await expect(handle).toHaveAttribute('aria-valuenow', String(SERIAL_DEFAULT_PX));
    await handle.focus();
    await page.keyboard.press('ArrowDown');
    await expect(handle).toHaveAttribute('aria-valuenow', String(SERIAL_DEFAULT_PX + SERIAL_STEP_PX));
    await page.keyboard.press('Shift+ArrowDown');
    await expect(handle).toHaveAttribute('aria-valuenow', String(SERIAL_DEFAULT_PX + SERIAL_STEP_PX + SERIAL_SHIFT_STEP_PX));
    await page.keyboard.press('ArrowUp');
    await expect(handle).toHaveAttribute('aria-valuenow', String(SERIAL_DEFAULT_PX + SERIAL_SHIFT_STEP_PX));
    await page.keyboard.press('Home');
    await expect(handle).toHaveAttribute('aria-valuenow', String(SERIAL_MAX_PX));
    await expect(page.locator('#serialterm')).toHaveCSS('height', `${SERIAL_MAX_PX}px`);
    await page.keyboard.press('End');
    await expect(handle).toHaveAttribute('aria-valuenow', String(SERIAL_MIN_PX));
    /* Disconnect closes the panel and it stays closed. */
    await page.locator('#serialpanel').getByRole('button', { name: 'Disconnect' }).click();
    await expect(page.locator('#serialpanel')).toBeHidden();
};

test('live console: client Retry, reconnect, display-only mode and the serial panel', async ({ page }) => {
    test.setTimeout(CONSOLE_TEST_TIMEOUT_MS);
    const name = 'wf-console';
    await bootGuest(page, name, 'display=vnc&embed_display=true&enable_serial=true');
    try {
        await retryAfterFailedClient(page, name);
        await driveDisplayOnly(page);
        await driveSerialPanel(page);
    } finally {
        await powerOff(page, name);
    }
});

test('console tab says why it is empty', async ({ page }) => {
    await api(page, 'POST', '/api/vms', 'name=wf-notice-vnc&mem=1024&cpu=1&disk=1&display=vnc&embed_display=true');
    await api(page, 'POST', '/api/vms', 'name=wf-notice-native&mem=1024&cpu=1&disk=1&display=0');
    await page.reload();
    /* The tab is disabled for both VMs, but its panel is filled from the selected VM even while hidden. */
    const hint = page.locator('#consoleHint');
    await selectVm(page, 'wf-notice-vnc');
    await expect(hint).toContainText('wf-notice-vnc is powered off.');
    await selectVm(page, 'wf-notice-native');
    await expect(hint).toContainText('No embedded browser console for this display.');
    await expect(hint).toContainText('native GTK QEMU window');
    await page.locator('.toolbar [data-action="deselectVm"]').click();
    await expect(hint).toContainText('No VM selected.');
    await removeVms(page, 'wf-notice-vnc', 'wf-notice-native');
});

test('migration bar follows the status poll, cancels and clears itself', async ({ page }) => {
    const name = 'wf-migbar';
    await createVm(page, name);
    /* Migration is offered for a running guest only, so the list reports one. */
    const restore = await overrideVm(page, name, () => ({ status: 'running', embed_display: false }));
    try {
        await page.reload();
        await selectVm(page, name);
        const poll: { body: { status: string; pct?: number } } = { body: { status: 'active', pct: 40 } };
        let cancels = 0;
        await page.route(/\/api\/vms\/\d+\/migrate$/, (route) =>
            route.request().method() === 'POST' ? route.fulfill({ json: { status: 'started' } }) : route.fulfill({ json: poll.body }));
        await page.route(/\/api\/vms\/\d+\/migrate\/cancel$/, (route) => {
            cancels += 1;
            return route.fulfill({ json: {} });
        });
        await expect(page.locator('#mig_progress')).toBeHidden();
        await chooseTool(page, 'migrateGuest');
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
        await expect(bar).toBeHidden({ timeout: MIGRATION_CLEAR_TIMEOUT_MS });
    } finally {
        await restore();
        await removeVms(page, name);
    }
});

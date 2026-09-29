/** Confirm and prompt dialogs, preferences, About, the QEMU log, and the VM dialogs (new, import, clone, snapshots, migrate). */
import { expect, test, type Page } from '@playwright/test';
import { chooseFromMenu, chooseTool, loadApp, overrideVm, refreshList, selectVm, setTheme } from './app-ui';
import { api, createVm, indexOf, listVms, parseJson, removeVms, vmField } from './daemon-api';

const SCRATCH_DIR = new URL('../../.scratch', import.meta.url).pathname;
const SNAPSHOT_TIMEOUT_MS = 15_000;
const DEFAULT_MEMORY_MB = 2048;
const DEFAULT_CPU_CORES = 2;
const DEFAULT_AUTOPROTECT_INTERVAL_MIN = 60;
const DEFAULT_AUTOPROTECT_MAX = 10;

test.beforeEach(async ({ page }) => {
    await loadApp(page);
});

// Confirm dialog

/** Opens the danger confirm for deleting `name` with the keyboard, from the focused sidebar row. */
const askToDelete = async (page: Page, name: string): Promise<void> => {
    await createVm(page, name);
    await page.reload();
    await selectVm(page, name);
    await page.locator('.vm-item', { hasText: name }).focus();
    await page.keyboard.press('Delete');
};

const CONFIRM_ANSWERS = [
    { how: 'OK button', deleted: true },
    { how: 'Cancel button', deleted: false },
    { how: 'Escape', deleted: false },
    { how: 'backdrop click', deleted: false },
] as const;

for (const { how, deleted } of CONFIRM_ANSWERS) {
    test(`confirm dialog ${deleted ? 'deletes the VM' : 'keeps the VM'} on ${how} and returns focus`, async ({ page }) => {
        const name = 'wf-confirm';
        await askToDelete(page, name);
        const dlg = page.locator('#confirmdlg');
        await expect(dlg).toBeVisible();
        await expect(dlg).toHaveAttribute('aria-labelledby', 'confirmmsg');
        await expect(page.locator('#confirmmsg')).toHaveText(`Delete VM "${name}"?`);
        await expect(page.locator('#confirmOkBtn')).toHaveText('Delete');
        await expect(page.locator('#confirmOkBtn')).toHaveClass(/text-danger-text/);
        await expect(page.locator('#confirmCancelBtn')).toBeFocused();
        if (how === 'OK button') {
            await page.locator('#confirmOkBtn').click();
        } else if (how === 'Cancel button') {
            await page.locator('#confirmCancelBtn').click();
        } else if (how === 'Escape') {
            await page.keyboard.press('Escape');
        } else {
            await page.mouse.click(4, 4);
        }
        await expect(dlg).toHaveCount(0);
        if (deleted) {
            await expect.poll(() => indexOf(page, name)).toBe(-1);
        } else {
            expect(await indexOf(page, name)).toBeGreaterThanOrEqual(0);
            await expect(page.locator('.vm-item', { hasText: name })).toBeFocused();
            await removeVms(page, name);
        }
    });
}

test('confirm dialog shows every line of a multi-line question', async ({ page }) => {
    const name = 'wf-confirm-lines';
    await createVm(page, name);
    const restore = await overrideVm(page, name, () => ({ status: 'running', embed_display: false }));
    try {
        await refreshList(page);
        await chooseFromMenu(page, 'dangerMenu', 'batchStop');
        await expect(page.locator('#confirmmsg')).toContainText('Power off ALL running VMs?');
        await expect(page.locator('#confirmmsg')).toContainText('Unsaved data may be lost.');
        await expect(page.locator('#confirmOkBtn')).toHaveText('Power Off All');
        await page.locator('#confirmCancelBtn').click();
        await expect(page.locator('#confirmdlg')).toHaveCount(0);
    } finally {
        await restore();
        await removeVms(page, name);
    }
});

test('confirm dialog without danger uses the primary button and OK label', async ({ page }) => {
    const name = 'wf-confirm-plain';
    await createVm(page, name);
    await page.reload();
    await selectVm(page, name);
    await page.click('#tab-btn-settings');
    await page.locator('#tabSettings [data-action="compactDisk"]').click();
    await expect(page.locator('#confirmOkBtn')).toHaveText('OK');
    await expect(page.locator('#confirmOkBtn')).not.toHaveClass(/text-danger-text/);
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#confirmdlg')).toHaveCount(0);
    await expect(page.locator('#statusannounce')).toHaveText('Primary disk compacted.');
    await removeVms(page, name);
});

// Prompt dialog

test('prompt dialog offers suggestions, submits on Enter and moves the VM', async ({ page }) => {
    await createVm(page, 'wf-prompt-a');
    await createVm(page, 'wf-prompt-b');
    await createVm(page, 'wf-prompt-move');
    await api(page, 'POST', `/api/vms/${await indexOf(page, 'wf-prompt-a')}`, 'folder=alpha');
    await api(page, 'POST', `/api/vms/${await indexOf(page, 'wf-prompt-b')}`, 'folder=beta');
    try {
        await page.reload();
        await selectVm(page, 'wf-prompt-move');
        await chooseTool(page, 'moveToFolder');
        await expect(page.locator('#promptdlg')).toBeVisible();
        await expect(page.locator('#promptLabel')).toHaveText('Move "wf-prompt-move" to folder (blank = none):');
        await expect(page.locator('#promptInput')).toHaveValue('');
        await expect(page.locator('#promptInput')).toBeFocused();
        await expect(page.locator('#promptOptions option[value="alpha"]')).toHaveCount(1);
        await expect(page.locator('#promptOptions option[value="beta"]')).toHaveCount(1);
        await page.locator('#promptInput').fill('gamma');
        await page.keyboard.press('Enter');
        await expect(page.locator('#promptdlg')).toHaveCount(0);
        await expect.poll(() => vmField(page, 'wf-prompt-move', 'folder')).toBe('gamma');
        await expect(page.locator('#statusannounce')).toHaveText('Moved to gamma');
    } finally {
        await removeVms(page, 'wf-prompt-a', 'wf-prompt-b', 'wf-prompt-move');
    }
});

test('prompt dialog without suggestions cancels with Escape and with Cancel', async ({ page }) => {
    const name = 'wf-prompt-rename';
    await createVm(page, name);
    try {
        await page.reload();
        await selectVm(page, name);
        await chooseTool(page, 'renameGuest');
        await expect(page.locator('#promptInput')).toHaveValue(name);
        await expect(page.locator('#promptInput')).toBeFocused();
        await expect(page.locator('#promptInput')).not.toHaveAttribute('list', /.+/);
        await page.locator('#promptInput').fill('wf-prompt-renamed');
        await page.keyboard.press('Escape');
        await expect(page.locator('#promptdlg')).toHaveCount(0);
        await chooseTool(page, 'renameGuest');
        await page.locator('#promptInput').fill('wf-prompt-renamed');
        await page.locator('#promptCancelBtn').click();
        await expect(page.locator('#promptdlg')).toHaveCount(0);
        expect(await indexOf(page, name)).toBeGreaterThanOrEqual(0);
        expect(await indexOf(page, 'wf-prompt-renamed')).toBe(-1);
        await chooseTool(page, 'renameGuest');
        await page.locator('#promptInput').fill('wf-prompt-renamed');
        await page.locator('#promptOkBtn').click();
        await expect.poll(() => indexOf(page, 'wf-prompt-renamed')).toBeGreaterThanOrEqual(0);
    } finally {
        await removeVms(page, name, 'wf-prompt-renamed');
    }
});

// Preferences and About

const fieldsOf = (record: unknown): Map<string, unknown> => new Map(typeof record === 'object' && record !== null ? Object.entries(record) : []);

/** The daemon's saved config as the preferences form posts it back; a fresh daemon has none, so the built-in defaults stand in. */
const preferencesBody = (saved: unknown): string => {
    const config = fieldsOf(saved);
    const prefs = fieldsOf(config.get('prefs'));
    const numberSetting = (name: string, fallback: number): number => {
        const found = prefs.get(name);
        return typeof found === 'number' ? found : fallback;
    };
    const theme = config.get('theme');
    const vmDir = prefs.get('default_vm_dir');
    return [
        `theme=${typeof theme === 'string' ? theme : 'system'}`,
        `default_vm_dir=${encodeURIComponent(typeof vmDir === 'string' ? vmDir : '')}`,
        `default_memory_mb=${numberSetting('default_memory_mb', DEFAULT_MEMORY_MB)}`,
        `default_cpu_cores=${numberSetting('default_cpu_cores', DEFAULT_CPU_CORES)}`,
        `autoprotect_enabled=${prefs.get('autoprotect_enabled_default') === true ? 1 : 0}`,
        `autoprotect_interval=${numberSetting('autoprotect_interval_min_default', DEFAULT_AUTOPROTECT_INTERVAL_MIN)}`,
        `autoprotect_max=${numberSetting('autoprotect_max_default', DEFAULT_AUTOPROTECT_MAX)}`,
    ].join('&');
};

/** Edits and saves the preferences form, then checks what the daemon stored. */
const saveEditedPreferences = async (page: Page): Promise<void> => {
    await chooseTool(page, 'openPrefs');
    await page.locator('#p_theme').selectOption('dark');
    await page.locator('#p_default_memory_mb').fill('3072');
    await page.locator('#p_default_cpu_cores').fill('3');
    await page.locator('#p_autoprotect_enabled').selectOption('1');
    await page.locator('#prefsdlg button[type="submit"]').click();
    await expect(page.locator('#prefsdlg')).toHaveCount(0);
    await expect(page.locator('html')).not.toHaveClass(/light/);
    const stored = await api(page, 'GET', '/api/config');
    expect(parseJson(stored.text)).toMatchObject({
        theme: 'dark',
        prefs: { default_memory_mb: 3072, default_cpu_cores: 3, autoprotect_enabled_default: true },
    });
};

test('preferences preview the theme, revert it on cancel and keep it on save', async ({ page }) => {
    const before = await api(page, 'GET', '/api/config');
    expect(before.ok).toBe(true);
    try {
        await setTheme(page, 'light');
        await chooseTool(page, 'openPrefs');
        await expect(page.locator('#prefsdlg')).toBeVisible();
        await page.locator('#p_theme').selectOption('dark');
        await expect(page.locator('html')).not.toHaveClass(/light/);
        await page.locator('#prefsdlg [data-action="closeDlg"]').click();
        await expect(page.locator('#prefsdlg')).toHaveCount(0);
        await expect(page.locator('html')).toHaveClass(/light/);

        await saveEditedPreferences(page);

        /* Reopening shows the saved values. */
        await chooseTool(page, 'openPrefs');
        await expect(page.locator('#p_default_memory_mb')).toHaveValue('3072');
        await expect(page.locator('#p_theme')).toHaveValue('dark');
        /* Enter in a field submits the form. */
        await page.locator('#p_default_cpu_cores').press('Enter');
        await expect(page.locator('#prefsdlg')).toHaveCount(0);
    } finally {
        const restored = await api(page, 'POST', '/api/config', preferencesBody(parseJson(before.text)));
        expect(restored.ok).toBe(true);
    }
});

test('about dialog shows the daemon version and closes with its button', async ({ page }) => {
    await chooseTool(page, 'openAbout');
    await expect(page.locator('#aboutdlg')).toBeVisible();
    await expect(page.locator('#aboutVersion')).toContainText('Version');
    await page.locator('#aboutdlg [data-action="closeDlg"]').click();
    await expect(page.locator('#aboutdlg')).toHaveCount(0);
});

test('QEMU log dialog refreshes in place and closes with Escape', async ({ page }) => {
    await createVm(page, 'wf-log');
    await selectVm(page, 'wf-log');
    await page.locator('#tabSummary [data-action="viewLog"]').click();
    await expect(page.locator('#log_vmname')).toHaveText('wf-log');
    await expect(page.locator('#logbody')).toContainText(/No log output yet/);
    await page.locator('#logdlg [data-action="refreshLog"]').click();
    await expect(page.locator('#logbody')).toContainText(/No log output yet/);
    await page.keyboard.press('Escape');
    await expect(page.locator('#logdlg')).toHaveCount(0);
});

// VM dialogs

test('new VM dialog validates inline, then creates the VM and selects it', async ({ page }) => {
    await page.locator('.new-vm-btn').click();
    await expect(page.locator('#newdlg')).toBeVisible();
    await expect(page.locator('#n_name')).toBeFocused();
    await expect(page.locator('#newdlg [aria-invalid]')).toHaveCount(0);

    await page.locator('#n_mem').fill('64');
    await expect(page.locator('#err_n_name')).toHaveText('Name is required.');
    await expect(page.locator('#err_n_mem')).toHaveText('Memory must be 128-65536 MB.');
    await expect(page.locator('#n_mem')).toHaveAttribute('aria-invalid', 'true');
    /* Enter with invalid fields submits nothing and lands on the first bad field. */
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

    expect(await vmField(page, 'wf-newvm-ui', 'mem')).toBe(512);
    await expect(page.locator('.vm-item[aria-current="true"]', { hasText: 'wf-newvm-ui' })).toBeVisible();
    await removeVms(page, 'wf-newvm-ui');
});

/** A real 1 MB qcow2 image under the repo's gitignored .scratch, never tmpfs. */
const makeDiskImage = async (): Promise<string> => {
    const image = `${SCRATCH_DIR}/wf-import-${Bun.randomUUIDv7()}/guest.qcow2`;
    await Bun.write(`${image}.keep`, '');
    /* No in-process API writes qcow2 images; qemu-img is the tool the daemon itself uses. */
    const created = Bun.spawnSync(['qemu-img', 'create', '-f', 'qcow2', image, '1M']);
    expect(created.exitCode, created.stderr.toString()).toBe(0);
    return image;
};

test('import dialog rejects bad paths inline and imports a disk image in place', async ({ page }) => {
    const image = await makeDiskImage();
    await chooseTool(page, 'importGuest');
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
    await selectVm(page, 'wf-clone-ui');
    const clones = async (): Promise<number> => {
        const vms = await listVms(page);
        return vms.filter((vm) => vm.name.includes('wf-clone-ui')).length;
    };
    await chooseTool(page, 'cloneGuest');
    await expect(page.locator('#clone_name')).toHaveText('wf-clone-ui');
    await page.locator('#clonedlg').getByRole('button', { name: 'Full Clone' }).click();
    await expect(page.locator('#clonedlg')).toHaveCount(0);
    await expect.poll(clones).toBe(2);

    await chooseTool(page, 'cloneGuest');
    await page.locator('#clonedlg').getByRole('button', { name: 'Linked Clone' }).click();
    await expect(page.locator('#clonedlg')).toHaveCount(0);
    await expect.poll(clones).toBe(3);
});

const openSnapshotManager = (page: Page): Promise<void> => chooseFromMenu(page, 'snapshotMenu', 'openSnapshots');

test('snapshot manager validates names, reverts and deletes behind confirmations', async ({ page }) => {
    const index = await createVm(page, 'wf-snap-ui');
    await page.reload();
    await selectVm(page, 'wf-snap-ui');
    await openSnapshotManager(page);
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
    await expect(page.locator('#snaplist')).toContainText('first', { timeout: SNAPSHOT_TIMEOUT_MS });
    await expect(page.locator('#s_tag')).toHaveValue('');

    /* Cancelling the delete confirmation keeps the snapshot. */
    await page.getByRole('button', { name: 'Delete snapshot first' }).click();
    await expect(page.locator('#confirmdlg')).toBeVisible();
    await expect(page.locator('#confirmOkBtn')).toHaveClass(/danger|bg-danger|text-danger/);
    await page.locator('#confirmCancelBtn').click();
    await expect(page.locator('#confirmdlg')).toHaveCount(0);
    await expect(page.locator('#snaplist')).toContainText('first');
    const listed = await api(page, 'GET', `/api/vms/${index}/snapshots`);
    expect(listed.text).toContain('first');

    /* Reverting closes the manager once confirmed. */
    await page.getByRole('button', { name: 'Revert to snapshot first' }).click();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#snapdlg')).toHaveCount(0);

    await openSnapshotManager(page);
    await page.getByRole('button', { name: 'Delete snapshot first' }).click();
    await page.locator('#confirmOkBtn').click();
    await expect(page.locator('#snaplist')).toContainText('No snapshots yet');
});

test('migrate dialog builds the URI live and validates the target', async ({ page }) => {
    const name = 'wf-migrate-ui';
    await createVm(page, name);
    /* Migration is offered for a running guest only, so the list reports one. */
    const restore = await overrideVm(page, name, () => ({ status: 'running', embed_display: false }));
    try {
        await page.reload();
        await selectVm(page, name);
        await chooseTool(page, 'migrateGuest');
        await expect(page.locator('#migrate_vmname')).toHaveText(name);
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
    } finally {
        await restore();
        await removeVms(page, name);
    }
});

test('snapshot manager shows the creation timestamp', async ({ page }) => {
    await createVm(page, 'wf-snaptime');
    await page.reload();
    await selectVm(page, 'wf-snaptime');
    await openSnapshotManager(page);
    await page.fill('#s_tag', 'stamped');
    await page.locator('#snapdlg button[type="submit"]').click();
    await expect(page.locator('#snaplist')).toContainText('stamped', { timeout: SNAPSHOT_TIMEOUT_MS });
    /* The row carries "Taken YYYY-MM-DD HH:MM:SS" parsed from qemu-img output. */
    await expect(page.locator('#snaplist')).toContainText(/Taken \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/);
});

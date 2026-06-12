import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdtempSync, appendFileSync } from 'fs';
const LOG = m => appendFileSync('/tmp/audit.log', m + '\n');
const PORT = '9223', BASE = `http://127.0.0.1:${PORT}`;
const daemon = spawn('./zig-out/bin/hangar-web', [], { env: { ...process.env, HOME: mkdtempSync('/tmp/ha-'), KV_PORT: PORT }, stdio: ['ignore', 'ignore', 'ignore'] });
await new Promise(r => setTimeout(r, 2500));
const b = await chromium.launch({ headless: true });
const pg = await b.newPage({ viewport: { width: 1500, height: 950 } });
const api = (m, p, body) => pg.evaluate(async ([m, p, body]) => (await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body })).status, [m, p, body]);
const shot = n => pg.screenshot({ path: '/tmp/audit/' + n + '.png' });
const esc = () => pg.keyboard.press('Escape');
try {
  await pg.goto(BASE);
  await api('POST', '/api/vms', 'name=web-prod-01&mem=4096&cpu=4&disk=20&guest_os=2&tags=prod%2Cweb&notes=Primary web server&folder=Production');
  await api('POST', '/api/vms', 'name=db-dev-02&mem=8192&cpu=8&disk=40&guest_os=3&tags=dev&folder=Development');
  await pg.reload(); await pg.waitForTimeout(700);
  await shot('00-dashboard');
  await pg.locator('.vm-item', { hasText: 'web-prod-01' }).first().click(); await pg.waitForTimeout(400);
  await shot('01-summary');
  // toolbar menus
  for (const [n, sel] of [['02-power', '[data-menu="powerMenu"]'], ['03-snapshots', '[data-menu="snapshotMenu"]'], ['04-devices', '[data-menu="devicesMenu"]'], ['05-tools', '[data-menu="toolsMenu"]'], ['06-danger', '[data-menu="dangerMenu"]']]) {
    const btn = pg.locator(sel).first();
    if (await btn.count()) { await btn.click(); await pg.waitForTimeout(250); await shot(n); await esc(); await pg.waitForTimeout(150); }
    else LOG('MISSING menu btn ' + sel);
  }
  // overflow ⋯ menu
  const more = pg.locator('.toolbar-more').first();
  if (await more.count()) { await more.click(); await pg.waitForTimeout(250); await shot('07-more'); await esc(); }
  // ctx menu on VM
  await pg.locator('.vm-item', { hasText: 'db-dev-02' }).first().click({ button: 'right' }); await pg.waitForTimeout(250); await shot('08-ctxmenu'); await esc();
  // settings tab (NIC/extra generated rows)
  await pg.locator('.vm-item', { hasText: 'web-prod-01' }).first().click(); await pg.waitForTimeout(300);
  await pg.locator('#tab-btn-settings').click(); await pg.waitForTimeout(400); await shot('09-settings-top');
  await pg.evaluate(() => { document.querySelector('.content-area').scrollTop = 1200; }); await pg.waitForTimeout(200); await shot('10-settings-network');
  await pg.evaluate(() => { document.querySelector('.content-area').scrollTop = 2400; }); await pg.waitForTimeout(200); await shot('11-settings-extra');
  await pg.evaluate(() => { document.querySelector('.content-area').scrollTop = 99999; }); await pg.waitForTimeout(200); await shot('12-settings-bottom');
  // dialogs
  for (const [n, act] of [['13-newvm', 'newVm'], ['14-vnets', 'openVnets'], ['15-catalog', 'openCatalog'], ['16-import', 'importGuest'], ['17-prefs', 'openPrefs'], ['18-shortcuts', 'showShortcutsModal'], ['19-about', 'openAbout'], ['20-snapmgr', 'openSnapshots'], ['21-topology', 'openTopology']]) {
    const el = pg.locator(`[data-action="${act}"]`).first();
    if (await el.count()) {
      const vis = await el.isVisible().catch(() => false);
      if (!vis) { await more.click(); await pg.waitForTimeout(200); }
      const el2 = pg.locator(`[data-action="${act}"]`).first();
      await el2.click({ force: true }).catch(e => LOG('click fail ' + act));
      await pg.waitForTimeout(500); await shot(n); await esc(); await pg.waitForTimeout(250); await esc(); await pg.waitForTimeout(150);
    } else LOG('MISSING action ' + act);
  }
  // palette
  await pg.keyboard.press('Control+k'); await pg.waitForTimeout(300); await shot('22-palette'); await esc();
} catch (e) { LOG('ERR ' + e.message.slice(0, 200)); }
await b.close(); daemon.kill('SIGKILL'); LOG('DONE');

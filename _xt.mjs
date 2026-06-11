import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdtempSync, appendFileSync } from 'fs';
const LOG = m => appendFileSync('/tmp/xt.log', m + '\n');
const PORT = '9175', BASE = `http://127.0.0.1:${PORT}`;
const daemon = spawn('./zig-out/bin/hangar-web', [], { env: { ...process.env, HOME: mkdtempSync('/tmp/hxt-'), KV_PORT: PORT }, stdio: ['ignore', 'ignore', 'ignore'] });
await new Promise(r => setTimeout(r, 2500));
const b = await chromium.launch({ headless: !process.env.DISPLAY });
const pg = await b.newPage({ viewport: { width: 1500, height: 950 } });
const api = (m, p, body) => pg.evaluate(async ([m, p, body]) => (await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body })).status, [m, p, body]);
const perr = []; pg.on('pageerror', e => perr.push(e.message.slice(0, 100)));
try {
  await pg.goto(BASE);
  await api('POST', '/api/vms', 'name=ser&mem=1024&cpu=1&disk=1&guest_os=2&display=vnc&embed_display=true&enable_serial=true&firmware=bios&vnc_port=5977&spice_port=5978');
  await pg.reload(); await pg.waitForTimeout(600);
  await api('POST', '/api/vms/0/power', '');
  let st = ''; for (let i = 0; i < 18; i++) { await pg.waitForTimeout(1000); st = await pg.evaluate(async () => (await (await fetch('/api/vms')).json())[0].status); if (st === 'running') break; }
  LOG('RUNNING=' + st);
  await pg.locator('.vm-item', { hasText: 'ser' }).first().click(); await pg.waitForTimeout(8000);
  const x = await pg.evaluate(() => {
    const host = document.getElementById('serialterm');
    const xt = host && host.querySelector('.xterm');
    const canvases = host ? host.querySelectorAll('canvas').length : 0;
    return { mounted: !!xt, canvases, wsOpen: !!(serialWs && serialWs.readyState === WebSocket.OPEN), panelShown: getComputedStyle(document.getElementById('serialpanel')).display !== 'none' };
  });
  LOG('XTERM=' + JSON.stringify(x));
  // type into the terminal — must not throw, ws must accept the send
  await pg.locator('#serialterm .xterm').click();
  await pg.keyboard.type('hello');
  await pg.keyboard.press('Enter');
  await pg.waitForTimeout(400);
  LOG('TYPED ok, PAGEERR=' + JSON.stringify(perr));
  await pg.screenshot({ path: '/tmp/cuj/z1-xterm.png' });
  await api('POST', '/api/vms/0/power', '');
} catch (e) { LOG('ERR ' + e.message.slice(0, 160)); }
await new Promise(r => setTimeout(r, 800));
await b.close(); daemon.kill('SIGKILL'); LOG('DONE');

import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdtempSync, appendFileSync } from 'fs';
const LOG = m => appendFileSync('/tmp/p2.log', m + '\n');
const PORT = '9171', BASE = `http://127.0.0.1:${PORT}`;
const daemon = spawn('./zig-out/bin/hangar-web', [], { env: { ...process.env, HOME: mkdtempSync('/tmp/hp2-'), KV_PORT: PORT }, stdio: ['ignore', 'ignore', 'ignore'] });
await new Promise(r => setTimeout(r, 2500));
const b = await chromium.launch({ headless: !process.env.DISPLAY });
const pg = await b.newPage({ viewport: { width: 1500, height: 950 } });
const api = (m, p, body) => pg.evaluate(async ([m, p, body]) => (await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body })).status, [m, p, body]);
try {
  await pg.goto(BASE);
  await api('POST', '/api/vms', 'name=web-prod-01&mem=4096&cpu=4&disk=1&guest_os=2&display=vnc&embed_display=true&enable_serial=true&firmware=bios&vnc_port=5975&spice_port=5976&tags=prod&folder=Production');
  await pg.reload(); await pg.waitForTimeout(900);
  const live = await pg.evaluate(() => { const lb = document.getElementById('livebadge'); return lb && !lb.hidden; });
  LOG('LIVEBADGE=' + live);
  // favorite star
  await pg.locator('.vm-item .star').first().click(); await pg.waitForTimeout(600);
  await api('POST', '/api/vms/0/power', '');
  let st = ''; for (let i = 0; i < 18; i++) { await pg.waitForTimeout(1000); st = await pg.evaluate(async () => (await (await fetch('/api/vms')).json())[0].status); if (st === 'running') break; }
  LOG('RUNNING=' + st);
  await pg.locator('.vm-item', { hasText: 'web-prod-01' }).first().click(); await pg.waitForTimeout(8000);
  await pg.screenshot({ path: '/tmp/cuj/y1-console-final.png' });
  await api('POST', '/api/vms/0/power', '');
} catch (e) { LOG('ERR ' + e.message.slice(0, 150)); }
await new Promise(r => setTimeout(r, 800));
await b.close(); daemon.kill('SIGKILL'); LOG('DONE');

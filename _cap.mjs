import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdtempSync, appendFileSync } from 'fs';
const LOG = m => appendFileSync('/tmp/cap.log', m + '\n');
const PORT = '9187', BASE = `http://127.0.0.1:${PORT}`;
const daemon = spawn('./zig-out/bin/hangar-web', [], { env: { ...process.env, HOME: mkdtempSync('/tmp/hcap-'), KV_PORT: PORT }, stdio: ['ignore', 'pipe', 'pipe'] });
let dlog = ''; daemon.stdout.on('data', d => dlog += d); daemon.stderr.on('data', d => dlog += d);
await new Promise(r => setTimeout(r, 2500));
const b = await chromium.launch({ headless: !process.env.DISPLAY });
const pg = await b.newPage();
const api = (m, p, body) => pg.evaluate(async ([m, p, body]) => { const r = await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body }); return { s: r.status, t: await r.text() }; }, [m, p, body]);
try {
  await pg.goto(BASE);
  await api('POST', '/api/vms', 'name=cap&mem=1024&cpu=1&disk=1&guest_os=2&display=vnc&embed_display=true&video_stream=1&firmware=bios&vnc_port=5979&spice_port=5980');
  const r = await api('POST', '/api/vms/0/power', '');
  LOG('POWER=' + r.s);
  let st = ''; for (let i = 0; i < 18; i++) { await pg.waitForTimeout(1000); st = JSON.parse((await api('GET', '/api/vms')).t)[0]?.status; if (st === 'running') break; }
  LOG('RUNNING=' + st);
  // wait for attach + at least two cadence windows (boot animation produces updates)
  await pg.waitForTimeout(13000);
  // also confirm the VNC console still works alongside
  await pg.reload(); await pg.waitForTimeout(500);
  await pg.locator('.vm-item', { hasText: 'cap' }).first().click(); await pg.waitForTimeout(7000);
  const canv = await pg.evaluate(() => { const c = document.querySelector('#tabConsole #display canvas'); return c ? c.width + 'x' + c.height : 'none'; });
  LOG('VNC_ALONGSIDE=' + canv);
  await api('POST', '/api/vms/0/power', '');
  await pg.waitForTimeout(1500);
} catch (e) { LOG('ERR ' + e.message.slice(0, 160)); }
LOG('DAEMON LINES:');
LOG(dlog.split('\n').filter(l => /dbusdisplay/.test(l)).join('\n') || '(none)');
await b.close(); daemon.kill('SIGKILL'); LOG('DONE');

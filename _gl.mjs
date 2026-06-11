import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdtempSync, appendFileSync } from 'fs';
const LOG = m => appendFileSync('/tmp/gl.log', m + '\n');
const PORT = '9183', BASE = `http://127.0.0.1:${PORT}`;
const daemon = spawn('./zig-out/bin/hangar-web', [], { env: { ...process.env, HOME: mkdtempSync('/tmp/hgl2-'), KV_PORT: PORT }, stdio: ['ignore', 'ignore', 'ignore'] });
await new Promise(r => setTimeout(r, 2500));
const b = await chromium.launch({ headless: !process.env.DISPLAY });
const pg = await b.newPage({ viewport: { width: 1500, height: 950 } });
const api = (m, p, body) => pg.evaluate(async ([m, p, body]) => { const r = await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body }); return { s: r.status, t: await r.text() }; }, [m, p, body]);
async function bootCheck(name, params, port) {
  await api('POST', '/api/vms', `name=${name}&mem=2048&cpu=2&disk=1&guest_os=2&firmware=bios&enable_3d=1&gpu_device=1&embed_display=true&${params}`);
  await pg.reload(); await pg.waitForTimeout(600);
  const idx = JSON.parse((await api('GET', '/api/vms')).t).findIndex(v => v.name === name);
  await api('POST', `/api/vms/${idx}/power`, '');
  let st = ''; for (let i = 0; i < 18; i++) { await pg.waitForTimeout(1000); st = JSON.parse((await api('GET', '/api/vms')).t)[idx]?.status; if (st === 'running') break; }
  LOG(name + ' RUNNING=' + st);
  if (st !== 'running') return;
  await pg.locator('.vm-item', { hasText: name }).first().click(); await pg.waitForTimeout(10000);
  const d = await pg.evaluate(() => { const c = document.querySelector('#tabConsole #display canvas'); const bg = document.getElementById('displayBadge'); return { canvas: c ? c.width + 'x' + c.height : 'none', badge: bg ? bg.textContent : '?' }; });
  LOG(name + ' = ' + JSON.stringify(d));
  await pg.screenshot({ path: '/tmp/cuj/gl-' + name + '.png' });
  await api('POST', `/api/vms/${idx}/power`, '');
  await pg.waitForTimeout(1500);
}
try {
  await pg.goto(BASE);
  await bootCheck('virgl-spice', 'display=2&vnc_port=5983&spice_port=5984');
  await bootCheck('virgl-vnc', 'display=3&vnc_port=5985&spice_port=5986');
} catch (e) { LOG('ERR ' + e.message.slice(0, 180)); }
await b.close(); daemon.kill('SIGKILL'); LOG('DONE');

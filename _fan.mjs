import { chromium } from '@playwright/test';
import { spawn } from 'child_process';
import { mkdtempSync, appendFileSync } from 'fs';
const LOG = m => appendFileSync('/tmp/fan.log', m + '\n');
const PORT = '9217', BASE = `http://127.0.0.1:${PORT}`;
const daemon = spawn('./zig-out/bin/hangar-web', [], { env: { ...process.env, HOME: mkdtempSync('/tmp/hf-'), KV_PORT: PORT }, stdio: ['ignore', 'pipe', 'pipe'] });
let dlog = ''; daemon.stdout.on('data', d => dlog += d); daemon.stderr.on('data', d => dlog += d);
await new Promise(r => setTimeout(r, 2500));
const b = await chromium.launch({ headless: true });
const mkpage = async () => b.newPage();
const p1 = await mkpage(), p2 = await mkpage();
const api = (pg, m, p, body) => pg.evaluate(async ([m, p, body]) => { const r = await fetch(p, { method: m, headers: { 'X-API-Key': 'hangar' }, body }); return { s: r.status, t: await r.text() }; }, [m, p, body]);
const state = pg => pg.evaluate(() => {
  const vc = document.querySelector('#display .video-layer');
  let painted = false;
  if (vc) { try { const d = vc.getContext('2d').getImageData(0, 0, 64, 64).data; for (let i = 0; i < d.length; i += 4) { if (d[i] || d[i+1] || d[i+2]) { painted = true; break; } } } catch (e) {} }
  return { size: vc ? vc.width + 'x' + vc.height : 'none', painted, dec: (typeof videoDec !== 'undefined' && videoDec) ? videoDec.state : 'none' };
});
try {
  await p1.goto(BASE);
  await api(p1, 'POST', '/api/vms', 'name=fan&mem=1024&cpu=1&disk=1&guest_os=2&display=vnc&embed_display=true&video_stream=1&firmware=bios');
  await api(p1, 'POST', '/api/vms/0/power', '');
  let st = ''; for (let i = 0; i < 20; i++) { await p1.waitForTimeout(1000); st = JSON.parse((await api(p1, 'GET', '/api/vms')).t)[0]?.status; if (st === 'running') break; }
  LOG('RUNNING=' + st);
  await p1.reload(); await p2.goto(BASE);
  await p1.waitForTimeout(600); await p2.waitForTimeout(600);
  await p1.locator('.vm-item', { hasText: 'fan' }).first().click();
  await p2.locator('.vm-item', { hasText: 'fan' }).first().click();
  await p1.waitForTimeout(12000);
  LOG('P1=' + JSON.stringify(await state(p1)));
  LOG('P2=' + JSON.stringify(await state(p2)));
  // first viewer leaves; second must keep streaming
  await p1.close();
  await p2.waitForTimeout(4000);
  LOG('P2_AFTER_P1_GONE=' + JSON.stringify(await state(p2)));
  await api(p2, 'POST', '/api/vms/0/power', '');
  await p2.waitForTimeout(1500);
} catch (e) { LOG('ERR ' + e.message.slice(0, 160)); }
LOG('DAEMON: ' + dlog.split('\n').filter(l => /dbusdisplay|encoder/.test(l)).slice(0, 8).join(' | '));
await b.close(); daemon.kill('SIGKILL'); LOG('DONE');

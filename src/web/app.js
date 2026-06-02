// SPDX-License-Identifier: MIT
(function(){
const saved=localStorage.getItem('kvmgui-theme')||'system';
window.kvmguiTheme=saved;
window.applyTheme=function(t){
 window.kvmguiTheme=t;
 localStorage.setItem('kvmgui-theme',t);
 const light=t==='light'||(t==='system'&&window.matchMedia('(prefers-color-scheme:light)').matches);
 document.documentElement.classList.toggle('light',light);
};
window.applyTheme(saved);
window.matchMedia('(prefers-color-scheme:light)').addEventListener('change',function(){
 if(window.kvmguiTheme==='system') window.applyTheme('system');
});
function cycleTheme(){
 var themes=['system','light','dark'];
 var cur=window.kvmguiTheme||'system';
 var idx=themes.indexOf(cur);
 var next=themes[(idx+1)%themes.length];
 window.applyTheme(next);
 var icons={system:'🌓',light:'☀️',dark:'🌙'};
 var btn=document.querySelector('.theme-toggle-btn');
 if(btn)btn.textContent=icons[next]||'🌓';
 showToast('Theme: '+next.charAt(0).toUpperCase()+next.slice(1),'info',{duration:2000});
}
})();
var vms=[]; var sel=null; var activeTab='summary'; var transitioningIdx=null; var refreshBusy=false;
function escHtml(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
function setStatus(s){var el=document.getElementById('statusbar');if(!el)return;el.textContent=s;el.classList.remove('loading');}
function setStatusLoading(s){var el=document.getElementById('statusbar');if(!el)return;el.textContent='⏳ '+s;el.classList.add('loading');}
var toastIcons={success:'✓',error:'✗',info:'ℹ',warn:'⚠'};
function showToast(msg,type,opts){type=type||'info';var c=document.getElementById('toast-container');if(!c)return;var toasts=c.querySelectorAll('.toast');while(toasts.length>=5){c.removeChild(toasts[0]);toasts=c.querySelectorAll('.toast');}var t=document.createElement('div');t.className='toast '+type;var icon=toastIcons[type]||toastIcons.info;var inner='<span class=\"toast-icon\">'+icon+'</span><span class=\"toast-msg\">'+escHtml(msg)+'</span>';if(opts&&opts.action){inner+='<button class=\"toast-action\" data-toast-action=\"'+opts.action+'\">UNDO</button>';}t.innerHTML=inner;c.appendChild(t);
if(opts&&opts.action&&opts.onAction){t.querySelector('.toast-action').addEventListener('click',function(){opts.onAction();c.removeChild(t);});}
var reducedMotion=window.matchMedia('(prefers-reduced-motion:reduce)').matches;
setTimeout(function(){if(reducedMotion){if(t.parentNode)c.removeChild(t);}else{t.classList.add('exit');setTimeout(function(){if(t.parentNode)c.removeChild(t);},280);}},opts&&opts.duration?opts.duration:3500);}
function toastUndo(msg,onUndo){showToast(msg,'info',{action:'undo',onAction:onUndo,duration:5000});}
var apiPostPending=0;
var loadBar=null;
function initLoadBar(){loadBar=document.createElement('div');loadBar.id='loadbar';var mn=document.querySelector('main');if(mn)mn.appendChild(loadBar);else document.body.appendChild(loadBar);}
function setLoadBar(on){if(!loadBar)initLoadBar();if(on)loadBar.classList.add('active');else{loadBar.classList.remove('active');}}
var busy=false,busyGen=0; // guard against double-submit
function setBusy(){if(busy)return false;busy=true;var gen=++busyGen;setTimeout(function(){if(busyGen===gen){busy=false;console.warn('busy guard auto-cleared after 30s — request may be hung');}},30000);return true;} // fallback auto-clear after 30s
async function apiPost(url,body){if(!setBusy()){showToast('Another operation is in progress — please wait.','warn');return null;}var sb=document.getElementById('statusbar');var wasIdle=apiPostPending<=0;var prev=sb?sb.textContent:'Ready';if(wasIdle){setStatusLoading('Working...');setLoadBar(true);}apiPostPending++;try{var opts={method:'POST',body:body||'',headers:{'X-API-Key':'kvmgui'}};var r=await fetch(url,opts);if(!r.ok){var msg=await r.text().catch(function(){return '';});throw new Error(msg||'HTTP '+r.status);}apiPostPending--;if(apiPostPending<=0){setStatus(prev);setLoadBar(false);}busy=false;busyGen++;return r;}catch(e){apiPostPending--;if(apiPostPending<=0){setStatus('Error: '+e.message);setLoadBar(false);}busy=false;busyGen++;showToast(e.message||'Request failed','error');return null;}}
var sidebarOpen=false;
function toggleSidebar(){sidebarOpen=!sidebarOpen;const aside=document.querySelector('aside');const btn=document.querySelector('.hamburger');if(aside){if(sidebarOpen){aside.classList.add('open');document.body.classList.add('sidebar-overlay');}else{aside.classList.remove('open');document.body.classList.remove('sidebar-overlay');}}
if(btn)btn.setAttribute('aria-expanded',sidebarOpen?'true':'false');}
function closeSidebar(){if(!sidebarOpen)return;sidebarOpen=false;const aside=document.querySelector('aside');if(aside){aside.classList.remove('open');document.body.classList.remove('sidebar-overlay');}const btn=document.querySelector('.hamburger');if(btn)btn.setAttribute('aria-expanded','false');}
var toolbarMoreOpen=false;
function toggleToolbarMore(){toolbarMoreOpen=!toolbarMoreOpen;const tb=document.querySelector('.toolbar');const btn=document.querySelector('.toolbar-more');const popover=document.querySelector('.toolbar-more-popover');
if(tb){if(toolbarMoreOpen){tb.classList.add('open-more');}else{tb.classList.remove('open-more');}}
if(btn)btn.setAttribute('aria-expanded',toolbarMoreOpen?'true':'false');
if(popover){if(toolbarMoreOpen){popover.classList.add('open');}else{popover.classList.remove('open');}}
}
function closeToolbarMore(){if(!toolbarMoreOpen)return;toolbarMoreOpen=false;const tb=document.querySelector('.toolbar');const btn=document.querySelector('.toolbar-more');const popover=document.querySelector('.toolbar-more-popover');if(tb)tb.classList.remove('open-more');if(btn)btn.setAttribute('aria-expanded','false');if(popover)popover.classList.remove('open');}
function clearSearch(){var s=document.getElementById('search');if(!s)return;s.value='';filterList();}
var settingsDirty=false;
function switchTab(tab){if(activeTab===tab)return;
if(activeTab==='settings'&&tab==='summary'&&settingsDirty){if(!confirm('You have unsaved changes. Discard them?'))return;}
var oldEl=document.getElementById(activeTab==='summary'?'tabSummary':'tabSettings');
activeTab=tab;
var s=document.getElementById('tabSummary');var st=document.getElementById('tabSettings');
const btns=document.querySelectorAll('.tab-btn');btns.forEach(b=>{b.classList.remove('active');b.setAttribute('aria-selected','false');});
var newEl=tab==='summary'?s:st;
if(tab==='summary'){btns[0].classList.add('active');btns[0].setAttribute('aria-selected','true');}else{btns[1].classList.add('active');btns[1].setAttribute('aria-selected','true');}
if(oldEl){oldEl.classList.add('exiting');setTimeout(function(){oldEl.classList.remove('exiting');oldEl.style.display='none';oldEl.setAttribute('aria-hidden','true');newEl.style.display='block';newEl.setAttribute('aria-hidden','false');},140);}
else{newEl.style.display='block';newEl.setAttribute('aria-hidden','false');}
if(tab==='settings'&&sel!==null)editVm();}
var serverDown=false;
var saveInFlight=false;
function setServerDown(s){serverDown=s;var b=document.getElementById('connbanner');if(b)b.style.display=s?'flex':'none';if(s)setStatus('Server unreachable — retrying...');}
async function refresh(){if(refreshBusy)return;if(transitioningIdx!==null||saveInFlight)return;refreshBusy=true;try{var listEl=document.getElementById('vmlist');if(!vms.length&&listEl){var skHtml='';for(var i=0;i<6;i++){skHtml+='<div class="skeleton sk-item" aria-hidden="true"></div>';}listEl.innerHTML=skHtml;listEl.setAttribute('aria-busy','true');}const r=await fetch('/api/vms');if(!r.ok){if(r.status>=500){if(!serverDown){setServerDown(true);}}return;}
setServerDown(false);vms=await r.json();renderList();if(sel!==null&&sel<vms.length)renderDetails();}catch(e){if(!serverDown){setServerDown(true);}}finally{refreshBusy=false;}}
function filterList(){const s=document.getElementById('search');if(!s)return;const f=s.value;const clr=document.getElementById('searchClear');if(clr)clr.style.display=f?'block':'none';renderList(f.toLowerCase());}
function renderList(filter){const e=document.getElementById('vmlist');if(!e)return;e.removeAttribute('aria-busy');const f=(filter||'').toLowerCase();let h='';
const viz=vms.map((v,i)=>({i,show:!f||(v.name||'').toLowerCase().includes(f),fav:v.favorite==='true',v}));
let hasFavs=false,hasNon=false,maxMem=16384;for(const x of viz){if(!x.show)continue;if(x.fav)hasFavs=true;else hasNon=true;const m=x.v.mem||0;if(m>maxMem)maxMem=m;}
function vmBars(v){var barMem=v.mem||1024;var memPct=Math.min(100,Math.round(barMem/maxMem*100));var cpu=v.cpu||1;var ch='',cs=Math.min(cpu,8);for(var j=0;j<cs;j++)ch+='<span class="cpu-dot"></span>';if(cpu>8)ch+='<span class="cpu-plus">+</span>';return '<div class="vm-bars"><span class="vm-bar-cpu">'+ch+'</span><span class="vm-bar-mem"><span class="vm-bar-fill" style="width:'+memPct+'%"></span><span class="vm-bar-mem-label">'+barMem+'MB</span></span></div>';}
for(const pass of[0,1]){if(pass===0){for(const x of viz){if(!x.show||!x.fav)continue;
const dotCls=x.v.status==='running'?'running':x.v.status==='paused'?'paused':x.v.status==='suspended'?'suspended':'';
const dotLabel=x.v.status==='running'?'Running':x.v.status==='paused'?'Paused':x.v.status==='suspended'?'Suspended':'Stopped';
h+=`<div class="vm-item${sel===x.i?' active':''}${transitioningIdx===x.i?' transitioning':''}" role="option" aria-selected="${sel===x.i?'true':'false'}" data-vm-index="${x.i}" tabindex="0" data-action="select" draggable="true"><span class="dot ${dotCls}" aria-label="${dotLabel}"></span> ${escHtml(x.v.name)}<span class="star fav" style="margin-left:auto;cursor:pointer" data-action="toggleFavorite" aria-label="Remove from favorites">★</span>${vmBars(x.v)}</div>`;}}
if(hasFavs&&hasNon)h+='<div style="color:var(--text-dim);font-size:11px;padding:4px 8px;border-bottom:1px solid var(--border);margin:4px 0">──────────</div>';
if(pass===1){for(const x of viz){if(!x.show||x.fav)continue;
const dotCls=x.v.status==='running'?'running':x.v.status==='paused'?'paused':x.v.status==='suspended'?'suspended':'';
const dotLabel=x.v.status==='running'?'Running':x.v.status==='paused'?'Paused':x.v.status==='suspended'?'Suspended':'Stopped';
h+=`<div class="vm-item${sel===x.i?' active':''}${transitioningIdx===x.i?' transitioning':''}" role="option" aria-selected="${sel===x.i?'true':'false'}" data-vm-index="${x.i}" tabindex="0" data-action="select" draggable="true"><span class="dot ${dotCls}" aria-label="${dotLabel}"></span> ${escHtml(x.v.name)}<span class="star" style="margin-left:auto;cursor:pointer" data-action="toggleFavorite" aria-label="Add to favorites">★</span>${vmBars(x.v)}</div>`;}}}
e.innerHTML=h||'<div style="color:var(--text-dim);font-size:12px">No VMs</div>';
let cnt=0,running=0,paused=0,suspended=0;for(let v of vms){cnt++;if(v.status==='running')running++;else if(v.status==='paused')paused++;else if(v.status==='suspended')suspended++;}
let parts=cnt+' virtual machine(s)';if(running>0)parts+=', '+running+' running';if(paused>0)parts+=', '+paused+' paused';if(suspended>0)parts+=', '+suspended+' suspended';
if(sel!==null&&sel<vms.length){const v=vms[sel];let st=v.name+' — '+v.status;if(v.started&&v.started>0&&v.status==='running'){const elapsed=Math.floor(Date.now()/1000)-v.started;const days=Math.floor(elapsed/86400);const hrs=Math.floor((elapsed%86400)/3600);const mins=Math.floor((elapsed%3600)/60);const secs=elapsed%60;st+=' | Uptime: '+(days>0?days+'d ':'')+hrs+':'+String(mins).padStart(2,'0')+':'+String(secs).padStart(2,'0');}st+='    |    '+parts;var sb=document.getElementById('statusbar');if(sb)sb.textContent=st;}
else{var sb2=document.getElementById('statusbar');if(sb2)sb2.textContent=parts;}}
async function toggleFavorite(i){if(i>=vms.length)return;const fav=vms[i].favorite==='true'?'0':'1';
const r=await apiPost('/api/save/'+i,'favorite='+fav);if(r){if(i<vms.length){vms[i].favorite=fav==='1'?'true':'false';}renderList();if(sel===i)renderDetails();}}
function select(i){if(i===sel)return;if(activeTab==='settings'&&settingsDirty&&sel!==i){if(!confirm('You have unsaved changes. Discard them?'))return;settingsDirty=false;}stopFb();sel=i;renderList();closeSidebar();closeToolbarMore();if(sel!==null){if(activeTab==='summary')renderDetails();else editVm();if(vms[sel]&&vms[sel].status==='running')startFb();}else{showEmptyState();}updatePowerBtn();}
function deselectVm(){if(activeTab==='settings'&&settingsDirty){if(!confirm('You have unsaved changes. Discard them?'))return;}stopFb();sel=null;renderList();showEmptyState();updatePowerBtn();}
function showEmptyState(){const t=document.getElementById('tabSummary');const s=document.getElementById('tabSettings');
const nm=document.getElementById('vmname');const tb=document.getElementById('tabBar');
if(!t||!s||!nm||!tb)return;
nm.textContent='Select a VM';tb.style.display='none';
t.setAttribute('aria-hidden','true');s.setAttribute('aria-hidden','true');
t.innerHTML='<div class="empty-state"><svg class="empty-icon"><use href="#icon-monitor"/></svg><h3>No Virtual Machine Selected</h3><p>Select a VM from the sidebar to view its details, or create a new one.</p></div>';
s.innerHTML='<div class="empty-state"><svg class="empty-icon"><use href="#icon-settings"/></svg><h3>No Virtual Machine Selected</h3><p>Select a VM from the sidebar to edit its settings.</p></div>';}
function renderDetails(){if(sel===null||sel>=vms.length){showEmptyState();return;}
const tb=document.getElementById('tabBar');const nm=document.getElementById('vmname');const ts=document.getElementById('tabSummary');
if(!tb||!nm||!ts)return;
tb.style.display='flex';
const v=vms[sel];const sc=v.status==='running'?'running':v.status==='paused'?'paused':v.status==='suspended'?'suspended':'stopped';
nm.textContent=v.name;
let h='<div class="summary-grid">';
h+=`<div class="summary-card ${sc}"><div class="card-label">State</div><div class="card-value ${sc}">${escHtml(v.status)}</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Guest OS</div><div class="card-value">${escHtml(v.os)}</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Memory</div><div class="card-value">${escHtml(v.mem)} MB</div></div>`;
h+=`<div class="summary-card"><div class="card-label">CPU</div><div class="card-value">${escHtml(v.cpu)} cores</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Hard Disk</div><div class="card-value">${escHtml(v.disk)} GB</div></div>`;
if(v.iso_path)h+=`<div class="summary-card"><div class="card-label">CD/DVD</div><div class="card-value">${escHtml(v.iso_path)}</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Network</div><div class="card-value">${escHtml(v.net)}</div></div>`;
if(v.mac)h+=`<div class="summary-card"><div class="card-label">MAC</div><div class="card-value">${escHtml(v.mac)}</div></div>`;
if(v.nic2_mode&&v.nic2_mode!=='none')h+=`<div class="summary-card"><div class="card-label">NIC 2</div><div class="card-value">${escHtml(v.nic2_mode)}</div></div>`;
if(v.nic3_mode&&v.nic3_mode!=='none')h+=`<div class="summary-card"><div class="card-label">NIC 3</div><div class="card-value">${escHtml(v.nic3_mode)}</div></div>`;
if(v.shared_folder)h+=`<div class="summary-card"><div class="card-label">Shared Folder</div><div class="card-value">${escHtml(v.shared_folder)}</div></div>`;
if(v.usb_device)h+=`<div class="summary-card"><div class="card-label">USB Device</div><div class="card-value">${escHtml(v.usb_device)}</div></div>`;
if(v.guest_tools==='true')h+=`<div class="summary-card"><div class="card-label">Guest Tools</div><div class="card-value">✓ installed</div></div>`;
if(v.autoprotect==='true')h+=`<div class="summary-card"><div class="card-label">AutoProtect</div><div class="card-value">every ${escHtml(v.autoprotect_interval)} min, keep ${escHtml(v.autoprotect_max)}</div></div>`;
if(v.hasDisk2==='true')h+=`<div class="summary-card"><div class="card-label">Disk 2</div><div class="card-value">${escHtml(v.disk2_size)} GB</div></div>`;
if(v.hasFloppy==='true')h+=`<div class="summary-card"><div class="card-label">Floppy</div><div class="card-value">attached</div></div>`;
if(v.port_forwards)h+=`<div class="summary-card"><div class="card-label">Port Forwards</div><div class="card-value">${escHtml(v.port_forwards)}</div></div>`;
if(v.notes)h+=`<div class="summary-card"><div class="card-label">Notes</div><div class="card-value">${escHtml(v.notes)}</div></div>`;
h+='</div>';
ts.innerHTML=h;
updatePowerBtn();}
async function powerToggle(){const idx=sel;if(idx===null)return;const v=vms[idx];if(v&&(v.status==='running'||v.status==='paused')){if(!confirm('Power off VM "'+v.name+'"?\nUnsaved data may be lost.'))return;}
var btn=document.getElementById('powerbtn');if(btn){btn.disabled=true;btn.textContent='...';}
transitioningIdx=idx;renderList();
try{const r=await apiPost('/api/power/'+idx);transitioningIdx=null;if(r){try{await refresh();}catch(e){setStatus('Refresh after power toggle failed: '+e.message);renderList();}finally{if(btn){updatePowerBtn();btn.disabled=false;}}}else{if(btn){updatePowerBtn();btn.disabled=false;}renderList();}}catch(e){transitioningIdx=null;if(btn){updatePowerBtn();btn.disabled=false;}renderList();setStatus('Power toggle failed: '+e.message);}}
async function shutdownGuest(){if(sel===null)return;const v=vms[sel];if(!confirm('Send ACPI shutdown to "'+v.name+'"?'))return;const r=await apiPost('/api/shutdown/'+sel);if(r)setStatus('Shut down guest — ACPI power button sent.');}
async function resetGuest(){if(sel===null)return;const v=vms[sel];if(!confirm('Reset guest "'+v.name+'"?\nUnsaved data in the guest may be lost.'))return;const r=await apiPost('/api/reset/'+sel);if(r)setStatus('Reset guest — system_reset sent.');}
async function pauseGuest(){if(sel===null)return;const r=await apiPost('/api/pause/'+sel);if(r){await refresh();setStatus('Paused guest — execution frozen.');}}
async function resumeGuest(){if(sel===null)return;const r=await apiPost('/api/resume/'+sel);if(r){await refresh();setStatus('Resumed guest — execution continued.');}}
async function renameGuest(){if(sel===null)return;const v=vms[sel];const n=prompt('Rename VM:',v.name);if(n===null)return;const trimmed=n.trim();if(!trimmed){showToast('Name cannot be empty or whitespace','error');return;}if(trimmed===v.name)return;const r=await apiPost('/api/rename/'+sel,'name='+encodeURIComponent(trimmed));if(r)await refresh();}
async function suspendGuest(){if(sel===null)return;const v=vms[sel];if(!confirm('Suspend VM "'+v.name+'" to disk?\\nThe VM state will be saved and the VM will be paused.'))return;const r=await apiPost('/api/suspend/'+sel);if(r){await refresh();setStatus('Suspended VM to disk.');}}
async function cloneGuest(){if(sel===null)return;var cn=document.getElementById('clone_name');var cd=document.getElementById('clonedlg');if(cn)cn.textContent=vms[sel].name;if(cd)cd.showModal();}
async function doClone(linked){if(sel===null)return;const body=linked?'linked=1':'';const r=await apiPost('/api/clone/'+sel,body);if(r){var cd=document.getElementById('clonedlg');if(cd)cd.close();await refresh();setStatus(linked?'Linked clone created.':'VM cloned.');}}
async function importGuest(){const p=prompt('Path to VM disk image (.qcow2):');const trimmed=p?p.trim():'';if(!trimmed){showToast('A file path is required','error');return;}if(trimmed.includes('..')){showToast('Invalid path: parent directory traversal not allowed','error');return;}if(!/\.(qcow2|qcow|vmdk|vdi|vhdx|raw|img)$/i.test(trimmed)){showToast('Path should end with a disk image extension (.qcow2, .vmdk, etc.)','warn');}const r=await apiPost('/api/import','path='+encodeURIComponent(trimmed));if(r){await refresh();setStatus('VM imported.');}}
async function batchStart(){const snap=vms.slice();var started=0,failed=0,total=0;for(let i=0;i<snap.length;i++){if(snap[i].status==='stopped')total++;}
for(let i=0;i<snap.length;i++){if(snap[i].status==='stopped'){setStatus('Batch start: VM '+(started+failed+1)+' of '+total+'...');const r=await apiPost('/api/power/'+i);if(r){started++;}else{failed++;setStatus('Batch start: VM '+(started+failed)+' of '+total+' failed, continuing...');}}}await refresh();setStatus('Batch start complete: '+started+' started'+(failed>0?', '+failed+' failed':''));}
async function batchStop(){const snap=vms.slice();var stopped=0,failed=0,total=0;for(let i=0;i<snap.length;i++){if(snap[i].status==='running'||snap[i].status==='paused')total++;}
if(!confirm('Power off ALL running VMs?\nUnsaved data may be lost.'))return;
for(let i=0;i<snap.length;i++){if(snap[i].status==='running'||snap[i].status==='paused'){setStatus('Batch stop: VM '+(stopped+failed+1)+' of '+total+'...');const r=await apiPost('/api/power/'+i);if(r){stopped++;}else{failed++;setStatus('Batch stop: VM '+(stopped+failed)+' of '+total+' failed, continuing...');}}}await refresh();setStatus('Batch stop complete: '+stopped+' stopped'+(failed>0?', '+failed+' failed':''));}
async function takeSnapshot(){if(sel===null)return;openSnapshots();}
async function takeSnapshotFromDlg(){if(sel===null)return;const st=document.getElementById('s_tag');if(!st)return;const t=st.value;if(!t){alert('Enter a tag name');return;}
var takeBtn=document.querySelector('[data-action="takeSnapshotFromDlg"]');if(takeBtn){takeBtn.disabled=true;takeBtn.textContent='Taking...';}
const r=await apiPost('/api/snapshot/take/'+sel,'tag='+encodeURIComponent(t));if(r){st.value='';loadSnapshots();setStatus('Snapshot taken: '+t);}
if(takeBtn){takeBtn.disabled=false;takeBtn.textContent='Take';}}
async function openSnapshots(){if(sel===null)return;var sd=document.getElementById('snapdlg');if(sd)sd.showModal();loadSnapshots();}
async function loadSnapshots(){if(sel===null)return;const el=document.getElementById('snaplist');if(!el)return;
try{const r=await fetch('/api/snapshot/list/'+sel);if(!r.ok){el.innerHTML='<div style="color:var(--text-dim)">Failed to load snapshots</div>';return;}const t=(await r.text()).trim();
if(!t||t==='(none)'){el.innerHTML='<div style="color:var(--text-dim)">No snapshots</div>';return;}
const lines=t.split('\n');let h='';for(const ln of lines){const tag=ln.trim();if(!tag)continue;
h+=`<div style="padding:4px 0;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center"><span>${escHtml(tag)}</span><span><button class="btn" style="padding:2px 8px;font-size:11px" data-action="revertSnapshot" data-snap-tag="${escHtml(tag)}">Revert</button><button class="btn danger" style="padding:2px 8px;font-size:11px" data-action="deleteSnapshot" data-snap-tag="${escHtml(tag)}">Del</button></span></div>`;}
el.innerHTML=h;}catch(e){el.innerHTML='<div style="color:var(--text-dim)">Failed to load snapshots</div>';}}
async function revertSnapshot(tag){if(sel===null||!tag)return;if(!confirm('Revert to snapshot "'+tag+'"? This will discard current state.'))return;
const r=await apiPost('/api/snapshot/revert/'+sel,'tag='+encodeURIComponent(tag));if(r){setStatus('Reverted to snapshot: '+tag);var sd=document.getElementById('snapdlg');if(sd)sd.close();}}
async function deleteSnapshot(tag){if(sel===null||!tag)return;if(!confirm('Delete snapshot "'+tag+'"?'))return;
const r=await apiPost('/api/snapshot/delete/'+sel,'tag='+encodeURIComponent(tag));if(r){loadSnapshots();setStatus('Deleted snapshot: '+tag);}}
async function sendCad(){if(sel===null)return;const r=await apiPost('/api/cad/'+sel);if(r)setStatus('Ctrl+Alt+Del sent to guest.');}
async function exportOvf(){if(sel===null)return;try{const r=await fetch('/api/export/'+sel,{method:'POST',headers:{'X-API-Key':'kvmgui'}});if(!r.ok){setStatus('Export failed: '+r.status);return;}const blob=await r.blob();const a=document.createElement('a');const url=URL.createObjectURL(blob);a.href=url;a.download=vms[sel].name+'.ova';a.click();setTimeout(function(){URL.revokeObjectURL(url);},60000);setStatus('Export downloaded.');}catch(e){setStatus('Export error: '+e);}}
async function migrateGuest(){if(sel===null)return;var vm=vms[sel];var mv=document.getElementById('migrate_vmname');if(mv)mv.textContent='Migrating: '+vm.name;var md=document.getElementById('migratedlg');if(md){updateMigUri();md.showModal();}}
function updateMigUri(){var host=document.getElementById('mig_host');var port=document.getElementById('mig_port');var uri=document.getElementById('mig_uri');if(host&&port&&uri){uri.value='tcp:'+host.value+':'+port.value;}}
async function doMigrate(){if(sel===null)return;var host=document.getElementById('mig_host');var port=document.getElementById('mig_port');if(!host||!port)return;var h=host.value.trim();var p=parseInt(port.value)||0;if(!h){showToast('Target host is required','error');return;}if(p<1||p>65535){showToast('Port must be 1–65535','error');return;}var dest='tcp:'+h+':'+p;var r=await apiPost('/api/migrate/'+sel,'dest='+encodeURIComponent(dest));if(!r)return;try{var j=JSON.parse(r);if(j.status!=='started'){showToast('Migration failed to start','error');return;}}catch(e){}var md=document.getElementById('migratedlg');if(md)md.close();showMigProgress();pollMigStatus();}
var migPollTimer=null;
function showMigProgress(){var bar=document.getElementById('mig_progress');var info=document.getElementById('mig_pct');var cancel=document.getElementById('mig_cancel');if(bar&&info){bar.style.display='block';info.style.display='inline';info.textContent='Migration in progress...';}if(cancel)cancel.style.display='inline';}
function hideMigProgress(){if(migPollTimer){clearTimeout(migPollTimer);migPollTimer=null;}var bar=document.getElementById('mig_progress');var info=document.getElementById('mig_pct');var cancel=document.getElementById('mig_cancel');if(bar)bar.style.display='none';if(info)info.style.display='none';if(cancel)cancel.style.display='none';}
async function pollMigStatus(){if(sel===null){hideMigProgress();return;}
var t='';try{var resp=await fetch('/api/migrate/status/'+sel);t=await resp.text();}catch(e){}
var info=document.getElementById('mig_pct');var bar=document.getElementById('mig_progress');
if(!info||!bar)return;
if(!t){info.textContent='Migration failed — connection lost';hideMigProgress();setStatus('Migration failed');return;}
try{
var s=JSON.parse(t);
if(s.status==='completed'){info.textContent='Migration completed.';bar.style.width='100%';bar.style.background='var(--success)';setStatus('Migration completed');setTimeout(hideMigProgress,3000);return;}
if(s.status==='failed'||s.status==='error'){info.textContent='Migration failed.';bar.style.background='var(--danger)';setStatus('Migration failed');setTimeout(hideMigProgress,3000);return;}
if(s.status==='cancelled'){info.textContent='Migration cancelled.';bar.style.background='var(--amber)';setStatus('Migration cancelled');setTimeout(hideMigProgress,3000);return;}
info.textContent='Migration '+s.status+'...';
}catch(e){info.textContent='Migration polling error';}
migPollTimer=setTimeout(pollMigStatus,500);}
async function cancelMigrate(){var r=await apiPost('/api/migrate/cancel/'+sel,'');if(r){var info=document.getElementById('mig_pct');if(info)info.textContent='Cancelling...';setStatus('Migration cancel requested');}}
function updatePowerBtn(){const b=document.getElementById('powerbtn');if(!b)return;if(sel===null||sel>=vms.length){b.textContent='▶ Power On';b.className='btn primary';return;}
const v=vms[sel];if(v.status==='running'||v.status==='paused'){b.textContent='⏹ Power Off';b.className='btn danger';}else{b.textContent='▶ Power On';b.className='btn primary';}}
function newVm(){var d=document.getElementById('newdlg');if(d)d.showModal();}
async function createVm(){const nn=document.getElementById('n_name');const nm=document.getElementById('n_mem');const nc=document.getElementById('n_cpu');const nd=document.getElementById('n_disk');
if(!nn||!nm||!nc||!nd)return;
const n=nn.value.trim();const m=parseInt(nm.value)||0;
const c=parseInt(nc.value)||0;const d=parseInt(nd.value)||0;
if(!n){showToast('VM name is required','error');return;}
if(m<128||m>65536){showToast('Memory must be 128–65536 MB','error');return;}
if(c<1||c>256){showToast('CPU cores must be 1–256','error');return;}
if(d<1||d>65536){showToast('Disk size must be 1–65536 GB','error');return;}
const r=await apiPost('/api/new','name='+encodeURIComponent(n)+'&mem='+m+'&cpu='+c+'&disk='+d);if(r){var ndlg=document.getElementById('newdlg');if(ndlg)ndlg.close();await refresh();}}
async function deleteVm(){if(sel===null)return;if(!confirm('Delete this VM?'))return;var deleted=vms[sel];var deletedIdx=sel;var r=await apiPost('/api/delete/'+sel);if(r){sel=null;var delName=deleted.name;await refresh();toastUndo('Deleted "'+escHtml(delName)+'"',async function(){var body='name='+encodeURIComponent(delName);var fm=[['mem','mem'],['cpu','cpu'],['cpu_sockets','cpu_sockets'],['disk','disk'],['disk_format','disk_format'],['guest_os','guest_os'],['net','network'],['fw','firmware'],['mac','mac_address'],['nic2_mode','nic2'],['nic3_mode','nic3'],['iso_path','iso_path'],['shared_folder','shared_folder'],['usb_device','usb'],['guest_tools','guest_tools'],['autoprotect','autoprotect'],['autoprotect_interval','ap_interval'],['autoprotect_max','ap_max'],['disk2_path','disk2_path'],['disk2_size','disk2_size'],['disk2_format','disk2_format'],['floppy_path','floppy'],['nic2_mac','nic2_mac'],['nic3_mac','nic3_mac'],['port_forwards','portfw'],['display','display'],['display_resolution','display_resolution'],['vnc_port','vnc_port'],['spice_port','spice_port'],['hasSerial','enable_serial'],['num_displays','num_displays'],['favorite','favorite'],['notes','notes'],['enable_3d','enable_3d'],['gpu_device','gpu_device'],['audio','audio'],['boot_order','boot_order'],['accel','accel'],['embed_display','embed_display']];fm.forEach(function(m){var v=deleted[m[0]];if(v!==undefined&&v!==null&&v!=='')body+='&'+m[1]+'='+encodeURIComponent(v);});await apiPost('/api/create',body);await refresh();});}}
function reorderVm(from,to){var oldFrom=from,oldTo=to,oldSel=sel;apiPost('/api/reorder','from='+from+'&to='+to).then(function(r){if(r){sel=to;refresh();toastUndo('Moved "'+escHtml(vms[to]?vms[to].name:'VM')+'"',function(){apiPost('/api/reorder','from='+oldTo+'&to='+oldFrom).then(function(r2){if(r2){sel=oldSel;refresh();}});});}});}
function editVm(){if(sel===null)return;if(activeTab==='settings'&&settingsDirty){if(!confirm('You have unsaved changes. Discard them?'))return;}switchTab('settings');if(sel===null||sel>=vms.length)return;
const v=vms[sel];
var tb=document.getElementById('tabBar');var nm=document.getElementById('vmname');if(tb)tb.style.display='flex';if(nm)nm.textContent=v.name;
const fields=[
{s:'Basic'},['Name','e_name','text',v.name||'','required maxlength="128"'],['Guest OS','e_guest_os','select',v.guest_os||0],
['Memory (MB)','e_mem','number',v.mem||2048,'required min="128" max="65536" step="1"'],['CPU Cores','e_cpu','number',v.cpu||2,'required min="1" max="256" step="1"'],
['CPU Sockets','e_cpu_sockets','number',v.cpu_sockets||1,'min="1" max="64" step="1"'],
['Disk Size (GB)','e_disk','number',v.disk||20,'required min="1" max="65536" step="1"'],['Disk Format','e_disk_format','select',v.disk_format||0],
['ISO Path','e_iso_path','text',v.iso_path||''],['Firmware','e_firmware','select',v.fw||'bios'],
['Boot Order','e_boot_order','select',v.boot_order||0],
{s:'Network &amp; Boot'},['Network','e_network','select',v.net||'user'],['MAC Address','e_mac_address','text',v.mac_address||'','pattern="([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"'],
['NIC 2','e_nic2','select',v.nic2_mode||'none'],['NIC 2 MAC','e_nic2_mac','text',v.nic2_mac||'','pattern="([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"'],
['NIC 3','e_nic3','select',v.nic3_mode||'none'],['NIC 3 MAC','e_nic3_mac','text',v.nic3_mac||'','pattern="([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"'],
['Port Forwards','e_portfw','text',v.port_forwards||''],
{s:'Sharing'},['Shared Folder','e_shared_folder','text',v.shared_folder||''],['USB Device','e_usb','text',v.usb_device||''],
['Guest Tools','e_guest_tools','select',v.guest_tools==='true'?'1':'0'],
{s:'AutoProtect'},['AutoProtect','e_autoprotect','select',v.autoprotect==='true'?'1':'0'],
['AP Interval','e_ap_interval','number',v.autoprotect_interval||60,'min="1" max="1440" step="1"'],
['AP Max','e_ap_max','number',v.autoprotect_max||10,'min="1" max="100" step="1"'],
{s:'Display &amp; Video'},['Display','e_display','select',v.display||0],['Display Res','e_display_resolution','select',v.display_resolution||0],
['3D Accel','e_enable_3d','select',v.enable_3d==='true'?'1':'0'],['GPU Device','e_gpu_device','select',v.gpu_device||0],
['Embed Display','e_embed_display','select',v.embed_display==='true'?'1':'0'],['Serial','e_enable_serial','select',v.enable_serial==='true'?'1':'0'],
['Num Displays','e_num_displays','number',v.num_displays||1,'min="1" max="16" step="1"'],
['VNC Port','e_vnc_port','number',v.vnc_port||5900,'min="1" max="65535" step="1"'],['SPICE Port','e_spice_port','number',v.spice_port||5901,'min="1" max="65535" step="1"'],
['Accelerator','e_accel','select',v.accel||'auto'],['Audio','e_audio','select',v.audio||0],
{s:'Storage &amp; Notes'},['Disk 2 Path','e_disk2_path','text',v.disk2_path||''],['Disk 2 Size','e_disk2_size','number',v.disk2_size||0,'min="0" max="65536" step="1"'],
['Disk 2 Format','e_disk2_format','select',v.disk2_format||0],['Floppy','e_floppy','text',v.floppy_path||''],
['Favorite','e_favorite','select',v.favorite==='true'?'1':'0'],['Notes','e_notes','text',v.notes||''],
{s:'QEMU Capabilities'},
['Guest Agent','e_guest_agent','select',v.guest_agent==='true'?'1':'0'],
['virtio-rng Entropy','e_virtio_rng','select',v.virtio_rng==='true'?'1':'0'],
['TPM','e_tpm','select',v.tpm==='true'?'1':'0'],
['Secure Boot','e_secure_boot','select',v.secure_boot==='true'?'1':'0'],
['Hyper-V Enlightenments','e_hyperv_enlightenments','select',v.hyperv_enlightenments==='true'?'1':'0'],
['Hugepages','e_hugepages','select',v.hugepages==='true'?'1':'0'],
['Watchdog','e_watchdog','select',v.watchdog||0],
['Ballooning','e_ballooning','select',v.ballooning==='true'?'1':'0'],
['Host Autostart','e_host_autostart','select',v.host_autostart==='true'?'1':'0'],
['I/O Threads','e_io_threads','number',v.io_threads||0,'min="0" max="64" step="1"'],
['Disk BPS Throttle','e_disk_bps_throttle','number',v.disk_bps_throttle||0,'min="0" step="1"'],
['Disk IOPS Throttle','e_disk_iops_throttle','number',v.disk_iops_throttle||0,'min="0" step="1"']];
const selects={e_network:[['user','NAT (User)'],['bridge','Bridged'],['none','None']],
e_firmware:[['bios','BIOS'],['uefi','UEFI']],e_disk_format:[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']],
e_disk2_format:[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']],
e_enable_3d:[['0','No'],['1','Yes']],e_gpu_device:[['0','Virtio-GPU'],['1','Virtio-VGA']],
e_display:[['0','GTK'],['1','SDL'],['2','SPICE'],['3','VNC'],['4','None']],
e_display_resolution:[['0','Auto'],['1','800x600'],['2','1024x768'],['3','1280x800'],['4','1920x1080']],
e_guest_os:[['0','Linux'],['1','Windows'],['2','FreeBSD'],['3','macOS'],['4','Other']],
e_audio:[['0','None'],['1','Intel HDA'],['2','AC97']],e_boot_order:[['0','Hard Disk'],['1','CD/DVD'],['2','PXE']],
e_accel:[['auto','Auto (best available)'],['tcg','TCG (software)'],['kvm','KVM (Linux)'],['hvf','HVF (macOS)'],['whpx','WHPX (Windows)']],e_embed_display:[['0','No'],['1','Yes']],
e_enable_serial:[['0','No'],['1','Yes']],e_favorite:[['0','No'],['1','Yes']],
e_guest_tools:[['0','No'],['1','Yes']],e_autoprotect:[['0','Off'],['1','On']],
e_nic2:[['none','None'],['user','NAT'],['bridge','Bridged']],
e_nic3:[['none','None'],['user','NAT'],['bridge','Bridged']],
e_guest_agent:[['0','No'],['1','Yes']],e_virtio_rng:[['0','No'],['1','Yes']],
e_tpm:[['0','No'],['1','Yes']],e_secure_boot:[['0','No'],['1','Yes']],
e_hyperv_enlightenments:[['0','No'],['1','Yes']],e_hugepages:[['0','No'],['1','Yes']],
e_ballooning:[['0','No'],['1','Yes']],e_host_autostart:[['0','No'],['1','Yes']],
e_watchdog:[['0','None'],['1','Reset Guest'],['2','Power Off Guest'],['3','Pause Guest']]};
let h='<div class="settings-form">';
for(const f of fields){
if(f.s!==undefined){h+=`<h4 class="form-section-header">${f.s}</h4>`;continue;}
const[lbl,id,type,val]=f;const attrs=f.length>4?f[4]:'';h+='<div class="field-group">';
h+=`<label for="${id}">${lbl}</label>`;
if(type==='select'&&selects[id]){h+=`<select id="${id}">`;
for(const[ov,ol]of selects[id])h+=`<option value="${ov}"${ov===String(val)?' selected':''}>${ol}</option>`;
h+='</select>';}else{h+=`<input id="${id}" type="${type}" value="${escHtml(String(val))}" ${attrs}>`;}
h+='</div>';}
h+='</div><div class="btn-row" style="margin-top:20px"><button id="savevmbtn" class="btn primary" data-action="saveVm" title="Save VM settings">Save Changes</button></div>';
var ts=document.getElementById('tabSettings');if(ts)ts.innerHTML=h;settingsDirty=false;}
async function saveVm(){const idx=sel;if(idx===null)return;const btn=document.getElementById('savevmbtn');if(btn){btn.disabled=true;btn.textContent='Saving...';}
saveInFlight=true;
const formEls=document.querySelectorAll('#tabSettings input, #tabSettings select, #tabSettings button');for(let i=0;i<formEls.length;i++)formEls[i].disabled=true;
const body=['name','mem','cpu','cpu_sockets','disk','disk_format','iso_path','mac_address','network','firmware','shared_folder','usb','guest_tools','autoprotect',
'ap_interval','ap_max','disk2_path','disk2_size','disk2_format','floppy','nic2','nic2_mac','nic3','nic3_mac','portfw','notes',
'enable_3d','gpu_device','display','display_resolution','guest_os','audio','boot_order',
'accel','embed_display','vnc_port','spice_port','enable_serial','num_displays','favorite',
'guest_agent','virtio_rng','tpm','secure_boot','hyperv_enlightenments','hugepages','watchdog','ballooning','host_autostart',
'io_threads','disk_bps_throttle','disk_iops_throttle']
.map(id=>{const el=document.getElementById('e_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
try{const r=await apiPost('/api/save/'+idx,body);if(r){settingsDirty=false;await refresh();switchTab('summary');setStatus('Settings saved.');}
else{setStatus('Save failed.');}}catch(e){setStatus('Save failed: '+e.message);}finally{if(btn){btn.disabled=false;btn.textContent='Save Changes';}
saveInFlight=false;
for(let i=0;i<formEls.length;i++)formEls[i].disabled=false;}}
// ── VNet Editor ──
let vnetsData=[],vnetIdx=-1;
async function openVnets(){await loadVnets();var vd=document.getElementById('vnetdlg');if(vd)vd.showModal();}
async function loadVnets(){try{const r=await fetch('/api/vnets');if(r.ok){vnetsData=await r.json();}else{vnetsData={networks:[]};console.error('Failed to load VNets:',r.status);}}catch(e){vnetsData={networks:[]};console.error('Failed to load VNets:',e);}renderVnetList();}
function renderVnetList(){const sel=document.getElementById('vnet_sel');if(!sel)return;let h='';if(!vnetsData.networks)vnetsData={networks:[]};
for(let i=0;i<vnetsData.networks.length;i++){const n=vnetsData.networks[i];const line=escHtml(n.name)+' — '+escHtml(n.type);h+=`<option value="${i}"${i===vnetIdx?' selected':''}>${line}</option>`;}
sel.innerHTML=h;if(vnetIdx>=0&&vnetIdx<vnetsData.networks.length){showVnetFields(vnetIdx);}else{clearVnetFields();}}
function clearVnetFields(){['vn_name','vn_type','vn_subnet','vn_mask','vn_dhcp','vn_dstart','vn_dend','vn_iface','vn_gw','vn_pf'].forEach(function(id){var el=document.getElementById(id);if(el)el.value='';});var vt=document.getElementById('vn_type');if(vt)vt.value='nat';var vd=document.getElementById('vn_dhcp');if(vd)vd.value='0';}
function onVnetSelect(){const s=document.getElementById('vnet_sel');if(!s)return;vnetIdx=parseInt(s.value);if(vnetIdx>=0)showVnetFields(vnetIdx);}
function showVnetFields(i){const n=vnetsData.networks[i];if(!n)return;
var vn=document.getElementById('vn_name');if(!vn)return;vn.value=n.name||'';
var vt=document.getElementById('vn_type');if(vt)vt.value=n.type||'nat';
var vs=document.getElementById('vn_subnet');if(vs)vs.value=n.subnet||'';
var vm=document.getElementById('vn_mask');if(vm)vm.value=n.mask||'';
var vd=document.getElementById('vn_dhcp');if(vd)vd.value=n.dhcp?'1':'0';
var vds=document.getElementById('vn_dstart');if(vds)vds.value=n.dhcp_start||'';
var vde=document.getElementById('vn_dend');if(vde)vde.value=n.dhcp_end||'';
var vi=document.getElementById('vn_iface');if(vi)vi.value=n.host_iface||'';
var vg=document.getElementById('vn_gw');if(vg)vg.value=n.gateway||'';
var vp=document.getElementById('vn_pf');if(vp)vp.value=n.port_forwards||'';}
function vnetSaveCurrent(){if(vnetIdx<0||vnetIdx>=vnetsData.networks.length)return;const n=vnetsData.networks[vnetIdx];
var vn=document.getElementById('vn_name');if(!vn)return;
const name=vn.value.trim();if(!name){showToast('Network name is required','error');return;}
var vt=document.getElementById('vn_type');var vs=document.getElementById('vn_subnet');
var vm=document.getElementById('vn_mask');var vd=document.getElementById('vn_dhcp');
var vds=document.getElementById('vn_dstart');var vde=document.getElementById('vn_dend');
var vi=document.getElementById('vn_iface');var vg=document.getElementById('vn_gw');
var vp=document.getElementById('vn_pf');
const subnet=(vs?vs.value:'').trim();const mask=(vm?vm.value:'').trim();
const dstart=(vds?vds.value:'').trim();const dend=(vde?vde.value:'').trim();
const gw=(vg?vg.value:'').trim();const iface=(vi?vi.value:'').trim();
if(subnet&&!/^\d{1,3}(\.\d{1,3}){3}$/.test(subnet)){showToast('Invalid subnet format','error');return;}
if(mask&&!/^\d{1,3}(\.\d{1,3}){3}$/.test(mask)){showToast('Invalid mask format','error');return;}
if(dstart&&!/^\d{1,3}(\.\d{1,3}){3}$/.test(dstart)){showToast('Invalid DHCP start IP format','error');return;}
if(dend&&!/^\d{1,3}(\.\d{1,3}){3}$/.test(dend)){showToast('Invalid DHCP end IP format','error');return;}
if(gw&&!/^\d{1,3}(\.\d{1,3}){3}$/.test(gw)){showToast('Invalid gateway IP format','error');return;}
// strip control characters from name/iface
n.name=name.replace(/[\x00-\x1f\x7f]/g,'');n.type=vt?vt.value:'nat';
n.subnet=subnet;n.mask=mask;
n.dhcp=vd?vd.value==='1':false;n.dhcp_start=dstart;
n.dhcp_end=dend;n.host_iface=iface.replace(/[\x00-\x1f\x7f]/g,'');
n.gateway=gw;n.port_forwards=(vp?vp.value||'':'').replace(/[\x00-\x1f\x7f]/g,'');renderVnetList();}
function vnetAdd(){if(vnetsData.networks.length>=20)return;const n={name:'VMnet'+vnetsData.networks.length,type:'host_only',subnet:'192.168.100.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.100.128',dhcp_end:'192.168.100.254',host_iface:'',gateway:'',port_forwards:''};
vnetsData.networks.push(n);vnetIdx=vnetsData.networks.length-1;renderVnetList();}
function vnetRemove(){if(vnetIdx<0||vnetIdx>=vnetsData.networks.length)return;vnetsData.networks.splice(vnetIdx,1);if(vnetIdx>=vnetsData.networks.length)vnetIdx=vnetsData.networks.length-1;renderVnetList();}
function vnetDefaults(){const def=[{name:'VMnet0',type:'bridged',subnet:'',mask:'',dhcp:false,dhcp_start:'',dhcp_end:'',host_iface:'auto',gateway:'',port_forwards:''},{name:'VMnet1',type:'host_only',subnet:'192.168.118.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.118.128',dhcp_end:'192.168.118.254',host_iface:'',gateway:'',port_forwards:''},{name:'VMnet8',type:'nat',subnet:'192.168.140.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.140.128',dhcp_end:'192.168.140.254',host_iface:'',gateway:'192.168.140.2',port_forwards:'2222:192.168.140.128:22'}];
vnetsData={networks:def};vnetIdx=0;renderVnetList();}
async function vnetSaveAll(){const r=await apiPost('/api/vnets/save',JSON.stringify(vnetsData));if(r){var vd=document.getElementById('vnetdlg');if(vd)vd.close();setStatus('VNet settings saved.');}}
// ── Preferences ──
var pendingTheme=null;
async function openPrefs(){var pd=document.getElementById('prefsdlg');if(!pd)return;let cfg={};try{const r=await fetch('/api/config');if(r.ok)cfg=await r.json();}catch(e){console.error('Failed to load config:',e);}
var pt=document.getElementById('p_theme');if(pt)pt.value=cfg.theme||window.kvmguiTheme||'system';
var pdm=document.getElementById('p_default_memory_mb');if(pdm)pdm.value=cfg.default_memory_mb||2048;
var pdc=document.getElementById('p_default_cpu_cores');if(pdc)pdc.value=cfg.default_cpu_cores||2;
var pae=document.getElementById('p_autoprotect_enabled');if(pae)pae.value=cfg.autoprotect_enabled_default?'1':'0';
var pai=document.getElementById('p_autoprotect_interval');if(pai)pai.value=cfg.autoprotect_interval_min_default||60;
var pam=document.getElementById('p_autoprotect_max');if(pam)pam.value=cfg.autoprotect_max_default||10;
pd.showModal();}
function openAbout(){var ad=document.getElementById('aboutdlg');if(ad)ad.showModal();}
async function savePrefs(){const body=['theme','default_memory_mb','default_cpu_cores','autoprotect_enabled','autoprotect_interval','autoprotect_max']
.map(id=>{const el=document.getElementById('p_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
const r=await apiPost('/api/config',body);if(r){if(pendingTheme!==null){window.applyTheme(pendingTheme);pendingTheme=null;}var pd=document.getElementById('prefsdlg');if(pd)pd.close();setStatus('Preferences saved.');}}
// ── Dialog Focus Trap + Backdrop Click-to-Close ──
var dialogFocusStack=[];
var FOCUSABLE='a[href],button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])';
function trapFocus(dlg){if(dlg._trapFocusHandler)return;var prev=document.activeElement;var items=dlg.querySelectorAll(FOCUSABLE);if(!items.length)return;var first=items[0],last=items[items.length-1];function onKey(e){if(e.key!=='Tab')return;if(e.shiftKey){if(document.activeElement===first){e.preventDefault();last.focus();}}else{if(document.activeElement===last){e.preventDefault();first.focus();}}};dlg._trapFocusHandler=onKey;dlg.addEventListener('keydown',onKey);first.focus();dialogFocusStack.push({dlg:dlg,prev:prev});}
function releaseFocus(dlg){var handler=dlg._trapFocusHandler;if(handler){dlg.removeEventListener('keydown',handler);delete dlg._trapFocusHandler;}dlg.dispatchEvent(new Event('trap-release'));for(var i=dialogFocusStack.length-1;i>=0;i--){if(dialogFocusStack[i].dlg===dlg){var prev=dialogFocusStack[i].prev;dialogFocusStack.splice(i,1);if(prev&&typeof prev.focus==='function'){setTimeout(function(){try{prev.focus();}catch(e){}},0);}break;}}}
['newdlg','snapdlg','clonedlg','vnetdlg','prefsdlg','aboutdlg','migratedlg','shortcutsdlg'].forEach(function(id){var dlg=document.getElementById(id);if(!dlg)return;dlg.addEventListener('click',function(e){if(e.target===dlg)dlg.close();});dlg.addEventListener('close',function(){releaseFocus(dlg);});var origShow=dlg.showModal;dlg.showModal=function(){trapFocus(dlg);origShow.call(dlg);};var origClose=dlg.close;dlg.close=function(){if(dlg.hasAttribute('data-closing'))return;dlg.setAttribute('data-closing','');function done(){dlg.removeAttribute('data-closing');dlg.removeEventListener('animationend',done);origClose.call(dlg);}dlg.addEventListener('animationend',done);setTimeout(function(){if(dlg.hasAttribute('data-closing'))done();},200);};});
// ── Sidebar Overlay Click-to-Close ──
document.body.addEventListener('click',function(e){if(document.body.classList.contains('sidebar-overlay')&&!e.target.closest('aside')){closeSidebar();}});
// ── Toolbar More Click-Outside ──
document.body.addEventListener('click',function(e){if(toolbarMoreOpen&&!e.target.closest('.toolbar')){closeToolbarMore();}});
// ── Right-Click Context Menu ──
let ctxMenu=null,ctxVmIdx=-1;
function hideCtxMenu(){if(ctxMenu){ctxMenu.remove();ctxMenu=null;ctxVmIdx=-1;}}
document.addEventListener('click',function(e){if(ctxMenu&&!ctxMenu.contains(e.target))hideCtxMenu();});
var vmlistEl=document.getElementById('vmlist');if(vmlistEl)vmlistEl.addEventListener('contextmenu',function(e){
  var item=e.target.closest('.vm-item');if(!item){hideCtxMenu();return;}
  var idx=parseInt(item.getAttribute('data-vm-index'));if(isNaN(idx)||idx>=vms.length){hideCtxMenu();return;}
  ctxVmIdx=idx;hideCtxMenu();
  e.preventDefault();
  ctxMenu=document.createElement('div');ctxMenu.className='ctx-menu';ctxMenu.setAttribute('role','menu');
  ctxMenu.style.position='fixed';ctxMenu.style.visibility='hidden';
  ctxMenu.style.left=e.clientX+'px';ctxMenu.style.top=e.clientY+'px';
  document.body.appendChild(ctxMenu);
  var mr=ctxMenu.getBoundingClientRect();
  var vw=window.innerWidth,vh=window.innerHeight;
  var x=e.clientX,y=e.clientY;
  if(x+mr.width>vw)x=vw-mr.width-4;if(x<4)x=4;
  if(y+mr.height>vh)y=vh-mr.height-4;if(y<4)y=4;
  ctxMenu.style.left=x+'px';ctxMenu.style.top=y+'px';
  ctxMenu.style.visibility='';
  var items=[
    ['▶ Power On/Off',function(){if(ctxVmIdx>=0){select(ctxVmIdx);powerToggle();}}],
    ['⚙ Settings',function(){if(ctxVmIdx>=0){select(ctxVmIdx);editVm();}}],
    ['✎ Rename',function(){if(ctxVmIdx>=0){select(ctxVmIdx);renameGuest();}}],
    ['⧉ Clone',function(){if(ctxVmIdx>=0){select(ctxVmIdx);cloneGuest();}}],
    ['⌨ Send Ctrl+Alt+Del',function(){if(ctxVmIdx>=0){select(ctxVmIdx);sendCad();}}],
    ['★ Toggle Favorite',function(){if(ctxVmIdx>=0){select(ctxVmIdx);toggleFavorite(ctxVmIdx);}}],
    ['✕ Delete',function(){if(ctxVmIdx>=0){select(ctxVmIdx);if(confirm('Delete this VM?'))deleteVm();}}]
  ];
  items.forEach(function(pair){var lbl=pair[0],fn=pair[1];var mi=document.createElement('div');mi.className='ctx-item';mi.setAttribute('role','menuitem');mi.setAttribute('tabindex','-1');
    mi.textContent=lbl;
    mi.addEventListener('click',function(){hideCtxMenu();fn();});
    ctxMenu.appendChild(mi);});
});
// ── Keyboard Shortcuts ──
document.addEventListener('keydown',function(e){var shift=e.shiftKey;
if((e.ctrlKey||e.metaKey)&&e.key==='s'&&activeTab==='settings'&&sel!==null){e.preventDefault();saveVm();return;}
if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.tagName==='SELECT')return;
if(e.key==='ArrowUp'||e.key==='ArrowDown'){var listEl=document.getElementById('vmlist');if(listEl&&listEl.contains(e.target)){e.preventDefault();var dir=e.key==='ArrowUp'?-1:1;var idx=sel===null?(dir<0?vms.length-1:0):Math.max(0,Math.min(vms.length-1,sel+dir));select(idx);return;}}
if(e.key==='Escape'){
  var anyOpen=false;['newdlg','snapdlg','clonedlg','vnetdlg','prefsdlg','aboutdlg','shortcutsdlg'].forEach(function(id){var d=document.getElementById(id);if(!d)return;if(d.hasAttribute('open')){d.close();anyOpen=true;}});
  if(!anyOpen&&document.body.classList.contains('displayonly')){exitDisplayOnly();return;}
  if(!anyOpen&&sel!==null){if(activeTab==='settings'&&settingsDirty){if(!confirm('You have unsaved changes. Discard them?'))return;}sel=null;renderList();showEmptyState();}
  return;
}
if(e.key==='?'&&!e.ctrlKey&&!e.metaKey){e.preventDefault();showShortcutsModal();return;}
if(e.ctrlKey&&e.key==='n'){e.preventDefault();if(shift)cloneGuest();else newVm();return;}
if(e.ctrlKey&&e.key==='e'){e.preventDefault();if(sel!==null)editVm();return;}
if(e.key==='F2'){e.preventDefault();if(sel!==null)editVm();return;}
if(e.ctrlKey&&e.key==='w'){e.preventDefault();deselectVm();return;}
if(e.ctrlKey&&e.key==='i'){e.preventDefault();importGuest();return;}
if(e.ctrlKey&&e.key==='s'){e.preventDefault();if(sel!==null)suspendGuest();return;}
if(e.ctrlKey&&e.key==='p'){e.preventDefault();openPrefs();return;}
if(e.ctrlKey&&e.key==='f'){e.preventDefault();var searchEl=document.getElementById('search');if(searchEl){searchEl.focus();searchEl.select();}return;}
if(e.ctrlKey&&e.key==='Enter'){e.preventDefault();if(sel!==null)editVm();return;}
if(e.key==='F5'){e.preventDefault();refresh();return;}
if(e.key==='F11'){e.preventDefault();if(document.body.classList.contains('displayonly')){exitDisplayOnly();}
else if(rfb||spice){enterDisplayOnly();}
else if(!document.fullscreenElement)document.documentElement.requestFullscreen().catch(function(){});else document.exitFullscreen();return;}
if(e.key==='Delete'){if(sel!==null)deleteVm();return;}
if(e.key==='Enter'){if(sel!==null)powerToggle();return;}
if(e.altKey&&e.key==='ArrowUp'&&sel!==null&&sel>0){e.preventDefault();reorderVm(sel,sel-1);return;}
if(e.altKey&&e.key==='ArrowDown'&&sel!==null&&sel<vms.length-1){e.preventDefault();reorderVm(sel,sel+1);return;}
});
function showShortcutsModal(){
  var d=document.getElementById('shortcutsdlg');
  if(d)d.showModal();
}
function enterDisplayOnly(){
  document.body.classList.add('displayonly');
  document.documentElement.requestFullscreen().catch(function(){});
  setStatus('Display-only — F11 or Esc to exit');
}
function exitDisplayOnly(){
  document.body.classList.remove('displayonly');
  if(document.fullscreenElement)document.exitFullscreen();
  setStatus('Exited display-only mode');
}
// ── Periodic Refresh ──
refresh();
setInterval(refresh,5000);
// ── Show keyboard shortcuts on first visit ──
if(!localStorage.getItem('kvmgui-shortcuts-shown')){localStorage.setItem('kvmgui-shortcuts-shown','1');setTimeout(showShortcutsModal,1500);}
// ── noVNC / SPICE live viewer ──
var rfb = null; // noVNC RFB client instance
var spice = null; // SPICE HTML5 client instance

function startFb() {
  if (rfb || spice) return; // already connected
  const idx = sel;
  if (idx === null || idx >= vms.length) return;
  const v = vms[idx];
  if (v.status !== 'running') return;
  var displayEl = document.getElementById('display');
  if (!displayEl) return;
  displayEl.style.display = 'block';
  displayEl.classList.add('loading');

  // Dispatch based on display type: 2 = SPICE, 3 = VNC
  if (v.display === 2) {
    startSpice(idx, displayEl, v);
  } else if (v.display === 3) {
    startVnc(idx, displayEl);
  }
  // Other display types (GTK, SDL, None) have no remote framebuffer; skip.
}

function startVnc(idx, displayEl) {
  // Remove any previously-created canvas.
  var oldCanvas = displayEl.querySelector('canvas');
  if (oldCanvas) displayEl.removeChild(oldCanvas);

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = proto + '//' + location.host + '/ws/vnc/' + idx;

  try {
    rfb = new noVNC.RFB(displayEl, url, {});
    rfb.addEventListener('connect', function() {
      displayEl.classList.remove('loading');
    });
    rfb.addEventListener('disconnect', function(e) {
      stopFb();
    });
    rfb.addEventListener('credentialsrequired', function(e) {
      rfb.sendCredentials({ password: '' });
    });
    rfb.scaleViewport = true;
    rfb.resizeSession = true;
  } catch (e) {
    stopFb();
  }
}

function startSpice(idx, displayEl, v) {
  // Remove any previously-created canvas.
  var oldCanvas = displayEl.querySelector('canvas');
  if (oldCanvas) displayEl.removeChild(oldCanvas);

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = proto + '//' + location.host + '/ws/spice/' + idx;

  try {
    spice = new SpiceHtml5.SpiceMainConn({
      uri: url,
      password: '',
      screen_id: 'display',
      onerror: function(e) {
        console.warn('SPICE error:', e);
        stopFb();
      },
      onsuccess: function() {
        displayEl.classList.remove('loading');
      }
    });
  } catch (e) {
    stopFb();
  }
}

function stopFb() {
  if (rfb) {
    try { rfb.disconnect(); } catch (e) {}
    rfb = null;
  }
  if (spice) {
    try { spice.stop(); } catch (e) {}
    spice = null;
  }
  var displayEl = document.getElementById('display');
  if (displayEl) {
    var canvases = displayEl.querySelectorAll('canvas');
    for (var ci = 0; ci < canvases.length; ci++) { if (canvases[ci].parentNode === displayEl) displayEl.removeChild(canvases[ci]); }
    displayEl.style.display = 'none';
    displayEl.classList.remove('loading');
  }
}
// Serial console
let serialWs=null,serialIdx=null,serialManualOff=false,serialManualOffVmIdx=-1,serialReconnectTimer=null;
function startSerial(idx){if(serialManualOff&&serialManualOffVmIdx===idx)return;
if(serialWs){if(serialIdx===idx&&(serialWs.readyState===WebSocket.OPEN||serialWs.readyState===WebSocket.CONNECTING))return;
serialWs.close();serialWs=null;} /* close stale CONNECTING socket before reconnect */
const sameVm=(serialIdx===idx);
stopSerial(!sameVm); /* clear terminal only when switching VMs */
if(idx===null||idx>=vms.length)return;const v=vms[idx];if(v.status!=='running'||v.hasSerial!=='true')return;
serialIdx=idx;const term=document.getElementById('serialterm');const sp=document.getElementById('serialpanel');if(!term||!sp)return;sp.style.display='block';sp.classList.add('connected');
const proto=location.protocol==='https:'?'wss:':'ws:';const ws=new WebSocket(proto+'//'+location.host+'/ws/serial/'+idx);
serialWs=ws; // reassign before old onclose fires to avoid closing the new socket
ws.onmessage=e=>{term.value+=e.data;term.scrollTop=term.scrollHeight;};
ws.onopen=()=>{sp.classList.add('connected');};
ws.onclose=()=>{if(serialWs===ws){serialWs=null;serialIdx=null;const sp2=document.getElementById('serialpanel');if(sp2){sp2.style.display='none';sp2.classList.remove('connected');}}};
ws.onerror=()=>{if(serialWs===ws){serialWs=null;serialIdx=null;const sp2=document.getElementById('serialpanel');if(sp2){sp2.style.display='none';sp2.classList.remove('connected');}}};
}
function stopSerial(clearTerm){if(clearTerm===void 0)clearTerm=true;if(serialWs){serialWs.close();serialWs=null;}serialIdx=null;if(clearTerm){const term=document.getElementById('serialterm');if(term)term.value='';}const sp=document.getElementById('serialpanel');if(sp){sp.style.display='none';sp.classList.remove('connected');}}
function manualDisconnectSerial(){serialManualOff=true;serialManualOffVmIdx=sel!==null?sel:-1;stopSerial(true);}
var serialTermEl=document.getElementById('serialterm');if(serialTermEl){serialTermEl.addEventListener('keydown',function(e){if(!serialWs||serialWs.readyState!==WebSocket.OPEN)return;
var s=null;
if(e.ctrlKey&&!e.altKey&&!e.metaKey){
 if(e.key.length===1){var cc=e.key.charCodeAt(0);if(cc>=64&&cc<=95)s=String.fromCharCode(cc-64);else if(cc>=97&&cc<=122)s=String.fromCharCode(cc-96);}
 else if(e.key===' '||e.key==='Spacebar')s='\x00';
}else if(!e.altKey&&!e.metaKey){
 switch(e.key){
  case'Enter':s='\r\n';break;case'Backspace':s='\x08';break;case'Tab':s='\t';break;
  case'Delete':s='\x1b[3~';break;case'Escape':s='\x1b';break;
  case'ArrowUp':s='\x1b[A';break;case'ArrowDown':s='\x1b[B';break;
  case'ArrowRight':s='\x1b[C';break;case'ArrowLeft':s='\x1b[D';break;
  case'Home':s='\x1b[H';break;case'End':s='\x1b[F';break;
  case'PageUp':s='\x1b[5~';break;case'PageDown':s='\x1b[6~';break;
  case'Insert':s='\x1b[2~';break;
  case'F1':s='\x1bOP';break;case'F2':s='\x1bOQ';break;case'F3':s='\x1bOR';break;case'F4':s='\x1bOS';break;
  case'F5':s='\x1b[15~';break;case'F6':s='\x1b[17~';break;case'F7':s='\x1b[18~';break;case'F8':s='\x1b[19~';break;
  case'F9':s='\x1b[20~';break;case'F10':s='\x1b[21~';break;case'F11':s='\x1b[23~';break;case'F12':s='\x1b[24~';break;
  default:if(e.key.length===1)s=e.key;break;
 }
}
if(s){e.preventDefault();e.stopPropagation();serialWs.send(s);}});}
if(serialReconnectTimer){clearInterval(serialReconnectTimer);}
serialReconnectTimer=setInterval(()=>{if(sel!==null&&sel<vms.length){const v=vms[sel];if(serialManualOff&&sel!==serialManualOffVmIdx){serialManualOff=false;serialManualOffVmIdx=-1;}if(v.status==='running'&&v.hasSerial==='true')startSerial(sel);else stopSerial();if(v.status==='running')startFb();else stopFb();}},3000);
// ── Event Delegation (CSP-safe: no inline handlers) ──
var actionHandlers={
 toggleSidebar:function(){toggleSidebar();},deselectVm:function(){deselectVm();},
 toggleToolbarMore:function(){toggleToolbarMore();},
 powerToggle:function(){powerToggle();},pauseGuest:function(){pauseGuest();},
 resumeGuest:function(){resumeGuest();},shutdownGuest:function(){shutdownGuest();},
 resetGuest:function(){resetGuest();},suspendGuest:function(){suspendGuest();},
 sendCad:function(){sendCad();},editVm:function(){editVm();},
 renameGuest:function(){renameGuest();},cloneGuest:function(){cloneGuest();},
 importGuest:function(){importGuest();},takeSnapshot:function(){takeSnapshot();},
 exportOvf:function(){exportOvf();},migrateGuest:function(){migrateGuest();},doMigrate:function(){doMigrate();},openVnets:function(){openVnets();},
 openPrefs:function(){openPrefs();},openAbout:function(){openAbout();},
 batchStart:function(){batchStart();},batchStop:function(){batchStop();},
 deleteVm:function(){deleteVm();},clearSearch:function(){clearSearch();},
 newVm:function(){newVm();},createVm:function(){createVm();},
 takeSnapshotFromDlg:function(){takeSnapshotFromDlg();},
 manualDisconnectSerial:function(){manualDisconnectSerial();},
 clearSerial:function(){var t=document.getElementById('serialterm');if(t)t.value='';},
 exportSerial:function(){var t=document.getElementById('serialterm');if(!t||!t.value)return;var blob=new Blob([t.value],{type:'text/plain'});var a=document.createElement('a');var url=URL.createObjectURL(blob);a.href=url;a.download='kvmgui-serial-'+new Date().toISOString().replace(/[:.]/g,'-')+'.txt';a.click();setTimeout(function(){URL.revokeObjectURL(url);},100);},
 savePrefs:function(){savePrefs();},saveVm:function(){saveVm();},
 vnetAdd:function(){vnetAdd();},vnetRemove:function(){vnetRemove();},
 vnetDefaults:function(){vnetDefaults();},vnetSaveCurrent:function(){vnetSaveCurrent();},
 vnetSaveAll:function(){vnetSaveAll();},
 select:function(el){var i=parseInt(el.getAttribute('data-vm-index'));if(!isNaN(i))select(i);},
 toggleFavorite:function(el){var parent=el.closest('.vm-item');if(!parent)return;var i=parseInt(parent.getAttribute('data-vm-index'));if(!isNaN(i))toggleFavorite(i);},
 revertSnapshot:function(el){revertSnapshot(el.getAttribute('data-snap-tag')||'');},
 deleteSnapshot:function(el){deleteSnapshot(el.getAttribute('data-snap-tag')||'');},
 doClone:function(el){doClone(parseInt(el.getAttribute('data-clone-linked')));},
 switchTab:function(el){switchTab(el.getAttribute('data-tab')||'summary');},
 closeDlg:function(el){var id=el.getAttribute('data-dialog');if(id){var d=document.getElementById(id);if(d)d.close();}},
 dismissBanner:function(){var b=document.getElementById('connbanner');if(b)b.style.display='none';serverDown=false;setStatus('');},
 applyTheme:function(el){pendingTheme=el.value;},
 toggleTheme:function(){cycleTheme();},
 filterList:function(){filterList();},
 onVnetSelect:function(){onVnetSelect();}
};
var filterTimer=null;
document.body.addEventListener('click',function(e){
 var el=e.target.closest('[data-action]');if(!el)return;
 var action=el.getAttribute('data-action');var h=actionHandlers[action];if(h)h(el);
});
document.body.addEventListener('input',function(e){
 if(e.target.closest('#tabSettings'))settingsDirty=true;
 var el=e.target.closest('[data-action="filterList"]');if(el){
  if(filterTimer)clearTimeout(filterTimer);
  filterTimer=setTimeout(filterList,180);
 }
 if(e.target.id==='mig_host'||e.target.id==='mig_port')updateMigUri();
});
document.body.addEventListener('change',function(e){
 if(e.target.closest('#tabSettings'))settingsDirty=true;
 var el=e.target.closest('[data-action]');if(!el)return;
 var action=el.getAttribute('data-action');
 if(action==='onVnetSelect')onVnetSelect();
 else if(action==='applyTheme'){pendingTheme=el.value;}
});
document.body.addEventListener('keydown',function(e){
 if(e.key==='Enter'&&e.target.tagName!=='INPUT'&&e.target.tagName!=='TEXTAREA'&&e.target.tagName!=='SELECT'){
  var el=e.target.closest('[data-action="select"]');if(el){var i=parseInt(el.getAttribute('data-vm-index'));if(!isNaN(i))select(i);}
 }
});
window.addEventListener('beforeunload',function(){stopFb();stopSerial(true);if(serialReconnectTimer){clearInterval(serialReconnectTimer);serialReconnectTimer=null;}});
// ── Drag-to-reorder VM list ──
(function initDragReorder(){
  var dragIdx=null;
  var vml=document.getElementById('vmlist');if(!vml)return;
  vml.addEventListener('dragstart',function(e){
    var item=e.target.closest('.vm-item');if(!item)return;
    dragIdx=parseInt(item.getAttribute('data-vm-index'));
    if(isNaN(dragIdx)){dragIdx=null;return;}
    e.dataTransfer.effectAllowed='move';
    e.dataTransfer.setData('text/plain',''); // required for Firefox
    item.classList.add('dragging');
    item.setAttribute('aria-grabbed','true');
  });
  vml.addEventListener('dragend',function(e){
    var item=e.target.closest('.vm-item');if(item){item.classList.remove('dragging');item.removeAttribute('aria-grabbed');}
    dragIdx=null;
    vml.querySelectorAll('.drag-over').forEach(function(el){el.classList.remove('drag-over');});
  });
  vml.addEventListener('dragover',function(e){
    e.preventDefault();
    e.dataTransfer.dropEffect='move';
    var item=e.target.closest('.vm-item');if(!item||!dragIdx)return;
    var idx=parseInt(item.getAttribute('data-vm-index'));
    if(isNaN(idx)||idx===dragIdx)return;
    vml.querySelectorAll('.drag-over').forEach(function(el){el.classList.remove('drag-over');});
    item.classList.add('drag-over');
  });
  vml.addEventListener('dragleave',function(e){
    var item=e.target.closest('.vm-item');if(item)item.classList.remove('drag-over');
  });
  vml.addEventListener('drop',function(e){
    e.preventDefault();
    var item=e.target.closest('.vm-item');if(!item||dragIdx===null)return;
    item.classList.remove('drag-over');
    var toIdx=parseInt(item.getAttribute('data-vm-index'));
    if(isNaN(toIdx)||toIdx===dragIdx)return;
    var from=dragIdx,to=toIdx;
    dragIdx=null;
    // Update sel to track the moved item
    if(sel===from)sel=to;else if(sel===to)sel=from;
    apiPost('/api/reorder','from='+from+'&to='+to).then(function(r){
      if(r)refresh();else{sel=from>to?from+1:from-1;refresh();}
    }).catch(function(){refresh();});
  });
})();
// ── Touch drag-to-reorder (pointer events fallback for mobile) ──
(function initTouchReorder(){
  var touchDrag=null,vml=document.getElementById('vmlist');if(!vml)return;
  function getItem(e){return e.target.closest('.vm-item');}
  function itemIdx(item){return parseInt(item.getAttribute('data-vm-index'));}
  function findTarget(y){var items=vml.querySelectorAll('.vm-item');for(var i=0;i<items.length;i++){var r=items[i].getBoundingClientRect();if(y<r.top+r.height/2){return items[i];}}return items.length?items[items.length-1]:null;}
  vml.addEventListener('pointerdown',function(e){
    if(e.pointerType==='mouse')return; // let HTML5 DnD handle mouse
    var item=getItem(e);if(!item)return;
    var idx=itemIdx(item);if(isNaN(idx))return;
    item.setPointerCapture(e.pointerId);
    touchDrag={idx:idx,item:item,startY:e.clientY,ghost:null,active:false,pointerId:e.pointerId};
  });
  vml.addEventListener('pointermove',function(e){
    if(!touchDrag||e.pointerId!==touchDrag.pointerId)return;
    if(!touchDrag.active){
      if(Math.abs(e.clientY-touchDrag.startY)<8)return; // threshold
      touchDrag.active=true;
      touchDrag.ghost=touchDrag.item.cloneNode(true);
      touchDrag.ghost.style.cssText='position:fixed;z-index:9999;pointer-events:none;opacity:0.85;width:'+touchDrag.item.offsetWidth+'px;box-shadow:var(--shadow-lg);background:var(--surface);border-radius:var(--radius)';
      document.body.appendChild(touchDrag.ghost);
      touchDrag.item.classList.add('dragging');
    }
    touchDrag.ghost.style.left='8px';
    touchDrag.ghost.style.top=(e.clientY-touchDrag.ghost.offsetHeight/2)+'px';
    vml.querySelectorAll('.drag-over').forEach(function(el){el.classList.remove('drag-over');});
    var target=findTarget(e.clientY);
    if(target&&itemIdx(target)!==touchDrag.idx)target.classList.add('drag-over');
  });
  vml.addEventListener('pointerup',function(e){
    if(!touchDrag||e.pointerId!==touchDrag.pointerId)return;
    if(touchDrag.ghost){document.body.removeChild(touchDrag.ghost);touchDrag.ghost=null;}
    touchDrag.item.classList.remove('dragging');
    vml.querySelectorAll('.drag-over').forEach(function(el){el.classList.remove('drag-over');});
    if(touchDrag.active){
      var target=findTarget(e.clientY);
      if(target){var toIdx=itemIdx(target);if(!isNaN(toIdx)&&toIdx!==touchDrag.idx){reorderVm(touchDrag.idx,toIdx);}}
    }
    touchDrag=null;
  });
  vml.addEventListener('pointercancel',function(e){
    if(touchDrag&&e.pointerId===touchDrag.pointerId){
      if(touchDrag.ghost){document.body.removeChild(touchDrag.ghost);}
      touchDrag.item.classList.remove('dragging');
      vml.querySelectorAll('.drag-over').forEach(function(el){el.classList.remove('drag-over');});
      touchDrag=null;
    }
  });
  vml.addEventListener('lostpointercapture',function(e){
    if(touchDrag&&e.pointerId===touchDrag.pointerId){
      if(touchDrag.ghost){document.body.removeChild(touchDrag.ghost);touchDrag.ghost=null;}
      if(touchDrag.item)touchDrag.item.classList.remove('dragging');
      vml.querySelectorAll('.drag-over').forEach(function(el){el.classList.remove('drag-over');});
      touchDrag=null;
    }
  });
})();
// ── Accessibility attributes (elements from server-rendered HTML) ──
(function initA11y(){
  var sl=document.getElementById('skip-link');if(!sl){sl=document.createElement('a');sl.id='skip-link';sl.href='#';sl.textContent='Skip to main content';sl.addEventListener('click',function(e){e.preventDefault();var mn=document.querySelector('main');if(mn)mn.focus();});document.body.insertBefore(sl,document.body.firstChild);}
  var aside=document.querySelector('aside');if(aside){aside.id='sidebar';aside.setAttribute('role','navigation');aside.setAttribute('aria-label','VM Library');}
  var hamb=document.querySelector('.hamburger');if(hamb){hamb.setAttribute('aria-controls','sidebar');hamb.setAttribute('aria-expanded','false');}
  var vml=document.getElementById('vmlist');if(vml){vml.setAttribute('role','listbox');vml.setAttribute('aria-label','VM Library');}
  var tb=document.querySelector('.tab-bar');if(tb)tb.setAttribute('role','tablist');
  var tbb=document.querySelectorAll('.tab-btn');for(var i=0;i<tbb.length;i++)tbb[i].setAttribute('role','tab');
})();
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
})();
var vms=[]; var sel=null; var activeTab='summary';
function setStatus(s){document.getElementById('statusbar').textContent=s;document.getElementById('statusbar').classList.remove('loading');}
function setStatusLoading(s){var el=document.getElementById('statusbar');el.textContent='⏳ '+s;el.classList.add('loading');}
function showToast(msg,type){type=type||'info';var c=document.getElementById('toast-container');var t=document.createElement('div');t.className='toast '+type;t.textContent=msg;c.appendChild(t);setTimeout(function(){t.style.opacity='0';t.style.transition='opacity 300ms ease';setTimeout(function(){if(t.parentNode)c.removeChild(t);},300);},3500);}
var apiPostPending=0;
async function apiPost(url,body){var prev=document.getElementById('statusbar').textContent;setStatusLoading('Working...');apiPostPending++;try{var opts={method:'POST',body:body||'',headers:{'X-API-Key':'kvmgui'}};var r=await fetch(url,opts);if(!r.ok)throw new Error(r.status);apiPostPending--;if(apiPostPending<=0)setStatus(prev);return r;}catch(e){apiPostPending--;if(apiPostPending<=0)setStatus('Error: '+e.message);showToast(e.message||'Request failed','error');return null;}}
function toggleSidebar(){const aside=document.querySelector('aside');aside.classList.toggle('open');document.body.classList.toggle('sidebar-overlay');}
function clearSearch(){document.getElementById('search').value='';filterList();}
function switchTab(tab){if(activeTab===tab)return;activeTab=tab;
document.getElementById('tabSummary').style.display=tab==='summary'?'block':'none';
document.getElementById('tabSettings').style.display=tab==='settings'?'block':'none';
const btns=document.querySelectorAll('.tab-btn');btns.forEach(b=>b.classList.remove('active'));
if(tab==='summary')btns[0].classList.add('active');else btns[1].classList.add('active');
if(tab==='settings'&&sel!==null)editVm();}
async function refresh(){try{const r=await fetch('/api/vms');if(!r.ok)return;vms=await r.json();renderList();if(sel!==null&&sel<vms.length)renderDetails();}catch(e){console.error('refresh failed:',e);}}
function filterList(){const f=document.getElementById('search').value;const clr=document.getElementById('searchClear');clr.style.display=f?'block':'none';renderList(f.toLowerCase());}
function renderList(filter){const e=document.getElementById('vmlist');const f=(filter||'').toLowerCase();let h='';
const viz=vms.map((v,i)=>({i,show:!f||v.name.toLowerCase().includes(f),fav:v.favorite==='true',v}));
let hasFavs=false,hasNon=false;for(const x of viz){if(!x.show)continue;if(x.fav)hasFavs=true;else hasNon=true;}
for(const pass of[0,1]){if(pass===0){for(const x of viz){if(!x.show||!x.fav)continue;
const color=x.v.status==='running'?'var(--success)':x.v.status==='paused'?'var(--pause)':x.v.status==='suspended'?'var(--warn)':'var(--text-muted)';
const icon=x.v.status==='running'?'▶':x.v.status==='paused'?'⏸':'  ';
h+=`<div class="vm-item${sel===x.i?' active':''}" tabindex="0" onclick="select(${x.i})" onkeydown="if(event.key==='Enter')select(${x.i})"><span style="color:${color};font-weight:bold">${icon}</span> ${x.v.name}<span class="star fav" style="margin-left:auto;cursor:pointer" onclick="event.stopPropagation();toggleFavorite(${x.i})">★</span></div>`;}}
if(hasFavs&&hasNon)h+='<div style="color:var(--text-dim);font-size:11px;padding:4px 8px;border-bottom:1px solid var(--border);margin:4px 0">──────────</div>';
if(pass===1){for(const x of viz){if(!x.show||x.fav)continue;
const color=x.v.status==='running'?'var(--success)':x.v.status==='paused'?'var(--pause)':x.v.status==='suspended'?'var(--warn)':'var(--text-muted)';
const icon=x.v.status==='running'?'▶':x.v.status==='paused'?'⏸':'  ';
h+=`<div class="vm-item${sel===x.i?' active':''}" tabindex="0" onclick="select(${x.i})" onkeydown="if(event.key==='Enter')select(${x.i})"><span style="color:${color};font-weight:bold">${icon}</span> ${x.v.name}<span class="star" style="margin-left:auto;cursor:pointer" onclick="event.stopPropagation();toggleFavorite(${x.i})">★</span></div>`;}}}
e.innerHTML=h||'<div style="color:var(--text-dim);font-size:12px">No VMs</div>';
let cnt=0,running=0,paused=0,suspended=0;for(let v of vms){cnt++;if(v.status==='running')running++;else if(v.status==='paused')paused++;else if(v.status==='suspended')suspended++;}
let parts=cnt+' virtual machine(s)';if(running>0)parts+=', '+running+' running';if(paused>0)parts+=', '+paused+' paused';if(suspended>0)parts+=', '+suspended+' suspended';
if(sel!==null&&sel<vms.length){const v=vms[sel];document.getElementById('statusbar').textContent=v.name+' — '+v.status+'    |    '+parts;}
else document.getElementById('statusbar').textContent=parts;}
async function toggleFavorite(i){if(i>=vms.length)return;const v=vms[i];const fav=v.favorite==='true'?'0':'1';
const r=await apiPost('/api/save/'+i,'favorite='+fav);if(r){v.favorite=fav==='1'?'true':'false';renderList();if(sel===i)renderDetails();}}
function select(i){sel=i;renderList();if(sel!==null){if(activeTab==='summary')renderDetails();else editVm();}else{showEmptyState();}updatePowerBtn();}
function showEmptyState(){const t=document.getElementById('tabSummary');const s=document.getElementById('tabSettings');
document.getElementById('vmname').textContent='Select a VM';document.getElementById('tabBar').style.display='none';
t.innerHTML='<div class="empty-state"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg><h3>No Virtual Machine Selected</h3><p>Select a VM from the sidebar to view its details, or create a new one.</p></div>';
s.innerHTML='<div class="empty-state"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg><h3>No Virtual Machine Selected</h3><p>Select a VM from the sidebar to edit its settings.</p></div>';}
function renderDetails(){if(sel===null||sel>=vms.length){showEmptyState();return;}
document.getElementById('tabBar').style.display='flex';
const v=vms[sel];const sc=v.status==='running'?'running':v.status==='paused'?'paused':v.status==='suspended'?'suspended':'stopped';
document.getElementById('vmname').textContent=v.name;
let h='<div class="summary-grid">';
h+=`<div class="summary-card"><div class="card-label">State</div><div class="card-value ${sc}">${v.status}</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Guest OS</div><div class="card-value">${v.os}</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Memory</div><div class="card-value">${v.mem} MB</div></div>`;
h+=`<div class="summary-card"><div class="card-label">CPU</div><div class="card-value">${v.cpu} cores</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Hard Disk</div><div class="card-value">${v.disk} GB (${v.fw})</div></div>`;
h+=`<div class="summary-card"><div class="card-label">Network</div><div class="card-value">${v.net}</div></div>`;
if(v.mac)h+=`<div class="summary-card"><div class="card-label">MAC</div><div class="card-value">${v.mac}</div></div>`;
if(v.nic2_mode&&v.nic2_mode!=='none')h+=`<div class="summary-card"><div class="card-label">NIC 2</div><div class="card-value">${v.nic2_mode}</div></div>`;
if(v.nic3_mode&&v.nic3_mode!=='none')h+=`<div class="summary-card"><div class="card-label">NIC 3</div><div class="card-value">${v.nic3_mode}</div></div>`;
if(v.shared_folder)h+=`<div class="summary-card"><div class="card-label">Shared Folder</div><div class="card-value">${v.shared_folder}</div></div>`;
if(v.usb_device)h+=`<div class="summary-card"><div class="card-label">USB Device</div><div class="card-value">${v.usb_device}</div></div>`;
if(v.guest_tools==='true')h+=`<div class="summary-card"><div class="card-label">Guest Tools</div><div class="card-value">✓ installed</div></div>`;
if(v.autoprotect==='true')h+=`<div class="summary-card"><div class="card-label">AutoProtect</div><div class="card-value">every ${v.autoprotect_interval} min, keep ${v.autoprotect_max}</div></div>`;
if(v.hasDisk2==='true')h+=`<div class="summary-card"><div class="card-label">Disk 2</div><div class="card-value">${v.disk2_size} GB</div></div>`;
if(v.hasFloppy==='true')h+=`<div class="summary-card"><div class="card-label">Floppy</div><div class="card-value">attached</div></div>`;
if(v.port_forwards)h+=`<div class="summary-card"><div class="card-label">Port Forwards</div><div class="card-value">${v.port_forwards}</div></div>`;
if(v.notes)h+=`<div class="summary-card"><div class="card-label">Notes</div><div class="card-value">${v.notes}</div></div>`;
h+='</div>';
document.getElementById('tabSummary').innerHTML=h;
updatePowerBtn();}
async function powerToggle(){if(sel===null)return;const r=await apiPost('/api/power/'+sel);if(r)await refresh();}
async function shutdownGuest(){if(sel===null)return;const r=await apiPost('/api/shutdown/'+sel);if(r)setStatus('Shut down guest — ACPI power button sent.');}
async function resetGuest(){if(sel===null)return;const r=await apiPost('/api/reset/'+sel);if(r)setStatus('Reset guest — system_reset sent.');}
async function pauseGuest(){if(sel===null)return;const r=await apiPost('/api/pause/'+sel);if(r){await refresh();setStatus('Paused guest — execution frozen.');}}
async function resumeGuest(){if(sel===null)return;const r=await apiPost('/api/resume/'+sel);if(r){await refresh();setStatus('Resumed guest — execution continued.');}}
async function renameGuest(){if(sel===null)return;const v=vms[sel];const n=prompt('Rename VM:',v.name);if(n&&n!==v.name){const r=await apiPost('/api/rename/'+sel,'name='+encodeURIComponent(n));if(r)await refresh();}}
async function suspendGuest(){if(sel===null)return;const r=await apiPost('/api/suspend/'+sel);if(r){await refresh();setStatus('Suspended VM to disk.');}}
async function cloneGuest(){if(sel===null)return;document.getElementById('clone_name').textContent=vms[sel].name;document.getElementById('clonedlg').showModal();}
async function doClone(linked){if(sel===null)return;document.getElementById('clonedlg').close();const body=linked?'linked=1':'';const r=await apiPost('/api/clone/'+sel,body);if(r){await refresh();setStatus(linked?'Linked clone created.':'VM cloned.');}}
async function importGuest(){const p=prompt('Path to VM disk image (.qcow2):');if(p){const r=await apiPost('/api/import','path='+encodeURIComponent(p));if(r){await refresh();setStatus('VM imported.');}}}
async function batchStart(){for(let i=0;i<vms.length;i++){if(vms[i].status==='stopped'){await apiPost('/api/power/'+i);}}await refresh();setStatus('Batch start complete.');}
async function batchStop(){for(let i=0;i<vms.length;i++){if(vms[i].status==='running'||vms[i].status==='paused'){await apiPost('/api/power/'+i);}}await refresh();setStatus('Batch stop complete.');}
async function takeSnapshot(){if(sel===null)return;openSnapshots();}
async function takeSnapshotFromDlg(){if(sel===null)return;const t=document.getElementById('s_tag').value;if(!t){alert('Enter a tag name');return;}
const r=await apiPost('/api/snapshot/take/'+sel,'tag='+encodeURIComponent(t));if(r){document.getElementById('s_tag').value='';loadSnapshots();setStatus('Snapshot taken: '+t);}}
async function openSnapshots(){if(sel===null)return;document.getElementById('snapdlg').showModal();loadSnapshots();}
async function loadSnapshots(){if(sel===null)return;const r=await fetch('/api/snapshot/list/'+sel);const t=await r.text();
const el=document.getElementById('snaplist');if(!t||t==='(none)'){el.innerHTML='<div style="color:var(--text-dim)">No snapshots</div>';return;}
const lines=t.split('\n');let h='';for(const ln of lines){if(!ln.trim())continue;if(/^\s*(ID|Snapshot)\s/.test(ln))continue;const parts=ln.trim().split(/\s+/);const tag=parts[1]||ln;const rest=parts.slice(2).join(' ');
h+=`<div style="padding:4px 0;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center"><span title="${rest}">${tag}</span><span><button class="btn" style="padding:2px 8px;font-size:11px" onclick="revertSnapshot('${tag}')">Revert</button><button class="btn danger" style="padding:2px 8px;font-size:11px" onclick="deleteSnapshot('${tag}')">Del</button></span></div>`;}
el.innerHTML=h;}
async function revertSnapshot(tag){if(sel===null||!tag)return;if(!confirm('Revert to snapshot "'+tag+'"? This will discard current state.'))return;
const r=await apiPost('/api/snapshot/revert/'+sel,'tag='+encodeURIComponent(tag));if(r){setStatus('Reverted to snapshot: '+tag);snapdlg.close();}}
async function deleteSnapshot(tag){if(sel===null||!tag)return;if(!confirm('Delete snapshot "'+tag+'"?'))return;
const r=await apiPost('/api/snapshot/delete/'+sel,'tag='+encodeURIComponent(tag));if(r){loadSnapshots();setStatus('Deleted snapshot: '+tag);}}
async function sendCad(){if(sel===null)return;const r=await apiPost('/api/cad/'+sel);if(r)setStatus('Ctrl+Alt+Del sent to guest.');}
async function exportOvf(){if(sel===null)return;try{const r=await fetch('/api/export/'+sel,{method:'POST',headers:{'X-API-Key':'kvmgui'}});if(!r.ok){setStatus('Export failed: '+r.status);return;}const blob=await r.blob();const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=vms[sel].name+'.ova';a.click();setStatus('Export downloaded.');}catch(e){setStatus('Export error: '+e);}}
function updatePowerBtn(){const b=document.getElementById('powerbtn');if(sel===null||sel>=vms.length){b.textContent='▶ Power On';b.className='btn primary';return;}
const v=vms[sel];if(v.status==='running'||v.status==='paused'){b.textContent='⏹ Power Off';b.className='btn danger';}else{b.textContent='▶ Power On';b.className='btn primary';}}
function newVm(){document.getElementById('newdlg').showModal();}
async function createVm(){const n=document.getElementById('n_name').value;const m=document.getElementById('n_mem').value;
const c=document.getElementById('n_cpu').value;const d=document.getElementById('n_disk').value;
const r=await apiPost('/api/new','name='+encodeURIComponent(n)+'&mem='+m+'&cpu='+c+'&disk='+d);if(r){document.getElementById('newdlg').close();await refresh();}}
async function deleteVm(){if(sel===null)return;if(!confirm('Delete this VM?'))return;const r=await apiPost('/api/delete/'+sel);if(r){sel=null;await refresh();}}
function editVm(){if(sel===null)return;switchTab('settings');if(sel===null||sel>=vms.length)return;
const v=vms[sel];document.getElementById('tabBar').style.display='flex';document.getElementById('vmname').textContent=v.name;
const fields=[
['Name','e_name','text',v.name||''],['Memory (MB)','e_mem','number',v.mem||2048],
['CPU Cores','e_cpu','number',v.cpu||2],['CPU Sockets','e_cpu_sockets','number',v.cpu_sockets||1],
['Disk Size (GB)','e_disk','number',v.disk||20],['Disk Format','e_disk_format','select',v.disk_format||0],
['ISO Path','e_iso_path','text',v.iso_path||''],['MAC Address','e_mac_address','text',v.mac_address||''],
['Network','e_network','select',v.net||'user'],['Firmware','e_firmware','select',v.fw||'bios'],
['Guest OS','e_guest_os','select',v.guest_os||0],['Display','e_display','select',v.display||0],
['Display Res','e_display_resolution','select',v.display_resolution||0],['Audio','e_audio','select',v.audio||0],
['Boot Order','e_boot_order','select',v.boot_order||0],['3D Accel','e_enable_3d','select',v.enable_3d==='true'?'1':'0'],
['GPU Device','e_gpu_device','select',v.gpu_device||0],['KVM','e_enable_kvm','select',v.enable_kvm==='true'?'1':'0'],
['Embed Display','e_embed_display','select',v.embed_display==='true'?'1':'0'],['VNC Port','e_vnc_port','number',v.vnc_port||5900],
['SPICE Port','e_spice_port','number',v.spice_port||5901],['Serial','e_enable_serial','select',v.enable_serial==='true'?'1':'0'],
['Num Displays','e_num_displays','number',v.num_displays||1],['Favorite','e_favorite','select',v.favorite==='true'?'1':'0'],
['Shared Folder','e_shared_folder','text',v.shared_folder||''],['USB Device','e_usb','text',v.usb_device||''],
['Guest Tools','e_guest_tools','select',v.guest_tools==='true'?'1':'0'],['AutoProtect','e_autoprotect','select',v.autoprotect==='true'?'1':'0'],
['AP Interval','e_ap_interval','number',v.autoprotect_interval||60],['AP Max','e_ap_max','number',v.autoprotect_max||10],
['Disk 2 Path','e_disk2_path','text',v.disk2_path||''],['Disk 2 Size','e_disk2_size','number',v.disk2_size||0],
['Disk 2 Format','e_disk2_format','select',v.disk2_format||0],['Floppy','e_floppy','text',v.floppy_path||''],
['NIC 2','e_nic2','select',v.nic2_mode||'none'],['NIC 2 MAC','e_nic2_mac','text',v.nic2_mac||''],
['NIC 3','e_nic3','select',v.nic3_mode||'none'],['NIC 3 MAC','e_nic3_mac','text',v.nic3_mac||''],
['Port Forwards','e_portfw','text',v.port_forwards||''],['Notes','e_notes','text',v.notes||'']];
const selects={e_network:[['user','NAT (User)'],['bridge','Bridged'],['none','None']],
e_firmware:[['bios','BIOS'],['uefi','UEFI']],e_disk_format:[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']],
e_disk2_format:[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']],
e_enable_3d:[['0','No'],['1','Yes']],e_gpu_device:[['0','Virtio-GPU'],['1','Virtio-VGA']],
e_display:[['0','GTK'],['1','SDL'],['2','SPICE'],['3','VNC'],['4','None']],
e_display_resolution:[['0','Auto'],['1','800x600'],['2','1024x768'],['3','1280x800'],['4','1920x1080']],
e_guest_os:[['0','Linux'],['1','Windows'],['2','FreeBSD'],['3','macOS'],['4','Other']],
e_audio:[['0','None'],['1','Intel HDA'],['2','AC97']],e_boot_order:[['0','Hard Disk'],['1','CD/DVD'],['2','PXE']],
e_enable_kvm:[['0','No'],['1','Yes']],e_embed_display:[['0','No'],['1','Yes']],
e_enable_serial:[['0','No'],['1','Yes']],e_favorite:[['0','No'],['1','Yes']],
e_guest_tools:[['0','No'],['1','Yes']],e_autoprotect:[['0','Off'],['1','On']],
e_nic2:[['none','None'],['user','NAT'],['bridge','Bridged']],
e_nic3:[['none','None'],['user','NAT'],['bridge','Bridged']]};
let h='<div class="settings-form">';
for(const f of fields){const[lbl,id,type,val]=f;h+='<div class="field-group">';
h+=`<label>${lbl}</label>`;
if(type==='select'&&selects[id]){h+=`<select id="${id}">`;
for(const[ov,ol]of selects[id])h+=`<option value="${ov}"${ov===String(val)?' selected':''}>${ol}</option>`;
h+='</select>';}else{h+=`<input id="${id}" type="${type}" value="${val}">`;}
h+='</div>';}
h+='</div><div class="btn-row" style="margin-top:20px"><button class="btn primary" onclick="saveVm()">Save Changes</button></div>';
document.getElementById('tabSettings').innerHTML=h;}
async function saveVm(){if(sel===null)return;
const body=['name','mem','cpu','cpu_sockets','disk','disk_format','iso_path','mac_address','network','firmware','shared_folder','usb','guest_tools','autoprotect',
'ap_interval','ap_max','disk2_path','disk2_size','disk2_format','floppy','nic2','nic2_mac','nic3','nic3_mac','portfw','notes',
'enable_3d','gpu_device','display','display_resolution','guest_os','audio','boot_order',
'enable_kvm','embed_display','vnc_port','spice_port','enable_serial','num_displays','favorite']
.map(id=>{const el=document.getElementById('e_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
const r=await apiPost('/api/save/'+sel,body);if(r){switchTab('summary');await refresh();setStatus('Settings saved.');}}
// ── VNet Editor ──
let vnetsData=[],vnetIdx=-1;
async function openVnets(){await loadVnets();document.getElementById('vnetdlg').showModal();}
async function loadVnets(){const r=await fetch('/api/vnets');if(r.ok)vnetsData=await r.json();renderVnetList();}
function renderVnetList(){const sel=document.getElementById('vnet_sel');let h='';if(!vnetsData.networks)vnetsData={networks:[]};
for(let i=0;i<vnetsData.networks.length;i++){const n=vnetsData.networks[i];const line=n.name+' — '+n.type;h+=`<option value="${i}"${i===vnetIdx?' selected':''}>${line}</option>`;}
sel.innerHTML=h;if(vnetIdx>=0&&vnetIdx<vnetsData.networks.length)showVnetFields(vnetIdx);}
function onVnetSelect(){const s=document.getElementById('vnet_sel');vnetIdx=parseInt(s.value);if(vnetIdx>=0)showVnetFields(vnetIdx);}
function showVnetFields(i){const n=vnetsData.networks[i];if(!n)return;
document.getElementById('vn_name').value=n.name||'';document.getElementById('vn_type').value=n.type||'nat';
document.getElementById('vn_subnet').value=n.subnet||'';document.getElementById('vn_mask').value=n.mask||'';
document.getElementById('vn_dhcp').value=n.dhcp?'1':'0';document.getElementById('vn_dstart').value=n.dhcp_start||'';
document.getElementById('vn_dend').value=n.dhcp_end||'';document.getElementById('vn_iface').value=n.host_iface||'';
document.getElementById('vn_gw').value=n.gateway||'';document.getElementById('vn_pf').value=n.port_forwards||'';}
function vnetSaveCurrent(){if(vnetIdx<0||vnetIdx>=vnetsData.networks.length)return;const n=vnetsData.networks[vnetIdx];
n.name=document.getElementById('vn_name').value;n.type=document.getElementById('vn_type').value;
n.subnet=document.getElementById('vn_subnet').value;n.mask=document.getElementById('vn_mask').value;
n.dhcp=document.getElementById('vn_dhcp').value==='1';n.dhcp_start=document.getElementById('vn_dstart').value;
n.dhcp_end=document.getElementById('vn_dend').value;n.host_iface=document.getElementById('vn_iface').value;
n.gateway=document.getElementById('vn_gw').value;n.port_forwards=document.getElementById('vn_pf').value;renderVnetList();}
function vnetAdd(){if(vnetsData.networks.length>=20)return;const n={name:'VMnet'+vnetsData.networks.length,type:'host_only',subnet:'192.168.100.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.100.128',dhcp_end:'192.168.100.254',host_iface:'',gateway:'',port_forwards:''};
vnetsData.networks.push(n);vnetIdx=vnetsData.networks.length-1;renderVnetList();}
function vnetRemove(){if(vnetIdx<0||vnetIdx>=vnetsData.networks.length)return;vnetsData.networks.splice(vnetIdx,1);if(vnetIdx>=vnetsData.networks.length)vnetIdx=vnetsData.networks.length-1;renderVnetList();}
function vnetDefaults(){const def=[{name:'VMnet0',type:'bridged',subnet:'',mask:'',dhcp:false,dhcp_start:'',dhcp_end:'',host_iface:'auto',gateway:'',port_forwards:''},{name:'VMnet1',type:'host_only',subnet:'192.168.118.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.118.128',dhcp_end:'192.168.118.254',host_iface:'',gateway:'',port_forwards:''},{name:'VMnet8',type:'nat',subnet:'192.168.140.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.140.128',dhcp_end:'192.168.140.254',host_iface:'',gateway:'192.168.140.2',port_forwards:'2222:192.168.140.128:22'}];
vnetsData={networks:def};vnetIdx=0;renderVnetList();}
async function vnetSaveAll(){const r=await apiPost('/api/vnets/save',JSON.stringify(vnetsData));if(r){document.getElementById('vnetdlg').close();setStatus('VNet settings saved.');}}
// ── Preferences ──
async function openPrefs(){const r=await fetch('/api/config');const cfg=r.ok?await r.json():{};
document.getElementById('p_theme').value=cfg.theme||window.kvmguiTheme||'system';document.getElementById('p_default_memory_mb').value=cfg.default_memory_mb||2048;
document.getElementById('p_default_cpu_cores').value=cfg.default_cpu_cores||2;document.getElementById('p_autoprotect_enabled').value=cfg.autoprotect_enabled_default?'1':'0';
document.getElementById('p_autoprotect_interval').value=cfg.autoprotect_interval_min_default||60;document.getElementById('p_autoprotect_max').value=cfg.autoprotect_max_default||10;
document.getElementById('prefsdlg').showModal();}
async function savePrefs(){const body=['theme','default_memory_mb','default_cpu_cores','autoprotect_enabled','autoprotect_interval','autoprotect_max']
.map(id=>{const el=document.getElementById('p_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
const r=await apiPost('/api/config',body);if(r){const el=document.getElementById('p_theme');if(el)window.applyTheme(el.value);document.getElementById('prefsdlg').close();setStatus('Preferences saved.');}}
// ── Dialog Backdrop Click-to-Close ──
['newdlg','snapdlg','clonedlg','vnetdlg','prefsdlg'].forEach(function(id){var dlg=document.getElementById(id);dlg.addEventListener('click',function(e){if(e.target===dlg)dlg.close();});});
// ── Sidebar Overlay Click-to-Close ──
document.body.addEventListener('click',function(e){if(document.body.classList.contains('sidebar-overlay')&&!e.target.closest('aside')){document.querySelector('aside').classList.remove('open');document.body.classList.remove('sidebar-overlay');}});
// ── Keyboard Shortcuts ──
document.addEventListener('keydown',function(e){if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.tagName==='SELECT')return;
if(e.key==='Escape'){
  var anyOpen=false;['newdlg','snapdlg','clonedlg','vnetdlg','prefsdlg'].forEach(function(id){var d=document.getElementById(id);if(d.open){d.close();anyOpen=true;}});
  if(!anyOpen&&sel!==null){sel=null;renderList();showEmptyState();}
  return;
}
if(e.ctrlKey&&e.key==='n'){e.preventDefault();newVm();return;}
if(e.ctrlKey&&e.key==='e'){e.preventDefault();if(sel!==null)editVm();return;}
if(e.key==='Delete'){if(sel!==null)deleteVm();return;}
if(e.key==='Enter'){if(sel!==null)powerToggle();return;}
});
// ── Periodic Refresh ──
refresh();
setInterval(refresh,5000);
// WebGPU/Canvas2D framebuffer display
let fbCanvas=document.getElementById('fbcanvas'),fbCtx=fbCanvas.getContext('2d'),fbInterval=null;
async function startFb(){if(sel===null){document.getElementById('display').style.display='none';if(fbInterval)clearInterval(fbInterval);return;}
document.getElementById('display').style.display='block';
if(fbInterval)clearInterval(fbInterval);fbInterval=setInterval(async()=>{if(sel===null||sel>=vms.length)return;const v=vms[sel];if(v.status!=='running')return;
try{const r=await fetch('/api/fb/'+sel);if(!r.ok)return;const buf=await r.arrayBuffer();const w=640,h=480;const needed=w*h*4;if(buf.byteLength<needed)return;fbCanvas.width=w;fbCanvas.height=h;
const img=fbCtx.createImageData(w,h);const src=new Uint8Array(buf);const dst=img.data;for(let i=0;i<w*h;i++){const o=i*4;dst[o]=src[o+2];dst[o+1]=src[o+1];dst[o+2]=src[o];dst[o+3]=255;}
fbCtx.putImageData(img,0,0);}catch(e){}},200)};
setInterval(()=>{if(sel!==null&&sel<vms.length&&vms[sel].status==='running')startFb();},2000);
// Serial console
let serialWs=null,serialIdx=null,serialManualOff=false;
function startSerial(idx){if(serialManualOff)return;if(serialWs&&serialIdx===idx)return;stopSerial();
if(idx===null||idx>=vms.length)return;const v=vms[idx];if(v.status!=='running'||!v.hasSerial)return;
serialIdx=idx;const term=document.getElementById('serialterm');term.value='';document.getElementById('serialpanel').style.display='block';
const proto=location.protocol==='https:'?'wss:':'ws:';serialWs=new WebSocket(proto+'//'+location.host+'/ws/serial/'+idx);
serialWs.onmessage=e=>{term.value+=e.data;term.scrollTop=term.scrollHeight;};
serialWs.onclose=()=>{stopSerial();};
serialWs.onerror=()=>{stopSerial();};}
function stopSerial(){if(serialWs){serialWs.close();serialWs=null;}serialIdx=null;const term=document.getElementById('serialterm');if(term)term.value='';document.getElementById('serialpanel').style.display='none';}
function manualDisconnectSerial(){serialManualOff=true;stopSerial();}
document.getElementById('serialterm').addEventListener('keydown',e=>{if(!serialWs||serialWs.readyState!==WebSocket.OPEN)return;
e.preventDefault();let s=e.key;if(e.key==='Enter')s='\r\n';else if(e.key==='Backspace')s='\x08';else if(e.key==='Tab')s='\t';
if(s.length===1||s==='\r\n'||s==='\x08'||s==='\t')serialWs.send(s);});
setInterval(()=>{if(sel!==null&&sel<vms.length){const v=vms[sel];if(serialManualOff&&serialIdx!==sel)serialManualOff=false;if(v.status==='running'&&v.hasSerial)startSerial(sel);else stopSerial();}},3000);
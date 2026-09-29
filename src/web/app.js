// SPDX-License-Identifier: MIT
// These must live at global script scope: the API helpers (apiPost, setBusy,
// loadLogInto, ...) below reference them, and they are NOT inside the theme IIFE.
var DEBUG=false;
// Built-in default X-API-Key. The bundled UI is same-origin and only fully
// functional under the daemon's default key (loopback). Setting KV_API_KEY to a
// strong secret exposes the daemon on all interfaces for vmrun/remote use, and
// browser write-actions then return 401, that path is intentionally CLI-only.
var API_KEY='hangar';
var logDebug=DEBUG?function(t,a){console.warn(t,a);}:function(){};
(function(){
const saved=localStorage.getItem('hangar-theme')||'dark';
window.hangarTheme=saved;
window.applyTheme=function(t){
 window.hangarTheme=t;
 localStorage.setItem('hangar-theme',t);
 const light=t==='light'||(t==='system'&&window.matchMedia('(prefers-color-scheme:light)').matches);
 document.documentElement.classList.toggle('light',light);
 document.documentElement.classList.toggle('dark',t==='dark');
};
window.applyTheme(saved);
// The toggle shows which theme is active through the sprite set (moon / sun /
// display), not a color emoji: every other toolbar control is a sprite, and a
// platform emoji is the one glyph that ignores the accent and radius tokens.
var themeIcons={system:'/icons.svg#i-monitor',light:'/icons.svg#i-sun',dark:'/icons.svg#i-theme'};
function syncThemeButtons(theme){
 var btns=document.querySelectorAll('.theme-toggle-btn');
 var label='Theme: '+theme.charAt(0).toUpperCase()+theme.slice(1)+' (click to change)';
 for(var i=0;i<btns.length;i++){
  var use=btns[i].querySelector('use');
  if(!use){var svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('class','ico');svg.setAttribute('aria-hidden','true');use=document.createElementNS('http://www.w3.org/2000/svg','use');svg.appendChild(use);btns[i].appendChild(svg);}
  use.setAttribute('href',themeIcons[theme]||themeIcons.system);
  btns[i].setAttribute('aria-label',label);btns[i].setAttribute('title',label);}
}
syncThemeButtons(saved);
window.matchMedia('(prefers-color-scheme:light)').addEventListener('change',function(){
 if(window.hangarTheme==='system') window.applyTheme('system');
});
function cycleTheme(){
 var themes=['system','light','dark'];
 var cur=window.hangarTheme||'system';
 var idx=themes.indexOf(cur);
 var next=themes[(idx+1)%themes.length];
 window.applyTheme(next);
 syncThemeButtons(next);
 showToast('Theme: '+next.charAt(0).toUpperCase()+next.slice(1),'info',{duration:2000});
}
window.cycleTheme=cycleTheme; // expose to global scope: the toolbar theme button + command palette (outside this IIFE) call it
})();
var vms=[]; var sel=null; var activeTab='summary'; var transitioningIdx=null; var refreshBusy=false;
// VMs are addressed by list index, but the background poll replaces vms[] wholesale.
// Resolve a VM's CURRENT index by its (server-unique) name right before an
// index-addressed request whose target was captured before an await, so a
// concurrent reorder/delete can't make the request hit a different VM. -1 if gone.
function idxByName(n){for(var i=0;i<vms.length;i++){if(vms[i].name===n)return i;}return -1;}
// Resolve current index by stable id, survives rename (preferred for tracking a
// VM across the poll for destructive/long-running actions).
function idxById(id){if(!id)return -1;for(var i=0;i<vms.length;i++){if(vms[i].id===id)return i;}return -1;}
// The /api/vms response encodes config flags as JSON booleans (true/false), but
// every consumer below compares them as the strings 'true'/'false'. Coerce any
// boolean-valued property back to that string form so the comparisons hold.
function normVmBools(arr){if(Array.isArray(arr)){for(var i=0;i<arr.length;i++){var v=arr[i];if(v&&typeof v==='object'){for(var k in v){if(typeof v[k]==='boolean')v[k]=v[k]?'true':'false';}}}}return arr;}
var dashSort={col:'name',dir:1}; // host-dashboard inventory-table sort state
var selectMode=false; var checkedIds=new Set(); // sidebar multi-select bulk-ops state
var settingsCategory='compute';
var displayLabels=['GTK','SDL','SPICE','VNC','None'];
var gpuLabels=['Virtio-GPU (virgl 3D)','Virtio-VGA (virgl 3D)','Virtio-GPU','Virtio-VGA','QXL','Standard VGA'];
function relAge(ts){var t=Date.parse(String(ts).replace(' ','T'));if(!t)return '';var d=Math.floor((Date.now()-t)/1000);if(d<0)return '';
if(d<60)return 'just now';if(d<3600)return Math.floor(d/60)+' min ago';if(d<86400)return Math.floor(d/3600)+' h ago';return Math.floor(d/86400)+' d ago';}
// Shared OS/distro visual identity (emblem color + monogram), used by the
// catalog cards, the summary header, and the inventory grid for a consistent
// visual language. `hint` is a name or description string; `osLabel` is the
// guest-OS label/family fallback.
function osBrand(hint,osLabel){var n=((hint||'')+' '+(osLabel||'')).toLowerCase();
 if(/ubuntu/.test(n))return {c:'#E95420',m:'U'};
 if(/fedora/.test(n))return {c:'#3C6EB4',m:'F'};
 if(/debian/.test(n))return {c:'#A80030',m:'D'};
 if(/alpine/.test(n))return {c:'#0D597F',m:'A'};
 if(/\barch\b/.test(n))return {c:'#1793D1',m:'A'};
 if(/rocky|alma|centos|rhel|red ?hat/.test(n))return {c:'#10B981',m:'R'};
 if(/openbsd/.test(n))return {c:'#F2CA30',m:'O'};
 if(/freebsd|\bbsd\b/.test(n))return {c:'#AB2B28',m:'B'};
 if(/windows|microsoft/.test(n))return {c:'#0078D4',m:'W'};
 if(/mac ?os|apple|darwin/.test(n))return {c:'#555',m:'M'};
 if(/linux/.test(n))return {c:'#5B7A8C',m:'L'};
 return {c:'var(--accent)',m:((hint||osLabel||'?').charAt(0)||'?').toUpperCase()};}
function escHtml(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
function announceStatus(s){var a=document.getElementById('statusannounce');if(a)a.textContent=s;}
function setStatus(s){var el=document.getElementById('statusmsg');if(!el)return;el.textContent=s;el.classList.remove('loading');announceStatus(s);}
function setStatusLoading(s){var el=document.getElementById('statusmsg');if(!el)return;el.textContent=s+'…';el.classList.add('loading');announceStatus(s);}
var toastIcons={success:'i-check',error:'i-x',info:'i-info',warn:'i-alert'};
function showToast(msg,type,opts){type=type||'info';var c=document.getElementById('toast-container');if(!c)return;var toasts=c.querySelectorAll('.toast');while(toasts.length>=5){c.removeChild(toasts[0]);toasts=c.querySelectorAll('.toast');}var t=document.createElement('div');t.className='toast '+type;t.setAttribute('role',(type==='error'||type==='warn')?'alert':'status');var icon=toastIcons[type]||toastIcons.info;var inner='<span class=\"toast-icon\" aria-hidden=\"true\"><svg class=\"ico\"><use href=\"#'+icon+'\"/></svg></span><span class=\"toast-msg\">'+escHtml(msg)+'</span>';if(opts&&opts.action){inner+='<button class=\"toast-action\" data-toast-action=\"'+opts.action+'\">UNDO</button>';}t.innerHTML=inner;c.appendChild(t);
if(opts&&opts.action&&opts.onAction){t.querySelector('.toast-action').addEventListener('click',function(){opts.onAction();c.removeChild(t);});}
var reducedMotion=window.matchMedia('(prefers-reduced-motion:reduce)').matches;
var defaultDur=type==='error'?6500:type==='warn'?5000:4000;
setTimeout(function(){if(reducedMotion){if(t.parentNode)c.removeChild(t);}else{t.classList.add('exit');setTimeout(function(){if(t.parentNode)c.removeChild(t);},280);}},opts&&opts.duration?opts.duration:defaultDur);}
function toastUndo(msg,onUndo){showToast(msg,'info',{action:'undo',onAction:onUndo,duration:5000});}
// ── Confirm dialog (replaces native confirm() with custom modal) ──
function showConfirmDialog(msg,opts){return window.hangarUi.confirm(msg,opts);}
// ── Prompt dialog (replaces native prompt() with custom modal) ──
function showPromptDialog(label,defaultValue,suggestions){return window.hangarUi.prompt(label,defaultValue||'',suggestions||[]);}
var apiPostPending=0;
var loadBar=null;
function initLoadBar(){loadBar=document.createElement('div');loadBar.id='loadbar';var mn=document.querySelector('main');if(mn)mn.appendChild(loadBar);else document.body.appendChild(loadBar);}
function setLoadBar(on){if(!loadBar)initLoadBar();if(on)loadBar.classList.add('active');else{loadBar.classList.remove('active');}}
var busy=false,busyGen=0; // guard against double-submit
function setBusy(){if(busy)return false;busy=true;var gen=++busyGen;setTimeout(function(){if(busyGen===gen){busy=false;apiPostPending=0;setLoadBar(false);setStatus('');logDebug('busy guard auto-cleared after 300s, request may be hung');}},300000);return true;} // fallback auto-clear: only for a genuinely hung request. Set well above realistic op durations (a large qcow2 compact/resize can run minutes) so a slow-but-progressing op keeps the gate (no double-submit, no poll-vs-mutation swap) for its whole duration; apiPost itself clears busy on completion/error.
async function apiPost(url,body){if(!setBusy()){showToast('Another operation is in progress, please wait.','warn');return null;}var sb=document.getElementById('statusmsg');var wasIdle=apiPostPending<=0;var prev=sb?sb.textContent:'Ready';if(wasIdle){setStatusLoading('Working...');setLoadBar(true);}apiPostPending++;try{var opts={method:'POST',body:body||'',headers:{'X-API-Key':API_KEY}};var r=await fetch(url,opts);if(!r.ok){var msg=await r.text().catch(function(){return '';});try{var j=JSON.parse(msg);if(j.error)msg=j.error;}catch(e){}throw new Error(msg||'HTTP '+r.status);}apiPostPending--;if(apiPostPending<=0){setStatus(prev);setLoadBar(false);}busy=false;busyGen++;return r;}catch(e){apiPostPending--;if(apiPostPending<=0){setStatus('Error: '+e.message);setLoadBar(false);}busy=false;busyGen++;showToast(e.message||'Request failed','error');return null;}}
var sidebarOpen=false;
function isMobileSidebar(){return window.matchMedia('(max-width:900px)').matches;}
function syncSidebarButton(){const aside=document.querySelector('aside');var expanded=isMobileSidebar()?sidebarOpen:!document.body.classList.contains('sidebar-collapsed');if(window.hangarUi)window.hangarUi.setToolbar({sidebarExpanded:expanded});if(aside){aside.toggleAttribute('inert',!expanded);aside.setAttribute('aria-hidden',expanded?'false':'true');}}
function toggleSidebar(){const aside=document.querySelector('aside');if(isMobileSidebar()){sidebarOpen=!sidebarOpen;if(aside){if(sidebarOpen){aside.classList.add('open');document.body.classList.add('sidebar-overlay');}else{aside.classList.remove('open');document.body.classList.remove('sidebar-overlay');}}}else{sidebarOpen=false;if(aside)aside.classList.remove('open');document.body.classList.remove('sidebar-overlay');document.body.classList.toggle('sidebar-collapsed');}syncSidebarButton();}
function closeSidebar(){if(!isMobileSidebar()){syncSidebarButton();return;}if(!sidebarOpen)return;sidebarOpen=false;const aside=document.querySelector('aside');if(aside){aside.classList.remove('open');document.body.classList.remove('sidebar-overlay');}syncSidebarButton();}
function clearSearch(){var s=document.getElementById('search');if(!s)return;s.value='';filterList();}
var settingsDirty=false;
function syncTabPanels(){var panelIds={console:'tabConsole',summary:'tabSummary',settings:'tabSettings'};var btns=document.querySelectorAll('.tab-btn');for(var bi=0;bi<btns.length;bi++){var on=btns[bi].getAttribute('data-tab')===activeTab;btns[bi].classList.toggle('active',on);btns[bi].setAttribute('aria-selected',on?'true':'false');btns[bi].setAttribute('tabindex',on?'0':'-1');} // roving tabindex: one tab stop for the tablist
for(var k in panelIds){var p=document.getElementById(panelIds[k]);if(!p)continue;var show=k===activeTab;p.style.display=show?'block':'none';p.setAttribute('aria-hidden',show?'false':'true');}}
async function switchTab(tab){if(activeTab===tab)return;
if(activeTab==='settings'&&tab!=='settings'&&settingsDirty){if(!(await showConfirmDialog('You have unsaved changes. Discard them?',{danger:true,okLabel:'Discard'})))return;}
var panelIds={console:'tabConsole',summary:'tabSummary',settings:'tabSettings'};
var oldEl=document.getElementById(panelIds[activeTab]||'tabSummary');
activeTab=tab;
var s=document.getElementById('tabSummary');var st=document.getElementById('tabSettings');var co=document.getElementById('tabConsole');
const btns=document.querySelectorAll('.tab-btn');btns.forEach(b=>{b.classList.remove('active');b.setAttribute('aria-selected','false');b.setAttribute('tabindex','-1');});
var newEl=tab==='settings'?st:(tab==='console'?co:s);
for(var bi=0;bi<btns.length;bi++){if(btns[bi].getAttribute('data-tab')===tab){btns[bi].classList.add('active');btns[bi].setAttribute('aria-selected','true');btns[bi].setAttribute('tabindex','0');}}
if(!newEl)return;
if(oldEl){oldEl.style.display='none';oldEl.setAttribute('aria-hidden','true');newEl.style.display='block';newEl.setAttribute('aria-hidden','false');}
else{newEl.style.display='block';newEl.setAttribute('aria-hidden','false');}
if(tab==='settings'&&sel!==null)editVm();}
var serverDown=false;
var saveInFlight=false;
function setServerDown(s){serverDown=s;var b=document.getElementById('connbanner');if(b)b.style.display=s?'flex':'none';if(s)setStatus('Server unreachable, retrying...');}
async function refresh(){if(document.hidden)return;if(refreshBusy)return;if(transitioningIdx!==null||saveInFlight||busy||apiPostPending>0)return;refreshBusy=true;try{const prevStatus=(sel!==null&&sel<vms.length)?vms[sel].status:null;const prevName=(sel!==null&&sel<vms.length)?vms[sel].name:null;const ctl=new AbortController();const t=setTimeout(function(){ctl.abort();},15000);try{const r=await fetch('/api/vms',{signal:ctl.signal});clearTimeout(t);if(!r.ok){if(r.status>=500){if(!serverDown){setServerDown(true);}}return;}
setServerDown(false);vms=normVmBools(await r.json());publishVms();
// Only act on a status transition if the selection still points at the SAME VM
// we sampled before the await. If the user switched VMs mid-fetch, select()
// already (re)started the console for the new VM, touching fb/serial here with
// the stale prevStatus would flap it. Compare by name (indices shift on
// delete/reorder).
if(sel!==null&&sel<vms.length&&vms[sel].name===prevName){const curStatus=vms[sel].status;if(curStatus!==prevStatus){if(curStatus==='running'){startFb();startSerial(sel);if(activeTab==='summary'&&embeddedDisplayCapable(vms[sel]))switchTab('console');}else{stopFb();stopSerial(true);if(activeTab==='console')switchTab('summary');}}}renderList();if(sel!==null&&sel<vms.length)renderDetails();else if(sel===null)showEmptyState();}catch(e){clearTimeout(t);if(!serverDown){setServerDown(true);}}}finally{refreshBusy=false;}}
function filterList(){const s=document.getElementById('search');if(!s)return;const f=s.value;const clr=document.getElementById('searchClear');if(clr)clr.style.display=f?'inline-flex':'none';renderList(f.toLowerCase());}
// VM folders are a `folder:<path>` tag convention (no backend change). The sidebar
// groups non-favorite VMs into collapsible folders; open/closed persists locally.
function vmFolder(v){return (v&&v.folder)?v.folder.trim():'';}
// User-facing tags exclude the structural folder:<path> tag.
function visibleTags(t){return (t||'').split(',').map(function(s){return s.trim();}).filter(function(s){return s&&s.toLowerCase().indexOf('folder:')!==0;});}
function folderOpen(f){try{var c=JSON.parse(localStorage.getItem('hangar.folders')||'{}');return c[f]!==false;}catch(e){return true;}}
function setFolderOpen(f,o){try{var c=JSON.parse(localStorage.getItem('hangar.folders')||'{}');c[f]=o;localStorage.setItem('hangar.folders',JSON.stringify(c));}catch(e){}}
async function moveToFolder(){if(sel===null||sel>=vms.length)return;var v=vms[sel];var cur=vmFolder(v);
  var folders=[];vms.forEach(function(x){var fl=vmFolder(x);if(fl&&folders.indexOf(fl)<0)folders.push(fl);});folders.sort();
  var f=await showPromptDialog('Move "'+v.name+'" to folder (blank = none):',cur,folders);if(f===null)return;f=f.trim();
  var r=await apiPost('/api/vms/'+sel,'folder='+encodeURIComponent(f));
  if(r){await refresh();setStatus(f?('Moved to '+escHtml(f)):'Removed from folder');}}
function renderList(filter){const e=document.getElementById('vmlist');if(!e||!window.hangarUi)return;e.removeAttribute('aria-busy');const search=document.getElementById('search');const f=(filter===undefined?(search?search.value:''):(filter||'')).toLowerCase();
const viz=vms.map((v,i)=>({i,show:!f||(v.name||'').toLowerCase().includes(f)||(v.tags||'').toLowerCase().includes(f),fav:v.favorite==='true',v}));
const firstVisible=viz.find(x=>x.show);
// Roving tabindex: the list is one tab stop. The selected row is that stop;
// with nothing selected the first rendered row takes it so Tab still reaches the list.
const rovingIdx=sel!==null?sel:(firstVisible?firstVisible.i:-1);
function rowFor(x){return {index:x.i,id:String(x.v.id),name:x.v.name,status:['running','paused','suspended'].includes(x.v.status)?x.v.status:'stopped',meta:(Number(x.v.cpu)||1)+' vCPU \u00b7 '+memText(x.v.mem),favorite:x.fav,active:sel===x.i,transitioning:transitioningIdx===x.i,checked:checkedIds.has(x.v.id),tabStop:x.i===rovingIdx};}
// Non-favorites group into collapsible folders (folder:<path> tag); ungrouped last.
const groups={},order=[],ungrouped=[];
for(const x of viz){if(!x.show||x.fav)continue;const fld=vmFolder(x.v);if(fld){if(!groups[fld]){groups[fld]=[];order.push(fld);}groups[fld].push(rowFor(x));}else ungrouped.push(rowFor(x));}
order.sort();
window.hangarUi.renderVmList({favorites:viz.filter(x=>x.show&&x.fav).map(rowFor),folders:order.map(fld=>({name:fld,open:folderOpen(fld),rows:groups[fld]})),ungrouped:ungrouped,selectMode:selectMode,filtered:f!==''});
updateBulkBar();
let cnt=0,running=0,paused=0,suspended=0;for(let v of vms){cnt++;if(v.status==='running')running++;else if(v.status==='paused')paused++;else if(v.status==='suspended')suspended++;}
let parts=cnt+(cnt===1?' virtual machine':' virtual machines');if(running>0)parts+=', '+running+' running';if(paused>0)parts+=', '+paused+' paused';if(suspended>0)parts+=', '+suspended+' suspended';
if(sel!==null&&sel<vms.length){const v=vms[sel];let st=v.name+': '+v.status;if(v.status==='running'&&Number.isFinite(v.uptime_sec)&&v.uptime_sec>=0){const elapsed=Math.floor(v.uptime_sec);const days=Math.floor(elapsed/86400);const hrs=Math.floor((elapsed%86400)/3600);const mins=Math.floor((elapsed%3600)/60);const secs=elapsed%60;st+=' | Uptime: '+(days>0?days+'d ':'')+hrs+':'+String(mins).padStart(2,'0')+':'+String(secs).padStart(2,'0');}st+='    |    '+parts;var sb=document.getElementById('statusmsg');if(sb)sb.textContent=st;}
else{var sb2=document.getElementById('statusmsg');if(sb2)sb2.textContent=parts;}updateCommandState();}
async function toggleFavorite(i){if(i>=vms.length)return;const fav=vms[i].favorite==='true'?'0':'1';
const r=await apiPost('/api/vms/'+i,'favorite='+fav);if(r){if(i<vms.length){vms[i].favorite=fav==='1'?'true':'false';}renderList();if(sel===i)renderDetails();}}
function selectedVm(){return sel!==null&&sel<vms.length?vms[sel]:null;}
function statusLabel(s){if(s==='running')return 'Running';if(s==='paused')return 'Paused';if(s==='suspended')return 'Suspended';if(s==='stopped')return 'Stopped';return s||'Unknown';}
function embeddedDisplayCapable(v){var dt=Number(v&&v.display);return v&&v.embed_display==='true'&&(dt===2||dt===3);}
function networkLabel(v){var n=(v&&v.net)||'user';if(n==='user')return 'NAT (user mode)';if(n==='gvproxy')return 'gvproxy (user mode)';if(n==='bridge')return 'Bridged';if(n==='none')return 'Disconnected';return n;}
function displayInfo(v){var displayLabel=displayLabels[Number(v&&v.display)]||'Display';var gpuLabel=gpuLabels[Number(v&&v.gpu_device)]||'GPU';var has3d=v&&v.enable_3d==='true';if(!has3d)gpuLabel=gpuLabel.replace(/ \(virgl 3D\)/,'');var embedLabel=v&&v.embed_display==='true'?'Embedded':'Native';var accelLabel=has3d?'3D accelerated':'2D';return {displayLabel:displayLabel,gpuLabel:gpuLabel,embedLabel:embedLabel,accelLabel:accelLabel};}
function closeToolbarMenus(returnFocus){return !!(window.hangarUi&&window.hangarUi.closeToolbarMenus(returnFocus));}
async function select(i){if(i===sel)return;if(activeTab==='settings'&&settingsDirty&&sel!==i){if(!(await showConfirmDialog('You have unsaved changes. Discard them?',{danger:true,okLabel:'Discard'})))return;settingsDirty=false;}stopFb();stopSerial(true);sel=i;renderList();closeSidebar();closeToolbarMenus(false);if(sel!==null){var v=vms[sel];if(v&&v.status==='running'&&embeddedDisplayCapable(v)&&activeTab!=='settings')activeTab='console';if(activeTab==='settings')editVm();else renderDetails();if(v&&v.status==='running'){startFb();startSerial(sel);}}else{showEmptyState();}updateCommandState();}
async function deselectVm(){if(activeTab==='settings'&&settingsDirty){if(!(await showConfirmDialog('You have unsaved changes. Discard them?',{danger:true,okLabel:'Discard'})))return;}stopFb();stopSerial(true);sel=null;renderList();showEmptyState();updateCommandState();}
// Host inventory dashboard shown when no VM is selected: state breakdown +
// allocated-capacity totals + an attention list. Pure render from the polled vms[].
// ── Reactive host dashboard (VanJS) ──────────────────────────────────
// vmsState/dashSortState drive the dashboard DOM in place: no innerHTML
// rebuilds, so focus (e.g. a sort header) survives every refresh.
// Hardware slot limits: served by GET /api/capabilities (vm.zig constants);
// the defaults below only cover the window before that fetch resolves.
var MAX_NICS=8,MAX_EXTRA_DISKS=4;
(function(){try{fetch('/api/capabilities').then(function(r){return r.json();}).then(function(c){if(c.max_nics)MAX_NICS=c.max_nics;if(c.max_extra_disks)MAX_EXTRA_DISKS=c.max_extra_disks;}).catch(function(){});}catch(e){}})();
// Settings rows for NIC 2..MAX_NICS and the extra-disk slots are generated,
// never hand-enumerated: adding a slot in vm.zig must not require UI edits.
function nicRows(v){var r=[];for(var n=2;n<=MAX_NICS;n++){r.push(['NIC '+n,'e_nic'+n,'select',v['nic'+n+'_mode']||'none'],['NIC '+n+' MAC','e_nic'+n+'_mac','text',v['nic'+n+'_mac']||'','pattern="([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"'],['NIC '+n+' VMnet','e_nic'+n+'_vnet','text',v['nic'+n+'_vnet']||'','placeholder="virtual network name (optional)"']);}return r;}
function extraDiskRows(v){var r=[];for(var n=0;n<MAX_EXTRA_DISKS;n++){r.push(['Extra '+n+' Path','e_extra'+n+'_path','text',v['extra'+n+'_path']||''],['Extra '+n+' Size','e_extra'+n+'_size','number',v['extra'+n+'_size']||0,'min="0" max="65536" step="1"'],['Extra '+n+' Format','e_extra'+n+'_format','select',v['extra'+n+'_format']||0]);}return r;}

var vmsState=null,dashSortState=null,dashMounted=false,hostState=null;
function publishVms(){if(window.van){if(!vmsState){vmsState=van.state(vms.slice());}else{vmsState.val=vms.slice();}}}
function fetchHost(){if(!window.van)return;if(!hostState)hostState=van.state({cpu_cores:0,ram_mb:0});try{fetch('/api/host').then(function(r){return r.json();}).then(function(h){hostState.val={cpu_cores:h.cpu_cores||0,ram_mb:h.ram_mb||0};}).catch(function(){});}catch(e){}}
function dashStats(list){var st={running:0,stopped:0,paused:0,suspended:0},vcpu=0,ram=0,disk=0,att=[];
 for(var i=0;i<list.length;i++){var v=list[i];st[v.status]=(st[v.status]||0)+1;vcpu+=Number(v.cpu)||0;ram+=Number(v.mem)||0;disk+=Number(v.disk)||0;if(summaryWarnings(v)!=='')att.push(v.name);}
 return {st:st,vcpu:vcpu,ramMB:ram,ramGB:memGiB(ram),disk:disk,att:att,count:list.length};}
var DASH_COLS=[['name','Name'],['status','State'],['os','Guest OS'],['cpu','vCPU'],['mem','RAM'],['disk','Disk'],['folder','Folder'],['tags','Tags']];
function DashView(){
 var t=van.tags;
 if(!dashSortState)dashSortState=van.state({col:dashSort.col,dir:dashSort.dir});
 function card(get,label,cls){return t.div({class:'dash-card'},t.div({class:'dash-num '+(cls||'')},get),t.div({class:'dash-lbl'},label));}
 function physCpu(){return (hostState&&hostState.val.cpu_cores)||0;}
 function physRamMb(){return (hostState&&hostState.val.ram_mb)||0;}
 function gauge(label,getCommitted,getPhysical,unit){
  return t.div({class:'cap-row'},
   t.span({class:'cap-label'},label),
   t.div({class:'cap-bar'},t.span({class:'cap-fill',style:function(){var c=getCommitted(),p=getPhysical();var pct=p>0?Math.min(100,Math.round(c/p*100)):0;return 'width:'+pct+'%;background:'+(p>0&&c>p?'var(--danger)':'var(--accent)');}})),
   t.span({class:'cap-val'},function(){var c=getCommitted(),p=getPhysical();return p>0?(c+' / '+p+' '+unit):(c+' '+unit);}),
   t.span({class:'cap-over'},function(){var c=getCommitted(),p=getPhysical();return (p>0&&c>p)?((Math.round(c/p*100)/100)+'× overcommit'):'';}));
 }
 return t.div({class:'dash'},
  t.div({class:'dash-head'},t.h2('Inventory'),t.span({class:'muted'},function(){var c=vmsState.val.length;return c+' virtual machine'+(c===1?'':'s');})),
  t.div({class:'cap-panel',style:function(){return (physCpu()||physRamMb())?'':'display:none';}},
   t.div({class:'cap-panel-head'},t.h3('Host Capacity'),t.span({class:'muted'},function(){return physCpu()+' cores · '+memGiB(physRamMb())+' GiB RAM';})),
   gauge('vCPU committed',function(){return dashStats(vmsState.val).vcpu;},physCpu,'vCPU'),
   gauge('RAM committed',function(){return dashStats(vmsState.val).ramMB;},physRamMb,'MiB')),
  t.div({class:'dash-cards'},
   card(function(){return String(dashStats(vmsState.val).st.running||0);},'Running','running'),
   card(function(){return String(dashStats(vmsState.val).st.stopped||0);},'Stopped',''),
   card(function(){return String(dashStats(vmsState.val).st.paused||0);},'Paused','paused'),
   card(function(){return String(dashStats(vmsState.val).st.suspended||0);},'Suspended','suspended')),
  t.div({class:'dash-cards'},
   card(function(){return String(dashStats(vmsState.val).vcpu);},'vCPU allocated',''),
   card(function(){return dashStats(vmsState.val).ramGB+' GiB';},'RAM allocated',''),
   card(function(){return dashStats(vmsState.val).disk+' GB';},'Disk provisioned','')),
  function(){var att=dashStats(vmsState.val).att;
   return att.length?t.div({class:'dash-attention'},t.h3('Needs attention'),t.ul(att.map(function(n){return t.li(n);}))):t.div();},
  t.div({class:'inv-wrap'},t.table({class:'inv'},
   t.thead(t.tr(DASH_COLS.map(function(c){return t.th({'data-action':'sortInv','data-col':c[0],tabindex:'0','aria-sort':function(){var so=dashSortState.val;return so.col===c[0]?(so.dir>0?'ascending':'descending'):'none';}},function(){var so=dashSortState.val;return c[1]+(so.col===c[0]?(so.dir>0?' ▲':' ▼'):'');});}))),
   function(){var so=dashSortState.val;var rows=vmsState.val.map(function(v,i){return {v:v,i:i};});
    rows.sort(function(a,b){var c=so.col,d=so.dir,x=a.v[c],y=b.v[c];
     if(c==='cpu'||c==='mem'||c==='disk'){return ((Number(x)||0)-(Number(y)||0))*d;}
     x=(x||'').toString().toLowerCase();y=(y||'').toString().toLowerCase();return x<y?-d:x>y?d:0;});
    return t.tbody(rows.map(function(r){var v=r.v;var mt=escHtml(memText(v.mem));
     return t.tr({'data-action':'select','data-vm-index':String(r.i),tabindex:'0'},
      t.td({class:'inv-name'},v.name),
      t.td(t.span({class:'sdot '+v.status}),statusLabel(v.status)),
      t.td(function(){var br=osBrand(v.name,v.os);return t.span({class:'os-cell'},t.span({class:'os-badge',style:'background:'+br.c},br.m),v.os);}),t.td(String(v.cpu)),t.td(mt),t.td(v.disk+' GB'),
      t.td({class:'muted'},v.folder||''),
      t.td(visibleTags(v.tags).map(function(tag){return t.span({class:'tag-chip sm'},tag);})));}));}
  )),
  t.div({class:'empty-actions',style:'justify-content:flex-start;margin-top:18px'},
   t.button({class:'btn primary','data-action':'newVm'},'New VM'),
   t.button({class:'btn','data-action':'importGuest'},'Import VM'),
   t.button({class:'btn','data-action':'openCatalog'},'Catalog')));
}
function mountDashboard(host){
 if(dashMounted&&host.firstChild&&host.firstChild.classList&&host.firstChild.classList.contains('dash'))return;
 publishVms();fetchHost();host.innerHTML='';van.add(host,DashView());addActionIcons(host);dashMounted=true;}

// VanJS builds nodes from tag functions, so the sprite glyph for the dashboard
// action buttons is inserted after mount. Same pattern as the theme toggle:
// every action button carries its `/icons.svg#i-*` symbol.
var dashActionIcons={'newVm':'/icons.svg#i-plus','importGuest':'/icons.svg#i-import','openCatalog':'/icons.svg#i-grid'};
function addActionIcons(root){const btns=root.querySelectorAll('.empty-actions [data-action]');
 for(let i=0;i<btns.length;i++){const b=btns[i];const href=dashActionIcons[b.getAttribute('data-action')];if(!href||b.querySelector('svg'))continue;
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('class','ico');svg.setAttribute('aria-hidden','true');
  const use=document.createElementNS('http://www.w3.org/2000/svg','use');use.setAttribute('href',href);svg.appendChild(use);b.insertBefore(svg,b.firstChild);}}

function hostDashboardHtml(){
  var st={running:0,stopped:0,paused:0,suspended:0};var vcpu=0,ram=0,disk=0,attention=[];
  for(var i=0;i<vms.length;i++){var v=vms[i];st[v.status]=(st[v.status]||0)+1;
    vcpu+=Number(v.cpu)||0;ram+=Number(v.mem)||0;disk+=Number(v.disk)||0;
    if(summaryWarnings(v)!=='')attention.push(v.name);}
  var ramGB=memGiB(ram);
  function card(n,l,cls){return '<div class="dash-card"><div class="dash-num '+(cls||'')+'">'+n+'</div><div class="dash-lbl">'+l+'</div></div>';}
  var h='<div class="dash"><div class="dash-head"><h2>Inventory</h2><span class="muted">'+vms.length+' virtual machine'+(vms.length===1?'':'s')+'</span></div>';
  h+='<div class="dash-cards">'+card(st.running||0,'Running','running')+card(st.stopped||0,'Stopped','')+card(st.paused||0,'Paused','paused')+card(st.suspended||0,'Suspended','suspended')+'</div>';
  h+='<div class="dash-cards">'+card(vcpu,'vCPU allocated')+card(ramGB+' GiB','RAM allocated')+card(disk+' GB','Disk provisioned')+'</div>';
  if(attention.length){h+='<div class="dash-attention"><h3>Needs attention</h3><ul>';for(var a=0;a<attention.length;a++)h+='<li>'+escHtml(attention[a])+'</li>';h+='</ul></div>';}
  // Sortable inventory table (vSphere "VMs" grid). Rows reuse the select handler.
  var cols=DASH_COLS;
  var rows=vms.map(function(v,i){return {v:v,i:i};});
  rows.sort(function(a,b){var c=dashSort.col,d=dashSort.dir,x=a.v[c],y=b.v[c];
    if(c==='cpu'||c==='mem'||c==='disk'){return ((Number(x)||0)-(Number(y)||0))*d;}
    x=(x||'').toString().toLowerCase();y=(y||'').toString().toLowerCase();return x<y?-d:x>y?d:0;});
  h+='<div class="inv-wrap"><table class="inv"><thead><tr>';
  cols.forEach(function(c){var on=dashSort.col===c[0];var ar=on?(dashSort.dir>0?' ▲':' ▼'):'';h+='<th data-action="sortInv" data-col="'+c[0]+'" tabindex="0" aria-sort="'+(on?(dashSort.dir>0?'ascending':'descending'):'none')+'">'+c[1]+ar+'</th>';});
  h+='</tr></thead><tbody>';
  rows.forEach(function(r){var v=r.v;var mt=escHtml(memText(v.mem));
    h+='<tr data-action="select" data-vm-index="'+r.i+'" tabindex="0">';
    h+='<td class="inv-name">'+escHtml(v.name)+'</td>';
    h+='<td><span class="sdot '+v.status+'"></span>'+escHtml(statusLabel(v.status))+'</td>';
    h+='<td>'+escHtml(v.os)+'</td><td>'+escHtml(v.cpu)+'</td><td>'+mt+'</td><td>'+escHtml(v.disk)+' GB</td>'
h+='<td class="muted">'+escHtml(v.folder||'')+'</td>';
    h+='<td>'+visibleTags(v.tags).map(function(t){return '<span class="tag-chip sm">'+escHtml(t)+'</span>';}).join('')+'</td>';
    h+='</tr>';});
  h+='</tbody></table></div>';
  h+='<div class="empty-actions" style="justify-content:flex-start;margin-top:18px"><button class="btn primary" data-action="newVm"><svg class="ico" aria-hidden="true"><use href="/icons.svg#i-plus"/></svg>New VM</button><button class="btn" data-action="importGuest">Import VM</button><button class="btn" data-action="openCatalog">Catalog</button></div></div>';
  return h;
}
function showEmptyState(){const t=document.getElementById('tabSummary');const s=document.getElementById('tabSettings');
const c=document.getElementById('tabConsole');const nm=document.getElementById('vmname');const tb=document.getElementById('tabBar');
if(!t||!s||!nm||!tb)return;
nm.textContent=vms.length?'Overview':'Welcome to Hangar';document.title='Hangar, VM Manager';tb.style.display='none';syncTabPanels();
t.style.display='block';s.style.display='none';if(c)c.style.display='none';activeTab='summary';
t.setAttribute('aria-hidden','false');s.setAttribute('aria-hidden','true');if(c)c.setAttribute('aria-hidden','true');
if(vms.length&&window.van){mountDashboard(t);publishVms();s.innerHTML='<div class="empty-state"><svg class="empty-icon" aria-hidden="true"><use href="/icons.svg#i-gear"/></svg><h3>No Virtual Machine Selected</h3><p>Select a VM from the sidebar to edit its settings.</p></div>';var chv=document.getElementById('consoleHint');if(chv)chv.innerHTML='<div class="console-empty"><strong>No VM selected.</strong><span>Select a running VM with embedded VNC or SPICE display to open the browser console.</span></div>';updateCommandState();return;}
dashMounted=false;
var empty=vms.length?hostDashboardHtml():'<div class="empty-state"><svg class="empty-icon" aria-hidden="true"><use href="/icons.svg#i-monitor"/></svg><h3>No Virtual Machines Yet</h3><p>Create your first virtual machine, import an existing disk image, or start from a catalog template.</p><div class="empty-actions"><button class="btn primary" data-action="newVm"><svg class="ico" aria-hidden="true"><use href="/icons.svg#i-plus"/></svg>New VM</button><button class="btn" data-action="importGuest">Import VM</button><button class="btn" data-action="openCatalog">Catalog</button></div></div>';
t.innerHTML=empty;
s.innerHTML='<div class="empty-state"><svg class="empty-icon" aria-hidden="true"><use href="/icons.svg#i-gear"/></svg><h3>No Virtual Machine Selected</h3><p>Select a VM from the sidebar to edit its settings.</p></div>';
var ch0=document.getElementById('consoleHint');if(ch0)ch0.innerHTML='<div class="console-empty"><strong>No VM selected.</strong><span>Select a running VM with embedded VNC or SPICE display to open the browser console.</span></div>';
updateCommandState();}
function renderDetails(){if(sel===null||sel>=vms.length){showEmptyState();return;}
const tb=document.getElementById('tabBar');const nm=document.getElementById('vmname');const ts=document.getElementById('tabSummary');const tc=document.getElementById('tabConsole');
if(!tb||!nm||!ts)return;
tb.style.display='flex';
const v=vms[sel];const sc=v.status==='running'?'running':v.status==='paused'?'paused':v.status==='suspended'?'suspended':'stopped';
if(activeTab==='console'&&!(v.status==='running'&&embeddedDisplayCapable(v)))activeTab='summary';
syncTabPanels();
nm.textContent=v.name;document.title='Hangar: '+v.name;
var emb=document.getElementById('vmemblem');if(emb){var br=osBrand(v.name,v.os);emb.textContent=br.m;emb.style.background=br.c;emb.hidden=false;}
var info=displayInfo(v);
var videoMeta=escHtml(info.embedLabel+' '+info.displayLabel)+' · '+escHtml(info.gpuLabel)+' · '+escHtml(info.accelLabel);
var ch=document.getElementById('consoleHint');
if(ch){if(embeddedDisplayCapable(v)){ch.innerHTML=v.status==='running'?'':'<div class="console-empty"><strong>'+escHtml(v.name)+' is powered off.</strong><span>Power on the VM to open its console here.</span></div>';}
else{ch.innerHTML='<div class="console-empty"><strong>No embedded browser console for this display.</strong><span>Switch Display to VNC or SPICE and enable Embed Display in Settings, or use the native '+escHtml(info.displayLabel)+' QEMU window.</span></div>';}}
function row(l,vv,ic){var icon=ic?'<svg class="srow-ico" aria-hidden="true"><use href="/icons.svg#'+ic+'"/></svg>':'';return '<div class="srow"><dt>'+icon+l+'</dt><dd>'+vv+'</dd></div>';}
const memTxt=escHtml(memText(v.mem));
let h='<div class="vm-facts">';
h+='<span class="fact-badge '+sc+'">'+escHtml(statusLabel(v.status))+'</span>';
h+='<span class="fact">'+escHtml(v.os)+'</span>';
h+='<span class="fact"><b>'+escHtml(v.cpu)+'</b> vCPU</span>';
h+='<span class="fact"><b>'+memTxt+'</b> RAM</span>';
h+='<span class="fact"><b>'+escHtml(v.disk)+'</b> GB disk</span>';
if(v.status==='running')h+='<span class="fact">IP <span id="guestIpVal">…</span></span>';
h+='</div><div class="summary-sections">';
// VM Hardware
h+='<section class="sum-section"><h3>VM Hardware</h3><dl class="sum-dl">';
h+=row('CPU',escHtml(v.cpu)+(Number(v.cpu)===1?' core':' cores')+(Number(v.cpu_sockets)>1?' · '+escHtml(v.cpu_sockets)+' sockets':''),'i-cpu');
h+=row('Memory',escHtml(memText(v.mem)),'i-ram');
h+=row('Hard Disk',escHtml(v.disk)+' GB'+(v.hasDisk==='true'?'<div class="usage" id="diskUsageVal">…</div>':''),'i-hdd');
if(v.hasDisk2==='true')h+=row('Disk 2',escHtml(v.disk2_size)+' GB');
['extra0','extra1','extra2','extra3'].forEach(function(k,i){if(v[k+'_path'])h+=row('Extra Disk '+(i+1),escHtml(v[k+'_size'])+' GB');});
if(v.iso_path)h+=row('CD/DVD',escHtml(v.iso_path));
if(v.hasFloppy==='true')h+=row('Floppy','attached');
h+=row('Network',escHtml(networkLabel(v))+(v.mac?' · '+escHtml(v.mac):''),'i-net');
  if(v.vnet)h+=row('Virtual Network',escHtml(v.vnet));
[2,3,4,5,6,7,8].forEach(function(n){var m=v['nic'+n+'_mode'];if(m&&m!=='none')h+=row('NIC '+n,escHtml(m));});
h+=row('Video',videoMeta,'i-monitor');
if(v.usb_device)h+=row('USB Device',escHtml(v.usb_device));
h+='</dl></section>';
// Guest & Tools
h+='<section class="sum-section"><h3>Guest &amp; Tools</h3><dl class="sum-dl">';
h+=row('Guest OS',escHtml(v.os));
h+=row('Guest Tools',v.guest_tools==='true'?'<span class="ok">✓ installed</span>':'<span class="muted">not installed</span>');
if(v.autoprotect==='true')h+=row('AutoProtect','every '+escHtml(v.autoprotect_interval)+' min · keep '+escHtml(v.autoprotect_max));
h+='</dl></section>';
// Options
var opts='';
if(v.shared_folder)opts+=row('Shared Folder',escHtml(v.shared_folder));
if(v.port_forwards)opts+=row('Port Forwards',escHtml(v.port_forwards));
if(opts)h+='<section class="sum-section"><h3>Options</h3><dl class="sum-dl">'+opts+'</dl></section>';
// Tags
var vtags=visibleTags(v.tags);
if(vtags.length){var chips=vtags.map(function(t){return '<span class="tag-chip">'+escHtml(t)+'</span>';}).join('');h+='<section class="sum-section"><h3>Tags</h3><div class="tag-chips">'+chips+'</div></section>';}
var vfld=vmFolder(v);if(vfld)h+='<section class="sum-section"><h3>Folder</h3><div class="sum-dl"><div class="srow"><dt>Path</dt><dd>'+escHtml(vfld)+'</dd></div></div></section>';
// Notes (full width)
if(v.notes)h+='<section class="sum-section span2"><h3>Notes</h3><div class="sum-notes">'+escHtml(v.notes)+'</div></section>';
h+='</div>';
var warn=summaryWarnings(v);
if(warn)h+='<div class="summary-grid" style="margin-top:14px">'+warn+'</div>';
h+='<div class="summary-actions" style="margin-top:16px;display:flex;gap:8px"><button type="button" class="btn" data-action="viewLog">View QEMU Log</button>'+(v.status==='running'?'<button type="button" class="btn" data-action="takeScreenshot">Screenshot</button>':'')+'</div>';
dashMounted=false;ts.innerHTML=h;
if(v.hasDisk==='true')loadDiskInfo(sel);
if(v.status==='running')loadGuestInfo(sel);
updateCommandState();}
async function loadLogInto(idx){var ui=window.hangarUi;ui.setLog('Loading…');try{var r=await fetch('/api/vms/'+idx+'/log',{headers:{'X-API-Key':API_KEY}});if(r.status===404){ui.setLog('No log output yet from this VM.');return;}if(!r.ok){var msg=await r.text().catch(function(){return '';});try{var j=JSON.parse(msg);if(j.error)msg=j.error;}catch(e){}ui.setLog('Failed to load log: '+(msg||('HTTP '+r.status)));return;}var txt=await r.text();ui.setLog(txt&&txt.length?txt:'(log is empty)');}catch(ex){ui.setLog('Failed to load log: '+(ex&&ex.message?ex.message:'request failed'));}}
function viewLog(){if(sel===null||sel>=vms.length)return;window.hangarUi.openLog(vms[sel].name);loadLogInto(sel);}
function refreshLog(){if(sel===null)return;loadLogInto(sel);}
async function powerToggle(){let idx=sel;if(idx===null)return;const v=vms[idx];if(!v)return;const stop=v.status==='running'||v.status==='paused';if(stop){if(!(await showConfirmDialog('Power off VM "'+v.name+'"?\nUnsaved data may be lost.',{danger:true,okLabel:'Power Off'})))return;}
idx=v.id?idxById(v.id):idxByName(v.name);if(idx<0)return;
if(window.hangarUi)window.hangarUi.setToolbar({powerBusy:true});
transitioningIdx=idx;renderList();
try{const r=await apiPost('/api/vms/'+idx+(stop?'/stop':'/start'));transitioningIdx=null;if(r){try{await refresh();}catch(e){setStatus('Refresh after power toggle failed: '+e.message);renderList();}finally{syncToolbar();}}else{syncToolbar();renderList();}}catch(e){transitioningIdx=null;syncToolbar();renderList();setStatus('Power toggle failed: '+e.message);}}
async function shutdownGuest(){if(sel===null)return;const v=vms[sel];if(!(await showConfirmDialog('Send ACPI shutdown to "'+v.name+'"?')))return;const r=await apiPost('/api/vms/'+sel+'/shutdown');if(r)setStatus('Shut down guest, ACPI power button sent.');}
async function resetGuest(){if(sel===null)return;const v=vms[sel];if(!(await showConfirmDialog('Reset guest "'+v.name+'"?\nUnsaved data in the guest may be lost.',{danger:true,okLabel:'Reset'})))return;const r=await apiPost('/api/vms/'+sel+'/reset');if(r)setStatus('Reset guest, system_reset sent.');}
async function pauseGuest(){if(sel===null)return;const r=await apiPost('/api/vms/'+sel+'/pause');if(r){await refresh();setStatus('Paused guest, execution frozen.');}}
async function resumeGuest(){if(sel===null)return;const r=await apiPost('/api/vms/'+sel+'/resume');if(r){await refresh();setStatus('Resumed guest, execution continued.');}}
async function renameGuest(){if(sel===null)return;const v=vms[sel];const n=await showPromptDialog('Rename VM:',v.name);if(n===null)return;const trimmed=n.trim();if(!trimmed){showToast('Name cannot be empty or whitespace','error');return;}if(trimmed===v.name)return;const r=await apiPost('/api/vms/'+sel+'/rename','name='+encodeURIComponent(trimmed));if(r){await refresh();setStatus('VM renamed.');}}
async function suspendGuest(){if(sel===null)return;const v=vms[sel];if(!(await showConfirmDialog('Suspend VM "'+v.name+'" to disk?\nThe VM state will be saved and the VM will be paused.',{okLabel:'Suspend'})))return;const r=await apiPost('/api/vms/'+sel+'/suspend');if(r){await refresh();setStatus('Suspended VM to disk.');}}
function cloneGuest(){if(sel===null)return;window.hangarUi.openClone({vmName:vms[sel].name,clone:doClone});}
async function doClone(linked){if(sel===null)return false;const r=await apiPost('/api/vms/'+sel+'/clone',linked?'linked=1':'');if(!r)return false;await refresh();setStatus(linked?'Linked clone created.':'VM cloned.');return true;}
function importGuest(){window.hangarUi.openImport({importVm:importConfirm});}
async function importConfirm(path,wantName){const before=vms.map(function(x){return x.name;});
const r=await apiPost('/api/vms/import','path='+encodeURIComponent(path));if(!r)return false;await refresh();
var added=vms.findIndex(function(x){return before.indexOf(x.name)<0;});
if(wantName&&added>=0&&vms[added].name!==wantName){await apiPost('/api/vms/'+added+'/rename','name='+encodeURIComponent(wantName));await refresh();added=vms.findIndex(function(x){return x.name===wantName;});}
if(added>=0)await select(added);
setStatus('VM imported.');return true;}
async function batchStart(){var btns=document.querySelectorAll('[data-action="batchStart"]');for(var b=0;b<btns.length;b++){btns[b].setAttribute('data-prev-label',btns[b].textContent);btns[b].disabled=true;btns[b].textContent='...';}
var started=0,failed=0,total=0;for(let i=0;i<vms.length;i++){if(vms[i].status==='stopped')total++;}
for(let i=0;i<vms.length;i++){if(vms[i].status==='stopped'){setStatus('Batch start: VM '+(started+failed+1)+' of '+total+'...');const r=await apiPost('/api/vms/'+i+'/start');if(r){started++;}else{failed++;setStatus('Batch start: VM '+(started+failed)+' of '+total+' failed, continuing...');}}}
await refresh();setStatus('Batch start complete: '+started+' started'+(failed>0?', '+failed+' failed':''));
for(var b2=0;b2<btns.length;b2++){btns[b2].disabled=false;btns[b2].textContent=btns[b2].getAttribute('data-prev-label')||'Power On All Stopped';btns[b2].removeAttribute('data-prev-label');}}
async function batchStop(){if(!(await showConfirmDialog('Power off ALL running VMs?\nUnsaved data may be lost.',{danger:true,okLabel:'Power Off All'})))return;
var btns=document.querySelectorAll('[data-action="batchStop"]');for(var b=0;b<btns.length;b++){btns[b].setAttribute('data-prev-label',btns[b].textContent);btns[b].disabled=true;btns[b].textContent='...';}
var stopped=0,failed=0,total=0;for(let i=0;i<vms.length;i++){if(vms[i].status==='running'||vms[i].status==='paused')total++;}
for(let i=vms.length-1;i>=0;i--){if(vms[i].status==='running'||vms[i].status==='paused'){setStatus('Batch stop: VM '+(stopped+failed+1)+' of '+total+'...');const r=await apiPost('/api/vms/'+i+'/stop');if(r){stopped++;}else{failed++;setStatus('Batch stop: VM '+(stopped+failed)+' of '+total+' failed, continuing...');}}}
await refresh();setStatus('Batch stop complete: '+stopped+' stopped'+(failed>0?', '+failed+' failed':''));
for(var b2=0;b2<btns.length;b2++){btns[b2].disabled=false;btns[b2].textContent=btns[b2].getAttribute('data-prev-label')||'Power Off All Running';btns[b2].removeAttribute('data-prev-label');}}
function takeSnapshot(){return openSnapshots();}
async function takeSnapshotFromDlg(tag){if(sel===null){showToast('No VM selected','warn');return false;}
const r=await apiPost('/api/vms/'+sel+'/snapshots','tag='+encodeURIComponent(tag));if(!r)return false;loadSnapshots();setStatus('Snapshot taken: '+tag);return true;}
function snapshotMeta(){var v=selectedVm();return{vmName:v?v.name:'',statusLabel:v?statusLabel(v.status):'',running:!!v&&(v.status==='running'||v.status==='paused')};}
async function openSnapshots(){if(sel===null)return;window.hangarUi.openSnapshots(Object.assign(snapshotMeta(),{list:{kind:'loading'},take:takeSnapshotFromDlg,revert:revertSnapshot,remove:deleteSnapshot}));loadSnapshots();}
async function loadSnapshots(){if(sel===null)return;var ui=window.hangarUi;var meta=snapshotMeta();
try{const r=await fetch('/api/vms/'+sel+'/snapshots');if(!r.ok){ui.setSnapshots(Object.assign(meta,{list:{kind:'failed'}}));return;}const t=(await r.text()).trim();var items=[];
if(t&&t!=='(none)'){for(const ln of t.split('\n')){const parts=ln.split('\t');const tag=(parts[0]||'').trim();if(!tag)continue;const when=(parts[1]||'').trim();items.push({tag:tag,when:when,age:when?relAge(when):''});}}
ui.setSnapshots(Object.assign(meta,{list:{kind:'ready',items:items}}));}catch(e){ui.setSnapshots(Object.assign(meta,{list:{kind:'failed'}}));}}
async function revertSnapshot(tag){if(sel===null||!tag)return false;if(!(await showConfirmDialog('Revert to snapshot "'+tag+'"? This will discard current state.',{danger:true,okLabel:'Revert'})))return false;
const r=await apiPost('/api/vms/'+sel+'/snapshots/revert','tag='+encodeURIComponent(tag));if(!r){loadSnapshots();return false;}setStatus('Reverted to snapshot: '+tag);return true;}
async function deleteSnapshot(tag){if(sel===null||!tag)return;if(!(await showConfirmDialog('Delete snapshot "'+tag+'"?',{danger:true,okLabel:'Delete'})))return;
const r=await apiPost('/api/vms/'+sel+'/snapshots/delete','tag='+encodeURIComponent(tag));if(r){loadSnapshots();setStatus('Deleted snapshot: '+tag);}}
async function sendCad(){if(sel===null)return;const r=await apiPost('/api/vms/'+sel+'/cad');if(r)setStatus('Ctrl+Alt+Del sent to guest.');}
async function exportOvf(){if(sel===null)return;try{const r=await fetch('/api/vms/'+sel+'/export',{method:'POST',headers:{'X-API-Key':API_KEY}});if(!r.ok){setStatus('Export failed: '+r.status);return;}const blob=await r.blob();const a=document.createElement('a');const url=URL.createObjectURL(blob);a.href=url;a.download=vms[sel].name+'.ova';a.click();setTimeout(function(){URL.revokeObjectURL(url);},60000);setStatus('Export downloaded.');}catch(e){setStatus('Export error: '+e);}}
async function migrateGuest(){if(sel===null)return;window.hangarUi.openMigrate({vmName:vms[sel].name,start:doMigrate});}
var migrating=false;
async function doMigrate(host,port){if(sel===null||migrating)return false;var dest='tcp:'+host+':'+port;migrating=true;migId=vms[sel].id;var resp=await apiPost('/api/vms/'+sel+'/migrate','dest='+encodeURIComponent(dest));if(!resp){migrating=false;migId=null;return false;}var j=await resp.json();if(!j||j.status!=='started'){showToast('Migration failed to start','error');migrating=false;migId=null;return false;}showMigProgress();pollMigStatus();return true;}
var migPollTimer=null;
var migId=null;
var migPollFails=0;
var MIG_POLL_MAX_FAILS=5;
function showMigProgress(){migPollFails=0;var bar=document.getElementById('mig_progress');var info=document.getElementById('mig_pct');var cancel=document.getElementById('mig_cancel');if(bar&&info){bar.style.display='block';bar.removeAttribute('aria-valuenow');info.style.display='inline';info.textContent='Migration in progress...';var fill=bar.firstElementChild;if(fill)fill.style.width='0%';}if(cancel)cancel.style.display='inline';}
function hideMigProgress(){migrating=false;migId=null;migPollFails=0;if(migPollTimer){clearTimeout(migPollTimer);migPollTimer=null;}var bar=document.getElementById('mig_progress');var info=document.getElementById('mig_pct');var cancel=document.getElementById('mig_cancel');if(bar)bar.style.display='none';if(info)info.style.display='none';if(cancel)cancel.style.display='none';}
async function pollMigStatus(){if(migId===null){hideMigProgress();return;}
var mi=idxById(migId);if(mi<0){showToast('Migrating VM no longer in the list','warn');hideMigProgress();return;}
var t='';try{var ctl=new AbortController();var tid=setTimeout(function(){ctl.abort();},10000);var resp=await fetch('/api/vms/'+mi+'/migrate',{signal:ctl.signal});clearTimeout(tid);t=await resp.text();}catch(e){}
var info=document.getElementById('mig_pct');var bar=document.getElementById('mig_progress');
if(!info||!bar)return;
var fill=bar.firstElementChild;
// A single dropped poll (timeout, busy daemon during transfer) must not abort
// a migration that is still running server-side. Tolerate a few consecutive
// failures before declaring the connection lost.
if(!t){migPollFails++;if(migPollFails>=MIG_POLL_MAX_FAILS){info.textContent='Migration failed: connection lost';hideMigProgress();setStatus('Migration failed');return;}info.textContent='Migration in progress... (retrying)';migPollTimer=setTimeout(pollMigStatus,500);return;}
migPollFails=0;
try{
var s=JSON.parse(t);
if(s.status==='completed'){info.textContent='Migration completed.';bar.setAttribute('aria-valuenow','100');if(fill){fill.style.width='100%';fill.style.background='var(--success)';}setStatus('Migration completed');setTimeout(hideMigProgress,3000);return;}
if(s.status==='failed'||s.status==='error'){info.textContent='Migration failed.';if(fill)fill.style.background='var(--danger)';setStatus('Migration failed');setTimeout(hideMigProgress,3000);return;}
if(s.status==='cancelled'){info.textContent='Migration cancelled.';if(fill)fill.style.background='var(--warn)';setStatus('Migration cancelled');setTimeout(hideMigProgress,3000);return;}
// Update progress bar if server provides percentage
if(typeof s.pct==='number'&&fill){var pc=Math.min(100,Math.max(0,s.pct));fill.style.width=pc+'%';bar.setAttribute('aria-valuenow',String(Math.round(pc)));}
info.textContent='Migration '+s.status+'...';
}catch(e){info.textContent='Migration polling error';}
migPollTimer=setTimeout(pollMigStatus,500);}
async function cancelMigrate(){if(migId===null)return;var mi=idxById(migId);if(mi<0){hideMigProgress();return;}var r=await apiPost('/api/vms/'+mi+'/migrate/cancel','');if(r){var info=document.getElementById('mig_pct');if(info)info.textContent='Cancelling...';setStatus('Migration cancel requested');}}
function summaryWarnings(v){var warnings=[];if(v.embed_display==='true'&&!embeddedDisplayCapable(v))warnings.push('Embedded display is enabled, but browser console requires VNC or SPICE.');if(v.net==='none')warnings.push('Network adapter is disconnected.');if(v.net==='gvproxy')warnings.push('gvproxy networking requires a gvproxy daemon listening on /tmp/hangar-gvproxy-qemu.sock.');if(v.net==='bridge')warnings.push('Bridged networking requires a configured host bridge (e.g. br0).');if(!warnings.length)return'';var h='<div class="summary-card warning-card"><div class="card-label">Attention</div><div class="card-value">';for(var i=0;i<warnings.length;i++)h+='<div>'+escHtml(warnings[i])+'</div>';return h+'</div></div>';}
function actionAllowed(name,v){var has=!!v;var running=v&&v.status==='running';var paused=v&&v.status==='paused';switch(name){
case'settings':case'rename':case'clone':case'export':case'delete':case'snapshot':return has;
case'power-toggle':return has;
case'power-on':return has&&!running&&!paused;
case'shutdown':case'reset':case'pause':case'suspend':case'cad':case'migrate':return running;
case'resume':return paused;
case'hard-power':return running||paused;
case'display':return running&&embeddedDisplayCapable(v);
case'serial':return running&&v.hasSerial==='true';
case'batch-start':return vms.some(function(x){return x.status==='stopped'||x.status==='suspended';});
case'batch-stop':return vms.some(function(x){return x.status==='running'||x.status==='paused';});
default:return true;}}
function disabledReason(name,v){if(!v&&name!=='batch-start'&&name!=='batch-stop')return 'Select a VM first';if(name==='display')return 'Requires a running VM with embedded VNC or SPICE display';if(name==='serial')return 'Requires a running VM with serial enabled';if(name==='resume')return 'Only paused or suspended VMs can resume';if(name==='shutdown'||name==='reset'||name==='pause'||name==='suspend'||name==='cad'||name==='migrate')return 'Requires a running VM';if(name==='hard-power')return 'Requires a running or paused VM';if(name==='power-on')return 'VM is already running';if(name==='batch-start')return 'No stopped VMs';if(name==='batch-stop')return 'No running VMs';return 'Unavailable';}
function syncToolbar(){if(!window.hangarUi)return;const v=selectedVm();window.hangarUi.setToolbar({hasVm:!!v,powered:!!v&&(v.status==='running'||v.status==='paused'),powerBusy:false,actionReason:function(name){return actionAllowed(name,v)?null:disabledReason(name,v);}});}
function updateCommandState(){syncToolbar();var v=selectedVm();var nodes=document.querySelectorAll('[data-vm-action]');for(var i=0;i<nodes.length;i++){var n=nodes[i];var name=n.getAttribute('data-vm-action');var ok=actionAllowed(name,v);n.disabled=!ok;n.setAttribute('aria-disabled',ok?'false':'true');if(!ok){n.title=disabledReason(name,v);n.setAttribute('data-disabled-title','1');}else if(n.getAttribute('data-disabled-title')==='1'){n.removeAttribute('title');n.removeAttribute('data-disabled-title');}}
var tabBar=document.getElementById('tabBar');if(tabBar&&v){var consoleBtn=tabBar.querySelector('[data-tab="console"]');if(consoleBtn){consoleBtn.disabled=!(v.status==='running'&&embeddedDisplayCapable(v));consoleBtn.title=consoleBtn.disabled?'Console requires a running embedded VNC or SPICE display':'Open VM console';}}}
function newVm(){window.hangarUi.openNewVm({create:createVm});}
async function createVm(v){var extra='&guest_os='+encodeURIComponent(v.guestOs)+'&firmware='+encodeURIComponent(v.firmware);if(v.isoPath)extra+='&iso_path='+encodeURIComponent(v.isoPath);
const r=await apiPost('/api/vms','name='+encodeURIComponent(v.name)+'&mem='+v.memoryMb+'&cpu='+v.cpuCores+'&disk='+v.diskGb+extra);if(!r)return false;await refresh();var ni=vms.findIndex(function(x){return x.name===v.name;});if(ni>=0)await select(ni);setStatus('VM created.');return true;}
async function deleteVm(){if(sel===null)return;var deleted=vms[sel];if(!deleted)return;if(!(await showConfirmDialog('Delete VM "'+deleted.name+'"?',{danger:true,okLabel:'Delete'})))return;var r=await apiPost('/api/vms/'+sel+'/delete');if(r){sel=null;var delName=deleted.name;await refresh();toastUndo('Deleted "'+delName+'"',async function(){await apiPost('/api/vms/undo');await refresh();});}}
function reorderVm(from,to){var oldFrom=from,oldTo=to,oldSel=sel;
if(saveInFlight)return;
// Block concurrent refresh during the reorder operation
saveInFlight=true;
// Optimistic: reorder the local array immediately so the UI feels responsive.
var moved=vms.splice(from,1)[0];vms.splice(to,0,moved);
sel=to;renderList();if(sel!==null)renderDetails();
apiPost('/api/vms/reorder','from='+from+'&to='+to).then(async function(r){
 saveInFlight=false;
 if(r){await refresh();
  toastUndo('Moved "'+moved.name+'"',function(){
   apiPost('/api/vms/reorder','from='+oldTo+'&to='+oldFrom).then(async function(r2){if(r2){sel=oldSel;await refresh();}});
  });
 }else{
  // Revert the optimistic reorder on failure.
  // Use the captured VM ref to avoid races with refresh() updating vms[].
  for(var i=0;i<vms.length;i++){if(vms[i]===moved){vms.splice(i,1);break;}}
  vms.splice(from,0,moved);
  // Only restore oldSel if the user hasn't changed selection during the call
  if(sel===to)sel=oldSel;
  renderList();if(sel!==null)renderDetails();
 }
}).catch(function(){saveInFlight=false;});}
async function editVm(){if(sel===null)return;if(activeTab==='settings'&&settingsDirty){if(!(await showConfirmDialog('You have unsaved changes. Discard them?',{danger:true,okLabel:'Discard'})))return;}switchTab('settings');if(sel===null||sel>=vms.length)return;
const v=vms[sel];
var tb=document.getElementById('tabBar');var nm=document.getElementById('vmname');if(tb)tb.style.display='flex';if(nm)nm.textContent=v.name;
const fields=[
{s:'Basic'},['Name','e_name','text',v.name||'','required maxlength="80"'],['Guest OS','e_guest_os','select',v.guest_os||0],
['Memory (MB)','e_mem','number',v.mem||2048,'required min="128" max="65536" step="1"'],['CPU Cores','e_cpu','number',v.cpu||2,'required min="1" max="256" step="1"'],
['CPU Sockets','e_cpu_sockets','number',v.cpu_sockets||1,'min="1" max="64" step="1"'],
['CPU Model','e_cpu_model','select',v.cpu_model||'host'],
['Disk Size (GB)','e_disk','number',v.disk||20,'required min="1" max="65536" step="1"'],['Disk Format','e_disk_format','select',v.disk_format||0],
['Disk Cache','e_disk_cache','select',v.disk_cache||0],
['ISO Path','e_iso_path','text',v.iso_path||''],['','','cdactions',''],['Firmware','e_firmware','select',v.fw||'bios'],
['Boot Order','e_boot_order','select',v.boot_order||0],['RTC Clock','e_rtc','select',v.rtc||0],
{s:'Network &amp; Boot'},['Network','e_network','select',v.net||'user'],['Virtual Network','e_vnet','text',v.vnet||'','placeholder="bind to a virtual network name (optional)"'],['MAC Address','e_mac_address','text',v.mac||'','pattern="([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"'],
].concat(nicRows(v)).concat([
['Port Forwards','e_portfw','text',v.port_forwards||''],
{s:'Sharing'},['Shared Folder','e_shared_folder','text',v.shared_folder||''],['USB Device','e_usb','text',v.usb_device||''],
['USB Policy','e_usb_policy','select',v.usb_policy||0],
['Guest Tools','e_guest_tools','select',v.guest_tools==='true'?'1':'0'],
{s:'AutoProtect'},['AutoProtect','e_autoprotect','select',v.autoprotect==='true'?'1':'0'],
['AP Interval','e_ap_interval','number',v.autoprotect_interval||60,'min="1" max="1440" step="1"'],
['AP Max','e_ap_max','number',v.autoprotect_max||10,'min="1" max="100" step="1"'],
{s:'Display &amp; Video'},['Display','e_display','select',v.display||0],['Display Res','e_display_resolution','select',v.display_resolution||0],
['3D Accel','e_enable_3d','select',v.enable_3d==='true'?'1':'0'],['GPU Device','e_gpu_device','select',v.gpu_device||0],
['Embed Display','e_embed_display','select',v.embed_display==='true'?'1':'0'],['Serial','e_enable_serial','select',v.hasSerial==='true'?'1':'0'],
['Num Displays','e_num_displays','number',v.num_displays||1,'min="1" max="16" step="1"'],
['VNC Port','e_vnc_port','number',v.vnc_port||5900,'min="1" max="65535" step="1"'],['SPICE Port','e_spice_port','number',v.spice_port||5901,'min="1" max="65535" step="1"'],
['Accelerator','e_accel','select',v.accel||'auto'],['Audio','e_audio','select',v.audio||0],
['Video Stream (experimental)','e_video_stream','select',v.video_stream==='true'?'1':'0'],['Video Bitrate (kbps, 0=auto)','e_video_bitrate','number',v.video_bitrate_kbps||0,'min="0" max="50000" step="500"'],
{s:'Storage &amp; Notes'},['Disk 2 Path','e_disk2_path','text',v.disk2_path||''],['','','disk2actions',''],['Disk 2 Size','e_disk2_size','number',v.disk2_size||0,'min="0" max="65536" step="1"'],
['Disk 2 Format','e_disk2_format','select',v.disk2_format||0],
['Floppy','e_floppy','text',v.floppy_path||''],
['Favorite','e_favorite','select',v.favorite==='true'?'1':'0'],['Notes','e_notes','text',v.notes||''],['Tags','e_tags','text',v.tags||'','placeholder="comma-separated, e.g. prod, web"'],['Cloud-Init User-Data','e_cloud_init','textarea',v.cloud_init||'','placeholder="#cloud-config&#10;… (NoCloud user-data; attached as a seed ISO)"'],
{s:'Extra Disks'},
].concat(extraDiskRows(v)).concat([
{s:'Advanced'},
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
['Disk Throttle (bytes/s, 0 = off)','e_disk_bps_throttle','number',v.disk_bps_throttle||0,'min="0" max="1099511627776" step="1"'],
['Disk Throttle (IOPS, 0 = off)','e_disk_iops_throttle','number',v.disk_iops_throttle||0,'min="0" max="100000000" step="1"']]));
const selects={e_network:[['user','NAT (User)'],['gvproxy','gvproxy (User)'],['bridge','Bridged'],['none','None']],
e_firmware:[['bios','BIOS'],['uefi','UEFI']],e_disk_format:[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']],
e_disk2_format:[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']],
e_disk_cache:[['0','Writeback'],['1','Writethrough'],['2','None'],['3','Direct Sync'],['4','Unsafe']],
e_cpu_model:[['host','Host'],['host-passthrough','Host Passthrough'],['max','Max'],['qemu64','QEMU64'],['kvm64','KVM64'],['EPYC','EPYC'],['EPYC-Rome','EPYC-Rome'],['EPYC-Milan','EPYC-Milan'],['Skylake-Server','Skylake-Server'],['Skylake-Client','Skylake-Client'],['Cascadelake-Server','Cascadelake-Server'],['Icelake-Server','Icelake-Server'],['Nehalem','Nehalem'],['Westmere','Westmere'],['SandyBridge','SandyBridge'],['IvyBridge','IvyBridge'],['Haswell','Haswell'],['Broadwell','Broadwell'],['Opteron_G5','Opteron G5'],['Cooperlake','Cooperlake'],['SapphireRapids','SapphireRapids'],['GraniteRapids','GraniteRapids'],['Neoverse-N1','Neoverse-N1'],['Neoverse-N2','Neoverse-N2'],['Neoverse-V1','Neoverse-V1'],['aarch64','AArch64']],
e_enable_3d:[['0','No'],['1','Yes']],e_gpu_device:[['0','Virtio-GPU (3D)'],['1','Virtio-VGA (3D)'],['2','Virtio-GPU'],['3','Virtio-VGA'],['4','QXL'],['5','Standard VGA']],
e_display:[['0','GTK'],['1','SDL'],['2','SPICE'],['3','VNC'],['4','None']],
e_display_resolution:[['0','Auto'],['1','800x600'],['2','1024x768'],['3','1280x800'],['4','1920x1080']],
e_guest_os:[['0','Linux'],['1','Windows'],['2','FreeBSD'],['3','macOS'],['4','Other']],
e_audio:[['0','None'],['1','Intel HDA'],['2','AC97']],e_boot_order:[['0','Hard Disk'],['1','CD/DVD'],['2','PXE']],e_rtc:[['0','UTC'],['1','Local time (Windows)']],
e_accel:[['auto','Auto (best available)'],['tcg','TCG (software)'],['kvm','KVM (Linux)'],['hvf','HVF (macOS)'],['whpx','WHPX (Windows)']],e_embed_display:[['0','No'],['1','Yes']],
e_enable_serial:[['0','No'],['1','Yes']],e_favorite:[['0','No'],['1','Yes']],
e_guest_tools:[['0','No'],['1','Yes']],e_autoprotect:[['0','Off'],['1','On']],
e_guest_agent:[['0','No'],['1','Yes']],e_virtio_rng:[['0','No'],['1','Yes']],
e_tpm:[['0','No'],['1','Yes']],e_secure_boot:[['0','No'],['1','Yes']],
e_hyperv_enlightenments:[['0','No'],['1','Yes']],e_hugepages:[['0','No'],['1','Yes']],
e_ballooning:[['0','No'],['1','Yes']],e_video_stream:[['0','No'],['1','Yes']],e_host_autostart:[['0','No'],['1','Yes']],
e_watchdog:[['0','None'],['1','Reset Guest'],['2','Power Off Guest'],['3','Pause Guest']],
e_usb_policy:[['0','None'],['1','USB 2.0 (EHCI)'],['2','USB 3.0 (xHCI)']]};
(function(){var nm=[['none','None'],['user','NAT'],['gvproxy','gvproxy'],['bridge','Bridged']],df=[['0','QCOW2'],['1','Raw'],['2','VMDK'],['3','VDI']];for(var n=2;n<=MAX_NICS;n++)selects['e_nic'+n]=nm;for(var k=0;k<MAX_EXTRA_DISKS;k++)selects['e_extra'+k+'_format']=df;})();

	var sectionNotes={
	 basic:'Identity, operating system, firmware, and boot defaults.',
	 network_and_boot:'VMnet, NAT, bridged adapters, MAC addresses, and port forwarding.',
	 sharing:'Guest integration, shared folders, and USB policy.',
	 autoprotect:'Automatic snapshot scheduling for this VM.',
	 display_and_video:'Browser console, SPICE/VNC, virgl, display ports, serial, audio.',
	 storage_and_notes:'Secondary storage, removable media, notes, tags, and cloud-init.',
	 extra_disks:'Additional virtual disks exposed to the guest.',
	 advanced:'Advanced QEMU capabilities and performance controls.'
	};
	function secId(title){return title.replace(/&amp;/g,'and').toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_+|_+$/g,'');}
	var sections=[];var current=null;
	for(const f of fields){if(f.s!==undefined){current={id:secId(f.s),title:f.s,fields:[]};sections.push(current);continue;}if(!current){current={id:'general',title:'General',fields:[]};sections.push(current);}current.fields.push(f);}
	if(!sections.some(function(s){return s.id===settingsCategory;}))settingsCategory=sections.length?sections[0].id:'basic';
	function renderField(f){const[lbl,id,type,val]=f;const attrs=f.length>4?f[4]:'';var out='<div class="field-group" data-field-id="'+id+'">';if(lbl)out+=`<label for="${id}">${lbl}</label>`;
	if(type==='disk2actions'){out+='<span class="inline-actions"><button type="button" class="btn" data-action="resizeDisk">Resize Primary Disk</button><button type="button" class="btn" data-action="compactDisk">Compact Primary Disk</button><button type="button" class="btn" data-action="disk2upload">Upload Disk 2</button><button type="button" class="btn" data-action="disk2download">Download Disk 2</button></span>';}
	if(type==='cdactions'){out+='<span class="inline-actions"><button type="button" class="btn" data-action="changeCd">Change CD/ISO</button><button type="button" class="btn" data-action="ejectCd">Eject CD/ISO</button></span>';}
	else if(type==='select'&&selects[id]){out+=`<select id="${id}" data-field="${id}">`;for(const[ov,ol]of selects[id])out+=`<option value="${ov}"${ov===String(val)?' selected':''}>${ol}</option>`;out+='</select>';}
	else if(type==='textarea'){out+=`<textarea id="${id}" data-field="${id}" rows="6" spellcheck="false" ${attrs}>${escHtml(String(val))}</textarea>`;}
		else{out+=`<input id="${id}" data-field="${id}" type="${type}" value="${escHtml(String(val))}" ${attrs}>`;}
	out+='<div class="field-error" id="err_'+id+'" aria-live="polite"></div></div>';return out;}
	let h='<div class="settings-shell"><nav class="settings-nav" aria-label="Settings categories">';
	for(const sec of sections){h+=`<button type="button" class="settings-nav-item${sec.id===settingsCategory?' active':''}"${sec.id===settingsCategory?' aria-current="page"':''} data-action="setSettingsCategory" data-settings-category="${sec.id}"><span>${sec.title}</span><small>${escHtml(sectionNotes[sec.id]||'Configure this virtual hardware group.')}</small></button>`;}
	h+='</nav><div class="settings-detail">';
	for(const sec of sections){h+=`<section class="settings-panel${sec.id===settingsCategory?' active':''}" data-settings-panel="${sec.id}"${sec.id===settingsCategory?'':' style="display:none"'}><div class="settings-panel-head"><h3>${sec.title}</h3><p>${escHtml(sectionNotes[sec.id]||'Configure this virtual hardware group.')}</p></div><div class="settings-form">`;for(const f of sec.fields)h+=renderField(f);h+='</div></section>';}
	h+='</div></div><div class="settings-actions"><button type="button" class="btn" data-action="switchTab" data-tab="summary">Cancel</button><button id="savevmbtn" type="button" class="btn primary" data-action="saveVm" title="Save VM settings">Save Changes</button></div>';
	var ts=document.getElementById('tabSettings');if(ts)ts.innerHTML=h;settingsDirty=false;
	// Workstation-style guard: virtual hardware is locked while the VM has live
	// or saved state. Identity/metadata fields stay editable; CD/ISO buttons stay
	// active (media changes apply live over QMP).
	var hwLocked=v.status==='running'||v.status==='paused'||v.status==='suspended';
	if(hwLocked&&ts){var soft={e_name:1,e_notes:1,e_tags:1,e_folder:1,e_vnet:1,e_favorite:1,e_autoprotect:1,e_ap_interval:1,e_ap_max:1};
	 var ctrls=ts.querySelectorAll('.settings-form input,.settings-form select,.settings-form textarea');
	 for(var ci=0;ci<ctrls.length;ci++){if(!soft[ctrls[ci].id]){ctrls[ci].disabled=true;ctrls[ci].title='Power off the VM to change virtual hardware';}}
	 var shell=ts.querySelector('.settings-shell');
	 if(shell){var ban=document.createElement('div');ban.className='settings-runlock';ban.setAttribute('role','note');ban.textContent='This VM is '+statusLabel(v.status).toLowerCase()+': virtual hardware is locked. Name, notes, tags, folder and AutoProtect stay editable; CD/ISO can be changed live.';ts.insertBefore(ban,shell);}}}
function setSettingsCategory(cat){settingsCategory=cat;var panels=document.querySelectorAll('.settings-panel');for(var i=0;i<panels.length;i++){var on=panels[i].getAttribute('data-settings-panel')===cat;panels[i].classList.toggle('active',on);panels[i].style.display=on?'block':'none';}
var items=document.querySelectorAll('.settings-nav-item');for(var j=0;j<items.length;j++){var on=items[j].getAttribute('data-settings-category')===cat;items[j].classList.toggle('active',on);if(on)items[j].setAttribute('aria-current','page');else items[j].removeAttribute('aria-current');}}
function setFieldError(id,msg,kind){var el=document.getElementById('err_'+id);var field=document.getElementById(id);if(el){el.textContent=msg||'';el.classList.toggle('warning',kind==='warn');}if(field){var bad=!!msg&&kind!=='warn';field.classList.toggle('invalid',bad);if(bad){field.setAttribute('aria-invalid','true');field.setAttribute('aria-describedby','err_'+id);}else{field.removeAttribute('aria-invalid');if(field.getAttribute('aria-describedby')==='err_'+id)field.removeAttribute('aria-describedby');}}}
function validateSettings(show){var ok=true;function fail(id,msg){ok=false;if(show)setFieldError(id,msg);}function clear(id){if(show)setFieldError(id,'');}
var nameEl=document.getElementById('e_name');if(nameEl){clear('e_name');if(!nameEl.value.trim())fail('e_name','Name is required.');}
[['e_mem',128,65536,'Memory must be 128-65536 MB.'],['e_cpu',1,256,'CPU cores must be 1-256.'],['e_disk',1,65536,'Disk size must be 1-65536 GB.']].forEach(function(c){var el=document.getElementById(c[0]);if(!el)return;clear(c[0]);var n=parseInt(el.value,10);if(!Number.isFinite(n)||n<c[1]||n>c[2])fail(c[0],c[3]);});
var macIds=['e_mac_address'];for(var mn=2;mn<=MAX_NICS;mn++)macIds.push('e_nic'+mn+'_mac');for(var i=0;i<macIds.length;i++){var m=document.getElementById(macIds[i]);if(!m)continue;var val=m.value.trim();clear(macIds[i]);if(val&&!/^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/.test(val))fail(macIds[i],'Use XX:XX:XX:XX:XX:XX.');}
['e_vnc_port','e_spice_port'].forEach(function(id){var p=document.getElementById(id);if(!p)return;var n=parseInt(p.value,10);clear(id);if(!Number.isFinite(n)||n<1||n>65535)fail(id,'Port must be 1-65535.');});
var pf=document.getElementById('e_portfw');if(pf){clear('e_portfw');var val=pf.value.trim();if(val&&!/^\s*\d{1,5}:\d{1,5}(\s*,\s*\d{1,5}:\d{1,5})*\s*$/.test(val)&&!/^\s*\d{1,5}:[^,]+:\d{1,5}(\s*,\s*\d{1,5}:[^,]+:\d{1,5})*\s*$/.test(val))fail('e_portfw','Use host:guest or host:ip:guest entries.');}
var embed=document.getElementById('e_embed_display');var disp=document.getElementById('e_display');var accel=document.getElementById('e_enable_3d');var gpu=document.getElementById('e_gpu_device');if(embed&&disp){clear('e_display');if(embed.value==='1'&&!(disp.value==='2'||disp.value==='3')&&show)setFieldError('e_display','Browser console requires SPICE or VNC; native display opens outside the browser.','warn');}
if(embed&&disp&&accel&&gpu){clear('e_gpu_device');if(embed.value==='1'&&disp.value==='3'&&accel.value==='1'&&(gpu.value==='0'||gpu.value==='1')&&show)setFieldError('e_gpu_device','Virgl 3D needs embedded SPICE; VNC will fall back to non-GL virtio.','warn');}
return ok;}
async function saveVm(){const idx=sel;if(idx===null)return;const btn=document.getElementById('savevmbtn');if(btn){btn.disabled=true;btn.textContent='Saving...';}
if(!validateSettings(true)){var bad=document.querySelector('#tabSettings .invalid');if(bad){var panel=bad.closest('.settings-panel');if(panel)setSettingsCategory(panel.getAttribute('data-settings-panel')||settingsCategory);bad.focus({preventScroll:false});}if(btn){btn.disabled=false;btn.textContent='Save Changes';}showToast('Fix highlighted settings before saving.','error');return;}
saveInFlight=true;
const formEls=document.querySelectorAll('#tabSettings input, #tabSettings select, #tabSettings button');for(let i=0;i<formEls.length;i++)formEls[i].disabled=true;
const fieldIds=['name','mem','cpu','cpu_sockets','cpu_model','disk','disk_format','disk_cache','iso_path','mac_address','network','vnet','firmware','shared_folder','usb','usb_policy','guest_tools','autoprotect',
'ap_interval','ap_max','disk2_path','disk2_size','disk2_format','floppy','portfw','notes','tags','cloud_init',
'enable_3d','gpu_device','display','display_resolution','guest_os','audio','boot_order','rtc',
'accel','embed_display','vnc_port','spice_port','enable_serial','num_displays','favorite',
'guest_agent','virtio_rng','tpm','secure_boot','hyperv_enlightenments','hugepages','watchdog','ballooning','host_autostart',
'io_threads','disk_bps_throttle','disk_iops_throttle','video_stream','video_bitrate'];
// Generated NIC 2..MAX_NICS and extra-disk slots are saved too (their form
// rows are generated from /api/capabilities; the field list must match).
for(var bn=2;bn<=MAX_NICS;bn++)fieldIds.push('nic'+bn,'nic'+bn+'_mac','nic'+bn+'_vnet');
for(var bk=0;bk<MAX_EXTRA_DISKS;bk++)fieldIds.push('extra'+bk+'_path','extra'+bk+'_size','extra'+bk+'_format');
const body=fieldIds.map(id=>{const el=document.getElementById('e_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
try{const r=await apiPost('/api/vms/'+idx,body);if(r){settingsDirty=false;saveInFlight=false;/* refresh() no-ops while saveInFlight, clear it first or the summary renders stale data */await refresh();switchTab('summary');setStatus('Settings saved.');}
else{setStatus('Save failed.');}}catch(e){setStatus('Save failed: '+e.message);}finally{if(btn){btn.disabled=false;btn.textContent='Save Changes';}
saveInFlight=false;
for(let i=0;i<formEls.length;i++)formEls[i].disabled=false;}}
async function uploadDisk2(){const idx=sel;if(idx===null)return;const inp=document.createElement('input');inp.type='file';inp.accept='.qcow2,.qcow,.vmdk,.vdi,.vhdx,.raw,.img';inp.onchange=async function(){const file=inp.files&&inp.files[0];
if(!file)return;const fd=new FormData();fd.append('disk2',file);setStatus('Uploading Disk 2 for "'+vms[idx].name+'"...');try{const r=await fetch('/api/vms/'+idx+'/disk2',{method:'POST',body:fd,headers:{'X-API-Key':API_KEY}});if(!r.ok){var em=await r.text().catch(function(){return'';});try{var j=JSON.parse(em);if(j.error)em=j.error;}catch(e){}throw new Error(em||'HTTP '+r.status);}await refresh();setStatus('Disk 2 uploaded successfully.');if(sel===idx)editVm();}catch(e){setStatus('Upload failed: '+e.message);showToast('Disk 2 upload failed: '+e.message,'error');}};inp.click();}
function downloadDisk2(){if(sel===null)return;const a=document.createElement('a');a.href='/api/vms/'+sel+'/disk2/download';a.download=vms[sel].name+'_disk2.qcow2';document.body.appendChild(a);a.click();setTimeout(function(){document.body.removeChild(a);},1000);}
function fmtBytes(n){if(!Number.isFinite(n)||n<0)return'?';const u=['B','KiB','MiB','GiB','TiB'];let i=0,x=n;while(x>=1024&&i<u.length-1){x/=1024;i++;}return(i===0?x:x.toFixed(1))+' '+u[i];}
// Memory arrives from the daemon in MiB. Every memory label goes through these
// two helpers: the /1024 step is a binary multiple, so a scaled value is GiB,
// never a decimal "GB" (same convention as fmtBytes).
function memGiB(mb){return Math.round((Number(mb)||0)/1024*10)/10;}
function memText(mb){var n=Number(mb)||0;return n>=1024?memGiB(n)+' GiB':n+' MiB';}
async function loadGuestInfo(idx){const el=document.getElementById('guestIpVal');if(!el)return;try{const r=await fetch('/api/vms/'+idx+'/guestinfo',{headers:{'X-API-Key':API_KEY}});if(!r.ok)throw 0;const j=await r.json();if(sel===idx&&document.getElementById('guestIpVal'))document.getElementById('guestIpVal').textContent=(j.ips&&j.ips.length)?j.ips:'unavailable, guest agent not running';}catch(e){if(document.getElementById('guestIpVal'))document.getElementById('guestIpVal').textContent='unavailable';}}
async function loadDiskInfo(idx){const el=document.getElementById('diskUsageVal');if(!el)return;try{const r=await fetch('/api/vms/'+idx+'/diskinfo');if(!r.ok)throw 0;const j=await r.json();if(j.error)throw 0;if(sel===idx&&document.getElementById('diskUsageVal')){var pct=j.virtual_bytes>0?Math.min(100,Math.round(j.actual_bytes/j.virtual_bytes*100)):0;document.getElementById('diskUsageVal').innerHTML='<div class="ubar"><span style="width:'+pct+'%"></span></div><div class="ubar-txt">'+fmtBytes(j.actual_bytes)+' used / '+fmtBytes(j.virtual_bytes)+' ('+pct+'%)</div>';}}catch(e){if(document.getElementById('diskUsageVal'))document.getElementById('diskUsageVal').textContent='unavailable';}}
async function takeScreenshot(){if(sel===null)return;try{const r=await fetch('/api/vms/'+sel+'/screenshot',{headers:{'X-API-Key':API_KEY}});if(!r.ok){let t='';try{const j=await r.json();t=j.error||'';}catch(e){}showToast('Screenshot failed: '+(t||('HTTP '+r.status)),'error');return;}const b=await r.blob();const u=URL.createObjectURL(b);window.open(u,'_blank');setTimeout(function(){URL.revokeObjectURL(u);},10000);}catch(e){showToast('Screenshot failed','error');}}
async function changeCd(){if(sel===null)return;const cur=(document.getElementById('e_iso_path')||{}).value||vms[sel].iso_path||'';const p=await showPromptDialog('Path to the CD/ISO image to mount:',cur);if(p===null||p==='')return;const r=await apiPost('/api/vms/'+sel+'/cdrom','path='+encodeURIComponent(p));if(r){await refresh();setStatus('CD/ISO changed.'+(vms[sel].status==='running'?'':' Mounts on next boot.'));}}
async function ejectCd(){if(sel===null)return;const r=await apiPost('/api/vms/'+sel+'/cdrom/eject','');if(r){await refresh();setStatus('CD/ISO ejected.');}}
async function compactDisk(){if(sel===null)return;const v=vms[sel];if(v.status!=='stopped'){showToast('Power off the VM before compacting its disk','warn');return;}if(!await showConfirmDialog('Compact the primary disk? This rewrites the image to reclaim freed space (VM must stay off during the operation).'))return;const r=await apiPost('/api/vms/'+sel+'/disk/compact','');if(r){await refresh();setStatus('Primary disk compacted.');}}
async function resizeDisk(){if(sel===null)return;const v=vms[sel];if(v.status!=='stopped'){showToast('Power off the VM before resizing its disk','warn');return;}const cur=parseInt(v.disk,10)||0;const n=await showPromptDialog('New primary disk size in GB (grow only; current '+cur+' GB):',String(cur));if(n===null)return;const gb=parseInt(n,10);if(!Number.isFinite(gb)||gb<=cur){showToast('Enter a size larger than '+cur+' GB','error');return;}const r=await apiPost('/api/vms/'+sel+'/disk/resize','size='+gb);if(r){await refresh();setStatus('Primary disk resized to '+gb+' GB.');}}
// ── VNet Editor ──
// The editor (Preact) owns the form, validation and dirty state; this side fetches and writes the set.
async function loadVnets(){try{const r=await fetch('/api/networks');if(r.ok){const d=await r.json();return d.networks||[];}logDebug('Failed to load VNets:',r.status);}catch(e){logDebug('Failed to load VNets:',e);}return null;}
async function openVnets(select){
 if(document.getElementById('vnetdlg')){if(select)window.hangarUi.selectVnet(select);return;}
 const networks=await loadVnets();
 if(networks===null){showToast('Failed to load virtual networks','error');return;}
 window.hangarUi.openVnets({networks:networks,select:select?{name:select}:undefined,save:saveVnets,confirmDiscard:function(){return showConfirmDialog('Discard unsaved network changes?',{danger:true,okLabel:'Discard'});}});}
// The daemon persists the whole network set: Save Selected (`saved` names it) and Save All write the same body.
async function saveVnets(networks,saved){const r=await apiPost('/api/networks',JSON.stringify({networks:networks}));if(r)setStatus(saved?'Saved "'+saved+'".':'VNet settings saved.');return !!r;}
// ── Preferences ──
async function openPrefs(){var cfg={};try{var r=await fetch('/api/config');if(r.ok)cfg=await r.json();}catch(e){logDebug('Failed to load config:',e);}
var pf=cfg.prefs||{};
window.hangarUi.openPrefs({values:{theme:cfg.theme||window.hangarTheme||(document.documentElement.classList.contains('light')?'light':'dark'),defaultVmDir:pf.default_vm_dir||'',defaultMemoryMb:String(pf.default_memory_mb||2048),defaultCpuCores:String(pf.default_cpu_cores||2),autoprotectEnabled:pf.autoprotect_enabled_default?'1':'0',autoprotectIntervalMin:String(pf.autoprotect_interval_min_default||60),autoprotectMax:String(pf.autoprotect_max_default||10)},save:savePrefs});}
async function savePrefs(body){var r=await apiPost('/api/config',body);if(!r)return false;setStatus('Preferences saved.');return true;}
function openAbout(){window.hangarUi.openAbout();try{fetch('/api/capabilities').then(function(r){return r.json();}).then(function(c){window.hangarUi.setAboutVersion('Version '+(c.version||'?')+' · up to '+(c.max_vms||'?')+' VMs');}).catch(function(e){logDebug('Failed to load capabilities:',e);});}catch(e){logDebug('Failed to load capabilities:',e);}}
// Catalog cards are drawn by the Preact dialog; this side fetches the templates and creates the VM.
// Distro/OS visual identity: accent color + monogram for the card emblem.
function catalogEntry(e){var os=['Linux','Windows','FreeBSD','macOS','Other'];var br=osBrand((e.name||'')+' '+(e.id||''),os[e.guest_os]||'');
 return {id:e.id,name:e.name,os:os[e.guest_os]||'Other',description:e.description||'',cpuCores:e.cpu_cores,memory:memText(e.memory_mb),diskGb:e.disk_size_gb,brandColor:br.c,monogram:br.m};}
async function openCatalog(){
 if(document.getElementById('catalogdlg'))return;
 window.hangarUi.openCatalog({list:{kind:'loading'},create:quickstartVm});
 try{var r=await fetch('/api/catalog');if(!r.ok){window.hangarUi.setCatalog({list:{kind:'failed'}});return;}
  var entries=await r.json();
  window.hangarUi.setCatalog({list:entries&&entries.length?{kind:'ready',items:entries.map(catalogEntry)}:{kind:'empty'}});
 }catch(ex){logDebug('Failed to load catalog:',ex);window.hangarUi.setCatalog({list:{kind:'failed'}});}}
async function quickstartVm(slug){var r=await apiPost('/api/vms/quickstart/'+slug);if(!r)return false;await refresh();setStatus('VM created from template.');return true;}
// ── Sidebar Overlay Click-to-Close ──
document.body.addEventListener('click',function(e){if(document.body.classList.contains('sidebar-overlay')&&!e.target.closest('aside')){closeSidebar();}});
// ── Toolbar More Click-Outside ──
// ── Right-Click Context Menu ──
let ctxMenu=null,ctxVmIdx=-1;
function hideCtxMenu(){if(ctxMenu){ctxMenu.remove();ctxMenu=null;ctxVmIdx=-1;}}
document.addEventListener('click',function(e){if(ctxMenu&&!ctxMenu.contains(e.target))hideCtxMenu();});
var vmlistEl=document.getElementById('vmlist');
function openCtxMenu(idx,x,y){
  hideCtxMenu();ctxVmIdx=idx;
  ctxMenu=document.createElement('div');ctxMenu.className='ctx-menu';ctxMenu.setAttribute('role','menu');ctxMenu.setAttribute('aria-label','VM actions');
  ctxMenu.style.position='fixed';ctxMenu.style.visibility='hidden';
  ctxMenu.style.left=x+'px';ctxMenu.style.top=y+'px';
  document.body.appendChild(ctxMenu);
  var mr=ctxMenu.getBoundingClientRect();
  var vw=window.innerWidth,vh=window.innerHeight;
  if(x+mr.width>vw)x=vw-mr.width-4;if(x<4)x=4;
  if(y+mr.height>vh)y=vh-mr.height-4;if(y<4)y=4;
  ctxMenu.style.left=x+'px';ctxMenu.style.top=y+'px';
  ctxMenu.style.visibility='';
  var vmForMenu=vms[idx];
  var items=[
    {label:vmForMenu.status==='running'||vmForMenu.status==='paused'?'Power Off':'Power On',icon:vmForMenu.status==='running'||vmForMenu.status==='paused'?'i-stop':'i-play',action:'power-toggle',fn:powerToggle},
    {label:'Shut Down Guest',icon:'i-power',action:'shutdown',fn:shutdownGuest},
    {label:'Suspend',icon:'i-import',action:'suspend',fn:suspendGuest},
    {label:'Pause',icon:'i-pause',action:'pause',fn:pauseGuest},
    {label:'Resume',icon:'i-play',action:'resume',fn:resumeGuest},
    {sep:true},
    {label:'Take Snapshot…',icon:'i-snapshot',action:'snapshot',fn:takeSnapshot},
    {label:'Snapshot Manager…',icon:'i-grid',action:'snapshot',fn:openSnapshots},
    {label:'Open Console',icon:'i-terminal',action:'display',fn:function(){select(idx).then(function(){switchTab('console');});}},
    {label:'Send Ctrl+Alt+Del',icon:'i-keyboard',action:'cad',fn:sendCad},
    {label:'Display Only',icon:'i-maximize',action:'display',fn:enterDisplayOnly},
    {sep:true},
    {label:'Settings',icon:'i-gear',action:'settings',fn:editVm},
    {label:'Move to Folder…',icon:'i-folder',action:'settings',fn:moveToFolder},
    {label:'Rename…',icon:'i-edit',action:'rename',fn:renameGuest},
    {label:'Clone…',icon:'i-copy',action:'clone',fn:cloneGuest},
    {label:'Migrate…',icon:'i-migrate',action:'migrate',fn:migrateGuest},
    {label:'Export to OVF',icon:'i-export',action:'export',fn:exportOvf},
    {label:'Toggle Favorite',icon:'i-star',action:'settings',fn:function(target){toggleFavorite(target);}},
    {sep:true},
    {label:'Reset',icon:'i-refresh',action:'reset',danger:true,fn:resetGuest},
    {label:'Delete',icon:'i-trash',action:'delete',danger:true,fn:deleteVm}
  ];
  items.forEach(function(item){if(item.sep){var sep=document.createElement('div');sep.className='ctx-sep';sep.setAttribute('role','separator');ctxMenu.appendChild(sep);return;}var mi=document.createElement('button');mi.type='button';mi.className='ctx-item'+(item.danger?' danger':'');mi.setAttribute('role','menuitem');mi.tabIndex=-1;var ok=actionAllowed(item.action,vmForMenu);mi.disabled=!ok;mi.title=ok?'':disabledReason(item.action,vmForMenu);if(item.icon){mi.innerHTML='<svg class="ico" aria-hidden="true"><use href="/icons.svg#'+item.icon+'"/></svg>'+escHtml(item.label);}else{mi.textContent=item.label;}
    mi.addEventListener('click',function(){if(mi.disabled)return;var target=ctxVmIdx;Promise.resolve(select(target)).then(function(){if(sel===target)item.fn(target);});hideCtxMenu();});
    ctxMenu.appendChild(mi);});
  var first=ctxMenu.querySelector('.ctx-item:not([disabled])');if(first){first.tabIndex=0;first.focus();}
}
// Shift+F10 / Menu key open the same menu as a right click, at the focused row.
function ctxMenuAnchor(item){var r=item.getBoundingClientRect();return{x:r.left+Math.min(24,r.width/2),y:r.bottom};}
if(vmlistEl){
  vmlistEl.addEventListener('contextmenu',function(e){
    var item=e.target.closest('.vm-item');if(!item){hideCtxMenu();return;}
    var idx=parseInt(item.getAttribute('data-vm-index'),10);if(isNaN(idx)||idx>=vms.length){hideCtxMenu();return;}
    e.preventDefault();openCtxMenu(idx,e.clientX,e.clientY);});
  vmlistEl.addEventListener('keydown',function(e){
    if(e.key!=='ContextMenu'&&!(e.shiftKey&&e.key==='F10'))return;
    var item=e.target.closest('.vm-item');if(!item)return;
    var idx=parseInt(item.getAttribute('data-vm-index'),10);if(isNaN(idx)||idx>=vms.length)return;
    e.preventDefault();e.stopPropagation();var p=ctxMenuAnchor(item);openCtxMenu(idx,p.x,p.y);});
}
document.addEventListener('keydown',function(e){
  if(!ctxMenu)return;
  var items=ctxMenu.querySelectorAll('.ctx-item:not([disabled])');
  if(e.key==='Escape'){e.preventDefault();e.stopPropagation();var inv=ctxVmIdx;hideCtxMenu();var row=document.querySelector('#vmlist .vm-item[data-vm-index="'+inv+'"]');if(row)row.focus();return;}
  if(e.key!=='ArrowDown'&&e.key!=='ArrowUp'&&e.key!=='Home'&&e.key!=='End')return;
  e.preventDefault();if(!items.length)return;
  var cur=items.length?Array.prototype.indexOf.call(items,document.activeElement):-1;
  var next=e.key==='Home'?0:e.key==='End'?items.length-1:e.key==='ArrowDown'?(cur+1+items.length)%items.length:(cur-1+items.length)%items.length;
  for(var i=0;i<items.length;i++)items[i].tabIndex=i===next?0:-1;
  items[next].focus();});
// ── Keyboard Shortcuts ──
// ── Command palette (Ctrl+K): fuzzy command + jump-to-VM launcher ──
var paletteItems=[],paletteSel=0,palettePrevFocus=null;
function paletteCommands(){
  var c=[{label:'New VM',icon:'i-plus',run:newVm},{label:'Import VM',icon:'i-import',run:importGuest},{label:'VM Catalog',icon:'i-grid',run:openCatalog},{label:'Virtual Network Editor',icon:'i-net',run:openVnets},{label:'Preferences',icon:'i-gear',run:openPrefs},{label:'Keyboard Shortcuts',icon:'i-keyboard',run:showShortcutsModal},{label:'Toggle Theme',icon:'i-theme',run:window.cycleTheme},{label:'Refresh Inventory',icon:'i-refresh',run:refresh}];
  if(sel!==null&&sel<vms.length){var v=vms[sel];var on=(v.status==='running'||v.status==='paused');
    c.push({label:(on?'Power Off, ':'Power On, ')+v.name,run:powerToggle});
    c.push({label:'Settings, '+v.name,run:editVm});
    c.push({label:'Take Snapshot, '+v.name,run:takeSnapshot});
    c.push({label:'Clone, '+v.name,run:cloneGuest});
    c.push({label:'Rename, '+v.name,run:renameGuest});
    c.push({label:'Move to Folder, '+v.name,run:moveToFolder});
    c.push({label:'Delete, '+v.name,run:deleteVm});}
  for(var i=0;i<vms.length;i++)c.push({label:'Go to '+vms[i].name,vm:vms[i].name});
  return c;
}
function ensurePalette(){
  if(document.getElementById('palette'))return;
  var o=document.createElement('div');o.id='palette';o.className='palette-overlay';o.hidden=true;
  o.innerHTML='<div class="palette" role="dialog" aria-modal="true" aria-label="Command palette"><input id="paletteInput" type="text" placeholder="Type a command or VM name…" aria-label="Command palette" role="combobox" aria-expanded="true" aria-controls="paletteList" aria-autocomplete="list" autocomplete="off"><ul id="paletteList" role="listbox" aria-label="Commands"></ul></div>';
  document.body.appendChild(o);
  o.addEventListener('click',function(e){if(e.target===o)closePalette();});
  var inp=o.querySelector('#paletteInput');
  inp.addEventListener('input',function(){renderPalette(inp.value);});
  inp.addEventListener('keydown',function(e){
    if(e.key==='Escape'){e.preventDefault();e.stopPropagation();closePalette();}
    else if(e.key==='ArrowDown'){e.preventDefault();e.stopPropagation();movePalette(1);}
    else if(e.key==='ArrowUp'){e.preventDefault();e.stopPropagation();movePalette(-1);}
    else if(e.key==='Enter'){e.preventDefault();e.stopPropagation();runPalette(paletteSel);}
  });
  o.querySelector('#paletteList').addEventListener('click',function(e){var li=e.target.closest('li[data-pidx]');if(li)runPalette(parseInt(li.getAttribute('data-pidx'),10));});
}
function openPalette(){ensurePalette();palettePrevFocus=document.activeElement;var o=document.getElementById('palette');var inp=o.querySelector('#paletteInput');o.hidden=false;inp.value='';renderPalette('');inp.focus();}
function closePalette(){var o=document.getElementById('palette');if(o)o.hidden=true;if(palettePrevFocus&&palettePrevFocus.focus)palettePrevFocus.focus();}
function renderPalette(filter){var all=paletteCommands();var f=(filter||'').toLowerCase().trim();paletteItems=f?all.filter(function(it){return it.label.toLowerCase().indexOf(f)>=0;}):all;paletteSel=0;var ul=document.getElementById('paletteList');if(!ul)return;var h='';for(var i=0;i<paletteItems.length;i++)h+='<li role="option" id="paletteOpt'+i+'" data-pidx="'+i+'" aria-selected="'+(i===0?'true':'false')+'" class="'+(i===0?'sel':'')+'">'+(paletteItems[i].icon?'<svg class="ico" aria-hidden="true"><use href="/icons.svg#'+paletteItems[i].icon+'"/></svg>':'')+escHtml(paletteItems[i].label)+'</li>';ul.innerHTML=h||'<li class="palette-empty">No matches</li>';var pi=document.getElementById('paletteInput');if(pi){if(paletteItems.length)pi.setAttribute('aria-activedescendant','paletteOpt0');else pi.removeAttribute('aria-activedescendant');}}
function movePalette(d){if(!paletteItems.length)return;paletteSel=(paletteSel+d+paletteItems.length)%paletteItems.length;var lis=document.querySelectorAll('#paletteList li[data-pidx]');for(var i=0;i<lis.length;i++){lis[i].classList.toggle('sel',i===paletteSel);lis[i].setAttribute('aria-selected',i===paletteSel?'true':'false');}if(lis[paletteSel]){lis[paletteSel].scrollIntoView({block:'nearest'});document.getElementById('paletteInput').setAttribute('aria-activedescendant','paletteOpt'+paletteSel);}}
function runPalette(i){var it=paletteItems[i];if(!it)return;closePalette();if(it.run){it.run();}else if(it.vm){var idx=idxByName(it.vm);if(idx>=0)select(idx);}}

// ── Visual network topology (elkjs auto-layout → SVG) ──
function modeLabel(m){return m==='user'?'NAT (user)':m==='gvproxy'?'gvproxy':m==='bridge'?'Bridged':m==='none'?'Isolated':m;}
function modeKind(m){return m==='bridge'?'bridged':(m==='user'||m==='gvproxy')?'nat':m==='none'?'dim':'accent';}
function vnetKindByName(nets,name){for(var i=0;i<nets.length;i++){if(nets[i].name===name)return window.hangarUi.netKind(nets[i].type);}return 'accent';}
function vmModes(v){var m=[v.net||'user'];for(var i=2;i<=8;i++){var nm=v['nic'+i+'_mode'];if(nm&&nm!=='none')m.push(nm);}return m.filter(Boolean);}
function buildTopologyGraph(nets){
 var children=[],edges=[],meta={},seen={},eid=0,modesUsed={},anyUplink=false;
 var edgeSeen={};
 function addNode(id,label,kind,target,accent,state){if(seen[id])return;seen[id]=1;var w=Math.max(96,Math.round(label.length*7.2)+26);children.push({id:id,width:w,height:38,labels:[{text:label}]});meta[id]={kind:kind,label:label,target:target,accent:accent||null,state:state||''};}
 function addEdge(a,b){var key=a+'>'+b;if(edgeSeen[key])return;edgeSeen[key]=1;edges.push({id:'e'+(eid++),sources:[a],targets:[b]});}
 for(var i=0;i<vms.length;i++){var v=vms[i];var vid='vm:'+v.name;addNode(vid,v.name,'vm',{kind:'vm',name:v.name},null,v.status||'');
  // Explicit vnet binding: draw the real VM -> named virtual-network edge.
  var bound=[v.vnet];for(var bn=2;bn<=8;bn++){bound.push(v['nic'+bn+'_vnet']);}
  for(var bi=0;bi<bound.length;bi++){var bname=bound[bi];if(!bname)continue;var bnid='net:'+bname;addNode(bnid,bname,'vnet',{kind:'network',name:bname},vnetKindByName(nets,bname));addEdge(vid,bnid);addEdge(bnid,'host');anyUplink=true;}
  var modes=vmModes(v),dd={};for(var k=0;k<modes.length;k++){var mode=modes[k];if(dd[mode])continue;dd[mode]=1;var mid='mode:'+mode;addNode(mid,modeLabel(mode),'net',null,modeKind(mode));modesUsed[mode]=1;addEdge(vid,mid);}}
 for(var n=0;n<nets.length;n++){var net=nets[n];var nid='net:'+net.name;addNode(nid,net.name+' · '+net.type,'vnet',{kind:'network',name:net.name},window.hangarUi.netKind(net.type));addEdge(nid,'host');anyUplink=true;}
 Object.keys(modesUsed).forEach(function(m){if(m!=='none'){addEdge('mode:'+m,'host');anyUplink=true;}});
 if(anyUplink)addNode('host','Host / Physical','host',null);
 return {graph:{id:'root',layoutOptions:{'elk.algorithm':'layered','elk.direction':'RIGHT','elk.spacing.nodeNode':'22','elk.layered.spacing.nodeNodeBetweenLayers':'80'},children:children,edges:edges},meta:meta};
}
// ELK result -> the typed layout the Preact dialog draws (edge path data, positioned nodes).
function topoLayout(res,meta){
 var edges=[];(res.edges||[]).forEach(function(e){(e.sections||[]).forEach(function(sec){var pts=[sec.startPoint].concat(sec.bendPoints||[]).concat([sec.endPoint]);edges.push(pts.map(function(p,i){return (i?'L':'M')+Math.round(p.x)+' '+Math.round(p.y);}).join(' '));});});
 var nodes=(res.children||[]).map(function(nd){var m=meta[nd.id]||{};return {id:nd.id,x:nd.x,y:nd.y,width:nd.width,height:nd.height,label:m.label||nd.id,kind:m.kind||'net',state:m.state||'',accent:m.accent||null,target:m.target||null};});
 return {width:Math.ceil(res.width||800),height:Math.ceil(res.height||400),edges:edges,nodes:nodes};
}
function openTopologyTarget(t){if(t.kind==='vm')topoSelectVm(t.name);else topoEditNet(t.name);}
async function openTopology(){if(!document.getElementById('topodlg'))window.hangarUi.openTopology({view:{kind:'loading',message:'Computing layout…'},open:openTopologyTarget});await renderTopology();}
// On-demand browser bundles. The layout engine, the two console clients and
// the serial terminal add up to over a megabyte that the VM library never
// touches, so they are fetched the first time the surface that needs them
// opens. Concurrent callers share the pending promise; a failed or timed-out
// load clears it so the surface's Retry button starts a fresh attempt.
const ASSET_LOAD_TIMEOUT_MS=15000;
const pendingAssets={};
function ensureAsset(src,isReady){
 if(isReady())return Promise.resolve();
 if(pendingAssets[src])return pendingAssets[src];
 pendingAssets[src]=new Promise(function(resolve,reject){
  var s=document.createElement('script');
  var timer=setTimeout(function(){finish(false);},ASSET_LOAD_TIMEOUT_MS);
  function finish(ok){
   clearTimeout(timer);s.onload=null;s.onerror=null;
   if(ok){resolve();}else{s.remove();delete pendingAssets[src];reject(new Error('Failed to load '+src));}
  }
  s.src=src;s.async=true;
  s.onload=function(){finish(isReady());};
  s.onerror=function(){finish(false);};
  document.head.appendChild(s);
 });
 return pendingAssets[src];
}
function ensureStylesheet(href){
 if(document.querySelector('link[data-asset="'+href+'"]'))return Promise.resolve();
 return new Promise(function(resolve,reject){
  var l=document.createElement('link');
  l.rel='stylesheet';l.href=href;l.dataset.asset=href;
  l.onload=function(){l.onload=null;l.onerror=null;resolve();};
  l.onerror=function(){l.onload=null;l.onerror=null;l.remove();reject(new Error('Failed to load '+href));};
  document.head.appendChild(l);
 });
}
function ensureElk(){return ensureAsset('/elk.js',function(){return typeof ELK==='function';});}
// Every step pushes a view to the dialog: loading (engine, then layout), failed (Retry), empty or ready.
async function renderTopology(){
 var ui=window.hangarUi;
 if(typeof ELK!=='function'){
  ui.setTopology({view:{kind:'loading',message:'Loading layout engine…'}});
  try{await ensureElk();}catch(e){ui.setTopology({view:{kind:'failed',message:'Layout engine failed to load.'}});return;}
 }
 var built=buildTopologyGraph((await loadVnets())||[]);
 if(!built.graph.children.length){ui.setTopology({view:{kind:'empty'}});return;}
 ui.setTopology({view:{kind:'loading',message:'Computing layout…'}});
 try{var res=await new ELK().layout(built.graph);ui.setTopology({view:{kind:'ready',layout:topoLayout(res,built.meta)}});}
 catch(e){ui.setTopology({view:{kind:'failed',message:'Layout failed: '+((e&&e.message)||'error')}});}
}
function topoSelectVm(name){var d=document.getElementById('topodlg');if(d)d.close();var vd=document.getElementById('vnetdlg');if(vd)vd.close();var idx=idxByName(name);if(idx>=0)select(idx);}
function topoEditNet(name){var d=document.getElementById('topodlg');if(d)d.close();openVnets(name);}

// ── Sidebar multi-select + bulk operations ──
function toggleSelectMode(){selectMode=!selectMode;if(!selectMode)checkedIds.clear();var t=document.getElementById('selectToggle');if(t)t.setAttribute('aria-pressed',selectMode?'true':'false');var sv=document.getElementById('search');renderList(sv?sv.value.toLowerCase():'');}
function updateBulkBar(){var bar=document.getElementById('bulkBar');if(!bar)return;bar.hidden=!selectMode;
 // Prune names of VMs deleted/renamed elsewhere so the count never over-reports.
 if(selectMode&&checkedIds.size)checkedIds.forEach(function(n){if(idxById(n)<0)checkedIds.delete(n);});
 var c=document.getElementById('bulkCount');if(c)c.textContent=checkedIds.size+' selected';}
// Run `fn(idx,name)` for each checked VM, re-syncing vms[] from the server before
// each so an index stays correct even as earlier deletes shift the list.
async function bulkRun(label,fn){
  var ids=Array.from(checkedIds);if(!ids.length){showToast('No VMs selected','warn');return;}
  var ok=0,fail=0;
  for(var i=0;i<ids.length;i++){
    try{var rr=await fetch('/api/vms');if(rr.ok){vms=normVmBools(await rr.json());publishVms();}}catch(e){}
    var idx=idxById(ids[i]);if(idx<0){continue;}
    try{var r=await fn(idx,ids[i]);if(r)ok++;else fail++;}catch(e){fail++;}
  }
  setStatus(label+': '+ok+' ok'+(fail?(', '+fail+' failed'):''));
  await refresh();
}
async function doBulkPower(on){
  if(!checkedIds.size){showToast('No VMs selected','warn');return;}
  var verb=on?'Power on':'Power off';
  if(!(await showConfirmDialog(verb+' '+checkedIds.size+' selected VM(s)?',on?{okLabel:'Power On'}:{danger:true,okLabel:'Power Off'})))return;
  await bulkRun(verb,function(idx){var v=vms[idx];var running=(v.status==='running'||v.status==='paused');if((on&&running)||(!on&&!running))return Promise.resolve(true);return apiPost('/api/vms/'+idx+(on?'/start':'/stop'));});
}
async function doBulkSnapshot(){
  if(!checkedIds.size){showToast('No VMs selected','warn');return;}
  var tag=await showPromptDialog('Snapshot name for '+checkedIds.size+' selected VM(s):','bulk-snapshot');
  if(tag===null)return;tag=tag.trim();if(!tag){showToast('Enter a snapshot name','warn');return;}
  if(/[\x00-\x1f]|\.\./.test(tag)||tag.length>255){showToast('Snapshot name is invalid','error');return;}
  await bulkRun('Snapshot',function(idx){return apiPost('/api/vms/'+idx+'/snapshots','tag='+encodeURIComponent(tag));});
}
async function doBulkDelete(){
  if(!checkedIds.size){showToast('No VMs selected','warn');return;}
  if(!(await showConfirmDialog('Delete '+checkedIds.size+' selected VM(s)? Undo restores them one at a time.',{danger:true,okLabel:'Delete'})))return;
  await bulkRun('Delete',function(idx){return apiPost('/api/vms/'+idx+'/delete');});
  checkedIds.clear();updateBulkBar();
}

document.addEventListener('keydown',async function(e){var shift=e.shiftKey;
if((e.ctrlKey||e.metaKey)&&e.key==='s'&&activeTab==='settings'&&sel!==null){e.preventDefault();saveVm();return;}
if((e.ctrlKey||e.metaKey)&&(e.key==='k'||e.key==='K')){e.preventDefault();openPalette();return;}
if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.tagName==='SELECT')return;
if(e.key==='ArrowUp'||e.key==='ArrowDown'){var listEl=document.getElementById('vmlist');if(listEl&&listEl.contains(e.target)){e.preventDefault();var dir=e.key==='ArrowUp'?-1:1;var idx=sel===null?(dir<0?vms.length-1:0):Math.max(0,Math.min(vms.length-1,sel+dir));Promise.resolve(select(idx)).then(function(){var ni=document.querySelector('#vmlist .vm-item[data-vm-index="'+idx+'"]');if(ni)ni.focus();});return;}}
if((e.key==='ArrowLeft'||e.key==='ArrowRight')&&e.target.closest('[role="tablist"]')){var tabs=Array.from(document.querySelectorAll('.tab-btn:not([disabled])'));var cur=tabs.indexOf(e.target);if(cur<0)return;e.preventDefault();var next=cur+(e.key==='ArrowRight'?1:-1);if(next<0)next=tabs.length-1;if(next>=tabs.length)next=0;switchTab(tabs[next].getAttribute('data-tab')||'summary');tabs[next].focus();return;}
if(e.key==='Escape'){
  if(closeToolbarMenus(true)||ctxMenu){hideCtxMenu();return;}
  var anyOpen=false;var openDlgs=document.querySelectorAll('dialog[open]');for(var di=0;di<openDlgs.length;di++){openDlgs[di].close();anyOpen=true;}
  if(!anyOpen&&document.body.classList.contains('displayonly')){exitDisplayOnly();return;}
  if(!anyOpen&&sel!==null){if(activeTab==='settings'&&settingsDirty){if(!(await showConfirmDialog('You have unsaved changes. Discard them?',{danger:true,okLabel:'Discard'})))return;}sel=null;renderList();showEmptyState();}
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
if(e.key==='Delete'){if(e.target.closest('button,a[href]'))return;if(sel!==null)deleteVm();return;}
if(e.key==='Enter'){if(e.target.closest('button,a[href]'))return;if(sel!==null)powerToggle();return;}
if(e.altKey&&e.key==='ArrowUp'&&sel!==null&&sel>0){e.preventDefault();reorderVm(sel,sel-1);return;}
if(e.altKey&&e.key==='ArrowDown'&&sel!==null&&sel<vms.length-1){e.preventDefault();reorderVm(sel,sel+1);return;}
});
function showShortcutsModal(){window.hangarUi.openShortcuts();}
function enterDisplayOnly(){
  if(!rfb&&!spice){showToast('No embedded display is connected','warn');return;}
  document.body.classList.add('displayonly');
  document.documentElement.requestFullscreen().catch(function(){});
  setStatus('Display-only, F11 or Esc to exit');
  // Briefly reveal the exit bar so first-time users can find their way out;
  // it otherwise stays hidden until hover, leaving keyboard-unaware users stuck.
  var bar=document.querySelector('.displayonly-bar');
  if(bar){bar.classList.add('reveal');setTimeout(function(){if(document.body.classList.contains('displayonly'))bar.classList.remove('reveal');},3500);}
}
function exitDisplayOnly(){
  document.body.classList.remove('displayonly');
  var bar=document.querySelector('.displayonly-bar');if(bar)bar.classList.remove('reveal');
  if(document.fullscreenElement)document.exitFullscreen();
  setStatus('Exited display-only mode');
}
function reconnectDisplay(){if(sel===null||sel>=vms.length)return;stopFb();startFb();}
// ── Periodic Refresh ──
refresh();
setInterval(refresh,5000);
// Server-Sent Events: the daemon bumps a state version on every mutation and
// unexpected VM exit; refresh immediately instead of waiting for the 5s poll.
// EventSource reconnects on its own; the poll above remains the fallback.
(function(){var deb=null;try{var es=new EventSource('/api/events');var lb=document.getElementById('livebadge');
es.onopen=function(){if(lb)lb.hidden=false;};
es.onerror=function(){if(lb)lb.hidden=true;};
es.addEventListener('change',function(){if(deb)clearTimeout(deb);deb=setTimeout(function(){refresh();},120);});}catch(e){}})();
document.addEventListener('visibilitychange',function(){if(!document.hidden)refresh();});
// ── noVNC / SPICE live viewer ──
var rfb = null; // noVNC RFB client instance
// Auto-reconnect for the embedded display: if the RFB/SPICE session drops while
// the VM is still running (QEMU restart, transient relay loss), retry with
// exponential backoff instead of leaving a dead console.
var fbReconnectTimer=null,fbReconnectDelay=1000;
function clearFbReconnect(){if(fbReconnectTimer){clearTimeout(fbReconnectTimer);fbReconnectTimer=null;}}
function scheduleFbReconnect(){if(fbReconnectTimer)return;fbReconnectTimer=setTimeout(function(){fbReconnectTimer=null;if(sel!==null&&sel<vms.length){var v=vms[sel];if(v.status==='running'&&embeddedDisplayCapable(v)&&!rfb&&!spice){fbReconnectDelay=Math.min(fbReconnectDelay*2,15000);startFb();}}},fbReconnectDelay);}
var spice = null; // SPICE HTML5 client instance
var displayPresenter = null;

function findProtocolCanvas(displayEl) {
  if (!displayEl) return null;
  var canvases = displayEl.querySelectorAll('canvas');
  for (var i = 0; i < canvases.length; i++) {
    if (!canvases[i].classList.contains('gpu-presenter')) return canvases[i];
  }
  return null;
}

function ensurePresenterCanvas(p) {
  if (p.canvas) return p.canvas;
  var canvas = document.createElement('canvas');
  canvas.className = 'gpu-presenter';
  canvas.setAttribute('aria-hidden', 'true');
  p.displayEl.appendChild(canvas);
  p.canvas = canvas;
  return canvas;
}

function stopDisplayPresenter() {
  if (!displayPresenter) return;
  displayPresenter.stopped = true;
  if (displayPresenter.raf) cancelAnimationFrame(displayPresenter.raf);
  if (displayPresenter.canvas && displayPresenter.canvas.parentNode) {
    displayPresenter.canvas.parentNode.removeChild(displayPresenter.canvas);
  }
  if (displayPresenter.displayEl) {
    displayPresenter.displayEl.classList.remove('gpu-presenting');
    displayPresenter.displayEl.removeAttribute('data-renderer');
    var sources = displayPresenter.displayEl.querySelectorAll('.display-source-canvas');
    for (var i = 0; i < sources.length; i++) sources[i].classList.remove('display-source-canvas');
  }
  displayPresenter = null;
}

function markPresenterReady(p, mode) {
  p.mode = mode;
  p.displayEl.classList.add('gpu-presenting');
  p.displayEl.setAttribute('data-renderer', mode);
  updateDisplayBadge('connected', p.protocol);
}

function startDisplayPresenter(displayEl, protocol) {
  stopDisplayPresenter();
  var p = { displayEl: displayEl, protocol: protocol, mode: 'canvas', stopped: false, raf: 0, canvas: null };
  displayPresenter = p;
  if (navigator.gpu) {
    initWebGpuPresenter(p).catch(function() {
      if (!p.stopped) initWebGlPresenter(p);
    });
  } else {
    initWebGlPresenter(p);
  }
}

async function initWebGpuPresenter(p) {
  if (!navigator.gpu) throw new Error('WebGPU unavailable');
  var adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
  if (!adapter) throw new Error('WebGPU adapter unavailable');
  var device = await adapter.requestDevice();
  if (p.stopped) return;
  var canvas = ensurePresenterCanvas(p);
  var context = canvas.getContext('webgpu');
  if (!context) throw new Error('WebGPU canvas unavailable');
  var format = navigator.gpu.getPreferredCanvasFormat ? navigator.gpu.getPreferredCanvasFormat() : 'bgra8unorm';
  context.configure({ device: device, format: format, alphaMode: 'opaque' });
  var sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });
  var shader = device.createShaderModule({ code:
    'struct Out { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };\n' +
    '@vertex fn vs(@builtin(vertex_index) i: u32) -> Out {\n' +
    '  var pos = array<vec2<f32>, 6>(vec2<f32>(-1.0,-1.0), vec2<f32>(1.0,-1.0), vec2<f32>(-1.0,1.0), vec2<f32>(-1.0,1.0), vec2<f32>(1.0,-1.0), vec2<f32>(1.0,1.0));\n' +
    '  var uv = array<vec2<f32>, 6>(vec2<f32>(0.0,1.0), vec2<f32>(1.0,1.0), vec2<f32>(0.0,0.0), vec2<f32>(0.0,0.0), vec2<f32>(1.0,1.0), vec2<f32>(1.0,0.0));\n' +
    '  var out: Out; out.pos = vec4<f32>(pos[i], 0.0, 1.0); out.uv = uv[i]; return out;\n' +
    '}\n' +
    '@group(0) @binding(0) var frameTex: texture_2d<f32>;\n' +
    '@group(0) @binding(1) var frameSampler: sampler;\n' +
    '@fragment fn fs(in: Out) -> @location(0) vec4<f32> { return textureSample(frameTex, frameSampler, in.uv); }\n'
  });
  var bindLayout = device.createBindGroupLayout({ entries: [
    { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: {} },
    { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: {} }
  ]});
  var pipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [bindLayout] }),
    vertex: { module: shader, entryPoint: 'vs' },
    fragment: { module: shader, entryPoint: 'fs', targets: [{ format: format }] },
    primitive: { topology: 'triangle-list' }
  });
  p.webgpu = { device: device, context: context, sampler: sampler, bindLayout: bindLayout, pipeline: pipeline, texture: null, bindGroup: null, width: 0, height: 0 };
  markPresenterReady(p, 'webgpu');
  function frame() {
    if (p.stopped) return;
    var source = findProtocolCanvas(p.displayEl);
    if (source && source.width > 0 && source.height > 0) {
      source.classList.add('display-source-canvas');
      if (canvas.width !== source.width || canvas.height !== source.height) {
        canvas.width = source.width;
        canvas.height = source.height;
      }
      if (p.webgpu.width !== source.width || p.webgpu.height !== source.height) {
        p.webgpu.width = source.width;
        p.webgpu.height = source.height;
        p.webgpu.texture = device.createTexture({
          size: [source.width, source.height, 1],
          format: 'rgba8unorm',
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
        });
        p.webgpu.bindGroup = device.createBindGroup({
          layout: bindLayout,
          entries: [
            { binding: 0, resource: p.webgpu.texture.createView() },
            { binding: 1, resource: sampler }
          ]
        });
      }
      device.queue.copyExternalImageToTexture({ source: source }, { texture: p.webgpu.texture }, { width: source.width, height: source.height });
      var encoder = device.createCommandEncoder();
      var pass = encoder.beginRenderPass({ colorAttachments: [{
        view: context.getCurrentTexture().createView(),
        clearValue: { r: 0, g: 0, b: 0, a: 1 },
        loadOp: 'clear',
        storeOp: 'store'
      }]});
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, p.webgpu.bindGroup);
      pass.draw(6);
      pass.end();
      device.queue.submit([encoder.finish()]);
    }
    p.raf = requestAnimationFrame(frame);
  }
  frame();
}

function initWebGlPresenter(p) {
  var canvas = ensurePresenterCanvas(p);
  var mode = 'webgl2';
  var gl = canvas.getContext('webgl2', { alpha: false, antialias: false });
  if (!gl) {
    mode = 'webgl';
    gl = canvas.getContext('webgl', { alpha: false, antialias: false });
  }
  if (!gl) {
    p.mode = 'canvas';
    if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
    p.canvas = null;
    p.displayEl.classList.remove('gpu-presenting');
    p.displayEl.setAttribute('data-renderer', 'canvas');
    updateDisplayBadge('connected', p.protocol);
    return;
  }
  function shader(type, source) {
    var s = gl.createShader(type);
    gl.shaderSource(s, source);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) || 'shader compile failed');
    return s;
  }
  try {
    var vs = shader(gl.VERTEX_SHADER, 'attribute vec2 aPos;attribute vec2 aUv;varying vec2 vUv;void main(){vUv=aUv;gl_Position=vec4(aPos,0.0,1.0);}');
    var fs = shader(gl.FRAGMENT_SHADER, 'precision mediump float;varying vec2 vUv;uniform sampler2D uTex;void main(){gl_FragColor=texture2D(uTex,vUv);}');
    var program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) || 'program link failed');
    gl.useProgram(program);
    var data = new Float32Array([
      -1,-1, 0,0,  1,-1, 1,0,  -1,1, 0,1,
      -1,1, 0,1,   1,-1, 1,0,   1,1, 1,1
    ]);
    var buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    var stride = 4 * 4;
    var aPos = gl.getAttribLocation(program, 'aPos');
    var aUv = gl.getAttribLocation(program, 'aUv');
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, stride, 0);
    gl.enableVertexAttribArray(aUv);
    gl.vertexAttribPointer(aUv, 2, gl.FLOAT, false, stride, 8);
    var tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    markPresenterReady(p, mode);
    function frame() {
      if (p.stopped) return;
      var source = findProtocolCanvas(p.displayEl);
      if (source && source.width > 0 && source.height > 0) {
        source.classList.add('display-source-canvas');
        if (canvas.width !== source.width || canvas.height !== source.height) {
          canvas.width = source.width;
          canvas.height = source.height;
          gl.viewport(0, 0, canvas.width, canvas.height);
        }
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      }
      p.raf = requestAnimationFrame(frame);
    }
    frame();
  } catch (e) {
    p.mode = 'canvas';
    if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
    p.canvas = null;
    p.displayEl.classList.remove('gpu-presenting');
    p.displayEl.setAttribute('data-renderer', 'canvas');
    updateDisplayBadge('connected', p.protocol);
  }
}

// ── Encoded video stream (WebCodecs ← /ws/video, docs/VIDEO-PIPELINE.md) ──
// When the VM has video_stream and the browser has VideoDecoder, an H.264
// stream paints onto an overlay canvas (pointer-events:none, so input still
// flows to the noVNC layer underneath). Fails silently back to noVNC.
var videoWs=null,videoDec=null,videoCanvas=null,videoTs=0,videoRetry=0,videoRetryTimer=null;
function startVideoStream(idx){
  if(videoWs||typeof VideoDecoder==='undefined')return;
  var v=vms[idx];if(!v||v.video_stream!=='true')return;
  var displayEl=document.getElementById('display');if(!displayEl)return;
  try{
    var ws=new WebSocket((location.protocol==='https:'?'wss:':'ws:')+'//'+location.host+'/ws/video/'+idx);
    ws.binaryType='arraybuffer';videoWs=ws;
    ws.onmessage=function(e){
      var b=new Uint8Array(e.data);if(!b.length)return;
      if(b[0]===1){ // config: u16 w, u16 h, u8 codec
        var w=b[1]|(b[2]<<8),h=b[3]|(b[4]<<8);
        if(!videoCanvas){videoCanvas=document.createElement('canvas');videoCanvas.className='video-layer';displayEl.appendChild(videoCanvas);}
        videoCanvas.width=w;videoCanvas.height=h;
        videoDec=new VideoDecoder({output:function(frame){
          try{var ctx=videoCanvas.getContext('2d');ctx.drawImage(frame,0,0);}catch(err){}
          frame.close();
        },error:function(){stopVideoStream();}});
        videoDec.configure({codec:'avc1.42E01F',optimizeForLatency:true,hardwareAcceleration:'no-preference'});
        displayEl.classList.add('video-active');
        updateDisplayBadge('connected','vnc');
        var bg=document.getElementById('displayBadge');if(bg)bg.textContent='H264 · WEBCODECS';
        return;
      }
      if((b[0]===2||b[0]===3)&&videoDec&&videoDec.state==='configured'){
        var key=b[0]===3;
        if(videoTs===0&&!key)return; // wait for the first key frame
        videoTs+=33333;
        try{videoDec.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:videoTs,data:b.subarray(1)}));}catch(err){stopVideoStream();}
      }
    };
    ws.onerror=function(){if(videoWs===ws)stopVideoStream();};
    ws.onclose=function(){if(videoWs!==ws)return;var hadConfig=!!videoDec;stopVideoStream();
     // Early close (e.g. connected before the capture session was up): retry
     // a few times while the VM is still running.
     if(!hadConfig&&videoRetry<5&&sel===idx&&vms[idx]&&vms[idx].status==='running'){videoRetry++;videoRetryTimer=setTimeout(function(){videoRetryTimer=null;startVideoStream(idx);},2000);}};
  }catch(e){stopVideoStream();}
}
function stopVideoStream(){
  if(videoRetryTimer){clearTimeout(videoRetryTimer);videoRetryTimer=null;}
  if(videoWs){try{videoWs.close();}catch(e){}videoWs=null;}
  if(videoDec){try{videoDec.close();}catch(e){}videoDec=null;}
  if(videoCanvas&&videoCanvas.parentNode)videoCanvas.parentNode.removeChild(videoCanvas);
  videoCanvas=null;videoTs=0;
  var d=document.getElementById('display');if(d)d.classList.remove('video-active');
}

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
  displayEl.classList.remove('connected');
  var hint=document.getElementById('displayHint');if(hint)hint.textContent='';

  // Dispatch based on display type: 2 = SPICE, 3 = VNC
  videoRetry=0;startVideoStream(idx);
  var dt = Number(v.display);
  if (dt === 2) {
    updateDisplayBadge('connecting', 'spice');
    startSpice(idx, displayEl, v);
  } else if (dt === 3) {
    updateDisplayBadge('connecting', 'vnc');
    startVnc(idx, displayEl);
  } else {
    displayEl.classList.remove('loading');
    displayEl.classList.remove('connected');
    displayEl.setAttribute('data-renderer','native');
    updateDisplayBadge('native');
    if(hint)hint.innerHTML='<strong>Native '+escHtml((displayLabels[dt]||'QEMU'))+' display</strong><span>Browser console requires embedded VNC or SPICE. Change Display & Video in Settings to use this pane.</span>';
  }
  // Other display types (GTK, SDL, None) have no remote framebuffer; skip.
}

function startVnc(idx, displayEl) {
  stopDisplayPresenter();
  // Remove any previously-created canvas.
  var oldCanvases = displayEl.querySelectorAll('canvas');
  for (var ci = 0; ci < oldCanvases.length; ci++) { if (oldCanvases[ci].parentNode === displayEl) displayEl.removeChild(oldCanvases[ci]); }
  return connectConsole(idx, displayEl, 'VNC', function(){return ensureAsset('/novnc.js',function(){return !!(window.noVNC&&(noVNC.default||noVNC.RFB));});}, function(url){
    // The vendored noVNC bundle exposes the RFB class as its `default` export
    // (noVNC.default), not noVNC.RFB. Accept either so a bundle update can't
    // silently break the console again.
    var RFBClass=(window.noVNC&&(noVNC.default||noVNC.RFB))||null;
    if(typeof RFBClass!=='function')throw new Error('noVNC bundle has no RFB class');
    rfb = new RFBClass(displayEl, url, {});
    rfb.addEventListener('connect', function() {
      fbReconnectDelay=1000;clearFbReconnect();
      displayEl.classList.remove('loading');
      displayEl.classList.add('connected');
      updateDisplayBadge('connected', 'vnc');
      startDisplayPresenter(displayEl, 'vnc');
    });
    rfb.addEventListener('disconnect', function() {
      stopFb();
      scheduleFbReconnect();
    });
    rfb.addEventListener('credentialsrequired', function() {
      rfb.sendCredentials({ password: '' });
    });
    rfb.scaleViewport = true;
    rfb.resizeSession = true;
  });
}

function startSpice(idx, displayEl, v) {
  stopDisplayPresenter();
  // Remove any previously-created canvas.
  var oldCanvases = displayEl.querySelectorAll('canvas');
  for (var ci = 0; ci < oldCanvases.length; ci++) { if (oldCanvases[ci].parentNode === displayEl) displayEl.removeChild(oldCanvases[ci]); }
  return connectConsole(idx, displayEl, 'SPICE', function(){return ensureAsset('/spice.js',function(){return typeof SpiceHtml5!=='undefined';});}, function(url){
    if(typeof SpiceHtml5==='undefined')throw new Error('SPICE bundle did not register');
    spice = new SpiceHtml5.SpiceMainConn({
      uri: url,
      password: '',
      screen_id: 'display',
      onerror: function(e) {
        logDebug('SPICE error:', e);
        stopFb();
      },
      onsuccess: function() {
        displayEl.classList.remove('loading');
        displayEl.classList.add('connected');
        updateDisplayBadge('connected', 'spice');
        startDisplayPresenter(displayEl, 'spice');
      }
    });
  });
}

// Shared console-connect path: fetch the client bundle on first use, then open
// the relay socket. A bundle that fails to load leaves the pane visible with a
// Retry button (reconnectDisplay) instead of a silently dead display.
function connectConsole(idx, displayEl, label, ensureClient, connect) {
  var hint=document.getElementById('displayHint');
  if(hint)hint.textContent='Loading '+label+' client…';
  var ready=ensureClient();
  return ready.then(function(){
    // The selection may have moved (or the pane closed) while the bundle
    // downloaded; connecting now would bind the relay to a stale VM.
    if(sel!==idx)return;
    if(hint)hint.textContent='';
    var proto=location.protocol==='https:'?'wss:':'ws:';
    var url=proto+'//'+location.host+'/ws/'+label.toLowerCase()+'/'+idx;
    connect(url);
  },function(){
    if(sel!==idx)return;
    displayEl.classList.remove('loading');
    updateDisplayBadge('disconnected');
    var h=document.getElementById('displayHint');
    if(h)h.innerHTML='<strong>'+escHtml(label)+' client failed to load.</strong><button type="button" class="btn" data-action="reconnectDisplay">Retry</button>';
  }).catch(function(e){
    if(sel!==idx)return;
    logDebug(label+' connect failed:',e);
    stopFb();
  });
}

function stopFb() {
  stopVideoStream();
  stopDisplayPresenter();
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
    displayEl.classList.remove('connected');
    displayEl.removeAttribute('data-renderer');
    var hint=document.getElementById('displayHint');if(hint)hint.textContent='';
    updateDisplayBadge('disconnected');
  }
}
function updateDisplayBadge(state, proto)  { if(typeof videoCanvas!=='undefined'&&videoCanvas){var vb=document.getElementById('displayBadge');if(vb){vb.textContent='H264 · WEBCODECS';return;}}
  var badge = document.getElementById('displayBadge');
  if (!badge) return;
  badge.classList.remove('vnc', 'spice');
  if (state === 'connecting') {
    badge.textContent = 'Connecting\u2026';
  } else if (state === 'connected') {
    var mode = displayPresenter && displayPresenter.mode ? displayPresenter.mode.toUpperCase() : 'Canvas';
    badge.textContent = (proto ? proto.toUpperCase() : 'Display') + ' · ' + mode;
  } else if (state === 'native') {
    badge.textContent = 'Native Display';
  } else {
    badge.textContent = 'Disconnected';
  }
  if (proto) badge.classList.add(proto);
}
// Serial console
let serialWs=null,serialIdx=null,serialManualOff=false,serialManualOffVmIdx=-1;
let serialReconnectDelay=1000,serialReconnectTimeoutId=null;
function scheduleSerialReconnect(){if(serialReconnectTimeoutId)return;serialReconnectTimeoutId=setTimeout(function(){serialReconnectTimeoutId=null;if(sel!==null&&sel<vms.length){const v=vms[sel];if(serialManualOff&&sel===serialManualOffVmIdx){serialReconnectDelay=1000;return;}if(v.status==='running'&&v.hasSerial==='true'){startSerial(sel);serialReconnectDelay=Math.min(serialReconnectDelay*2,30000);}else{serialReconnectDelay=1000;}}},serialReconnectDelay);}
function clearSerialReconnect(){if(serialReconnectTimeoutId){clearTimeout(serialReconnectTimeoutId);serialReconnectTimeoutId=null;}serialReconnectDelay=1000;}
// xterm.js serial terminal: real ANSI emulation, bidirectional (onData →
// guest), WebGL renderer when available (canvas/DOM fallback inside xterm).
// The terminal bundles are ~740 KB of the initial page load for a panel most
// sessions never open, so they load on the first serial connection.
var serialTerm=null,serialFit=null,serialBuf='';
function ensureXterm(){
 return Promise.all([
  ensureStylesheet('/xterm.css'),
  ensureAsset('/xterm.js',function(){return typeof Terminal!=='undefined';}),
 ]).then(function(){
  return Promise.all([
   ensureAsset('/xterm-fit.js',function(){return typeof FitAddon!=='undefined';}),
   ensureAsset('/xterm-webgl.js',function(){return typeof WebglAddon!=='undefined';}),
  ]);
 });
}
function setSerialStatus(msg,isError){
 var st=document.getElementById('serialStatus');
 if(!st)return;
 st.textContent=msg||'';
 st.classList.toggle('error',!!isError);
 if(msg&&isError)st.innerHTML=escHtml(msg)+' <button type="button" class="btn" data-action="reconnectSerial">Retry</button>';
}
function ensureSerialTerm(){
 if(serialTerm)return Promise.resolve(serialTerm);
 var host=document.getElementById('serialterm');if(!host)return Promise.resolve(null);
 setSerialStatus('Loading terminal…',false);
 return ensureXterm().then(function(){
  if(typeof Terminal==='undefined')throw new Error('xterm did not register');
  serialTerm=new Terminal({fontSize:12,fontFamily:'ui-monospace,"Cascadia Code","JetBrains Mono",Consolas,monospace',cursorBlink:true,scrollback:5000,convertEol:false,theme:{background:'#101214',foreground:'#b7c5bd',cursor:'#86c89a',cursorAccent:'#101214',selectionBackground:'rgba(77,130,184,.4)'}});
  try{serialFit=new FitAddon.FitAddon();serialTerm.loadAddon(serialFit);}catch(e){}
  serialTerm.open(host);
  try{serialTerm.loadAddon(new WebglAddon.WebglAddon());}catch(e){/* GPU unavailable: xterm falls back to its DOM/canvas renderer */}
  serialTerm.onData(function(d){if(serialWs&&serialWs.readyState===WebSocket.OPEN)serialWs.send(d);});
  if(serialFit){try{serialFit.fit();}catch(e){}}
  setSerialStatus('',false);
  return serialTerm;
 },function(){
  setSerialStatus('Serial terminal failed to load.',true);
  return null;
 });
}
function serialFitNow(){if(serialFit){try{serialFit.fit();}catch(e){}}}
function startSerial(idx){if(serialManualOff&&serialManualOffVmIdx===idx)return;
clearSerialReconnect();
if(serialWs){if(serialIdx===idx&&(serialWs.readyState===WebSocket.OPEN||serialWs.readyState===WebSocket.CONNECTING))return;
serialWs.close();serialWs=null;} /* close stale CONNECTING socket before reconnect */
const sameVm=(serialIdx===idx);
stopSerial(!sameVm); /* clear terminal only when switching VMs */
if(idx===null||idx>=vms.length)return;const v=vms[idx];if(v.status!=='running'||v.hasSerial!=='true')return;
serialIdx=idx;const sp=document.getElementById('serialpanel');if(!sp)return;sp.style.display='block';sp.classList.add('connected');
// The terminal bundle may still be downloading; open the relay socket once it
// is ready, unless the selection moved on in the meantime.
ensureSerialTerm().then(function(t){
if(!t||sel!==idx)return;
if(!sameVm){t.reset();serialBuf='';}
const proto=location.protocol==='https:'?'wss:':'ws:';const ws=new WebSocket(proto+'//'+location.host+'/ws/serial/'+idx);
ws.binaryType='arraybuffer';
serialWs=ws; // reassign before old onclose fires to avoid closing the new socket
ws.onmessage=e=>{var data=e.data instanceof ArrayBuffer?new Uint8Array(e.data):e.data;t.write(data);
 var txt=typeof data==='string'?data:new TextDecoder('utf-8',{fatal:false}).decode(data);
 serialBuf+=txt;var SERIAL_MAX=256*1024;if(serialBuf.length>SERIAL_MAX)serialBuf=serialBuf.slice(serialBuf.length-SERIAL_MAX);};
ws.onopen=()=>{serialReconnectDelay=1000;sp.classList.add('connected');serialFitNow();};
ws.onclose=()=>{if(serialWs===ws){serialWs=null;serialIdx=null;const sp2=document.getElementById('serialpanel');if(sp2){sp2.style.display='none';sp2.classList.remove('connected');}if(!serialManualOff||serialManualOffVmIdx!==idx)scheduleSerialReconnect();}};
ws.onerror=()=>{if(serialWs===ws){serialWs=null;serialIdx=null;const sp2=document.getElementById('serialpanel');if(sp2){sp2.style.display='none';sp2.classList.remove('connected');}if(!serialManualOff||serialManualOffVmIdx!==idx)scheduleSerialReconnect();}};
}); /* terminal ready */
}
function stopSerial(clearTerm){if(clearTerm===void 0)clearTerm=true;clearSerialReconnect();if(serialWs){serialWs.close();serialWs=null;}serialIdx=null;if(clearTerm){if(serialTerm)serialTerm.reset();serialBuf='';}setSerialStatus('',false);const sp=document.getElementById('serialpanel');if(sp){sp.style.display='none';sp.classList.remove('connected');}}
function reconnectSerial(){if(sel===null||sel>=vms.length)return;startSerial(sel);}
function manualDisconnectSerial(){serialManualOff=true;serialManualOffVmIdx=sel!==null?sel:-1;clearSerialReconnect();stopSerial(true);}
// (keyboard input now flows through xterm's onData)
// Serial panel resize handle
(function() {
  var handle = document.getElementById('serialResize');
  var term = document.getElementById('serialterm');
  if (!handle || !term) return;
  // After any height change, refit the xterm grid to the new box.
  var refit = function(){ if (typeof serialFitNow === 'function') serialFitNow(); };
  var startY = 0, startH = 0, dragging = false;
  function dragStart(clientY){dragging=true;startY=clientY;startH=term.offsetHeight;document.body.style.cursor='ns-resize';document.body.style.userSelect='none';}
  handle.addEventListener('touchstart', function(e){ if(e.touches.length===1){ e.preventDefault(); dragStart(e.touches[0].clientY); } }, {passive:false});
  window.addEventListener('touchmove', function(e){ if(!dragging||!e.touches.length) return; var dy=e.touches[0].clientY-startY; var nh=Math.max(60,Math.min(600,startH+dy)); term.style.height=nh+'px'; refit(); }, {passive:true});
  window.addEventListener('touchend', function(){ if(!dragging) return; dragging=false; document.body.style.cursor=''; document.body.style.userSelect=''; refit(); });
  handle.addEventListener('mousedown', function(e) {
    e.preventDefault();
    dragStart(e.clientY);
  });
  window.addEventListener('mousemove', function(e) {
    if (!dragging) return;
    var dy = e.clientY - startY;
    var newH = Math.max(60, Math.min(600, startH + dy));
    term.style.height = newH + 'px';
    refit();
  });
  window.addEventListener('mouseup', function() {
    if (!dragging) return;
    dragging = false;
    document.body.style.cursor = '';
    document.body.style.userSelect = '';
    refit();
  });
  // Keyboard equivalent for the drag handle: arrows resize in steps, Home/End
  // jump to the limits. Without it the pane height is pointer-only.
  function syncHandleValue(){
    var h=Math.round(term.offsetHeight);
    if(!handle.getAttribute('aria-valuenow')||Math.abs(Number(handle.getAttribute('aria-valuenow'))-h)>1){
      handle.setAttribute('aria-valuenow',String(h));
      handle.setAttribute('aria-valuetext',h+' pixels');
    }
  }
  function setHeight(h){
    term.style.height=Math.max(60,Math.min(600,h))+'px';
    syncHandleValue();
    refit();
  }
  handle.addEventListener('keydown', function(e) {
    var h=term.offsetHeight, step=e.shiftKey?48:16, handled=true;
    if(e.key==='ArrowUp')setHeight(h-step);
    else if(e.key==='ArrowDown')setHeight(h+step);
    else if(e.key==='Home')setHeight(600);
    else if(e.key==='End')setHeight(60);
    else handled=false;
    if(handled)e.preventDefault();
  });
  handle.addEventListener('focus',syncHandleValue);
  syncHandleValue();
})();
var filterTimer=null;
// ── Event Delegation (CSP-safe: no inline handlers) ──
var actionHandlers={
	 toggleSidebar:function(){toggleSidebar();},deselectVm:function(){deselectVm();},
	 powerToggle:function(){powerToggle();},pauseGuest:function(){pauseGuest();},
 resumeGuest:function(){resumeGuest();},shutdownGuest:function(){shutdownGuest();},
 resetGuest:function(){resetGuest();},suspendGuest:function(){suspendGuest();},
 sendCad:function(){sendCad();},editVm:function(){editVm();},
 renameGuest:function(){renameGuest();},cloneGuest:function(){cloneGuest();},
 importGuest:function(){importGuest();},takeSnapshot:function(){takeSnapshot();},openSnapshots:function(){openSnapshots();},
 exportOvf:function(){exportOvf();},migrateGuest:function(){migrateGuest();},openVnets:function(){openVnets();},
 openPrefs:function(){openPrefs();},openAbout:function(){openAbout();},openCatalog:function(){openCatalog();},
 showShortcutsModal:function(){showShortcutsModal();},
 batchStart:function(){batchStart();},batchStop:function(){batchStop();},
 deleteVm:function(){deleteVm();},clearSearch:function(){clearSearch();},
 newVm:function(){newVm();},
 manualDisconnectSerial:function(){manualDisconnectSerial();},reconnectSerial:function(){reconnectSerial();},
 clearSerial:function(){if(serialTerm)serialTerm.reset();serialBuf='';},
 exportSerial:function(){if(!serialBuf)return;var blob=new Blob([serialBuf],{type:'text/plain'});var a=document.createElement('a');var url=URL.createObjectURL(blob);a.href=url;a.download='hangar-serial-'+new Date().toISOString().replace(/[:.]/g,'-')+'.txt';a.click();setTimeout(function(){URL.revokeObjectURL(url);},100);},
 saveVm:function(){saveVm();},
 select:function(el){var i=parseInt(el.getAttribute('data-vm-index'),10);if(!isNaN(i))select(i);},
	 sortInv:function(el){var c=el.getAttribute('data-col');if(!c)return;if(dashSort.col===c)dashSort.dir=-dashSort.dir;else{dashSort.col=c;dashSort.dir=1;}if(window.van&&dashSortState){dashSortState.val={col:dashSort.col,dir:dashSort.dir};}else{showEmptyState();}},
	 toggleSelectMode:function(){toggleSelectMode();},
	 toggleCheck:function(el){var n=el.getAttribute('data-vm-id');if(!n)return;if(el.checked)checkedIds.add(n);else checkedIds.delete(n);updateBulkBar();},
	 bulkPower:function(el){doBulkPower(el.getAttribute('data-on')==='1');},
	 bulkSnapshot:function(){doBulkSnapshot();},
	 bulkDelete:function(){doBulkDelete();},
	 toggleFolder:function(el){var f=el.getAttribute('data-folder');if(f===null)return;setFolderOpen(f,!folderOpen(f));filterList();},
	 moveToFolder:function(){moveToFolder();},
	 openTopology:function(){openTopology();},
 toggleFavorite:function(el){var i=parseInt(el.getAttribute('data-vm-index'),10);if(!isNaN(i))toggleFavorite(i);},
 switchTab:function(el){switchTab(el.getAttribute('data-tab')||'summary');},
 closeDlg:function(el){var id=el.getAttribute('data-dialog');if(id){var d=document.getElementById(id);if(d)d.close();}},
 viewLog:function(){viewLog();},refreshLog:function(){refreshLog();},
 dismissBanner:function(){var b=document.getElementById('connbanner');if(b)b.style.display='none';serverDown=false;setStatus('');},
 cancelMigrate:function(){cancelMigrate();},
 toggleTheme:function(){window.cycleTheme();},
 filterList:function(){filterList();},
	 disk2upload:function(){uploadDisk2();},
	 disk2download:function(){downloadDisk2();},
	 resizeDisk:function(){resizeDisk();},
	 compactDisk:function(){compactDisk();},
	 changeCd:function(){changeCd();},
	 ejectCd:function(){ejectCd();},
	 takeScreenshot:function(){takeScreenshot();},
	 enterDisplayOnly:function(){enterDisplayOnly();},
	 exitDisplayOnly:function(){exitDisplayOnly();},
	 reconnectDisplay:function(){reconnectDisplay();},
	 setSettingsCategory:function(el){setSettingsCategory(el.getAttribute('data-settings-category')||'compute');}
	};
document.body.addEventListener('click',function(e){
 // Click anywhere outside an open menu/popover closes it (Escape already does).
 var el=e.target.closest('[data-action]');if(!el)return;
 var action=el.getAttribute('data-action');var h=actionHandlers[action];if(h)h(el);
});
document.body.addEventListener('input',function(e){
 if(e.target.closest('#tabSettings')){settingsDirty=true;validateSettings(true);}
 var el=e.target.closest('[data-action="filterList"]');if(el){
  if(filterTimer)clearTimeout(filterTimer);
  filterTimer=setTimeout(filterList,180);
 }
});
document.body.addEventListener('change',function(e){
 if(e.target.closest('#tabSettings')){settingsDirty=true;validateSettings(true);}
});
document.body.addEventListener('keydown',function(e){
 if((e.key==='Enter'||e.key===' ')&&e.target.tagName!=='INPUT'&&e.target.tagName!=='TEXTAREA'&&e.target.tagName!=='SELECT'){
  // Keyboard-activate focusable non-button controls (CSP-safe dispatch is click
  // only): list rows, folder headers, sort headers.
  var el=e.target.closest('[data-action]');if(!el)return;
  if(el.getAttribute('role')==='button'||el.tagName==='TH'||el.getAttribute('data-action')==='select'){
   e.preventDefault();var action=el.getAttribute('data-action');var h=actionHandlers[action];if(h)h(el);
  }
 }
});
window.addEventListener('beforeunload',function(){stopFb();stopSerial(true);clearSerialReconnect();});
// ── Drag-to-reorder VM list ──
(function initDragReorder(){
  var dragIdx=null;
  var vml=document.getElementById('vmlist');if(!vml)return;
  vml.addEventListener('dragstart',function(e){
    var item=e.target.closest('.vm-item');if(!item)return;
    dragIdx=parseInt(item.getAttribute('data-vm-index'),10);
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
    var item=e.target.closest('.vm-item');if(!item||dragIdx===null)return;
    var idx=parseInt(item.getAttribute('data-vm-index'),10);
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
    var toIdx=parseInt(item.getAttribute('data-vm-index'),10);
    if(isNaN(toIdx)||toIdx===dragIdx)return;
    var from=dragIdx,to=toIdx;
    dragIdx=null;
    // Route through reorderVm so mouse drag matches keyboard/touch: optimistic
    // reorder, undo toast, and correct selection tracking on success/failure.
    if(!saveInFlight)reorderVm(from,to);
  });
})();
// ── Touch drag-to-reorder (pointer events fallback for mobile) ──
(function initTouchReorder(){
  var touchDrag=null,vml=document.getElementById('vmlist');if(!vml)return;
  function getItem(e){return e.target.closest('.vm-item');}
  function itemIdx(item){return parseInt(item.getAttribute('data-vm-index'),10);}
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
      touchDrag.ghost.style.cssText='position:fixed;z-index:9999;pointer-events:none;opacity:0.85;width:'+touchDrag.item.offsetWidth+'px;box-shadow:var(--shadow-lg);background:var(--surface);border-radius:var(--radius-md)';
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
      if(target){var toIdx=itemIdx(target);if(!isNaN(toIdx)&&toIdx!==touchDrag.idx&&!saveInFlight){reorderVm(touchDrag.idx,toIdx);}}
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
  var sl=document.getElementById('skip-link');if(!sl){sl=document.createElement('a');sl.id='skip-link';sl.href='#main-content';sl.textContent='Skip to main content';document.body.insertBefore(sl,document.body.firstChild);}else{sl.href='#main-content';}
  sl.addEventListener('click',function(e){e.preventDefault();var mn=document.getElementById('main-content');if(mn){if(!mn.hasAttribute('tabindex'))mn.setAttribute('tabindex','-1');mn.focus();}});
  var mn=document.getElementById('main-content');if(mn&&!mn.hasAttribute('tabindex'))mn.setAttribute('tabindex','-1');
  var aside=document.querySelector('aside');if(aside){aside.id='sidebar';aside.setAttribute('role','navigation');aside.setAttribute('aria-label','VM Library');}
  syncSidebarButton();
  var vml=document.getElementById('vmlist');if(vml){vml.setAttribute('aria-label','VM Library');vml.setAttribute('role','group');}
  var tb=document.querySelector('.tab-bar');if(tb)tb.setAttribute('role','tablist');
  var tbb=document.querySelectorAll('.tab-btn');for(var i=0;i<tbb.length;i++)tbb[i].setAttribute('role','tab');
})();
window.addEventListener('resize',function(){if(!isMobileSidebar()){sidebarOpen=false;var aside=document.querySelector('aside');if(aside)aside.classList.remove('open');document.body.classList.remove('sidebar-overlay');}syncSidebarButton();});

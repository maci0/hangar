//! KVMGUI — Web Frontend (HTTP server + HTML/CSS UI)
//! Serves a VMware WS7-style UI via embedded HTTP server.
//! Open http://localhost:9080 in any browser.
const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");

const MAX_VMS = 64;
var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
var vm_count: usize = 0;
var prefs: vm.Prefs = .{};

const PORT: u16 = 9080;
const BIND_ADDR: [4]u8 = .{ 0, 0, 0, 0 }; // 0.0.0.0 — accessible remotely
var auth_token: [64]u8 = [_]u8{0} ** 64;
var auth_token_len: usize = 0;

const c = std.c;

fn acceptLoop(fd: c.fd_t) void {
    while (true) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) continue;
        _ = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
    }
}

fn serveHtml(conn: c.fd_t) void {
    defer _ = c.close(conn);
    var buf: [4096]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n <= 0) return;
    const req = buf[0..@intCast(n)];

    // Route: GET / → index page, GET /api/vms → JSON, POST /api/power/{idx} → toggle
    var response: []const u8 = "";
    var content_type: []const u8 = "text/html";

    if (std.mem.startsWith(u8, req, "GET /api/vms")) {
        content_type = "application/json";
        response = try renderJson();
    } else if (std.mem.startsWith(u8, req, "GET /api/health")) {
        response = "{\"status\":\"ok\",\"version\":\"1.0\"}";
        content_type = "application/json";
    } else if (std.mem.startsWith(u8, req, "GET /api/vm/")) {
        content_type = "application/json";
        response = try renderVmDetail(req);
    } else if (std.mem.startsWith(u8, req, "POST /api/power/")) {
        response = try handlePower(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/new")) {
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/delete/")) {
        response = try handleDelete(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/fb/")) {
        response = try renderFramebuffer(req);
        content_type = "image/bmp";
    } else if (std.mem.startsWith(u8, req, "POST /api/clone/")) {
        response = try handleClone(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/save")) {
        persist.save(&vms, vm_count, prefs) catch {};
        response = "saved";
        content_type = "text/plain";
    } else {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    }

    _ = c.write(conn, @ptrCast("HTTP/1.1 200 OK\r\nContent-Type: "), 36);
    _ = c.write(conn, content_type.ptr, content_type.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{response.len}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 25);
    _ = c.write(conn, response.ptr, response.len);
}

var fb_client: ?*vnc.VncClient = null;

fn renderFramebuffer(req: []const u8) ![]const u8 {
    // GET /api/fb/N — return the framebuffer for VM N as raw BGRA
    const prefix = "GET /api/fb/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid idx";
    if (idx >= vm_count) return "no vm";
    const v = &vms[idx];
    if (!v.isAlive()) return "off";

    if (fb_client == null) {
        fb_client = vnc.VncClient.new() orelse return "no vnc";
    }
    const vc = fb_client.?;
    if (!vc.isConnected()) {
        _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0; var fh: c_int = 0;
        if (vc.getSize(&fw, &fh)) {
            const size: usize = @intCast(fw * fh * 4);
            return @as([*]const u8, @ptrCast(pixels))[0..@min(size, @as(usize, 1024 * 1024))];
        }
    }
    return "no fb";
}

fn renderVmDetail(req: []const u8) ![]const u8 {
    const prefix = "GET /api/vm/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "{}";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "{}";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "{}";
    if (idx >= vm_count) return "{}";
    const v = &vms[idx];
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"disk":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"notes":"{s}"}}
    , .{ idx, v.getNameSlice(), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()), v.memory_mb, v.cpu_cores, v.disk_size_gb, std.mem.span(v.network.toStr()), std.mem.span(v.firmware.toStr()), if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false", if (v.hasNotes()) v.getNotesSlice() else "" }) catch return "{}";
    return buf[0..json.len];
}

fn renderJson() ![]const u8 {
    // Build simple JSON list of VMs
    var json_buf: [8192]u8 = undefined;
    var w: usize = 0;
    @memcpy(json_buf[w..][0..1], "[");
    w += 1;
    for (0..vm_count) |i| {
        if (i > 0) { json_buf[w] = ','; w += 1; }
        const v = &vms[i];
        const entry = std.fmt.bufPrint(json_buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"disk":{d}}}
        , .{ i, v.getNameSlice(), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()), v.memory_mb, v.cpu_cores, v.disk_size_gb }) catch break;
        w += entry.len;
    }
    json_buf[w] = ']';
    w += 1;
    return json_buf[0..w];
}

fn handlePower(req: []const u8) ![]const u8 {
    // Extract idx from /api/power/N
    const prefix = "POST /api/power/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (v.isAlive()) { qemu.forceStopVm(v); qemu.reapVm(v); }
    else { qemu.startVm(v, std.heap.page_allocator) catch {}; }
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleNewVm(req: []const u8) ![]const u8 {
    if (vm_count >= MAX_VMS) return "full";
    // Parse body: name=...&mem=...&cpu=...&disk=...
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var cfg = vm.VmConfig{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) cfg.setName(val);
        if (std.mem.eql(u8, key, "mem")) cfg.memory_mb = std.fmt.parseInt(u32, val, 10) catch 2048;
        if (std.mem.eql(u8, key, "cpu")) cfg.cpu_cores = std.fmt.parseInt(u32, val, 10) catch 2;
        if (std.mem.eql(u8, key, "disk")) cfg.disk_size_gb = std.fmt.parseInt(u32, val, 10) catch 20;
    }
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleClone(req: []const u8) ![]const u8 {
    const prefix = "POST /api/clone/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count or vm_count >= MAX_VMS) return "full";
    var clone = vms[idx];
    var name_buf: [256]u8 = undefined;
    const cn = std.fmt.bufPrintZ(&name_buf, "{s} (clone)", .{clone.getNameSlice()}) catch return "nameerr";
    clone.setName(cn);
    clone.status = .stopped;
    clone.pid = null;
    clone.vnc_port = 5900 + @as(u16, @intCast(vm_count));
    clone.spice_port = 5930 + @as(u16, @intCast(vm_count));
    vms[vm_count] = clone;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleDelete(req: []const u8) ![]const u8 {
    const prefix = "POST /api/delete/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    // Shift remaining
    var i = idx;
    while (i + 1 < vm_count) : (i += 1) vms[i] = vms[i + 1];
    vm_count -= 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

const index_html =
    \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>KVMGUI</title><style>
    \\*{margin:0;padding:0;box-sizing:border-box}body{font:14px system-ui;display:flex;height:100vh;background:#1e1f23;color:#e6e7ea}
    \\aside{width:220px;background:#16171a;padding:10px;overflow-y:auto;display:flex;flex-direction:column}
    \\aside h2{font-size:13px;color:#9aa1ab;margin:10px 0 5px;text-transform:uppercase;letter-spacing:1px}
    \\aside .vm-item{padding:6px 8px;cursor:pointer;border-radius:4px;display:flex;align-items:center;gap:6px;font-size:13px}
    \\aside .vm-item:hover{background:#2c2f36}.vm-item.active{background:#3b82f6;color:#fff}
    \\main{flex:1;padding:20px;overflow-y:auto}
    \\main h1{font-size:24px;margin-bottom:10px}.detail-row{display:flex;gap:10px;padding:6px 0;font-size:13px}
    \\.detail-label{color:#9aa1ab;width:100px}.btn{padding:6px 14px;border:1px solid #3a3e46;background:#2c2f36;color:#e6e7ea;border-radius:5px;cursor:pointer;font-size:13px;margin-right:6px}
    \\.btn:hover{background:#363a42}.btn.primary{background:#3b82f6;border-color:#3b82f6;color:#fff}
    \\.btn.danger{background:#c0392b;border-color:#c0392b;color:#fff}
    \\.toolbar{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
    \\dialog{border:none;border-radius:8px;padding:20px;background:#1e1f23;color:#e6e7ea;width:400px}
    \\dialog input,select{width:100%;padding:6px;margin:6px 0;background:#16171a;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px}
    \\dialog .btn-row{display:flex;gap:6px;margin-top:12px;justify-content:flex-end}
    \\#statusbar{position:fixed;bottom:0;left:0;right:0;padding:4px 12px;font-size:11px;background:#16171a;color:#9aa1ab}
    \\</style></head><body>
    \\<aside><h2>KVMGUI</h2><input id="search" placeholder="Filter VMs..." style="width:100%;padding:4px 8px;margin-bottom:8px;background:#2c2f36;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px;font-size:12px" oninput="filterList()"><div id="vmlist"></div>
    \\<div style="margin-top:auto"><button class="btn primary" style="width:100%" onclick="newVm()">+ New VM</button></div></aside>
    \\<main><div id="display" style="background:#000;border-radius:8px;margin-bottom:16px;display:none"><canvas id="fbcanvas" width="640" height="480" style="width:100%;max-height:400px"></canvas></div><div class="toolbar">
    \\<button id="powerbtn" class="btn primary" onclick="powerToggle()">▶ Power On</button>
    \\<button class="btn" onclick="editVm()">Settings</button>
    \\<button class="btn danger" onclick="deleteVm()">Delete</button>
    \\</div><h1 id="vmname">Select a VM</h1>
    \\<div id="details"></div></main>
    \\<div id="statusbar">Ready</div>
    \\<dialog id="newdlg"><h3>New Virtual Machine</h3>
    \\<input id="n_name" placeholder="VM Name" value="New VM"><input id="n_mem" placeholder="Memory (MB)" type="number" value="2048">
    \\<input id="n_cpu" placeholder="CPU Cores" type="number" value="2"><input id="n_disk" placeholder="Disk (GB)" type="number" value="20">
    \\<div class="btn-row"><button class="btn" onclick="newdlg.close()">Cancel</button><button class="btn primary" onclick="createVm()">Create</button></div></dialog>
    \\<script>
    \\let vms=[]; let sel=null;
    \\async function refresh(){const r=await fetch('/api/vms');vms=await r.json();renderList();if(sel!==null&&sel<vms.length)renderDetails();}
    \\function filterList(){const f=document.getElementById('search').value.toLowerCase();renderList(f);}
    \\function renderList(filter){const e=document.getElementById('vmlist');const f=(filter||'').toLowerCase();let h='';for(let i=0;i<vms.length;i++){const v=vms[i];if(f&&!v.name.toLowerCase().includes(f))continue;
    \\const color=v.status==='running'?'#22c55e':v.status==='paused'?'#f97316':v.status==='suspended'?'#eab308':'#9aa1ab';
    \\const icon=v.status==='running'?'▶':v.status==='paused'?'⏸':'  ';
    \\h+=`<div class="vm-item${sel===i?' active':''}" onclick="select(${i})"><span style="color:${color};font-weight:bold">${icon}</span> ${v.name}</div>`;}
    \\e.innerHTML=h||'<div style="color:#666;font-size:12px">No VMs</div>';
    \\let cnt=0,running=0;for(let v of vms){cnt++;if(v.status==='running')running++;}
    \\document.getElementById('statusbar').textContent=cnt+' virtual machine(s)'+(running>0?', '+running+' running':'');}
    \\function select(i){sel=i;renderList();renderDetails();}
    \\function renderDetails(){if(sel===null||sel>=vms.length){document.getElementById('vmname').textContent='Select a VM';document.getElementById('details').innerHTML='';return;}
    \\const v=vms[sel];const sc=v.status==='running'?'#22c55e':v.status==='paused'?'#f97316':v.status==='suspended'?'#eab308':'#9aa1ab';
    \\document.getElementById('vmname').textContent=v.name;
    \\document.getElementById('details').innerHTML=`<div class="detail-row"><span class="detail-label">State</span><span style="color:${sc};font-weight:bold">${v.status}</span></div>`+
    \\`<div class="detail-row"><span class="detail-label">Guest OS</span>${v.os}</div>`+
    \\`<div class="detail-row"><span class="detail-label">Memory</span>${v.mem} MB</div>`+
    \\`<div class="detail-row"><span class="detail-label">CPU</span>${v.cpu} cores</div>`+
    \\`<div class="detail-row"><span class="detail-label">Hard Disk</span>${v.disk} GB</div>`;updatePowerBtn();}
    \\async function powerToggle(){if(sel===null)return;await fetch('/api/power/'+sel,{method:'POST'});refresh();}
    \\function updatePowerBtn(){const b=document.getElementById('powerbtn');if(sel===null||sel>=vms.length){b.textContent='▶ Power On';b.className='btn primary';return;}
    \\const v=vms[sel];if(v.status==='running'){b.textContent='⏹ Power Off';b.className='btn danger';}else if(v.status==='paused'){b.textContent='▶ Resume';b.className='btn primary';}else{b.textContent='▶ Power On';b.className='btn primary';}}
    \\function newVm(){document.getElementById('newdlg').showModal();}
    \\async function createVm(){const n=document.getElementById('n_name').value;const m=document.getElementById('n_mem').value;
    \\const c=document.getElementById('n_cpu').value;const d=document.getElementById('n_disk').value;
    \\await fetch(`/api/new`,{method:'POST',body:`name=${encodeURIComponent(n)}&mem=${m}&cpu=${c}&disk=${d}`});document.getElementById('newdlg').close();refresh();}
    \\async function deleteVm(){if(sel===null)return;if(!confirm('Delete this VM?'))return;await fetch('/api/delete/'+sel,{method:'POST'});sel=null;refresh();}
    \\function editVm(){if(sel===null)return;alert('Edit settings opens the FLTK desktop app.');}
    \\refresh();
    \\setInterval(refresh,5000);
    \\// WebGPU/Canvas2D framebuffer display
    \\let fbCanvas=document.getElementById('fbcanvas'),fbCtx=fbCanvas.getContext('2d'),fbInterval=null;
    \\async function startFb(){if(sel===null){document.getElementById('display').style.display='none';if(fbInterval)clearInterval(fbInterval);return;}
    \\document.getElementById('display').style.display='block';
    \\if(fbInterval)clearInterval(fbInterval);fbInterval=setInterval(async()=>{if(sel===null||sel>=vms.length)return;const v=vms[sel];if(v.status!=='running')return;
    \\try{const r=await fetch('/api/fb/'+sel);if(!r.ok)return;const buf=await r.arrayBuffer();if(buf.byteLength<100)return;const w=640,h=480;fbCanvas.width=w;fbCanvas.height=h;
    \\const img=fbCtx.createImageData(w,h);const src=new Uint8Array(buf);const dst=img.data;for(let i=0;i<w*h;i++){const o=i*4;dst[o]=src[o+2];dst[o+1]=src[o+1];dst[o+2]=src[o];dst[o+3]=255;}
    \\fbCtx.putImageData(img,0,0);}catch(e){}},200)};
    \\setInterval(()=>{if(sel!==null&&sel<vms.length&&vms[sel].status==='running')startFb();},2000);
    \\</script></body></html>
;

pub fn main() !void {
    vm_count = persist.load(&vms, std.heap.page_allocator, &prefs);

    const sock = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (sock < 0) return;
    defer _ = c.close(sock);

    const one: c_int = 1;
    _ = c.setsockopt(sock, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));

    // Bind to 0.0.0.0 — accessible locally and remotely
    const bind_ip: u32 = (@as(u32, BIND_ADDR[0]) << 24) | (@as(u32, BIND_ADDR[1]) << 16) | (@as(u32, BIND_ADDR[2]) << 8) | @as(u32, BIND_ADDR[3]);
    var addr: c.sockaddr.in = .{ .family = c.AF.INET, .port = std.mem.nativeToBig(u16, PORT), .addr = std.mem.nativeToBig(u32, bind_ip), .zero = [_]u8{0} ** 8 };
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return;
    if (c.listen(sock, 10) != 0) return;

    // Create Unix socket listener for local clients
    const unix_path = "/tmp/kvmgui-daemon.sock";
    _ = c.unlink(unix_path);
    const unix_sock = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    var unix_addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memcpy(unix_addr.path[0..unix_path.len], unix_path);
    unix_addr.path[unix_path.len] = 0;
    const unix_len = @offsetOf(c.sockaddr.un, "path") + unix_path.len + 1;
    _ = c.setsockopt(unix_sock, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    _ = c.bind(unix_sock, @ptrCast(&unix_addr), @intCast(unix_len));
    _ = c.listen(unix_sock, 10);

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  KVMGUI Daemon v1.0                         ║\n", .{});
    std.debug.print("║  TCP:   http://0.0.0.0:{d}                 ║\n", .{PORT});
    std.debug.print("║  Unix:  unix://{s}       ║\n", .{unix_path});
    std.debug.print("║  Health: GET /api/health                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    // Spawn thread to accept Unix socket connections
    _ = std.Thread.spawn(std.Thread.SpawnConfig{}, acceptLoop, .{ unix_sock }) catch {};

    while (true) {
        const conn = c.accept(sock, null, null);
        if (conn < 0) continue;
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
        th.detach();
    }
}

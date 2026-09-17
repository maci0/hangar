# AGENTS.md: src (Zig core)

Zig 0.16 source for all three executables (`hangar-web`, `hangar-webui`, `vmrun`)
plus every shared module. Inherits all root rules (no `std.json`, `std.Io`
migration, `use_llvm`/`use_lld`, enum pattern, concurrency); this doc owns the
module map and source-local contracts.

## Purpose
Hold the VM model, persistence, QEMU/QMP control, the HTTP server + remote daemon,
and the leaf utilities they share. No `App` struct: shared state is module-level
globals in `appstate.zig`.

## Ownership
- **Core / router:** `web_server.zig` (router + VM CRUD/lifecycle + renders + main;
  also the remote daemon). `vmrun.zig` (CLI client), `webui_app.zig` (WebView wrapper),
  `transport.zig` (Unix/TCP + HTTP helpers).
- **Model / persistence:** `vm.zig` (`VmConfig`, all config enums, `generateId`/`ensureId`,
  `findUnusedVncPort`), `persist.zig` (hand-rolled JSON; `vms.json`), `vnet.zig`
  (`networks.json`), `appstate.zig` (globals + `vms_mutex` + VMM handles), `catalog.zig`.
- **Hypervisor process control:** `src/hv/` (dispatch table). See its AGENTS.md.
- **QEMU / guest:** `qemu.zig` (arg builders + `forkExec`/`runWait`; never `std.process.spawn`),
  `qmp.zig` (QMP client), `framebuffer.zig`, `vnc_client.zig`.
- **Video pipeline (phases 1-2):** `dbusdisplay.zig`, QMP add_client + hand-rolled D-Bus
  subset attaches on power-on of a `video_stream` VM; assembles scanouts into a
  framebuffer, encodes via an ffmpeg child (qemu.forkExecPiped), serves H.264 access
  units on `/ws/video/<idx>` to the WebCodecs client (docs/VIDEO-PIPELINE.md).
- **Events:** `GET /api/events` (SSE), `appstate.state_version` bumps on every accepted
  POST mutation and unexpected VM exit; `handleEvents` streams change events.
- **HTTP leaf utils:** `httpreq` `httpresp` `ws` `wlog` `netutil` `auth` `urlencode` `form_parsers`.
- **Handler groups:** `snapshots` `migrate` `disk` `cdrom` `guestagent` `streams`
  `wsproxy` `framebuffer` `vmrender`.
- **Frontend assets:** `src/web/`, see its AGENTS.md (served by `web_server`, embedded via `@embedFile`).
- **Leaf helpers:** `sync` `usock` `appio` `fbmath`
  `snapparse` `ovf` `autoprotect` `path_helpers` `hostinfo`
  (host CPU/RAM capacity for the dashboard).
- **Storage paths:** `path_helpers` owns `configDir`, `vmsPath`, and `networksPath`,
  resolving `HANGAR_CONFIG_HOME` with a `HOME` fallback. Persistence modules use
  these helpers without importing application state.

## Local Contracts
- **Runtime listener configuration:** `transport.configPort` owns `KV_PORT` parsing:
  only unset uses 9080; empty, invalid, zero, and overflowing values fail.
  Both daemon and desktop wrapper validate `KV_PORT` and `KV_API_KEY` before
  loading VM state, spawning a backend, or opening a window.
  `vmrun` validates `KV_API_KEY` before connecting. `transport.apiKey` returns
  an error for invalid values; only an unset variable uses the built-in default.
  Neither buffered nor streaming requests send a fallback key for invalid input.
- **CLI stdout:** all three entrypoints use `appio.writeStdout`, which writes the
  complete slice and exits 1 with a stderr diagnostic on failure.
- **VM and virtual-network string capacities are byte limits.** `VmConfig` and
  `VirtualNetwork` setters truncate valid UTF-8 only at scalar boundaries;
  they do not normalize or case-fold. Non-UTF-8 byte
  strings retain byte-prefix behavior for filesystem compatibility. Grapheme
  clusters are not the unit of storage.
- **Persistence JSON strings:** `persist` and `vnet` decode `\b` and `\f` to their
  control bytes, as well as Unicode escapes and UTF-16 surrogate pairs.
- **VM config metadata:** `persist` reads `version`, `theme`, `prefs`, and `vms`
  only from the root object; nested fields and string values cannot select them.
- **Add a `VmConfig` field →** update `VmJson` + `emitVmJson` + `parseVmObject` +
  `fromVmJson` in `persist.zig`, add a round-trip parser test, and emit it in **both**
  `vmrender.zig` renders. Large string fields also need the `parseVmObject` `str_buf`,
  the create/save `val_buf`, and the detail render buffer sized to hold them.
- **`vmrender` 32-arg cap:** `std.fmt.bufPrint` allows ≤32 args per call. The renders
  split into `part1`/`part2a…`; new fields go in a block with spare slots (e.g. a
  closing block), not a full one.
- **Uniform `POST /api/vms/<id>/<action>` →** extend the comptime `post_routes` table
  in `web_server.zig`. **Create/save fields →** extend the `@field` setter tables
  (`applyBoolField`/`applyEnumField`/`applyStrField`), never copy-paste an arm.
- **QEMU CPU selection:** with `.auto` or `.tcg` acceleration, `host` CPU models
  emit `max` so TCG can start; QEMU's `max` uses host features under KVM. Explicit
  hardware acceleration preserves `host`. Stored CPU selections stay unchanged.
  `hyperv_enlightenments` appends `hv_*` properties to the effective model.
- **OVF CPU quantity:** `ovf.Spec` receives cores per socket and socket count;
  the descriptor emits their product with the same 1–1024 per-field bounds as QEMU.
- **AutoProtect persistence:** the ticker saves only after advancing snapshot scheduling
  metadata or to retry its failed save; idle ticks do not rewrite `vms.json`.
- **VNC connection cache:** `VncClient.disconnect` must join the polling thread and
  release cached resources even after peer failure clears `connected`; framebuffer
  polling calls it before reconnecting.
- **New static asset / GET route →** add to `auth.isAuthExempt` only if non-sensitive.
- **HTTP header lookup:** `httpreq.findHeader` and `parseContentLength` stop at the
  CRLFCRLF boundary; body bytes must never supply header values.
- **Logging goes through `wlog`**, never a bare `std.c.write(2, ...)`: one timestamped,
  leveled line per call on `wlog.log_fd`, which defaults to -1 (dropped) in test builds
  so a passing `zig build test` stays silent. Untrusted text (VM names, QEMU/QMP replies,
  argv) passes `wlog.sanitizeLogText` first. Direct fd-2 writes are limited to
  CLI usage/startup messages in `web_server`/`webui_app`, not daemon log lines.
- **Request correlation:** `serveHtml` begins `wlog` context after the first successful
  read, before rejection gates, and clears it on return. `writeHttpResponse` emits
  `X-Request-ID`; handler logs share that ID. Completion logs include status, elapsed
  milliseconds and send success for POSTs, server errors and failed sends, without
  logging successful GET polling.
- **Never** touch `appstate.vms`/`vm_count` without `vms_mutex`; never hold a lock during
  QEMU/QMP/filesystem/network I/O (power-on's brief `portInUse` probe is the one
  bounded exception).

## Work Guidance
- Every function gets a unit test **and** a fuzz test (deterministic fixed-seed PRNG),
  at the bottom of its own `.zig` (thin wrappers: `*_test.zig`).
- Every enum: `fromIndex` round-trip, `toIndex` inverts it, `toStr`, `label`, out-of-range default.
- `qemu.zig` arg tests use `buildScriptStr`/`buildArgs`, never spawn QEMU.

## Verification
Use `zig build test-unit-<module>` for a module registered in `build.zig`
(e.g. `zig build test-unit-vnc_client`). These steps supply the same linker flags,
libraries and imports as `zig build test`, including `libvncclient` and `webui`.
Run the full suite and executable link as required by the root testing rules.

## Child DOX Index
- [hv/AGENTS.md](hv/AGENTS.md): hypervisor process-lifecycle dispatch table (start/stop/reap/clone).
- [web/AGENTS.md](web/AGENTS.md): embedded web UI assets (vanilla JS/CSS/HTML + vendored libs).

# AGENTS.md: Hangar

Lightweight QEMU VM manager with web UI and optional native WebView wrapper.
Zig 0.16.0. No libvirt.

## Build / Run / Test Commands

```bash
zig build web          # Build + launch web backend (HTTP on :9080; also the remote daemon)
zig build webui        # Build + launch native WebView desktop wrapper
zig build test         # Run ALL unit + fuzz tests (hermetic; no network/browser)
zig build web-e2e      # Web UI end-to-end tests (Playwright; needs bun install + chromium)
zig build test-api     # HTTP API integration test (spawns a real daemon)
zig build test-vmrun   # vmrun CLI integration test (spawns a real daemon)
```

`zig build check` runs all executables, formatting, shell/JS lint, the hermetic
unit/fuzz suite, and `zig build test-cli` (help/version and stdout-failure exit
codes for all three binaries, without a daemon). CI runs the build, lint and
unit/fuzz steps; `test-cli` is an additional local check. Integration and browser
tests remain standalone. Fix failing code, never weaken gates or assertions to pass.

Static analysis (blocking CI steps, all scoped to git-tracked files so vendored
code and scratch trees are excluded):

```bash
zig build fmt-check    # zig fmt --check over tracked *.zig/*.zon
zig build lint-shell   # shellcheck over tracked *.sh
zig build lint-js      # bun build over hand-written JS (vendored src/web bundles excluded)
```

`lint-shell` enables `add-default-case`, `avoid-negated-conditions`,
`avoid-nullary-conditions`, `check-extra-masked-returns`, `check-set-e-suppressed`,
`check-unassigned-uppercase`, `deprecate-which`, `quote-safe-variables`, and
`useless-use-of-cat` in addition to ShellCheck's default checks.
`require-double-brackets` and `require-variable-braces` remain off because the
scripts use POSIX test brackets and unbraced variable references.
Static-analysis pipelines propagate file-enumeration failures and preserve filenames
with whitespace. `fmt-check` uses the Zig executable running the build.

All executables (`hangar-web`, `hangar-webui`, `vmrun`) and all test binaries are built with `use_llvm = true, use_lld = true`. The three shipped executables also enable PIE.

CI runs on Ubuntu 24.04 and installs `libvncserver-dev`, `pkg-config`, and
`shellcheck` before building and running the existing lint and unit/fuzz gates.

### Running a single test module

Each test module registered in `build.zig` has a `test-unit-<module>` step,
which reuses the full suite's linker flags, libraries, and module imports:

```bash
zig build test-unit-persist
zig build test-unit-qmp
zig build test-unit-vnc_client
```

Imported tests run too. `test-unit-vmrun` is the unit module; `test-vmrun` remains
the standalone daemon integration suite. `zig build --help` lists all steps.

## Critical Constraints

### No `std.json`
`std.json` pulls in f128 float math that causes linker errors with the system `cc` link step. All JSON is hand-rolled in `persist.zig` (also `qmp.zig`, `vnet.zig`). Never import or use `std.json`.

### Build link step
Tests and the three shipped executables must use `use_llvm = true, use_lld = true`.

### Zig 0.16 `std.Io` migration
Filesystem, process, networking, and threading go through `std.Io`. Never use the removed/emptied APIs:

- FS: `std.Io.Dir.cwd().<op>(appio.io(), ...)`, never `std.fs.cwd()`.
- Unix sockets: `usock.UnixStream` (libc-backed), `std.net` is gone.
- Mutex: `sync.SpinMutex`, `std.Thread.Mutex` is gone.
- Env / sleep / clock: `appio.getenv`, `appio.sleepMs`, `std.c.clock_gettime`.
- Process spawn for QEMU: `qemu.forkExec` / `qemu.runWait` (manual `fork` + `execvp`). These preserve the real environment (`DISPLAY`, `HOME`, `XDG_RUNTIME_DIR`, ...). Never `std.process.spawn`.

### No glib `@cImport`
Zig 0.16's C importer rejects GLib headers (they emit file-scope `_Pragma`). No module links GLib/gio; the SPICE path is a raw TCP relay in `wsproxy.zig` + the vendored browser client. rfb (VNC) headers may be `@cImport`'ed.

## State & Wiring

- There is no `App` struct. All shared state lives as module-level globals in `appstate.zig`:
  - `vms` / `vm_count` / `vms_mutex`, `prefs`, `g_vmm` + `g_vmm_handles`, undo state.
- `web_server.zig` is both the local web UI server and the remote daemon. Remote clients (`vmrun`, `webui_app`) talk to it via `transport.zig` (Unix/TCP + HTTP helpers).
- `web_server.zig` is the router + VM CRUD/lifecycle core; cohesive handler groups and leaf utilities have been carved into their own modules, which `web_server` `@import`s and (for the leaf helpers) aliases so call sites read unchanged:
  - HTTP plumbing (leaf): `httpreq.zig` (request-line/header/route parsers), `httpresp.zig` (status codes + response writer + `isServerErrToken`/`sanitizeHeaderValue`), `wlog.zig` (structured logging), `netutil.zig` (socket constants + `setTcpNoDelay`), `auth.zig` (API-key check, exempt list, host/WS gates).
  - Handler groups: `snapshots.zig`, `migrate.zig`, `disk.zig` (info/compact/resize), `cdrom.zig`, `guestagent.zig`, `streams.zig` (conn-streaming: screenshot/download/upload/exportOva), `wsproxy.zig` (VNC/SPICE/serial relays), `catalog.zig`, `framebuffer.zig`.
  - The uniform `POST /api/vms/<id>/<action>` routes dispatch through a comptime `post_routes` table in `web_server.zig`; create/save form fields apply through `@field`-driven tables (`applyBoolField`/`applyEnumField`/`applyStrField`). Add a new uniform POST route or boolean/enum/string field by extending the table, not by copy-pasting an arm.
- Hypervisor abstraction: the `g_vmm.*Fn` dispatch table (`hv/interface.zig` + `hv/qemu_backend.zig`) covers PROCESS lifecycle only: `start`, `forceStop`, `isAlive`, `reap`, `createLinkedClone`, `deinit`. Guest control (pause/resume/shutdown/reset/cdrom/migrate/screenshot) goes directly to QMP via `web_server.vmQmpByName` (fresh connection, lock released); offline disk/snapshot ops call `qemu.*`/`qemu-img` directly. Extend the dispatch interface only when a real second backend needs more.

## Configuration (environment variables)

`web_server.main` validates `KV_API_KEY` and `KV_PORT` before reading VM state or
autostarting guests. All variables are optional.

| Variable | Default | Effect |
| --- | --- | --- |
| `KV_API_KEY` | `hangar` (built-in) | X-API-Key secret. **Setting it also opts the daemon into binding all interfaces (`::`).** With no key set, the daemon binds **loopback only** (`::ffff:127.0.0.1`, the IPv4-mapped loopback on its dual-stack socket) so the weak default is never reachable off-host. Must be 1–64 printable-ASCII bytes (no spaces or control characters); an invalid value aborts startup. Setting it to the built-in default value (`hangar`) is treated as unset, the daemon stays loopback-only rather than exposing all interfaces behind the known default. |
| `KV_PORT` | `9080` | TCP listen port. Must parse as a non-zero `u16`; otherwise startup aborts. |
| `HANGAR_CONFIG_HOME` | `$HOME` | Base dir for `~/.config/hangar/*` state (see Persistence). |

Never commit a real `KV_API_KEY`. For any non-local deployment, set a strong `KV_API_KEY` (which is also what exposes the daemon beyond loopback).

## Persistence

- VMs: `~/.config/hangar/vms.json` (override via `HANGAR_CONFIG_HOME`).
- Virtual networks: `~/.config/hangar/networks.json` (owned by `vnet.zig`).
- Only configuration is persisted. Runtime state (`status`, `pid`, ...) is never written.
- When adding fields to `VmConfig`, also update `VmJson`, `emitVmJson`, `fromVmJson` / `parseVmObject` in `persist.zig`, and add parser tests. Large string fields (e.g. `cloud_init`, 8 KB) also need the `parseVmObject` `str_buf`, the create/save `val_buf`, and the VM-detail render buffer sized to hold them.

## Testing

- Tests live at the bottom of each module's `.zig` (not in separate files), except for thin wrappers (`appstate_test.zig`, `hv_*_test.zig`).
- Fuzz tests are deterministic PRNG harnesses (fixed seed) and are ordinary `zig build test` entries. They cover parsers, setters, arg builders, and pure helpers.
- Every enum must have tests for: fromIndex round-trip, toIndex inverts fromIndex, toStr values, label values, out-of-range default.
- `qemu.zig` arg-builder tests must use the `buildScriptStr` / `buildArgs` functions, never by spawning QEMU.
- **Confirm source or embedded-asset changes with `zig build` (the exe link), not only a single-module test:** tests may not instantiate code reachable solely through the executable. A missing string in a binary does not prove cache corruption. Check the worktree, build options, and artifact path first; if needed, rebuild with fresh repository-local `--cache-dir` and `--prefix` paths rather than deleting existing caches or outputs.
- The Playwright e2e suite (`tests/e2e/`, config `playwright.config.mjs`) is a **standalone** `zig build web-e2e` step, NOT in the umbrella `test` (which stays hermetic). Playwright launches the built binary on a dedicated port against a temp `$HOME`. Run `bun install --frozen-lockfile` and `bun run e2e:install` (Chromium) once before the first run. The build invokes the repository-local Playwright CLI and fails if it is missing instead of downloading a runner. The shell integration tests `zig build test-api` / `zig build test-vmrun` are likewise standalone (they spawn a real daemon).
- **Every user-facing workflow must have an end-to-end Playwright test.** Any web-UI flow (VM create/clone/delete/rename, power on/off, snapshots, settings save, import/export, log viewer, console, vnet editor, preferences) needs a Playwright e2e test that drives the real built binary (temp port + temp `$HOME`, same as the smoke harness) and asserts the observable result. Add or extend the e2e test alongside the feature, never after. A new workflow without a Playwright e2e test is incomplete.

## Code Style & Conventions

- `//!` module doc at the top of every `.zig`; `///` docs on public functions (1-3 lines).
- Imports: `std` first, then local files as string literals (`@import("vm.zig")`).
- Enums follow the exact `vm.zig` pattern (see `DiskFormat`, `GuestOs`, etc.):
  - `count`, `toIndex`, `fromIndex` (safe default), `toStr` (QEMU CLI value), `label` (UI).
- Naming: `PascalCase` types, `camelCase` functions, `SCREAMING_SNAKE` hard limits, `snake_case` for enum variants and source lists.
- Fixed-size buffers for VM data (`name_buf`, `disk_path_buf`); C interop uses `[*:0]const u8`; internal slices are `[]const u8`.
- UI terminology follows VMware Workstation conventions:
  - "Power On" / "Power Off", "Suspend" / "Resume", "Shut Down Guest", "Take Snapshot" / "Revert to Snapshot", "VM Library", "Settings".
- Config enums are stored in JSON as their `toStr` values (e.g. `"qcow2"`, `"gtk"`, `"user"`).

## Zig Idioms & Rules

Target **Zig 0.16.0**. Never write code that assumes older `std.fs`, `std.net`, `std.posix`, or `std.Thread` APIs. See the `std.Io` migration constraint above for the required replacements.

### Builtins & comptime
- Reach for builtins/comptime where natural: `@typeInfo`, `@TypeOf`, `@intCast`, `@enumFromInt`, `@intFromEnum`, `@memcpy`, `@memset`, `@atomicLoad`, `@atomicStore`.
- There is **no** `@builtin`. Platform/build info comes from `const builtin = @import("builtin");`.

### Avoid low-level OS work
- No direct syscalls; no new `fork`/`exec` code.
- Avoid `std.os`, `std.posix`, and raw libc unless there is no Zig 0.16 API.
- Keep existing low-level code behind the local wrappers (`usock`, `appio`, `qemu`).
- Process spawning: use `std.process` only where Zig 0.16 environment handling is safe. Keep QEMU/`qemu-img` on the existing `qemu.forkExec`/`runWait` wrapper until the env-stripping issue is proven fixed with tests.

### Structured stdlib helpers
- `std.mem` for slicing/search/copying.
- `std.fmt.bufPrint` / `bufPrintZ` for fixed buffers.
- `std.testing` helpers in tests.
- `std.heap` allocators only when fixed buffers are not enough.

### Ownership
- Functions that allocate must document who frees.
- Prefer caller-provided buffers for hot paths and config serialization.
- Use `defer` / `errdefer` consistently.

### Slices over raw pointers
- Use `[]const u8` / `[]u8` for internal Zig logic.
- Reserve `[*:0]const u8` for C/QEMU interop boundaries.
- Convert with `std.mem.span()` only at boundaries.

### Errors
- Return `!T` / `!void`.
- `catch return` for non-critical failure paths.
- Avoid silent `catch {}` except known acceptable best-effort persistence cases.

### Concurrency
- Use `sync.SpinMutex` (per project rule); atomics for cross-thread scalar flags.
- Never touch `appstate.vms` / `vm_count` without `vms_mutex`.
- Do not hold locks during QEMU/QMP/filesystem/network I/O.

### build.zig
- Keep link/backend choices explicit (`use_llvm`/`use_lld`, see constraint above).
- Avoid global-machine assumptions; prefer project-local cache/config for reproducible test runs.

## References

- `CLAUDE.md` is a symlink to this file.
- Longer design notes (if needed) are in `docs/`.
- Consumer release notes and upgrade steps are in `README.md` under "Release notes and upgrades".

# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

## Child DOX Index

- [src/AGENTS.md](src/AGENTS.md): Zig core: VM model, persistence, QEMU/QMP, HTTP server +
  remote daemon, leaf utils, the module map and source-local contracts. Children:
  - [src/hv/AGENTS.md](src/hv/AGENTS.md): hypervisor process-lifecycle dispatch table.
  - [src/web/AGENTS.md](src/web/AGENTS.md): embedded vanilla-JS web UI + vendored libs.
- [tests/AGENTS.md](tests/AGENTS.md): standalone integration/e2e suites (Playwright,
  shell API/vmrun) that drive the built binary; distinct from the in-module unit/fuzz tests.

Owned by the parent (no child doc): `docs/` (design notes, DESIGN/PRD/GAP-ANALYSIS/
TEST-COVERAGE/WEB-UI-CUJS/TODO/VIDEO-PIPELINE; reference material, not contracts), `reference/`
(read-only external material: VMware WS7), `zig-pkg/` (vendored Zig deps, do not edit),
and the root build files (`build.zig`, `build.zig.zon`, `package.json`, `playwright.config.mjs`).

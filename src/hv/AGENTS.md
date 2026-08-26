# AGENTS.md: src/hv (hypervisor abstraction)

## Purpose
The pluggable hypervisor layer: a dispatch table for VM **process lifecycle only**.
Lets a second backend slot in without touching `web_server`.

## Ownership
- `interface.zig`, the `g_vmm.*Fn` dispatch table type + the handle abstraction
  (`g_vmm` / `g_vmm_handles` live in `appstate.zig`).
- `qemu_backend.zig`, the only implementation: forks/execs QEMU via `qemu.zig`.
- Tests: `../hv_interface_test.zig`, `../hv_qemu_backend_test.zig`.

## Local Contracts
- The interface covers **process lifecycle only**: `start`, `forceStop`, `isAlive`,
  `reap`, `createLinkedClone`, `deinit`.
- **Everything else does NOT go through this table:**
  - Guest control (pause/resume/shutdown/reset/cdrom/migrate/screenshot) → QMP directly
    via `web_server.vmQmpByName` (fresh connection, lock released).
  - Offline disk/snapshot ops → `qemu.*` / `qemu-img` directly.
- Extend the dispatch interface **only when a real second backend needs more**, do not
  widen it speculatively. There is no libvirt.

## Verification
Covered by `zig build test` (the `hv_*_test.zig` wrappers) and the exe link.

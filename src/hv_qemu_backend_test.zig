// SPDX-License-Identifier: MIT
//! Test runner for hv/qemu_backend.zig.
//!
//! Zig 0.16 restricts relative imports to within the module root
//! (the directory of the root source file). When hv/qemu_backend.zig
//! is the root, its `../qemu.zig` imports are forbidden because the
//! module root is src/hv/. Placing this wrapper at src/ makes the
//! module root src/, so `../` imports from hv/ resolve correctly.

comptime {
    _ = @import("hv/qemu_backend.zig");
}

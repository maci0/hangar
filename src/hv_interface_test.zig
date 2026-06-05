// SPDX-License-Identifier: MIT
//! Test runner for hv/interface.zig.
//!
//! When hv/interface.zig is compiled with its own directory as module root,
//! its `@import("../vm.zig")` is outside the module path.  Placing this
//! wrapper at src/ makes the module root src/, so `../vm.zig` from hv/
//! resolves to src/vm.zig correctly.

comptime {
    _ = @import("hv/interface.zig");
}

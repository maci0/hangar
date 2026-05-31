//! Headless GUI-callback fuzz harness (run under Xvfb via `zig build cbfuzz`).
//!
//! Imports main.zig (whose callbacks are otherwise private and unreachable by
//! `zig test`, which can't link IUP) and calls `main.fuzzCallbacks`, which
//! invokes the menu/toolbar/list/timer/theme callbacks with randomized
//! arguments and no VM selected — so they exercise their real logic without
//! popping the modal dialogs that would deadlock a headless loop. Any crash,
//! panic, or non-zero exit fails the test.
//!
//! main.zig provides the `app*` export symbols its dialogs need, so this binary
//! supplies no shims. main.zig's own `pub fn main` is just a namespaced function
//! here (this file is the program entry), so there is no entry-point collision.

const std = @import("std");

const iup = @cImport({
    @cInclude("iup.h");
});

const app_main = @import("main.zig");

pub fn main() void {
    if (iup.IupOpen(null, null) == iup.IUP_ERROR) {
        std.debug.print("cbfuzz: IupOpen failed\n", .{});
        std.process.exit(2);
    }
    defer iup.IupClose();

    // `cbfuzz modals` fuzzes the unconditionally-modal callbacks (driven by an
    // external Escape injector in tests/fuzz_modals.sh); default fuzzes the
    // ~26 non-modal callbacks directly.
    // Mode via env var (libc getenv) — argv is unreliable in this cc-linked
    // binary (no Zig _start to capture it). CBFUZZ_MODE=modals → modal fuzz.
    const mode = std.c.getenv("CBFUZZ_MODE");
    const modal_mode = mode != null and std.mem.eql(u8, std.mem.span(mode.?), "modals");

    if (modal_mode) {
        app_main.fuzzModalCallbacks(60);
        std.debug.print("cbfuzz modals OK\n", .{});
    } else {
        app_main.fuzzCallbacks(0xCB_F00D_42);
        std.debug.print("cbfuzz OK\n", .{});
    }
}

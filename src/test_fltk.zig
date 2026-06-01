// SPDX-License-Identifier: MIT
//! Direct @cImport of cfltk — FLTK toolchain verified.
const cfltk = @cImport({
    @cInclude("cfltk/cfl.h");
    @cInclude("cfltk/cfl_window.h");
    @cInclude("cfltk/cfl_button.h");
});

pub fn main() void {
    const win = cfltk.Cfl_window_new(400, 300, "KVMGUI FLTK");
    defer cfltk.Cfl_window_delete(win);

    _ = cfltk.Cfl_button_new(150, 130, 100, 40, "Hello FLTK!");

    cfltk.Cfl_window_end(win);
    cfltk.Cfl_window_show(win);
    _ = cfltk.Fl_run();
}

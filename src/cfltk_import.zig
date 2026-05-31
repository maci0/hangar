//! Single @cImport of cfltk shared by all modules.
//!
//! Every FLTK widget pointer must flow through THIS file's types, otherwise
//! each @cImport produces incompatible opaque types.

pub const c = @cImport({
    @cInclude("cfltk/cfl.h");
    @cInclude("cfltk/cfl_window.h");
    @cInclude("cfltk/cfl_button.h");
    @cInclude("cfltk/cfl_box.h");
    @cInclude("cfltk/cfl_group.h");
    @cInclude("cfltk/cfl_menu.h");
    @cInclude("cfltk/cfl_input.h");
    @cInclude("cfltk/cfl_browser.h");
    @cInclude("cfltk/cfl_text.h");
    @cInclude("cfltk/cfl_misc.h");
    @cInclude("cfltk/cfl_image.h");
    @cInclude("cfltk/cfl_draw.h");
    @cInclude("cfltk/cfl_dialog.h");
});

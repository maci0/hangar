// SPDX-License-Identifier: MIT
//! OpenGL-accelerated framebuffer display for the FLTK frontend.
//!
//! Uses an Fl_Gl_Window with GL 2.1+ shaders to upload BGRA pixel data
//! as a texture and render it with BGRA→RGBA swizzle on the GPU.
//! Falls back to the software Fl_RGB_Image path if GL is unavailable.

const std = @import("std");
const app = @import("appstate.zig");
const cfltk = @import("cfltk_import.zig").c;

const gl = @cImport({
    @cInclude("GL/gl.h");
});

// GL 2.0+ functions and constants not in <GL/gl.h> — declared manually.
// Functions: file-scope externs (NOT in the `gl` @cImport struct).
extern fn glCreateShader(typ: gl.GLenum) gl.GLuint;
extern fn glShaderSource(shader: gl.GLuint, count: gl.GLsizei, string: [*c]const [*c]const u8, length: [*c]const gl.GLint) void;
extern fn glCompileShader(shader: gl.GLuint) void;
extern fn glGetShaderiv(shader: gl.GLuint, pname: gl.GLenum, params: [*c]gl.GLint) void;
extern fn glDeleteShader(shader: gl.GLuint) void;
extern fn glCreateProgram() gl.GLuint;
extern fn glAttachShader(program: gl.GLuint, shader: gl.GLuint) void;
extern fn glLinkProgram(program: gl.GLuint) void;
extern fn glGetProgramiv(program: gl.GLuint, pname: gl.GLenum, params: [*c]gl.GLint) void;
extern fn glDeleteProgram(program: gl.GLuint) void;
extern fn glUseProgram(program: gl.GLuint) void;
extern fn glGetAttribLocation(program: gl.GLuint, name: [*c]const u8) gl.GLint;
extern fn glGenBuffers(n: gl.GLsizei, buffers: [*c]gl.GLuint) void;
extern fn glBindBuffer(target: gl.GLenum, buffer: gl.GLuint) void;
extern fn glBufferData(target: gl.GLenum, size: isize, data: ?*const anyopaque, usage: gl.GLenum) void;
extern fn glDeleteBuffers(n: gl.GLsizei, buffers: [*c]const gl.GLuint) void;
extern fn glEnableVertexAttribArray(index: gl.GLuint) void;
extern fn glVertexAttribPointer(index: gl.GLuint, size: gl.GLint, typ: gl.GLenum, normalized: gl.GLboolean, stride: gl.GLsizei, pointer: ?*const anyopaque) void;
extern fn glDisableVertexAttribArray(index: gl.GLuint) void;
extern fn glGenTextures(n: gl.GLsizei, textures: [*c]gl.GLuint) void;
extern fn glDeleteTextures(n: gl.GLsizei, textures: [*c]const gl.GLuint) void;
extern fn glActiveTexture(texture: gl.GLenum) void;
extern fn glGetShaderInfoLog(shader: gl.GLuint, bufSize: gl.GLsizei, length: [*c]gl.GLsizei, infoLog: [*c]u8) void;
extern fn glGetProgramInfoLog(program: gl.GLuint, bufSize: gl.GLsizei, length: [*c]gl.GLsizei, infoLog: [*c]u8) void;

// GL 2.0+ constants — not in <GL/gl.h> headers that aro can parse.
const GL_VERTEX_SHADER: gl.GLenum = 0x8B31;
const GL_FRAGMENT_SHADER: gl.GLenum = 0x8B30;
const GL_COMPILE_STATUS: gl.GLenum = 0x8B81;
const GL_LINK_STATUS: gl.GLenum = 0x8B82;
const GL_RGBA8: gl.GLint = 0x8058;
const GL_BGRA: gl.GLenum = 0x80E1;
const GL_ARRAY_BUFFER: gl.GLenum = 0x8892;
const GL_STATIC_DRAW: gl.GLenum = 0x88E4;

// ── GL shader sources ──────────────────────────────────────────────

const vertex_src: [*c]const u8 =
    \\#version 120
    \\attribute vec2 aPos;
    \\attribute vec2 aUV;
    \\varying vec2 vUV;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vUV = aUV;
    \\}
;

const frag_src: [*c]const u8 =
    \\#version 120
    \\varying vec2 vUV;
    \\uniform sampler2D uTex;
    \\void main() {
    \\    vec4 c = texture2D(uTex, vUV);
    \\    gl_FragColor = c.bgra; // BGRA input → RGBA output
    \\}
;

// ── Static GL state ────────────────────────────────────────────────

var gl_initialized: bool = false;
var gl_program: gl.GLuint = 0;
var gl_texture: gl.GLuint = 0;
var gl_vbo: gl.GLuint = 0;
var gl_tex_w: gl.GLint = 0;
var gl_tex_h: gl.GLint = 0;

// ── Quad geometry: two triangles as triangle-strip ─────────────────
//  pos.xy  |  uv
// (-1, 1)  | (0, 0)
// ( 1, 1)  | (1, 0)
// (-1,-1)  | (0, 1)
// ( 1,-1)  | (1, 1)
const quad_verts = [16]gl.GLfloat{
    -1.0, 1.0, 0.0, 0.0,
    1.0, 1.0, 1.0, 0.0,
    -1.0, -1.0, 0.0, 1.0,
    1.0, -1.0, 1.0, 1.0,
};

/// Compile a GL shader from source. Returns 0 on failure.
fn compileShader(kind: gl.GLenum, src: [*c]const u8) gl.GLuint {
    const s = glCreateShader(kind);
    glShaderSource(s, 1, @constCast(&src), @ptrFromInt(0));
    glCompileShader(s);
    var ok: gl.GLint = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [512]u8 = undefined;
        glGetShaderInfoLog(s, log_buf.len, null, &log_buf);
        const kind_str: [*:0]const u8 = if (kind == GL_VERTEX_SHADER) "vertex" else "fragment";
        std.debug.print("[hangar] GL {s} shader compile failed: {s}\n", .{ kind_str, &log_buf });
        return 0;
    }
    return s;
}

/// One-time GL resource init. Call with the GL context current.
fn initGL() bool {
    if (gl_initialized) return gl_program != 0;
    gl_initialized = true;

    const vs = compileShader(GL_VERTEX_SHADER, vertex_src);
    if (vs == 0) return false;
    defer glDeleteShader(vs);

    const fs = compileShader(GL_FRAGMENT_SHADER, frag_src);
    if (fs == 0) return false;
    defer glDeleteShader(fs);

    const prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    var ok: gl.GLint = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [512]u8 = undefined;
        glGetProgramInfoLog(prog, log_buf.len, null, &log_buf);
        std.debug.print("[hangar] GL program link failed: {s}\n", .{&log_buf});
        glDeleteProgram(prog);
        return false;
    }
    gl_program = prog;

    // Texture
    glGenTextures(1, &gl_texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, gl_texture);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    // VBO
    glGenBuffers(1, &gl_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, gl_vbo);
    glBufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, GL_STATIC_DRAW);

    return true;
}

/// Render a BGRA framebuffer to the GL window.
/// Call only from the Fl_Gl_Window draw callback or when the context is current.
/// `fb` must be at least 4-byte aligned (BGRA pixel data).
pub fn renderGL(fb: [*]const u8, fw: c_int, fh: c_int) void {
    if (app.gl_display == null) return;
    if (fw <= 0 or fh <= 0) return;

    // BGRA pixel data requires 4-byte alignment for glTexImage2D.
    if (@intFromPtr(fb) & 3 != 0) return;

    if (!initGL()) return;

    _ = cfltk.Fl_Gl_Window_make_current(app.gl_display);
    if (cfltk.Fl_Gl_Window_context_valid(app.gl_display) == 0) return;

    const w: gl.GLsizei = @intCast(fw);
    const h: gl.GLsizei = @intCast(fh);

    // Upload BGRA pixels as RGBA texture (GL will treat BGRA as RGBA,
    // then our shader swizzles `.bgra` → correct RGBA output).
    gl.glBindTexture(gl.GL_TEXTURE_2D, gl_texture);
    if (w != gl_tex_w or h != gl_tex_h) {
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_BGRA, gl.GL_UNSIGNED_BYTE, @ptrCast(@alignCast(fb)));
        gl_tex_w = w;
        gl_tex_h = h;
    } else {
        gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, w, h, GL_BGRA, gl.GL_UNSIGNED_BYTE, @ptrCast(@alignCast(fb)));
    }

    // Render
    glUseProgram(gl_program);
    glBindBuffer(GL_ARRAY_BUFFER, gl_vbo);

    const pos_loc = glGetAttribLocation(gl_program, "aPos");
    const uv_loc = glGetAttribLocation(gl_program, "aUV");
    if (pos_loc < 0 or uv_loc < 0) return;
    glEnableVertexAttribArray(@intCast(pos_loc));
    glVertexAttribPointer(@intCast(pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, 16, @ptrFromInt(0));
    glEnableVertexAttribArray(@intCast(uv_loc));
    glVertexAttribPointer(@intCast(uv_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, 16, @ptrFromInt(8));

    gl.glViewport(0, 0, w, h);
    gl.glClearColor(0.0, 0.0, 0.0, 1.0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);

    cfltk.Fl_Gl_Window_swap_buffers(app.gl_display);
}

/// Free GL resources on shutdown.
pub fn cleanupGL() void {
    if (gl_program != 0) { glDeleteProgram(gl_program); gl_program = 0; }
    if (gl_texture != 0) { glDeleteTextures(1, &gl_texture); gl_texture = 0; }
    if (gl_vbo != 0) { glDeleteBuffers(1, &gl_vbo); gl_vbo = 0; }
    gl_tex_w = 0; gl_tex_h = 0;
}

/// Show the GL window and hide the software display box.
pub fn showGL() void {
    if (app.gl_display) |glw| {
        cfltk.Fl_Gl_Window_show(glw);
        if (app.display_box) |db| {
            cfltk.Fl_Box_set_label(db, "");
        }
    }
}

/// Hide the GL window, show the placeholder box.
pub fn hideGL() void {
    if (app.gl_display) |glw| {
        cfltk.Fl_Gl_Window_hide(glw);
    }
    if (app.display_box) |db| {
        cfltk.Fl_Box_set_label(db, "VNC/SPICE display renders here when a VM is running.");
        cfltk.Fl_Box_redraw(db);
    }
}

/// GL window draw callback — delegates to the framebuffer render.
fn glDrawCB(_: ?*anyopaque) callconv(.c) void {
    // The framebuffer timer calls renderGL directly;
    // draw is mostly a no-op — just ensure the GL window is valid.
    _ = cfltk.Fl_Gl_Window_make_current(app.gl_display);
    const w = cfltk.Fl_Gl_Window_pixel_w(app.gl_display);
    const h = cfltk.Fl_Gl_Window_pixel_h(app.gl_display);
    if (w > 0 and h > 0) {
        gl.glViewport(0, 0, w, h);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        cfltk.Fl_Gl_Window_swap_buffers(app.gl_display);
    }
}

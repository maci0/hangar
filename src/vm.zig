// SPDX-License-Identifier: MIT
//! Virtual Machine configuration data model.
//!
//! Defines all types needed to describe a QEMU virtual machine's hardware
//! settings and runtime state.  Every enum provides a symmetric API surface:
//!
//!   - `count`     — comptime-derived variant count (always in sync)
//!   - `toIndex`   — convert to `usize` for combobox index / serialisation
//!   - `fromIndex` — convert from `usize`, with a safe default for out-of-range
//!   - `toStr`     — QEMU command-line value (where applicable)
//!   - `label`     — human-readable UI label

const std = @import("std");
const builtin = @import("builtin");

/// Maximum number of VMs that can be managed (single source of truth).
pub const MAX_VMS: usize = 64;

/// Maximum length of a VM name (bytes, not including sentinel).
pub const MAX_NAME: usize = 255;

/// Maximum length of a file-system path (bytes, not including sentinel).
pub const MAX_PATH: usize = 4095;

// ── Disk Format ──────────────────────────────────────────────────────

/// Supported virtual disk image formats.
pub const DiskFormat = enum(u8) {
    qcow2 = 0,
    raw = 1,
    vmdk = 2,
    vdi = 3,

    /// Number of variants — comptime-derived, always in sync.
    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    /// Convert to a combobox / serialisation index.
    pub fn toIndex(self: DiskFormat) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `DiskFormat`.  Out-of-range defaults to `.qcow2`.
    pub fn fromIndex(i: usize) DiskFormat {
        if (i >= count) return .qcow2;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU-compatible format string (e.g. passed to `-drive format=`).
    pub fn toStr(self: DiskFormat) [*:0]const u8 {
        return switch (self) {
            .qcow2 => "qcow2",
            .raw => "raw",
            .vmdk => "vmdk",
            .vdi => "vdi",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: DiskFormat) [*:0]const u8 {
        return switch (self) {
            .qcow2 => "QCOW2",
            .raw => "Raw",
            .vmdk => "VMDK",
            .vdi => "VDI",
        };
    }

    /// Parse a DiskFormat from its toStr representation.
    pub fn fromStr(s: []const u8) DiskFormat {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: DiskFormat = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .qcow2;
    }

    /// Detect disk format from a file extension (case-insensitive).
    /// "img" maps to raw; unrecognized extensions default to qcow2.
    pub fn fromExtension(path: []const u8) DiskFormat {
        const dot = std.mem.lastIndexOfScalar(u8, path, '.');
        const ext = if (dot) |d| path[d + 1 ..] else "";
        if (std.ascii.eqlIgnoreCase(ext, "qcow2")) return .qcow2;
        if (std.ascii.eqlIgnoreCase(ext, "vmdk")) return .vmdk;
        if (std.ascii.eqlIgnoreCase(ext, "vdi")) return .vdi;
        if (std.ascii.eqlIgnoreCase(ext, "raw") or std.ascii.eqlIgnoreCase(ext, "img")) return .raw;
        return .qcow2;
    }
};

// ── Disk Cache Mode ──────────────────────────────────────────────────

/// QEMU cache mode for virtual disk drives (-drive cache=...).
pub const DiskCache = enum(u8) {
    writeback = 0,
    writethrough = 1,
    none = 2,
    directsync = 3,
    unsafe = 4,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: DiskCache) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) DiskCache {
        if (i >= count) return .writeback;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU `-drive cache=` value.
    pub fn toStr(self: DiskCache) [*:0]const u8 {
        return switch (self) {
            .writeback => "writeback",
            .writethrough => "writethrough",
            .none => "none",
            .directsync => "directsync",
            .unsafe => "unsafe",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: DiskCache) [*:0]const u8 {
        return switch (self) {
            .writeback => "Writeback",
            .writethrough => "Writethrough",
            .none => "None",
            .directsync => "Direct Sync",
            .unsafe => "Unsafe",
        };
    }

    /// Parse a QEMU cache string (e.g. from JSON), case-insensitive.
    pub fn fromStr(s: []const u8) DiskCache {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: DiskCache = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .writeback;
    }
};

// ── Network Mode ─────────────────────────────────────────────────────

/// Network backend modes supported by the QEMU command builder.
pub const NetworkMode = enum(u8) {
    user = 0,
    bridge = 1,
    none = 2,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: NetworkMode) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `NetworkMode`.  Out-of-range defaults to `.user`.
    pub fn fromIndex(i: usize) NetworkMode {
        if (i >= count) return .user;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU netdev type string.
    pub fn toStr(self: NetworkMode) [*:0]const u8 {
        return switch (self) {
            .user => "user",
            .bridge => "bridge",
            .none => "none",
        };
    }

    /// Human-readable label for the UI detail panel.
    pub fn label(self: NetworkMode) [*:0]const u8 {
        return switch (self) {
            .user => "NAT (User mode)",
            .bridge => "Bridged",
            .none => "None",
        };
    }

    pub fn fromStr(s: []const u8) NetworkMode {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: NetworkMode = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .user;
    }
};

/// Maximum number of NICs per VM.  QEMU can support more, but this is a
/// reasonable upper bound for any guest OS; no hypervisor-enforced limit.
pub const MAX_NICS: usize = 8;

/// A single virtual network adapter (persisted).
pub const Nic = struct {
    mode: NetworkMode = .none,
    mac_buf: [18]u8 = [_]u8{0} ** 18,
    mac_len: u16 = 0,
};

/// Maximum number of extra (non-primary) disk images.
pub const MAX_EXTRA_DISKS: usize = 4;

/// An extra disk image attached to a VM (persisted).
pub const ExtraDisk = struct {
    path_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    path_len: u16 = 0,
    size_gb: u32 = 0,
    format: DiskFormat = .qcow2,
};

// ── Display Resolution ───────────────────────────────────────────────

/// Standard display resolutions for the VM framebuffer.
pub const DisplayResolution = enum(u8) {
    auto = 0,
    res_800x600 = 1,
    res_1024x768 = 2,
    res_1280x800 = 3,
    res_1920x1080 = 4,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: DisplayResolution) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) DisplayResolution {
        if (i >= count) return .auto;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the serialisation-friendly resolution string (e.g. "auto", "800x600").
    pub fn toStr(self: DisplayResolution) [*:0]const u8 {
        return switch (self) {
            .auto => "auto",
            .res_800x600 => "800x600",
            .res_1024x768 => "1024x768",
            .res_1280x800 => "1280x800",
            .res_1920x1080 => "1920x1080",
        };
    }

    /// Returns a descriptive label for the UI.
    pub fn label(self: DisplayResolution) [*:0]const u8 {
        return switch (self) {
            .auto => "Auto",
            .res_800x600 => "800x600",
            .res_1024x768 => "1024x768",
            .res_1280x800 => "1280x800",
            .res_1920x1080 => "1920x1080",
        };
    }

    /// Returns the QEMU `xres` value, or 0 if auto.
    pub fn xres(self: DisplayResolution) u32 {
        return switch (self) {
            .auto => 0,
            .res_800x600 => 800,
            .res_1024x768 => 1024,
            .res_1280x800 => 1280,
            .res_1920x1080 => 1920,
        };
    }

    /// Returns the QEMU `yres` value, or 0 if auto.
    pub fn yres(self: DisplayResolution) u32 {
        return switch (self) {
            .auto => 0,
            .res_800x600 => 600,
            .res_1024x768 => 768,
            .res_1280x800 => 800,
            .res_1920x1080 => 1080,
        };
    }

    /// Parse a DisplayResolution from its toStr representation.
    pub fn fromStr(s: []const u8) DisplayResolution {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: DisplayResolution = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .auto;
    }
};

// ── Display Type ─────────────────────────────────────────────────────

/// QEMU display backends.
pub const DisplayType = enum(u8) {
    gtk = 0,
    sdl = 1,
    spice = 2,
    vnc = 3,
    none = 4,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: DisplayType) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `DisplayType`.  Out-of-range defaults to `.gtk`.
    pub fn fromIndex(i: usize) DisplayType {
        if (i >= count) return .gtk;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU `-display` argument value.
    pub fn toStr(self: DisplayType) [*:0]const u8 {
        return switch (self) {
            .gtk => "gtk",
            .sdl => "sdl",
            .spice => "spice-app",
            .vnc => "vnc",
            .none => "none",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: DisplayType) [*:0]const u8 {
        return switch (self) {
            .gtk => "GTK",
            .sdl => "SDL",
            .spice => "SPICE",
            .vnc => "VNC",
            .none => "None (headless)",
        };
    }

    /// Parse a DisplayType from its toStr representation.
    pub fn fromStr(s: []const u8) DisplayType {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: DisplayType = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        // Backward compatibility: old JSON files may have "spice" instead of "spice-app".
        if (std.ascii.eqlIgnoreCase(s, "spice")) return .spice;
        return .gtk;
    }
};

// ── VM Status ────────────────────────────────────────────────────────

/// Runtime lifecycle state of a virtual machine.
pub const VmStatus = enum(u8) {
    stopped = 0,
    running = 1,
    paused = 2,
    suspended = 3,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    /// Convert to a serialisation / iteration index.
    pub fn toIndex(self: VmStatus) usize {
        return @intFromEnum(self);
    }

    /// Maps an index to a `VmStatus`.  Out-of-range defaults to `.stopped`.
    pub fn fromIndex(i: usize) VmStatus {
        if (i >= count) return .stopped;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    pub fn toStr(self: VmStatus) [*:0]const u8 {
        return switch (self) {
            .stopped => "stopped",
            .running => "running",
            .paused => "paused",
            .suspended => "suspended",
        };
    }

    /// Human-readable status label (VMware Workstation style).
    pub fn label(self: VmStatus) [*:0]const u8 {
        return switch (self) {
            .stopped => "Powered Off",
            .running => "Powered On",
            .paused => "Paused",
            .suspended => "Suspended",
        };
    }

    /// Parse a VmStatus from its toStr representation.
    pub fn fromStr(s: []const u8) VmStatus {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: VmStatus = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .stopped;
    }
};

// ── Guest OS Type ────────────────────────────────────────────────────

/// Guest operating system type — used for display in the Summary tab
/// and potentially for future OS-specific QEMU tuning.
pub const GuestOs = enum(u8) {
    linux = 0,
    windows = 1,
    freebsd = 2,
    macos = 3,
    other = 4,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: GuestOs) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `GuestOs`.  Out-of-range defaults to `.other`.
    pub fn fromIndex(i: usize) GuestOs {
        if (i >= count) return .other;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Parse a GuestOs from its toStr representation (case-insensitive exact match).
    pub fn fromStr(s: []const u8) GuestOs {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: GuestOs = @enumFromInt(f.value);
            const str = std.mem.span(variant.toStr());
            if (std.ascii.eqlIgnoreCase(s, str)) return variant;
        }
        return .linux;
    }

    /// Returns a serialisation-friendly string.
    pub fn toStr(self: GuestOs) [*:0]const u8 {
        return switch (self) {
            .linux => "linux",
            .windows => "windows",
            .freebsd => "freebsd",
            .macos => "macos",
            .other => "other",
        };
    }

    /// Human-readable label for the UI (VMware Workstation style).
    pub fn label(self: GuestOs) [*:0]const u8 {
        return switch (self) {
            .linux => "Linux",
            .windows => "Microsoft Windows",
            .freebsd => "FreeBSD",
            .macos => "Apple macOS",
            .other => "Other",
        };
    }
};

// ── Boot Order ───────────────────────────────────────────────────────

/// Boot device priority order for the VM.
pub const BootOrder = enum(u8) {
    disk_first = 0,
    cdrom_first = 1,
    network_first = 2,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: BootOrder) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `BootOrder`.  Out-of-range defaults to `.disk_first`.
    pub fn fromIndex(i: usize) BootOrder {
        if (i >= count) return .disk_first;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU `-boot order=` value.
    pub fn toStr(self: BootOrder) [*:0]const u8 {
        return switch (self) {
            .disk_first => "cdn",
            .cdrom_first => "dcn",
            .network_first => "ncd",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: BootOrder) [*:0]const u8 {
        return switch (self) {
            .disk_first => "Hard Disk",
            .cdrom_first => "CD/DVD",
            .network_first => "Network (PXE)",
        };
    }

    /// Parse a BootOrder from its toStr representation.
    pub fn fromStr(s: []const u8) BootOrder {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: BootOrder = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .disk_first;
    }
};

// ── CPU Model ────────────────────────────────────────────────────────

/// CPU model exposed to the guest. "host" passes through the host CPU
/// (best for KVM); "max" enables all features QEMU knows about (best for TCG).
pub const CpuModel = enum(u8) {
    host = 0,
    max = 1,
    qemu64 = 2,
    kvm64 = 3,
    EPYC = 4,
    EPYC_Rome = 5,
    EPYC_Milan = 6,
    Skylake_Server = 7,
    Skylake_Client = 8,
    Icelake_Server = 9,
    Cascadelake_Server = 10,
    Nehalem = 11,
    Westmere = 12,
    SandyBridge = 13,
    IvyBridge = 14,
    Haswell = 15,
    Broadwell = 16,
    Opteron_G5 = 17,
    host_passthrough = 18,
    Cooperlake = 19,
    SapphireRapids = 20,
    GraniteRapids = 21,
    Neoverse_N1 = 22,
    Neoverse_N2 = 23,
    Neoverse_V1 = 24,
    aarch64 = 25,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: CpuModel) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) CpuModel {
        if (i >= count) return .host;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    pub fn toStr(self: CpuModel) [*:0]const u8 {
        return switch (self) {
            .host => "host",
            .max => "max",
            .qemu64 => "qemu64",
            .kvm64 => "kvm64",
            .EPYC => "EPYC",
            .EPYC_Rome => "EPYC-Rome",
            .EPYC_Milan => "EPYC-Milan",
            .Skylake_Server => "Skylake-Server",
            .Skylake_Client => "Skylake-Client",
            .Icelake_Server => "Icelake-Server",
            .Cascadelake_Server => "Cascadelake-Server",
            .Nehalem => "Nehalem",
            .Westmere => "Westmere",
            .SandyBridge => "SandyBridge",
            .IvyBridge => "IvyBridge",
            .Haswell => "Haswell",
            .Broadwell => "Broadwell",
            .Opteron_G5 => "Opteron_G5",
            .host_passthrough => "host-passthrough",
            .Cooperlake => "Cooperlake",
            .SapphireRapids => "SapphireRapids",
            .GraniteRapids => "GraniteRapids",
            .Neoverse_N1 => "Neoverse-N1",
            .Neoverse_N2 => "Neoverse-N2",
            .Neoverse_V1 => "Neoverse-V1",
            .aarch64 => "aarch64",
        };
    }

    pub fn label(self: CpuModel) [*:0]const u8 {
        return switch (self) {
            .host => "Host (default)",
            .max => "Max (all features)",
            .qemu64 => "QEMU 64-bit",
            .kvm64 => "KVM 64-bit",
            .EPYC => "AMD EPYC",
            .EPYC_Rome => "AMD EPYC Rome",
            .EPYC_Milan => "AMD EPYC Milan",
            .Skylake_Server => "Intel Skylake Server",
            .Skylake_Client => "Intel Skylake Client",
            .Icelake_Server => "Intel Icelake Server",
            .Cascadelake_Server => "Intel Cascadelake Server",
            .Nehalem => "Intel Nehalem",
            .Westmere => "Intel Westmere",
            .SandyBridge => "Intel Sandy Bridge",
            .IvyBridge => "Intel Ivy Bridge",
            .Haswell => "Intel Haswell",
            .Broadwell => "Intel Broadwell",
            .Opteron_G5 => "AMD Opteron G5",
            .host_passthrough => "Host Passthrough",
            .Cooperlake => "Intel Cooperlake",
            .SapphireRapids => "Intel Sapphire Rapids",
            .GraniteRapids => "Intel Granite Rapids",
            .Neoverse_N1 => "ARM Neoverse N1",
            .Neoverse_N2 => "ARM Neoverse N2",
            .Neoverse_V1 => "ARM Neoverse V1",
            .aarch64 => "ARM aarch64 (generic)",
        };
    }

    /// Parse a QEMU CPU model string (from JSON or CLI), case-insensitive.
    pub fn fromStr(s: []const u8) CpuModel {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: CpuModel = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .host;
    }
};

// ── Audio Device ─────────────────────────────────────────────────────

/// Audio device emulation for the guest VM.
pub const AudioDevice = enum(u8) {
    none = 0,
    hda = 1,
    ac97 = 2,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: AudioDevice) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to an `AudioDevice`.  Out-of-range defaults to `.none`.
    pub fn fromIndex(i: usize) AudioDevice {
        if (i >= count) return .none;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU device model string.
    pub fn toStr(self: AudioDevice) [*:0]const u8 {
        return switch (self) {
            .none => "none",
            .hda => "intel-hda",
            .ac97 => "AC97",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: AudioDevice) [*:0]const u8 {
        return switch (self) {
            .none => "None",
            .hda => "Intel HDA",
            .ac97 => "AC97",
        };
    }

    /// Parse an AudioDevice from its toStr representation.
    pub fn fromStr(s: []const u8) AudioDevice {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: AudioDevice = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .none;
    }
};

// ── Boot Firmware ────────────────────────────────────────────────────

/// Boot firmware selection.
pub const BootFirmware = enum(u8) {
    bios = 0,
    uefi = 1,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: BootFirmware) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `BootFirmware`.  Out-of-range defaults to `.bios`.
    pub fn fromIndex(i: usize) BootFirmware {
        if (i >= count) return .bios;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU firmware identifier.
    pub fn toStr(self: BootFirmware) [*:0]const u8 {
        return switch (self) {
            .bios => "bios",
            .uefi => "uefi",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: BootFirmware) [*:0]const u8 {
        return switch (self) {
            .bios => "BIOS (SeaBIOS)",
            .uefi => "UEFI (OVMF)",
        };
    }

    pub fn fromStr(s: []const u8) BootFirmware {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: BootFirmware = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .bios;
    }
};

/// UI theme preference (application-wide setting, not per-VM).
pub const Theme = enum(u8) {
    system = 0, // follow the host GTK theme, no override
    light = 1,
    dark = 2,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: Theme) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) Theme {
        if (i >= count) return .light; // default
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Persisted identifier.
    pub fn toStr(self: Theme) [*:0]const u8 {
        return switch (self) {
            .system => "system",
            .light => "light",
            .dark => "dark",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: Theme) [*:0]const u8 {
        return switch (self) {
            .system => "System",
            .light => "Light",
            .dark => "Dark",
        };
    }

    pub fn fromStr(s: []const u8) Theme {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: Theme = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .light;
    }
};

// ── GPU Device ───────────────────────────────────────────────────────
pub const GpuDevice = enum(u8) {
    virtio_gpu_gl = 0,
    virtio_vga_gl = 1,
    virtio_gpu = 2,
    virtio_vga = 3,
    qxl = 4,
    std_vga = 5,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;
    pub fn toIndex(self: GpuDevice) usize {
        return @intFromEnum(self);
    }
    pub fn fromIndex(i: usize) GpuDevice {
        if (i >= count) return .virtio_vga_gl;
        return @enumFromInt(@as(u8, @intCast(i)));
    }
    pub fn toStr(self: GpuDevice) [*:0]const u8 {
        return switch (self) {
            .virtio_gpu_gl => "virtio_gpu_gl",
            .virtio_vga_gl => "virtio_vga_gl",
            .virtio_gpu => "virtio_gpu",
            .virtio_vga => "virtio_vga",
            .qxl => "qxl",
            .std_vga => "std_vga",
        };
    }
    pub fn label(self: GpuDevice) [*:0]const u8 {
        return switch (self) {
            .virtio_gpu_gl => "Virtio-GPU (virgl 3D)",
            .virtio_vga_gl => "Virtio-VGA (virgl 3D)",
            .virtio_gpu => "Virtio-GPU",
            .virtio_vga => "Virtio-VGA",
            .qxl => "QXL (SPICE)",
            .std_vga => "Standard VGA",
        };
    }
    pub fn fromStr(s: []const u8) GpuDevice {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: GpuDevice = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .virtio_vga_gl;
    }

    /// Returns true if this GPU device requires virgl (3D acceleration).
    pub fn needsVirgl(self: GpuDevice) bool {
        return switch (self) {
            .virtio_gpu_gl, .virtio_vga_gl => true,
            else => false,
        };
    }
};

// ── USB Policy ───────────────────────────────────────────────────────

/// USB controller policy controlling which USB host controller QEMU emulates.
pub const UsbPolicy = enum(u8) {
    none = 0,
    usb2 = 1,
    usb3 = 2,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: UsbPolicy) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `UsbPolicy`.  Out-of-range defaults to `.usb2`.
    pub fn fromIndex(i: usize) UsbPolicy {
        if (i >= count) return .usb2;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Returns the QEMU controller identifier.
    pub fn toStr(self: UsbPolicy) [*:0]const u8 {
        return switch (self) {
            .none => "none",
            .usb2 => "usb2",
            .usb3 => "usb3",
        };
    }

    /// Human-readable label for the UI.
    pub fn label(self: UsbPolicy) [*:0]const u8 {
        return switch (self) {
            .none => "None",
            .usb2 => "USB 2.0 (EHCI)",
            .usb3 => "USB 3.0 (xHCI)",
        };
    }

    /// Parse a UsbPolicy from its toStr representation.
    pub fn fromStr(s: []const u8) UsbPolicy {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: UsbPolicy = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .usb2;
    }
};

// ── Watchdog Action ─────────────────────────────────────────────────

/// Watchdog device action when the guest timer expires.
pub const WatchdogAction = enum(u8) {
    none = 0,
    reset = 1,
    poweroff = 2,
    pause = 3,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: WatchdogAction) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) WatchdogAction {
        if (i >= count) return .none;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    pub fn toStr(self: WatchdogAction) [*:0]const u8 {
        return switch (self) {
            .none => "none",
            .reset => "reset",
            .poweroff => "poweroff",
            .pause => "pause",
        };
    }

    pub fn label(self: WatchdogAction) [*:0]const u8 {
        return switch (self) {
            .none => "None",
            .reset => "Reset Guest",
            .poweroff => "Power Off Guest",
            .pause => "Pause Guest",
        };
    }

    pub fn fromStr(s: []const u8) WatchdogAction {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: WatchdogAction = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .none;
    }
};

// ── Accelerator ─────────────────────────────────────────────────────

/// Which virtualisation accelerator to use.
/// `auto` picks the best hardware accelerator available on this platform,
/// falling back to TCG (software emulation) if none is found.
pub const VmAccel = enum(u8) {
    auto = 0,
    tcg = 1,
    kvm = 2,
    hvf = 3,
    whpx = 4,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: VmAccel) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) VmAccel {
        if (i >= count) return .auto;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    pub fn toStr(self: VmAccel) [*:0]const u8 {
        return switch (self) {
            .auto => "auto",
            .tcg => "tcg",
            .kvm => "kvm",
            .hvf => "hvf",
            .whpx => "whpx",
        };
    }

    pub fn label(self: VmAccel) [*:0]const u8 {
        return switch (self) {
            .auto => "Auto (best available)",
            .tcg => "TCG (software)",
            .kvm => "KVM (Linux)",
            .hvf => "HVF (macOS)",
            .whpx => "WHPX (Windows)",
        };
    }

    /// Parse a VmAccel from its toStr representation (case-insensitive).
    pub fn fromStr(s: []const u8) VmAccel {
        inline for (@typeInfo(@This()).@"enum".fields) |f| {
            const variant: VmAccel = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, std.mem.span(variant.toStr()))) return variant;
        }
        return .auto;
    }

    /// Returns the platform-appropriate hardware accelerator for the current OS.
    pub fn platformDefault() VmAccel {
        return switch (builtin.os.tag) {
            .linux => .kvm,
            .macos => .hvf,
            .windows => .whpx,
            else => .tcg,
        };
    }
};

// ── Application Preferences ──────────────────────────────────────────

/// Application-wide preferences (persisted in vms.json alongside VMs).
pub const Prefs = struct {
    /// UI theme preference.
    theme: Theme = .light,
    /// Default directory for new VM disk images.
    default_vm_dir_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    default_vm_dir_len: u16 = 0,
    /// Default memory for new VMs (MB).
    default_memory_mb: u32 = 2048,
    /// Default CPU cores for new VMs.
    default_cpu_cores: u32 = 2,
    /// AutoProtect enabled by default for new VMs.
    autoprotect_enabled_default: bool = false,
    /// Default snapshot interval in minutes.
    autoprotect_interval_min_default: u32 = 60,
    /// Default max auto-protect snapshots.
    autoprotect_max_default: u32 = 10,
    /// Last window geometry — x, -1 means "not saved yet".
    win_x: i32 = -1,
    win_y: i32 = -1,
    win_w: i32 = 0,
    win_h: i32 = 0,
};

// ── VM Configuration ─────────────────────────────────────────────────

/// Complete configuration for a single virtual machine.
///
/// Fixed-size buffers are used for strings so that the struct can live in
/// a plain array without heap allocation.  Runtime state (`status`, `pid`)
/// is kept alongside config but should *not* be persisted.
pub const VmConfig = struct {
    // ── Name ──────────────────────────────────────────────────────
    name_buf: [MAX_NAME + 1]u8 = [_]u8{0} ** (MAX_NAME + 1),
    name_len: u16 = 0,

    // ── Disk ──────────────────────────────────────────────────────
    disk_path_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    disk_path_len: u16 = 0,

    // ── ISO / CD-ROM ─────────────────────────────────────────────
    iso_path_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    iso_path_len: u16 = 0,

    // ── Network adapters (persisted) ──────────────────────────────
    nics: [MAX_NICS]Nic = [_]Nic{.{ .mode = .user }} ++ [_]Nic{Nic{}} ** (MAX_NICS - 1),

    // ── Notes ────────────────────────────────────────────────────
    notes_buf: [4096]u8 = [_]u8{0} ** 4096,
    notes_len: u16 = 0,

    // ── Port Forwarding ──────────────────────────────────────────
    // Format: "HOST:GUEST,HOST:GUEST" e.g., "8080:80,2222:22"
    port_fwd_buf: [512]u8 = [_]u8{0} ** 512,
    port_fwd_len: u16 = 0,

    // ── Hardware settings ────────────────────────────────────────
    cpu_cores: u32 = 2,
    cpu_sockets: u32 = 1,
    cpu_model: CpuModel = .host,
    memory_mb: u32 = 2048,
    disk_size_gb: u32 = 20,
    disk_format: DiskFormat = .qcow2,
    disk_cache: DiskCache = .writeback,
    display: DisplayType = .gtk,
    display_resolution: DisplayResolution = .auto,
    /// Number of virtual displays (1-4).  QEMU adds a virtio-gpu device for each.
    num_displays: u32 = 1,
    /// Which accelerator to use.  `.auto` picks the best hardware accelerator
    /// available on this platform, falling back to TCG if none is found.
    accel: VmAccel = .auto,
    firmware: BootFirmware = .bios,
    guest_os: GuestOs = .linux,
    audio: AudioDevice = .none,
    boot_order: BootOrder = .disk_first,

    // ── Display embedding settings ──────────────────────────────
    /// When true, QEMU uses `-display none -vnc localhost:<vnc_port>`
    /// and the app connects as a VNC client to show the display inline.
    embed_display: bool = true,
    /// localhost port for embedded VNC (5900 + N).  Auto-assigned per VM.
    vnc_port: u16 = 5900,
    /// localhost port for embedded SPICE.  Auto-assigned per VM.
    spice_port: u16 = 5930,
    /// Enable serial console via Unix socket.
    enable_serial: bool = true,
    /// Enable virtio-rng entropy device for the guest.
    virtio_rng: bool = false,
    /// Guest agent channel (virtio-serial for qemu-guest-agent).
    guest_agent: bool = false,
    /// Watchdog device with configurable action.
    watchdog: WatchdogAction = .none,
    /// TPM 2.0 device for the guest (required for Windows 11).
    tpm: bool = false,
    /// Secure Boot via UEFI + SMM (requires firmware=uefi).
    secure_boot: bool = false,
    /// Hyper-V enlightenments for Windows guest optimization.
    hyperv_enlightenments: bool = false,
    /// Hugepages / memory preallocation for performance.
    hugepages: bool = false,
    /// Number of IO threads for block devices (0 = disabled, 1+ = enabled).
    io_threads: u32 = 0,
    /// Disk I/O throttling: max bytes per second (0 = unlimited).
    disk_bps_throttle: u64 = 0,
    /// Disk I/O throttling: max IOPS (0 = unlimited).
    disk_iops_throttle: u32 = 0,
    /// Virtio memory balloon device for dynamic memory management.
    ballooning: bool = false,
    /// Auto-start VM when host boots.
    host_autostart: bool = false,

    // ── Runtime state (not persisted) ────────────────────────────
    status: VmStatus = .stopped,
    pid: ?i32 = null,

    // ── Saved State (persisted) ──────────────────────────────────
    saved_state_path_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    saved_state_path_len: u16 = 0,

    // ── Shared Folders (9p mount, persisted) ──────────────────────
    shared_folder_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    shared_folder_len: u16 = 0,

    // ── Second (data) disk (persisted) ────────────────────────────
    disk2_path_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    disk2_path_len: u16 = 0,
    disk2_size_gb: u32 = 0,
    disk2_format: DiskFormat = .qcow2,

    // ── Extra (non-primary) disk images (persisted) ───────────────
    extra_disks: [MAX_EXTRA_DISKS]ExtraDisk = [_]ExtraDisk{ExtraDisk{}} ** MAX_EXTRA_DISKS,

    // ── USB controller policy (persisted) ─────────────────────────
    usb_policy: UsbPolicy = .usb2,

    // ── USB passthrough device, "vendorid:productid" hex (persisted) ──
    usb_device_buf: [64]u8 = [_]u8{0} ** 64,
    usb_device_len: u16 = 0,

    // ── Additional network adapters (persisted) ───────────────────
    // The primary adapter is `network`/`mac_buf` above. These are extra
    // NICs; `.none` mode means the adapter is absent.
    // ── 3D graphics acceleration (virgl), persisted ───────────────
    enable_3d: bool = false,
    gpu_device: GpuDevice = .virtio_vga_gl,

    // ── Auto-mount virtio-win guest tools ISO as an extra CD (persisted) ──
    guest_tools: bool = false,

    // ── Library favorites (persisted) ─────────────────────────────
    /// True when this VM appears in the "Favorites" group at the top of the
    /// library sidebar (WS7 parity: right-click → Add/Remove from Favorites).
    favorite: bool = false,

    // ── AutoProtect: scheduled automatic snapshots (persisted) ────
    autoprotect: bool = false,
    autoprotect_interval_min: u32 = 1440, // daily
    autoprotect_max: u32 = 3, // keep newest N
    autoprotect_last_epoch: i64 = 0, // unix timestamp of last AutoProtect snapshot
    autoprotect_last_seq: u32 = 0, // sequence counter for snapshot naming

    // ── Floppy disk image path (persisted) ────────────────────────
    floppy_path_buf: [MAX_PATH + 1]u8 = [_]u8{0} ** (MAX_PATH + 1),
    floppy_path_len: u16 = 0,

    // ── Name accessors ───────────────────────────────────────────

    /// Returns the VM name as a null-terminated C string pointer.
    pub fn getName(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.name_buf);
    }

    /// Returns the VM name as a Zig slice.
    pub fn getNameSlice(self: *const VmConfig) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Sets the VM name, truncating to `MAX_NAME` if necessary.
    pub fn setName(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_NAME));
        @memcpy(self.name_buf[0..len], s[0..len]);
        self.name_buf[len] = 0;
        self.name_len = len;
    }

    /// Clears the VM name (resets to empty).
    pub fn clearName(self: *VmConfig) void {
        self.name_buf[0] = 0;
        self.name_len = 0;
    }

    // ── Disk path accessors ──────────────────────────────────────

    /// Returns the disk path as a null-terminated C string pointer.
    pub fn getDiskPath(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.disk_path_buf);
    }

    /// Returns the disk path as a Zig slice.
    pub fn getDiskPathSlice(self: *const VmConfig) []const u8 {
        return self.disk_path_buf[0..self.disk_path_len];
    }

    /// Sets the disk image path, truncating to `MAX_PATH` if necessary.
    pub fn setDiskPath(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.disk_path_buf[0..len], s[0..len]);
        self.disk_path_buf[len] = 0;
        self.disk_path_len = len;
    }

    /// Clears the disk path (resets to empty).
    pub fn clearDiskPath(self: *VmConfig) void {
        self.disk_path_buf[0] = 0;
        self.disk_path_len = 0;
    }

    // ── ISO path accessors ───────────────────────────────────────

    /// Returns the ISO path as a null-terminated C string pointer.
    pub fn getIsoPath(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.iso_path_buf);
    }

    /// Returns the ISO path as a Zig slice.
    pub fn getIsoPathSlice(self: *const VmConfig) []const u8 {
        return self.iso_path_buf[0..self.iso_path_len];
    }

    /// Sets the ISO / CD-ROM path, truncating to `MAX_PATH` if necessary.
    pub fn setIsoPath(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.iso_path_buf[0..len], s[0..len]);
        self.iso_path_buf[len] = 0;
        self.iso_path_len = len;
    }

    /// Clears the ISO path (resets to empty).
    pub fn clearIsoPath(self: *VmConfig) void {
        self.iso_path_buf[0] = 0;
        self.iso_path_len = 0;
    }

    // ── NIC accessors (delegate to nics[i]) ──────────────────────

    /// Returns the MAC address of NIC 0 as a null-terminated C string pointer.
    pub fn getMacAddress(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.nics[0].mac_buf);
    }

    /// Returns the MAC address of NIC 0 as a Zig slice.
    pub fn getMacAddressSlice(self: *const VmConfig) []const u8 {
        return self.nics[0].mac_buf[0..self.nics[0].mac_len];
    }

    /// Sets the MAC address of NIC 0.
    pub fn setMacAddress(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, 17));
        @memcpy(self.nics[0].mac_buf[0..len], s[0..len]);
        self.nics[0].mac_buf[len] = 0;
        self.nics[0].mac_len = len;
    }

    /// Clears the MAC address of NIC 0 (resets to empty).
    pub fn clearMacAddress(self: *VmConfig) void {
        self.nics[0].mac_buf[0] = 0;
        self.nics[0].mac_len = 0;
    }

    // ── Notes accessors ──────────────────────────────────────────

    pub fn getNotes(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.notes_buf);
    }

    pub fn getNotesSlice(self: *const VmConfig) []const u8 {
        return self.notes_buf[0..self.notes_len];
    }

    pub fn setNotes(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, 4095));
        @memcpy(self.notes_buf[0..len], s[0..len]);
        self.notes_buf[len] = 0;
        self.notes_len = len;
    }

    pub fn clearNotes(self: *VmConfig) void {
        self.notes_buf[0] = 0;
        self.notes_len = 0;
    }

    // ── Port Forwarding accessors ────────────────────────────────

    pub fn getPortForwards(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.port_fwd_buf);
    }

    pub fn getPortForwardsSlice(self: *const VmConfig) []const u8 {
        return self.port_fwd_buf[0..self.port_fwd_len];
    }

    pub fn setPortForwards(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, 511));
        @memcpy(self.port_fwd_buf[0..len], s[0..len]);
        self.port_fwd_buf[len] = 0;
        self.port_fwd_len = len;
    }

    pub fn clearPortForwards(self: *VmConfig) void {
        self.port_fwd_buf[0] = 0;
        self.port_fwd_len = 0;
    }

    // ── Saved State accessors ────────────────────────────────────

    pub fn getSavedStatePath(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.saved_state_path_buf);
    }

    pub fn getSavedStatePathSlice(self: *const VmConfig) []const u8 {
        return self.saved_state_path_buf[0..self.saved_state_path_len];
    }

    pub fn setSavedStatePath(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.saved_state_path_buf[0..len], s[0..len]);
        self.saved_state_path_buf[len] = 0;
        self.saved_state_path_len = len;
    }

    pub fn clearSavedStatePath(self: *VmConfig) void {
        self.saved_state_path_buf[0] = 0;
        self.saved_state_path_len = 0;
    }

    // ── Shared Folder accessors ──────────────────────────────────

    pub fn getSharedFolder(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.shared_folder_buf);
    }

    pub fn getSharedFolderSlice(self: *const VmConfig) []const u8 {
        return self.shared_folder_buf[0..self.shared_folder_len];
    }

    pub fn setSharedFolder(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.shared_folder_buf[0..len], s[0..len]);
        self.shared_folder_buf[len] = 0;
        self.shared_folder_len = len;
    }

    pub fn clearSharedFolder(self: *VmConfig) void {
        self.shared_folder_buf[0] = 0;
        self.shared_folder_len = 0;
    }

    pub fn hasSharedFolder(self: *const VmConfig) bool {
        return self.shared_folder_len > 0;
    }

    // ── Second (data) disk accessors ─────────────────────────────

    pub fn getDisk2Path(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.disk2_path_buf);
    }

    pub fn getDisk2PathSlice(self: *const VmConfig) []const u8 {
        return self.disk2_path_buf[0..self.disk2_path_len];
    }

    pub fn setDisk2Path(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.disk2_path_buf[0..len], s[0..len]);
        self.disk2_path_buf[len] = 0;
        self.disk2_path_len = len;
    }

    pub fn clearDisk2Path(self: *VmConfig) void {
        self.disk2_path_buf[0] = 0;
        self.disk2_path_len = 0;
    }

    pub fn hasDisk2(self: *const VmConfig) bool {
        return self.disk2_path_len > 0;
    }

    // ── Extra disk accessors ─────────────────────────────────────

    pub fn getExtraDiskPath(self: *const VmConfig, i: usize) [*:0]const u8 {
        return @ptrCast(&self.extra_disks[i].path_buf);
    }

    pub fn getExtraDiskPathSlice(self: *const VmConfig, i: usize) []const u8 {
        return self.extra_disks[i].path_buf[0..self.extra_disks[i].path_len];
    }

    pub fn setExtraDiskPath(self: *VmConfig, i: usize, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.extra_disks[i].path_buf[0..len], s[0..len]);
        self.extra_disks[i].path_buf[len] = 0;
        self.extra_disks[i].path_len = len;
    }

    pub fn clearExtraDiskPath(self: *VmConfig, i: usize) void {
        self.extra_disks[i].path_buf[0] = 0;
        self.extra_disks[i].path_len = 0;
    }

    pub fn hasExtraDisk(self: *const VmConfig, i: usize) bool {
        return self.extra_disks[i].path_len > 0;
    }

    // ── USB passthrough accessors ────────────────────────────────

    pub fn getUsbDevice(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.usb_device_buf);
    }

    pub fn getUsbDeviceSlice(self: *const VmConfig) []const u8 {
        return self.usb_device_buf[0..self.usb_device_len];
    }

    pub fn setUsbDevice(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, self.usb_device_buf.len - 1));
        @memcpy(self.usb_device_buf[0..len], s[0..len]);
        self.usb_device_buf[len] = 0;
        self.usb_device_len = len;
    }

    pub fn clearUsbDevice(self: *VmConfig) void {
        self.usb_device_buf[0] = 0;
        self.usb_device_len = 0;
    }

    pub fn hasUsbDevice(self: *const VmConfig) bool {
        return self.usb_device_len > 0;
    }

    // ── Additional NIC accessors ─────────────────────────────────

    pub fn getNic2Mac(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.nics[1].mac_buf);
    }
    pub fn getNic2MacSlice(self: *const VmConfig) []const u8 {
        return self.nics[1].mac_buf[0..self.nics[1].mac_len];
    }
    pub fn setNic2Mac(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, 17));
        @memcpy(self.nics[1].mac_buf[0..len], s[0..len]);
        self.nics[1].mac_buf[len] = 0;
        self.nics[1].mac_len = len;
    }
    pub fn getNic3Mac(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.nics[2].mac_buf);
    }
    pub fn getNic3MacSlice(self: *const VmConfig) []const u8 {
        return self.nics[2].mac_buf[0..self.nics[2].mac_len];
    }
    pub fn setNic3Mac(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, 17));
        @memcpy(self.nics[2].mac_buf[0..len], s[0..len]);
        self.nics[2].mac_buf[len] = 0;
        self.nics[2].mac_len = len;
    }

    /// Generic accessors for any NIC (0 = NIC1, 1 = NIC2, … up to MAX_NICS-1).
    pub fn getNicMacSliceAny(self: *const VmConfig, idx: usize) []const u8 {
        if (idx >= MAX_NICS) return "";
        return self.nics[idx].mac_buf[0..self.nics[idx].mac_len];
    }
    pub fn setNicMacAny(self: *VmConfig, idx: usize, s: []const u8) void {
        if (idx >= MAX_NICS) return;
        const len: u16 = @intCast(@min(s.len, 17));
        @memcpy(self.nics[idx].mac_buf[0..len], s[0..len]);
        self.nics[idx].mac_buf[len] = 0;
        self.nics[idx].mac_len = len;
    }

    // ── Floppy accessors ─────────────────────────────────────────

    pub fn getFloppyPath(self: *const VmConfig) [*:0]const u8 {
        return @ptrCast(&self.floppy_path_buf);
    }
    pub fn getFloppyPathSlice(self: *const VmConfig) []const u8 {
        return self.floppy_path_buf[0..self.floppy_path_len];
    }
    pub fn setFloppyPath(self: *VmConfig, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, MAX_PATH));
        @memcpy(self.floppy_path_buf[0..len], s[0..len]);
        self.floppy_path_buf[len] = 0;
        self.floppy_path_len = len;
    }
    pub fn clearFloppyPath(self: *VmConfig) void {
        self.floppy_path_buf[0] = 0;
        self.floppy_path_len = 0;
    }
    pub fn hasFloppy(self: *const VmConfig) bool {
        return self.floppy_path_len > 0;
    }

    // ── Predicate helpers ────────────────────────────────────────

    /// Returns `true` if this VM has a name set.
    pub fn hasName(self: *const VmConfig) bool {
        return self.name_len > 0;
    }

    /// Returns `true` if this VM has a disk image configured.
    pub fn hasDisk(self: *const VmConfig) bool {
        return self.disk_path_len > 0;
    }

    /// Returns `true` if this VM has an ISO attached.
    pub fn hasIso(self: *const VmConfig) bool {
        return self.iso_path_len > 0;
    }

    /// Returns `true` if this VM's QEMU process is (believed to be) running.
    pub fn isRunning(self: *const VmConfig) bool {
        return self.status == .running;
    }

    /// Returns `true` if this VM is stopped.
    pub fn isStopped(self: *const VmConfig) bool {
        return self.status == .stopped or self.status == .suspended;
    }

    /// Returns `true` if the VM's QEMU process exists (running or paused).
    pub fn isAlive(self: *const VmConfig) bool {
        return self.status == .running or self.status == .paused;
    }

    /// Returns `true` if this VM is paused.
    pub fn isPaused(self: *const VmConfig) bool {
        return self.status == .paused;
    }

    /// Returns `true` if NIC 0 has a MAC address configured.
    pub fn hasMacAddress(self: *const VmConfig) bool {
        return self.nics[0].mac_len > 0;
    }

    /// Returns `true` if this VM has notes.
    pub fn hasNotes(self: *const VmConfig) bool {
        return self.notes_len > 0;
    }

    /// Returns `true` if this VM has port forwarding rules.
    pub fn hasPortForwards(self: *const VmConfig) bool {
        return self.port_fwd_len > 0;
    }

    /// Returns `true` if this VM has a saved state file.
    pub fn hasSavedState(self: *const VmConfig) bool {
        return self.saved_state_path_len > 0;
    }

    // ── Platform accelerator helpers ─────────────────────────────

    /// Returns the human-readable name of the platform's best hardware accelerator.
    pub fn accelName() [*:0]const u8 {
        return VmAccel.platformDefault().label();
    }

    /// Returns the QEMU `-machine accel=` flag value for the platform's best HW accelerator.
    pub fn accelFlag() [*:0]const u8 {
        return VmAccel.platformDefault().toStr();
    }
};

/// Generates a random unicast, locally-administered MAC address.
pub fn generateMacAddress(buf: *[18]u8) [*:0]const u8 {
    // Seed from the monotonic clock. 0.16 moved `std.time.milliTimestamp`
    // behind the `Io` interface, so we read the clock via libc directly.
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @bitCast(@as(i64, ts.sec))) ^
        (@as(u64, @bitCast(@as(i64, ts.nsec))) << 1);
    var rand_impl = std.Random.DefaultPrng.init(seed);
    const random = rand_impl.random();

    // First byte must have bit 0 clear (unicast) and bit 1 set (locally administered).
    // So binary is xxxx xxxx xxxx xx10 -> the lower nibble is 2, 6, A, or E.
    const b0 = (random.int(u8) & 0xFC) | 0x02;
    const b1 = random.int(u8);
    const b2 = random.int(u8);
    const b3 = random.int(u8);
    const b4 = random.int(u8);
    const b5 = random.int(u8);

    return std.fmt.bufPrintZ(buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{ b0, b1, b2, b3, b4, b5 }) catch "02:00:00:00:00:00";
}

// ── Input validation helpers ─────────────────────────────────────────

/// Returns true if `name` is safe to use as a VM name (no path separators,
/// no control characters, not empty after trimming).
pub fn isValidVmName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return false;
    for (trimmed) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

/// Returns true if `mac` looks like a valid MAC address (XX:XX:XX:XX:XX:XX).
pub fn isValidMac(mac: []const u8) bool {
    if (mac.len == 0) return true; // empty = auto-generate, always valid
    if (mac.len != 17) return false;
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        if (i == 2 or i == 5 or i == 8 or i == 11 or i == 14) {
            if (mac[i] != ':') return false;
        } else {
            const c = mac[i];
            if (!((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f'))) return false;
        }
    }
    return true;
}

/// Returns true if `port` is in a safe range for VNC/SPICE (5900-5999).
pub fn isValidDisplayPort(port: u16) bool {
    return port >= 5900 and port <= 5999;
}

/// Find an unused VNC port by scanning existing VMs. Falls back to 5900 + count.
pub fn findUnusedVncPort(vms: []VmConfig) u16 {
    var port: u16 = 5900;
    while (port <= 5999) : (port += 1) {
        var used = false;
        for (vms) |*v| {
            if (v.vnc_port == port) {
                used = true;
                break;
            }
        }
        if (!used) return port;
    }
    return 5900;
}

/// Find an unused SPICE port by scanning existing VMs. Falls back to 5930 + count.
pub fn findUnusedSpicePort(vms: []VmConfig) u16 {
    var port: u16 = 5930;
    while (port <= 5999) : (port += 1) {
        var used = false;
        for (vms) |*v| {
            if (v.spice_port == port) {
                used = true;
                break;
            }
        }
        if (!used) return port;
    }
    return 5930;
}

/// Clamp memory to a sane range (1 MB to 1 TB). Zero is replaced with min.
pub fn clampMemory(mb: u32) u32 {
    return std.math.clamp(mb, 1, 1048576);
}

/// Clamp CPU cores to a sane range (1 to 256).
pub fn clampCpuCores(cores: u32) u32 {
    return std.math.clamp(cores, 1, 256);
}

/// Clamp disk size to a sane range (1 GB to 64 TB).
pub fn clampDiskSize(gb: u32) u32 {
    return std.math.clamp(gb, 1, 65536);
}

// ── Tests ────────────────────────────────────────────────────────────

// -- Name / path round-trips --

test "VmConfig: setName and getName round-trip" {
    var cfg = VmConfig{};
    cfg.setName("TestVM");
    const slice = cfg.getNameSlice();
    try std.testing.expectEqualStrings("TestVM", slice);
    // Null-terminated C pointer should also match.
    const c_str = cfg.getName();
    try std.testing.expectEqualStrings("TestVM", std.mem.span(c_str));
}

test "VmConfig: setName truncates at MAX_NAME" {
    var cfg = VmConfig{};
    const long = "A" ** (MAX_NAME + 100);
    cfg.setName(long);
    try std.testing.expectEqual(@as(u16, MAX_NAME), cfg.name_len);
}

test "VmConfig: mac address round-trip" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasMacAddress());

    cfg.setMacAddress("00:11:22:33:44:55");
    try std.testing.expect(cfg.hasMacAddress());
    try std.testing.expectEqualStrings("00:11:22:33:44:55", cfg.getMacAddressSlice());
    try std.testing.expectEqualStrings("00:11:22:33:44:55", std.mem.span(cfg.getMacAddress()));

    cfg.clearMacAddress();
    try std.testing.expect(!cfg.hasMacAddress());
    try std.testing.expectEqual(@as(usize, 0), cfg.getMacAddressSlice().len);
}

test "generateMacAddress format" {
    var buf: [18]u8 = undefined;
    const mac_ptr = generateMacAddress(&buf);
    const mac = std.mem.span(mac_ptr);
    try std.testing.expectEqual(@as(usize, 17), mac.len);
    // Locally administered unicast means second nibble is 2, 6, A, or E
    try std.testing.expect(mac[1] == '2' or mac[1] == '6' or mac[1] == 'A' or mac[1] == 'E');
    try std.testing.expect(mac[2] == ':');
}

test "VmConfig: setDiskPath and getDiskPath round-trip" {
    var cfg = VmConfig{};
    cfg.setDiskPath("/home/user/VMs/test.qcow2");
    try std.testing.expectEqualStrings("/home/user/VMs/test.qcow2", cfg.getDiskPathSlice());
    try std.testing.expectEqualStrings("/home/user/VMs/test.qcow2", std.mem.span(cfg.getDiskPath()));
}

test "VmConfig: setDiskPath truncates at MAX_PATH" {
    var cfg = VmConfig{};
    const long = "X" ** (MAX_PATH + 200);
    cfg.setDiskPath(long);
    try std.testing.expectEqual(@as(u16, MAX_PATH), cfg.disk_path_len);
}

test "VmConfig: setIsoPath and getIsoPath round-trip" {
    var cfg = VmConfig{};
    cfg.setIsoPath("/tmp/ubuntu.iso");
    try std.testing.expectEqualStrings("/tmp/ubuntu.iso", cfg.getIsoPathSlice());
    try std.testing.expectEqualStrings("/tmp/ubuntu.iso", std.mem.span(cfg.getIsoPath()));
    try std.testing.expect(cfg.hasIso());
}

test "VmConfig: setIsoPath truncates at MAX_PATH" {
    var cfg = VmConfig{};
    const long = "Y" ** (MAX_PATH + 200);
    cfg.setIsoPath(long);
    try std.testing.expectEqual(@as(u16, MAX_PATH), cfg.iso_path_len);
}

// -- Clear methods --

test "VmConfig: clearName resets name" {
    var cfg = VmConfig{};
    cfg.setName("MyVM");
    try std.testing.expect(cfg.hasName());
    cfg.clearName();
    try std.testing.expect(!cfg.hasName());
    try std.testing.expectEqual(@as(u16, 0), cfg.name_len);
    try std.testing.expectEqualStrings("", cfg.getNameSlice());
}

test "VmConfig: clearDiskPath resets disk" {
    var cfg = VmConfig{};
    cfg.setDiskPath("/tmp/disk.qcow2");
    try std.testing.expect(cfg.hasDisk());
    cfg.clearDiskPath();
    try std.testing.expect(!cfg.hasDisk());
    try std.testing.expectEqual(@as(u16, 0), cfg.disk_path_len);
}

test "VmConfig: clearIsoPath resets ISO" {
    var cfg = VmConfig{};
    cfg.setIsoPath("/tmp/boot.iso");
    try std.testing.expect(cfg.hasIso());
    cfg.clearIsoPath();
    try std.testing.expect(!cfg.hasIso());
    try std.testing.expectEqual(@as(u16, 0), cfg.iso_path_len);
}

// -- Reset --

test "VmConfig: reset restores all defaults" {
    var cfg = VmConfig{};
    cfg.setName("Modified");
    cfg.setDiskPath("/tmp/disk.raw");
    cfg.setIsoPath("/tmp/boot.iso");
    cfg.cpu_cores = 8;
    cfg.memory_mb = 16384;
    cfg.disk_size_gb = 500;
    cfg.disk_format = .vmdk;
    cfg.display = .vnc;
    cfg.nics[0].mode = .bridge;
    cfg.firmware = .uefi;
    cfg.accel = .tcg;
    cfg.status = .running;
    cfg.pid = 12345;

    cfg = VmConfig{};

    try std.testing.expectEqual(@as(u32, 2), cfg.cpu_cores);
    try std.testing.expectEqual(@as(u32, 2048), cfg.memory_mb);
    try std.testing.expectEqual(@as(u32, 20), cfg.disk_size_gb);
    try std.testing.expectEqual(DiskFormat.qcow2, cfg.disk_format);
    try std.testing.expectEqual(DisplayType.gtk, cfg.display);
    try std.testing.expectEqual(NetworkMode.user, cfg.nics[0].mode);
    try std.testing.expectEqual(BootFirmware.bios, cfg.firmware);
    try std.testing.expectEqual(VmAccel.auto, cfg.accel);
    try std.testing.expect(cfg.isStopped());
    try std.testing.expect(!cfg.hasName());
    try std.testing.expect(!cfg.hasDisk());
    try std.testing.expect(!cfg.hasIso());
    try std.testing.expectEqual(@as(?i32, null), cfg.pid);
}

// -- Default values & predicates --

test "VmConfig: default values" {
    const cfg = VmConfig{};
    try std.testing.expectEqual(@as(u32, 2), cfg.cpu_cores);
    try std.testing.expectEqual(@as(u32, 2048), cfg.memory_mb);
    try std.testing.expectEqual(@as(u32, 20), cfg.disk_size_gb);
    try std.testing.expectEqual(DiskFormat.qcow2, cfg.disk_format);
    try std.testing.expectEqual(DisplayType.gtk, cfg.display);
    try std.testing.expectEqual(NetworkMode.user, cfg.nics[0].mode);
    try std.testing.expectEqual(BootFirmware.bios, cfg.firmware);
    try std.testing.expectEqual(VmAccel.auto, cfg.accel);
    try std.testing.expectEqual(VmStatus.stopped, cfg.status);
    try std.testing.expect(!cfg.hasDisk());
    try std.testing.expect(!cfg.hasIso());
    try std.testing.expect(!cfg.hasName());
    try std.testing.expect(!cfg.isRunning());
    try std.testing.expect(cfg.isStopped());
}

// -- Enum counts (comptime-verified) --

test "enum counts match expected values" {
    try std.testing.expectEqual(@as(usize, 4), DiskFormat.count);
    try std.testing.expectEqual(@as(usize, 3), NetworkMode.count);
    try std.testing.expectEqual(@as(usize, 5), DisplayType.count);
    try std.testing.expectEqual(@as(usize, 4), VmStatus.count);
    try std.testing.expectEqual(@as(usize, 2), BootFirmware.count);
    try std.testing.expectEqual(@as(usize, 5), GuestOs.count);
}

// -- DiskFormat --

test "DiskFormat: fromIndex round-trip" {
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromIndex(0));
    try std.testing.expectEqual(DiskFormat.raw, DiskFormat.fromIndex(1));
    try std.testing.expectEqual(DiskFormat.vmdk, DiskFormat.fromIndex(2));
    try std.testing.expectEqual(DiskFormat.vdi, DiskFormat.fromIndex(3));
    // Out-of-range defaults to qcow2
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromIndex(99));
}

test "DiskFormat: toIndex inverts fromIndex" {
    for (0..DiskFormat.count) |i| {
        try std.testing.expectEqual(i, DiskFormat.fromIndex(i).toIndex());
    }
}

test "DiskFormat: toStr values" {
    try std.testing.expectEqualStrings("qcow2", std.mem.span(DiskFormat.qcow2.toStr()));
    try std.testing.expectEqualStrings("raw", std.mem.span(DiskFormat.raw.toStr()));
    try std.testing.expectEqualStrings("vmdk", std.mem.span(DiskFormat.vmdk.toStr()));
    try std.testing.expectEqualStrings("vdi", std.mem.span(DiskFormat.vdi.toStr()));
}

test "DiskFormat: label values" {
    try std.testing.expectEqualStrings("QCOW2", std.mem.span(DiskFormat.qcow2.label()));
    try std.testing.expectEqualStrings("Raw", std.mem.span(DiskFormat.raw.label()));
    try std.testing.expectEqualStrings("VMDK", std.mem.span(DiskFormat.vmdk.label()));
    try std.testing.expectEqualStrings("VDI", std.mem.span(DiskFormat.vdi.label()));
}

test "DiskFormat: fromExtension qcow2" {
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension("disk.qcow2"));
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension("DISK.QCOW2"));
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension("/path/to/vm.qcow2"));
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension("disk.QcOw2"));
}

test "DiskFormat: fromExtension raw" {
    try std.testing.expectEqual(DiskFormat.raw, DiskFormat.fromExtension("disk.raw"));
    try std.testing.expectEqual(DiskFormat.raw, DiskFormat.fromExtension("disk.RAW"));
}

test "DiskFormat: fromExtension img maps to raw" {
    try std.testing.expectEqual(DiskFormat.raw, DiskFormat.fromExtension("disk.img"));
    try std.testing.expectEqual(DiskFormat.raw, DiskFormat.fromExtension("disk.IMG"));
}

test "DiskFormat: fromExtension vmdk" {
    try std.testing.expectEqual(DiskFormat.vmdk, DiskFormat.fromExtension("disk.vmdk"));
    try std.testing.expectEqual(DiskFormat.vmdk, DiskFormat.fromExtension("DISK.VMDK"));
}

test "DiskFormat: fromExtension vdi" {
    try std.testing.expectEqual(DiskFormat.vdi, DiskFormat.fromExtension("disk.vdi"));
    try std.testing.expectEqual(DiskFormat.vdi, DiskFormat.fromExtension("disk.VDI"));
}

test "DiskFormat: fromExtension unknown defaults to qcow2" {
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension("disk.vhd"));
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension("disk"));
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromExtension(""));
}

test "DiskFormat: fromStr values" {
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromStr("qcow2"));
    try std.testing.expectEqual(DiskFormat.raw, DiskFormat.fromStr("raw"));
    try std.testing.expectEqual(DiskFormat.vmdk, DiskFormat.fromStr("vmdk"));
    try std.testing.expectEqual(DiskFormat.vdi, DiskFormat.fromStr("vdi"));
    try std.testing.expectEqual(DiskFormat.qcow2, DiskFormat.fromStr("unknown"));
}

// -- DiskCache --

test "DiskCache: fromIndex round-trip" {
    try std.testing.expectEqual(DiskCache.writeback, DiskCache.fromIndex(0));
    try std.testing.expectEqual(DiskCache.writethrough, DiskCache.fromIndex(1));
    try std.testing.expectEqual(DiskCache.none, DiskCache.fromIndex(2));
    try std.testing.expectEqual(DiskCache.directsync, DiskCache.fromIndex(3));
    try std.testing.expectEqual(DiskCache.unsafe, DiskCache.fromIndex(4));
    try std.testing.expectEqual(DiskCache.writeback, DiskCache.fromIndex(99));
}

test "DiskCache: toIndex inverts fromIndex" {
    for (0..DiskCache.count) |i| {
        try std.testing.expectEqual(i, DiskCache.fromIndex(i).toIndex());
    }
}

test "DiskCache: toStr values" {
    try std.testing.expectEqualStrings("writeback", std.mem.span(DiskCache.writeback.toStr()));
    try std.testing.expectEqualStrings("writethrough", std.mem.span(DiskCache.writethrough.toStr()));
    try std.testing.expectEqualStrings("none", std.mem.span(DiskCache.none.toStr()));
    try std.testing.expectEqualStrings("directsync", std.mem.span(DiskCache.directsync.toStr()));
    try std.testing.expectEqualStrings("unsafe", std.mem.span(DiskCache.unsafe.toStr()));
}

test "DiskCache: label values" {
    try std.testing.expectEqualStrings("Writeback", std.mem.span(DiskCache.writeback.label()));
    try std.testing.expectEqualStrings("Writethrough", std.mem.span(DiskCache.writethrough.label()));
    try std.testing.expectEqualStrings("None", std.mem.span(DiskCache.none.label()));
    try std.testing.expectEqualStrings("Direct Sync", std.mem.span(DiskCache.directsync.label()));
    try std.testing.expectEqualStrings("Unsafe", std.mem.span(DiskCache.unsafe.label()));
}

test "DiskCache: fromStr round-trip" {
    for (0..DiskCache.count) |i| {
        const dc = DiskCache.fromIndex(i);
        try std.testing.expectEqual(dc, DiskCache.fromStr(std.mem.span(dc.toStr())));
    }
    try std.testing.expectEqual(DiskCache.writeback, DiskCache.fromStr("unknown"));
    try std.testing.expectEqual(DiskCache.writeback, DiskCache.fromStr(""));
}

// -- WatchdogAction --

test "WatchdogAction: fromIndex round-trip" {
    try std.testing.expectEqual(WatchdogAction.none, WatchdogAction.fromIndex(0));
    try std.testing.expectEqual(WatchdogAction.reset, WatchdogAction.fromIndex(1));
    try std.testing.expectEqual(WatchdogAction.poweroff, WatchdogAction.fromIndex(2));
    try std.testing.expectEqual(WatchdogAction.pause, WatchdogAction.fromIndex(3));
    try std.testing.expectEqual(WatchdogAction.none, WatchdogAction.fromIndex(99));
}

test "WatchdogAction: toIndex inverts fromIndex" {
    for (0..WatchdogAction.count) |i| {
        try std.testing.expectEqual(i, WatchdogAction.fromIndex(i).toIndex());
    }
}

test "WatchdogAction: toStr values" {
    try std.testing.expectEqualStrings("none", std.mem.span(WatchdogAction.none.toStr()));
    try std.testing.expectEqualStrings("reset", std.mem.span(WatchdogAction.reset.toStr()));
    try std.testing.expectEqualStrings("poweroff", std.mem.span(WatchdogAction.poweroff.toStr()));
    try std.testing.expectEqualStrings("pause", std.mem.span(WatchdogAction.pause.toStr()));
}

test "WatchdogAction: label values" {
    try std.testing.expectEqualStrings("None", std.mem.span(WatchdogAction.none.label()));
    try std.testing.expectEqualStrings("Reset Guest", std.mem.span(WatchdogAction.reset.label()));
    try std.testing.expectEqualStrings("Power Off Guest", std.mem.span(WatchdogAction.poweroff.label()));
    try std.testing.expectEqualStrings("Pause Guest", std.mem.span(WatchdogAction.pause.label()));
}

test "WatchdogAction: fromStr round-trip" {
    for (0..WatchdogAction.count) |i| {
        const wa = WatchdogAction.fromIndex(i);
        try std.testing.expectEqual(wa, WatchdogAction.fromStr(std.mem.span(wa.toStr())));
    }
    try std.testing.expectEqual(WatchdogAction.none, WatchdogAction.fromStr("unknown"));
    try std.testing.expectEqual(WatchdogAction.none, WatchdogAction.fromStr(""));
}

// -- CpuModel --

test "CpuModel: fromIndex round-trip" {
    try std.testing.expectEqual(CpuModel.host, CpuModel.fromIndex(0));
    try std.testing.expectEqual(CpuModel.max, CpuModel.fromIndex(1));
    try std.testing.expectEqual(CpuModel.qemu64, CpuModel.fromIndex(2));
    try std.testing.expectEqual(CpuModel.kvm64, CpuModel.fromIndex(3));
    try std.testing.expectEqual(CpuModel.host, CpuModel.fromIndex(99));
}

test "CpuModel: toIndex inverts fromIndex" {
    for (0..CpuModel.count) |i| {
        try std.testing.expectEqual(i, CpuModel.fromIndex(i).toIndex());
    }
}

test "CpuModel: toStr values" {
    try std.testing.expectEqualStrings("host", std.mem.span(CpuModel.host.toStr()));
    try std.testing.expectEqualStrings("max", std.mem.span(CpuModel.max.toStr()));
    try std.testing.expectEqualStrings("qemu64", std.mem.span(CpuModel.qemu64.toStr()));
    try std.testing.expectEqualStrings("kvm64", std.mem.span(CpuModel.kvm64.toStr()));
    try std.testing.expectEqualStrings("EPYC", std.mem.span(CpuModel.EPYC.toStr()));
    try std.testing.expectEqualStrings("EPYC-Rome", std.mem.span(CpuModel.EPYC_Rome.toStr()));
    try std.testing.expectEqualStrings("EPYC-Milan", std.mem.span(CpuModel.EPYC_Milan.toStr()));
    try std.testing.expectEqualStrings("Skylake-Server", std.mem.span(CpuModel.Skylake_Server.toStr()));
    try std.testing.expectEqualStrings("Skylake-Client", std.mem.span(CpuModel.Skylake_Client.toStr()));
    try std.testing.expectEqualStrings("Icelake-Server", std.mem.span(CpuModel.Icelake_Server.toStr()));
    try std.testing.expectEqualStrings("Cascadelake-Server", std.mem.span(CpuModel.Cascadelake_Server.toStr()));
    try std.testing.expectEqualStrings("Nehalem", std.mem.span(CpuModel.Nehalem.toStr()));
    try std.testing.expectEqualStrings("Westmere", std.mem.span(CpuModel.Westmere.toStr()));
    try std.testing.expectEqualStrings("SandyBridge", std.mem.span(CpuModel.SandyBridge.toStr()));
    try std.testing.expectEqualStrings("IvyBridge", std.mem.span(CpuModel.IvyBridge.toStr()));
    try std.testing.expectEqualStrings("Haswell", std.mem.span(CpuModel.Haswell.toStr()));
    try std.testing.expectEqualStrings("Broadwell", std.mem.span(CpuModel.Broadwell.toStr()));
    try std.testing.expectEqualStrings("Opteron_G5", std.mem.span(CpuModel.Opteron_G5.toStr()));
    try std.testing.expectEqualStrings("host-passthrough", std.mem.span(CpuModel.host_passthrough.toStr()));
    try std.testing.expectEqualStrings("Cooperlake", std.mem.span(CpuModel.Cooperlake.toStr()));
    try std.testing.expectEqualStrings("SapphireRapids", std.mem.span(CpuModel.SapphireRapids.toStr()));
    try std.testing.expectEqualStrings("GraniteRapids", std.mem.span(CpuModel.GraniteRapids.toStr()));
    try std.testing.expectEqualStrings("Neoverse-N1", std.mem.span(CpuModel.Neoverse_N1.toStr()));
    try std.testing.expectEqualStrings("Neoverse-N2", std.mem.span(CpuModel.Neoverse_N2.toStr()));
    try std.testing.expectEqualStrings("Neoverse-V1", std.mem.span(CpuModel.Neoverse_V1.toStr()));
    try std.testing.expectEqualStrings("aarch64", std.mem.span(CpuModel.aarch64.toStr()));
}

test "CpuModel: label values" {
    try std.testing.expectEqualStrings("Host (default)", std.mem.span(CpuModel.host.label()));
    try std.testing.expectEqualStrings("Max (all features)", std.mem.span(CpuModel.max.label()));
    try std.testing.expectEqualStrings("QEMU 64-bit", std.mem.span(CpuModel.qemu64.label()));
    try std.testing.expectEqualStrings("KVM 64-bit", std.mem.span(CpuModel.kvm64.label()));
    try std.testing.expectEqualStrings("AMD EPYC", std.mem.span(CpuModel.EPYC.label()));
    try std.testing.expectEqualStrings("Intel Haswell", std.mem.span(CpuModel.Haswell.label()));
    try std.testing.expectEqualStrings("ARM Neoverse N1", std.mem.span(CpuModel.Neoverse_N1.label()));
}

test "CpuModel: fromStr round-trip" {
    for (0..CpuModel.count) |i| {
        const cm = CpuModel.fromIndex(i);
        try std.testing.expectEqual(cm, CpuModel.fromStr(std.mem.span(cm.toStr())));
    }
    try std.testing.expectEqual(CpuModel.host, CpuModel.fromStr("unknown"));
    try std.testing.expectEqual(CpuModel.host, CpuModel.fromStr(""));
}

// -- NetworkMode --

test "NetworkMode: fromIndex round-trip" {
    try std.testing.expectEqual(NetworkMode.user, NetworkMode.fromIndex(0));
    try std.testing.expectEqual(NetworkMode.bridge, NetworkMode.fromIndex(1));
    try std.testing.expectEqual(NetworkMode.none, NetworkMode.fromIndex(2));
    try std.testing.expectEqual(NetworkMode.user, NetworkMode.fromIndex(99));
}

test "NetworkMode: toIndex inverts fromIndex" {
    for (0..NetworkMode.count) |i| {
        try std.testing.expectEqual(i, NetworkMode.fromIndex(i).toIndex());
    }
}

test "NetworkMode: toStr values" {
    try std.testing.expectEqualStrings("user", std.mem.span(NetworkMode.user.toStr()));
    try std.testing.expectEqualStrings("bridge", std.mem.span(NetworkMode.bridge.toStr()));
    try std.testing.expectEqualStrings("none", std.mem.span(NetworkMode.none.toStr()));
}

test "NetworkMode: label values" {
    try std.testing.expectEqualStrings("NAT (User mode)", std.mem.span(NetworkMode.user.label()));
    try std.testing.expectEqualStrings("Bridged", std.mem.span(NetworkMode.bridge.label()));
    try std.testing.expectEqualStrings("None", std.mem.span(NetworkMode.none.label()));
}

// -- DisplayType --

test "DisplayType: fromIndex round-trip" {
    try std.testing.expectEqual(DisplayType.gtk, DisplayType.fromIndex(0));
    try std.testing.expectEqual(DisplayType.sdl, DisplayType.fromIndex(1));
    try std.testing.expectEqual(DisplayType.spice, DisplayType.fromIndex(2));
    try std.testing.expectEqual(DisplayType.vnc, DisplayType.fromIndex(3));
    try std.testing.expectEqual(DisplayType.none, DisplayType.fromIndex(4));
    try std.testing.expectEqual(DisplayType.gtk, DisplayType.fromIndex(99));
}

test "DisplayType: toIndex inverts fromIndex" {
    for (0..DisplayType.count) |i| {
        try std.testing.expectEqual(i, DisplayType.fromIndex(i).toIndex());
    }
}

test "DisplayType: toStr values" {
    try std.testing.expectEqualStrings("gtk", std.mem.span(DisplayType.gtk.toStr()));
    try std.testing.expectEqualStrings("sdl", std.mem.span(DisplayType.sdl.toStr()));
    try std.testing.expectEqualStrings("spice-app", std.mem.span(DisplayType.spice.toStr()));
    try std.testing.expectEqualStrings("vnc", std.mem.span(DisplayType.vnc.toStr()));
    try std.testing.expectEqualStrings("none", std.mem.span(DisplayType.none.toStr()));
}

test "DisplayType: label values" {
    try std.testing.expectEqualStrings("GTK", std.mem.span(DisplayType.gtk.label()));
    try std.testing.expectEqualStrings("SDL", std.mem.span(DisplayType.sdl.label()));
    try std.testing.expectEqualStrings("SPICE", std.mem.span(DisplayType.spice.label()));
    try std.testing.expectEqualStrings("VNC", std.mem.span(DisplayType.vnc.label()));
    try std.testing.expectEqualStrings("None (headless)", std.mem.span(DisplayType.none.label()));
}

// -- BootFirmware --

test "BootFirmware: fromIndex round-trip" {
    try std.testing.expectEqual(BootFirmware.bios, BootFirmware.fromIndex(0));
    try std.testing.expectEqual(BootFirmware.uefi, BootFirmware.fromIndex(1));
    try std.testing.expectEqual(BootFirmware.bios, BootFirmware.fromIndex(99));
}

test "BootFirmware: toIndex inverts fromIndex" {
    for (0..BootFirmware.count) |i| {
        try std.testing.expectEqual(i, BootFirmware.fromIndex(i).toIndex());
    }
}

test "BootFirmware: toStr values" {
    try std.testing.expectEqualStrings("bios", std.mem.span(BootFirmware.bios.toStr()));
    try std.testing.expectEqualStrings("uefi", std.mem.span(BootFirmware.uefi.toStr()));
}

test "BootFirmware: label values" {
    try std.testing.expectEqualStrings("BIOS (SeaBIOS)", std.mem.span(BootFirmware.bios.label()));
    try std.testing.expectEqualStrings("UEFI (OVMF)", std.mem.span(BootFirmware.uefi.label()));
}

// -- VmStatus --

test "VmStatus: toStr values" {
    try std.testing.expectEqualStrings("stopped", std.mem.span(VmStatus.stopped.toStr()));
    try std.testing.expectEqualStrings("running", std.mem.span(VmStatus.running.toStr()));
    try std.testing.expectEqualStrings("paused", std.mem.span(VmStatus.paused.toStr()));
    try std.testing.expectEqualStrings("suspended", std.mem.span(VmStatus.suspended.toStr()));
}

// -- GuestOs --

test "GuestOs: fromIndex round-trip" {
    try std.testing.expectEqual(GuestOs.linux, GuestOs.fromIndex(0));
    try std.testing.expectEqual(GuestOs.windows, GuestOs.fromIndex(1));
    try std.testing.expectEqual(GuestOs.freebsd, GuestOs.fromIndex(2));
    try std.testing.expectEqual(GuestOs.macos, GuestOs.fromIndex(3));
    try std.testing.expectEqual(GuestOs.other, GuestOs.fromIndex(4));
    try std.testing.expectEqual(GuestOs.other, GuestOs.fromIndex(99));
}

test "GuestOs: toIndex inverts fromIndex" {
    for (0..GuestOs.count) |i| {
        try std.testing.expectEqual(i, GuestOs.fromIndex(i).toIndex());
    }
}

test "GuestOs: toStr values" {
    try std.testing.expectEqualStrings("linux", std.mem.span(GuestOs.linux.toStr()));
    try std.testing.expectEqualStrings("windows", std.mem.span(GuestOs.windows.toStr()));
    try std.testing.expectEqualStrings("freebsd", std.mem.span(GuestOs.freebsd.toStr()));
    try std.testing.expectEqualStrings("macos", std.mem.span(GuestOs.macos.toStr()));
    try std.testing.expectEqualStrings("other", std.mem.span(GuestOs.other.toStr()));
}

test "GuestOs: label values" {
    try std.testing.expectEqualStrings("Linux", std.mem.span(GuestOs.linux.label()));
    try std.testing.expectEqualStrings("Microsoft Windows", std.mem.span(GuestOs.windows.label()));
    try std.testing.expectEqualStrings("FreeBSD", std.mem.span(GuestOs.freebsd.label()));
    try std.testing.expectEqualStrings("Apple macOS", std.mem.span(GuestOs.macos.label()));
    try std.testing.expectEqualStrings("Other", std.mem.span(GuestOs.other.label()));
}

// -- AudioDevice --

test "AudioDevice: fromIndex round-trip" {
    try std.testing.expectEqual(AudioDevice.none, AudioDevice.fromIndex(0));
    try std.testing.expectEqual(AudioDevice.hda, AudioDevice.fromIndex(1));
    try std.testing.expectEqual(AudioDevice.ac97, AudioDevice.fromIndex(2));
    try std.testing.expectEqual(AudioDevice.none, AudioDevice.fromIndex(99));
}

test "AudioDevice: toIndex inverts fromIndex" {
    for (0..AudioDevice.count) |i| {
        try std.testing.expectEqual(i, AudioDevice.fromIndex(i).toIndex());
    }
}

test "AudioDevice: toStr values" {
    try std.testing.expectEqualStrings("none", std.mem.span(AudioDevice.none.toStr()));
    try std.testing.expectEqualStrings("intel-hda", std.mem.span(AudioDevice.hda.toStr()));
    try std.testing.expectEqualStrings("AC97", std.mem.span(AudioDevice.ac97.toStr()));
}

test "AudioDevice: label values" {
    try std.testing.expectEqualStrings("None", std.mem.span(AudioDevice.none.label()));
    try std.testing.expectEqualStrings("Intel HDA", std.mem.span(AudioDevice.hda.label()));
    try std.testing.expectEqualStrings("AC97", std.mem.span(AudioDevice.ac97.label()));
}

// -- BootOrder --

test "BootOrder: fromIndex round-trip" {
    try std.testing.expectEqual(BootOrder.disk_first, BootOrder.fromIndex(0));
    try std.testing.expectEqual(BootOrder.cdrom_first, BootOrder.fromIndex(1));
    try std.testing.expectEqual(BootOrder.network_first, BootOrder.fromIndex(2));
    try std.testing.expectEqual(BootOrder.disk_first, BootOrder.fromIndex(99));
}

test "BootOrder: toIndex inverts fromIndex" {
    for (0..BootOrder.count) |i| {
        try std.testing.expectEqual(i, BootOrder.fromIndex(i).toIndex());
    }
}

test "BootOrder: toStr values" {
    try std.testing.expectEqualStrings("cdn", std.mem.span(BootOrder.disk_first.toStr()));
    try std.testing.expectEqualStrings("dcn", std.mem.span(BootOrder.cdrom_first.toStr()));
    try std.testing.expectEqualStrings("ncd", std.mem.span(BootOrder.network_first.toStr()));
}

test "BootOrder: label values" {
    try std.testing.expectEqualStrings("Hard Disk", std.mem.span(BootOrder.disk_first.label()));
    try std.testing.expectEqualStrings("CD/DVD", std.mem.span(BootOrder.cdrom_first.label()));
    try std.testing.expectEqualStrings("Network (PXE)", std.mem.span(BootOrder.network_first.label()));
}

// -- VmStatus (full standard suite) --

test "VmStatus: fromIndex round-trip" {
    try std.testing.expectEqual(VmStatus.stopped, VmStatus.fromIndex(0));
    try std.testing.expectEqual(VmStatus.running, VmStatus.fromIndex(1));
    try std.testing.expectEqual(VmStatus.paused, VmStatus.fromIndex(2));
    try std.testing.expectEqual(VmStatus.suspended, VmStatus.fromIndex(3));
    // Out-of-range defaults to .stopped
    try std.testing.expectEqual(VmStatus.stopped, VmStatus.fromIndex(99));
}

test "VmStatus: toIndex inverts fromIndex" {
    for (0..VmStatus.count) |i| {
        try std.testing.expectEqual(i, VmStatus.fromIndex(i).toIndex());
    }
}

test "VmStatus: label values" {
    try std.testing.expectEqualStrings("Powered Off", std.mem.span(VmStatus.stopped.label()));
    try std.testing.expectEqualStrings("Powered On", std.mem.span(VmStatus.running.label()));
    try std.testing.expectEqualStrings("Paused", std.mem.span(VmStatus.paused.label()));
    try std.testing.expectEqualStrings("Suspended", std.mem.span(VmStatus.suspended.label()));
}

test "VmStatus: fromStr values" {
    try std.testing.expectEqual(VmStatus.stopped, VmStatus.fromStr("stopped"));
    try std.testing.expectEqual(VmStatus.running, VmStatus.fromStr("running"));
    try std.testing.expectEqual(VmStatus.paused, VmStatus.fromStr("paused"));
    try std.testing.expectEqual(VmStatus.suspended, VmStatus.fromStr("suspended"));
}

test "VmStatus: fromStr unknown defaults to stopped" {
    try std.testing.expectEqual(VmStatus.stopped, VmStatus.fromStr("invalid"));
    try std.testing.expectEqual(VmStatus.stopped, VmStatus.fromStr(""));
}

// -- DisplayResolution (full standard suite) --

test "DisplayResolution: fromIndex round-trip" {
    try std.testing.expectEqual(DisplayResolution.auto, DisplayResolution.fromIndex(0));
    try std.testing.expectEqual(DisplayResolution.res_800x600, DisplayResolution.fromIndex(1));
    try std.testing.expectEqual(DisplayResolution.res_1024x768, DisplayResolution.fromIndex(2));
    try std.testing.expectEqual(DisplayResolution.res_1280x800, DisplayResolution.fromIndex(3));
    try std.testing.expectEqual(DisplayResolution.res_1920x1080, DisplayResolution.fromIndex(4));
    // Out-of-range defaults to .auto
    try std.testing.expectEqual(DisplayResolution.auto, DisplayResolution.fromIndex(99));
}

test "DisplayResolution: toIndex inverts fromIndex" {
    for (0..DisplayResolution.count) |i| {
        try std.testing.expectEqual(i, DisplayResolution.fromIndex(i).toIndex());
    }
}

test "DisplayResolution: toStr values" {
    try std.testing.expectEqualStrings("auto", std.mem.span(DisplayResolution.auto.toStr()));
    try std.testing.expectEqualStrings("800x600", std.mem.span(DisplayResolution.res_800x600.toStr()));
    try std.testing.expectEqualStrings("1024x768", std.mem.span(DisplayResolution.res_1024x768.toStr()));
    try std.testing.expectEqualStrings("1280x800", std.mem.span(DisplayResolution.res_1280x800.toStr()));
    try std.testing.expectEqualStrings("1920x1080", std.mem.span(DisplayResolution.res_1920x1080.toStr()));
}

test "DisplayResolution: label values" {
    try std.testing.expectEqualStrings("Auto", std.mem.span(DisplayResolution.auto.label()));
    try std.testing.expectEqualStrings("800x600", std.mem.span(DisplayResolution.res_800x600.label()));
    try std.testing.expectEqualStrings("1024x768", std.mem.span(DisplayResolution.res_1024x768.label()));
    try std.testing.expectEqualStrings("1280x800", std.mem.span(DisplayResolution.res_1280x800.label()));
    try std.testing.expectEqualStrings("1920x1080", std.mem.span(DisplayResolution.res_1920x1080.label()));
}

test "DisplayResolution: xres/yres values" {
    try std.testing.expectEqual(@as(u32, 0), DisplayResolution.auto.xres());
    try std.testing.expectEqual(@as(u32, 0), DisplayResolution.auto.yres());
    try std.testing.expectEqual(@as(u32, 800), DisplayResolution.res_800x600.xres());
    try std.testing.expectEqual(@as(u32, 600), DisplayResolution.res_800x600.yres());
    try std.testing.expectEqual(@as(u32, 1024), DisplayResolution.res_1024x768.xres());
    try std.testing.expectEqual(@as(u32, 768), DisplayResolution.res_1024x768.yres());
    try std.testing.expectEqual(@as(u32, 1280), DisplayResolution.res_1280x800.xres());
    try std.testing.expectEqual(@as(u32, 800), DisplayResolution.res_1280x800.yres());
    try std.testing.expectEqual(@as(u32, 1920), DisplayResolution.res_1920x1080.xres());
    try std.testing.expectEqual(@as(u32, 1080), DisplayResolution.res_1920x1080.yres());
}

test "DisplayResolution: fromStr round-trip" {
    for (0..DisplayResolution.count) |i| {
        const dr = DisplayResolution.fromIndex(i);
        try std.testing.expectEqual(dr, DisplayResolution.fromStr(std.mem.span(dr.toStr())));
    }
    try std.testing.expectEqual(DisplayResolution.auto, DisplayResolution.fromStr("unknown"));
    try std.testing.expectEqual(DisplayResolution.auto, DisplayResolution.fromStr(""));
}

// -- Extended enum counts --

test "enum counts: AudioDevice, BootOrder, DisplayResolution" {
    try std.testing.expectEqual(@as(usize, 3), AudioDevice.count);
    try std.testing.expectEqual(@as(usize, 3), BootOrder.count);
    try std.testing.expectEqual(@as(usize, 5), DisplayResolution.count);
}

// -- VmConfig predicates with non-default states --

test "VmConfig: isAlive true when running or paused" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.isAlive());

    cfg.status = .running;
    try std.testing.expect(cfg.isAlive());
    try std.testing.expect(cfg.isRunning());
    try std.testing.expect(!cfg.isPaused());

    cfg.status = .paused;
    try std.testing.expect(cfg.isAlive());
    try std.testing.expect(!cfg.isRunning());
    try std.testing.expect(cfg.isPaused());

    cfg.status = .suspended;
    try std.testing.expect(!cfg.isAlive());
    try std.testing.expect(!cfg.isRunning());
    try std.testing.expect(!cfg.isPaused());
    try std.testing.expect(cfg.isStopped());
}

// -- VmConfig accessor round-trips for notes, port-forwards, saved-state --

test "VmConfig: notes round-trip" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasNotes());

    cfg.setNotes("Test notes\nLine 2");
    try std.testing.expect(cfg.hasNotes());
    try std.testing.expectEqualStrings("Test notes\nLine 2", cfg.getNotesSlice());
    try std.testing.expectEqualStrings("Test notes\nLine 2", std.mem.span(cfg.getNotes()));

    cfg.clearNotes();
    try std.testing.expect(!cfg.hasNotes());
    try std.testing.expectEqual(@as(usize, 0), cfg.getNotesSlice().len);
}

test "VmConfig: port forwards round-trip" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasPortForwards());

    cfg.setPortForwards("8080:80,2222:22");
    try std.testing.expect(cfg.hasPortForwards());
    try std.testing.expectEqualStrings("8080:80,2222:22", cfg.getPortForwardsSlice());
    try std.testing.expectEqualStrings("8080:80,2222:22", std.mem.span(cfg.getPortForwards()));

    cfg.clearPortForwards();
    try std.testing.expect(!cfg.hasPortForwards());
}

test "VmConfig: saved state path round-trip" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasSavedState());

    cfg.setSavedStatePath("/tmp/vm.state");
    try std.testing.expect(cfg.hasSavedState());
    try std.testing.expectEqualStrings("/tmp/vm.state", cfg.getSavedStatePathSlice());
    try std.testing.expectEqualStrings("/tmp/vm.state", std.mem.span(cfg.getSavedStatePath()));

    cfg.clearSavedStatePath();
    try std.testing.expect(!cfg.hasSavedState());
}

// -- Platform accelerator helpers --

test "VmConfig: accelName and accelFlag return non-empty" {
    const name = std.mem.span(VmConfig.accelName());
    const flag = std.mem.span(VmConfig.accelFlag());
    try std.testing.expect(name.len > 0);
    try std.testing.expect(flag.len > 0);
}

// ── Fuzz tests ──────────────────────────────────────────────────────
//
// Deterministic PRNG-driven fuzzing: feed each input-facing API thousands of
// random and adversarial inputs and assert it never crashes (no OOB/overflow/
// UB) and that documented invariants hold. Reproducible via the fixed seed.

test "fuzz: string setters clamp arbitrary input and stay null-terminated" {
    var prng = std.Random.DefaultPrng.init(0xF0F0_1234);
    const rnd = prng.random();
    var cfg = VmConfig{};
    var buf: [6000]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        const input = buf[0..len];

        // Each setter must clamp to its capacity, copy the matching prefix,
        // and NUL-terminate. cap = buffer length minus the NUL slot.
        const Case = struct { set: *const fn (*VmConfig, []const u8) void, get: *const fn (*const VmConfig) []const u8, cap: usize };
        const cases = [_]Case{
            .{ .set = VmConfig.setName, .get = VmConfig.getNameSlice, .cap = MAX_NAME },
            .{ .set = VmConfig.setDiskPath, .get = VmConfig.getDiskPathSlice, .cap = MAX_PATH },
            .{ .set = VmConfig.setIsoPath, .get = VmConfig.getIsoPathSlice, .cap = MAX_PATH },
            .{ .set = VmConfig.setMacAddress, .get = VmConfig.getMacAddressSlice, .cap = 17 },
            .{ .set = VmConfig.setNotes, .get = VmConfig.getNotesSlice, .cap = 4095 },
            .{ .set = VmConfig.setPortForwards, .get = VmConfig.getPortForwardsSlice, .cap = 511 },
            .{ .set = VmConfig.setSavedStatePath, .get = VmConfig.getSavedStatePathSlice, .cap = MAX_PATH },
            .{ .set = VmConfig.setSharedFolder, .get = VmConfig.getSharedFolderSlice, .cap = MAX_PATH },
            .{ .set = VmConfig.setDisk2Path, .get = VmConfig.getDisk2PathSlice, .cap = MAX_PATH },
            .{ .set = VmConfig.setUsbDevice, .get = VmConfig.getUsbDeviceSlice, .cap = 63 },
            .{ .set = VmConfig.setFloppyPath, .get = VmConfig.getFloppyPathSlice, .cap = MAX_PATH },
        };
        for (cases) |c| {
            c.set(&cfg, input);
            const out = c.get(&cfg);
            const want = @min(len, c.cap);
            try std.testing.expectEqual(want, out.len);
            try std.testing.expectEqualSlices(u8, input[0..want], out);
        }
    }
}

test "fuzz: enum fromIndex always yields a valid variant" {
    var prng = std.Random.DefaultPrng.init(0xBEEF_5678);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const i = rnd.int(usize);
        // Every enum's fromIndex must map ANY usize to an in-range variant
        // whose toIndex stays below count (no @enumFromInt UB).
        try std.testing.expect(DiskFormat.fromIndex(i).toIndex() < DiskFormat.count);
        try std.testing.expect(NetworkMode.fromIndex(i).toIndex() < NetworkMode.count);
        try std.testing.expect(DisplayResolution.fromIndex(i).toIndex() < DisplayResolution.count);
        try std.testing.expect(DisplayType.fromIndex(i).toIndex() < DisplayType.count);
        try std.testing.expect(VmStatus.fromIndex(i).toIndex() < VmStatus.count);
        try std.testing.expect(GuestOs.fromIndex(i).toIndex() < GuestOs.count);
        try std.testing.expect(BootOrder.fromIndex(i).toIndex() < BootOrder.count);
        try std.testing.expect(AudioDevice.fromIndex(i).toIndex() < AudioDevice.count);
        try std.testing.expect(BootFirmware.fromIndex(i).toIndex() < BootFirmware.count);
        try std.testing.expect(GpuDevice.fromIndex(i).toIndex() < GpuDevice.count);
        try std.testing.expect(UsbPolicy.fromIndex(i).toIndex() < UsbPolicy.count);
        try std.testing.expect(Theme.fromIndex(i).toIndex() < Theme.count);
        try std.testing.expect(DiskCache.fromIndex(i).toIndex() < DiskCache.count);
        try std.testing.expect(VmAccel.fromIndex(i).toIndex() < VmAccel.count);
        try std.testing.expect(CpuModel.fromIndex(i).toIndex() < CpuModel.count);
        try std.testing.expect(WatchdogAction.fromIndex(i).toIndex() < WatchdogAction.count);
    }
}

test "fuzz: Theme.fromStr always returns a valid variant" {
    var prng = std.Random.DefaultPrng.init(0x7E_ABCD);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        try std.testing.expect(Theme.fromStr(buf[0..n]).toIndex() < Theme.count);
    }
}

test "fuzz: generateMacAddress always valid locally-administered unicast" {
    var b: [18]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const mac = std.mem.span(generateMacAddress(&b));
        try std.testing.expectEqual(@as(usize, 17), mac.len);
        // First octet: locally administered (bit1 set) + unicast (bit0 clear).
        const first = try std.fmt.parseInt(u8, mac[0..2], 16);
        try std.testing.expectEqual(@as(u8, 0x02), first & 0x03);
    }
}

// ── Theme enum: concrete value coverage (fuzz only checked validity) ──

test "Theme: fromIndex concrete + out-of-range default" {
    try std.testing.expectEqual(Theme.system, Theme.fromIndex(0));
    try std.testing.expectEqual(Theme.light, Theme.fromIndex(1));
    try std.testing.expectEqual(Theme.dark, Theme.fromIndex(2));
    try std.testing.expectEqual(Theme.light, Theme.fromIndex(99));
}

test "Theme: toStr values" {
    try std.testing.expectEqualStrings("system", std.mem.span(Theme.system.toStr()));
    try std.testing.expectEqualStrings("light", std.mem.span(Theme.light.toStr()));
    try std.testing.expectEqualStrings("dark", std.mem.span(Theme.dark.toStr()));
}

test "Theme: fromStr concrete + unknown default" {
    try std.testing.expectEqual(Theme.system, Theme.fromStr("system"));
    try std.testing.expectEqual(Theme.light, Theme.fromStr("light"));
    try std.testing.expectEqual(Theme.dark, Theme.fromStr("dark"));
    try std.testing.expectEqual(Theme.light, Theme.fromStr("nonsense"));
}

test "Theme: label values non-empty + toIndex inverts fromIndex" {
    for (0..Theme.count) |i| {
        const t = Theme.fromIndex(i);
        try std.testing.expectEqual(i, t.toIndex());
        try std.testing.expect(std.mem.span(t.label()).len > 0);
    }
}

// ── Accessor families that previously lacked direct tests ──
// shared_folder / disk2 / usb_device / nic2_mac / nic3_mac / floppy all follow
// the get / getSlice / set / clear / has pattern. Assert round-trip, the C-string
// (NUL-terminated) form, has-flag transitions, and clear.

test "VmConfig: shared folder get/set/clear/has" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasSharedFolder());
    cfg.setSharedFolder("/mnt/share");
    try std.testing.expect(cfg.hasSharedFolder());
    try std.testing.expectEqualStrings("/mnt/share", cfg.getSharedFolderSlice());
    try std.testing.expectEqualStrings("/mnt/share", std.mem.span(cfg.getSharedFolder()));
    cfg.clearSharedFolder();
    try std.testing.expect(!cfg.hasSharedFolder());
    try std.testing.expectEqual(@as(usize, 0), cfg.getSharedFolderSlice().len);
}

test "VmConfig: disk2 get/set/clear/has" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasDisk2());
    cfg.setDisk2Path("/tmp/data.qcow2");
    try std.testing.expect(cfg.hasDisk2());
    try std.testing.expectEqualStrings("/tmp/data.qcow2", cfg.getDisk2PathSlice());
    try std.testing.expectEqualStrings("/tmp/data.qcow2", std.mem.span(cfg.getDisk2Path()));
    cfg.clearDisk2Path();
    try std.testing.expect(!cfg.hasDisk2());
}

test "VmConfig: usb device get/set/clear/has" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasUsbDevice());
    cfg.setUsbDevice("1234:5678");
    try std.testing.expect(cfg.hasUsbDevice());
    try std.testing.expectEqualStrings("1234:5678", cfg.getUsbDeviceSlice());
    try std.testing.expectEqualStrings("1234:5678", std.mem.span(cfg.getUsbDevice()));
    cfg.clearUsbDevice();
    try std.testing.expect(!cfg.hasUsbDevice());
}

test "VmConfig: floppy get/set/clear/has" {
    var cfg = VmConfig{};
    try std.testing.expect(!cfg.hasFloppy());
    cfg.setFloppyPath("/tmp/boot.img");
    try std.testing.expect(cfg.hasFloppy());
    try std.testing.expectEqualStrings("/tmp/boot.img", cfg.getFloppyPathSlice());
    try std.testing.expectEqualStrings("/tmp/boot.img", std.mem.span(cfg.getFloppyPath()));
    cfg.clearFloppyPath();
    try std.testing.expect(!cfg.hasFloppy());
}

test "VmConfig: nic2/nic3 MAC get/set" {
    var cfg = VmConfig{};
    cfg.setNic2Mac("AA:BB:CC:DD:EE:01");
    cfg.setNic3Mac("AA:BB:CC:DD:EE:02");
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:01", cfg.getNic2MacSlice());
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:01", std.mem.span(cfg.getNic2Mac()));
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:02", cfg.getNic3MacSlice());
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:02", std.mem.span(cfg.getNic3Mac()));
}

test "fuzz: nic2/nic3 + secondary string setters clamp and stay NUL-terminated" {
    var prng = std.Random.DefaultPrng.init(0xF10DDA7A);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*c| c.* = rnd.int(u8);
        const s = buf[0..n];
        var cfg = VmConfig{};
        cfg.setNic2Mac(s);
        cfg.setNic3Mac(s);
        cfg.setSharedFolder(s);
        cfg.setDisk2Path(s);
        cfg.setUsbDevice(s);
        cfg.setFloppyPath(s);
        // Every slice must stay within its buffer; the C-string span never
        // exceeds the tracked slice length (it stops at an embedded NUL, which
        // arbitrary fuzz bytes can introduce — real paths/MACs never do).
        try std.testing.expect(cfg.getNic2MacSlice().len < 18);
        try std.testing.expect(cfg.getNic3MacSlice().len < 18);
        try std.testing.expect(std.mem.span(cfg.getSharedFolder()).len <= cfg.getSharedFolderSlice().len);
        try std.testing.expect(std.mem.span(cfg.getDisk2Path()).len <= cfg.getDisk2PathSlice().len);
        try std.testing.expect(std.mem.span(cfg.getUsbDevice()).len <= cfg.getUsbDeviceSlice().len);
        try std.testing.expect(std.mem.span(cfg.getFloppyPath()).len <= cfg.getFloppyPathSlice().len);
    }
}

// ── Missing standalone coverage: clearSavedStatePath, clearPortForwards,
//    nic2/nic3 MAC clear, setNotes/setPortForwards truncation, empty-string
//    setters, disk2/usb/floppy C-string accessors ──

test "VmConfig: clearSavedStatePath standalone" {
    var cfg = VmConfig{};
    cfg.setSavedStatePath("/tmp/state.bin");
    try std.testing.expect(cfg.hasSavedState());
    cfg.clearSavedStatePath();
    try std.testing.expect(!cfg.hasSavedState());
    try std.testing.expectEqual(@as(u16, 0), cfg.saved_state_path_len);
    try std.testing.expectEqualStrings("", cfg.getSavedStatePathSlice());
    try std.testing.expectEqual(@as(u8, 0), cfg.saved_state_path_buf[0]);
}

test "VmConfig: clearPortForwards standalone" {
    var cfg = VmConfig{};
    cfg.setPortForwards("8080:80");
    try std.testing.expect(cfg.hasPortForwards());
    cfg.clearPortForwards();
    try std.testing.expect(!cfg.hasPortForwards());
    try std.testing.expectEqual(@as(u16, 0), cfg.port_fwd_len);
    try std.testing.expectEqualStrings("", cfg.getPortForwardsSlice());
}

test "VmConfig: clear nic2/nic3 MAC" {
    var cfg = VmConfig{};
    cfg.setNic2Mac("AA:BB:CC:DD:EE:01");
    cfg.setNic3Mac("AA:BB:CC:DD:EE:02");
    cfg.setNic2Mac("");
    cfg.setNic3Mac("");
    try std.testing.expectEqual(@as(u16, 0), cfg.nics[1].mac_len);
    try std.testing.expectEqual(@as(u16, 0), cfg.nics[2].mac_len);
    try std.testing.expectEqualStrings("", cfg.getNic2MacSlice());
    try std.testing.expectEqualStrings("", cfg.getNic3MacSlice());
}

test "VmConfig: setNotes truncates at 4095" {
    var cfg = VmConfig{};
    const long = "N" ** 5000;
    cfg.setNotes(long);
    try std.testing.expectEqual(@as(u16, 4095), cfg.notes_len);
    try std.testing.expectEqualStrings(long[0..4095], cfg.getNotesSlice());
    try std.testing.expectEqual(@as(u8, 0), cfg.notes_buf[4095]); // NUL-terminated
}

test "VmConfig: setPortForwards truncates at 511" {
    var cfg = VmConfig{};
    const long = "X" ** 600;
    cfg.setPortForwards(long);
    try std.testing.expectEqual(@as(u16, 511), cfg.port_fwd_len);
    try std.testing.expectEqualStrings(long[0..511], cfg.getPortForwardsSlice());
    try std.testing.expectEqual(@as(u8, 0), cfg.port_fwd_buf[511]);
}

test "VmConfig: setDiskPath with empty string" {
    var cfg = VmConfig{};
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.setDiskPath("");
    try std.testing.expect(!cfg.hasDisk());
    try std.testing.expectEqual(@as(u16, 0), cfg.disk_path_len);
}

test "VmConfig: disk2/usb/floppy C-string accessors NUL-terminated" {
    var cfg = VmConfig{};
    cfg.setDisk2Path("/tmp/data.qcow2");
    cfg.setUsbDevice("046d:c52b");
    cfg.setFloppyPath("/tmp/floppy.img");
    try std.testing.expectEqualStrings("/tmp/data.qcow2", std.mem.span(cfg.getDisk2Path()));
    try std.testing.expectEqualStrings("046d:c52b", std.mem.span(cfg.getUsbDevice()));
    try std.testing.expectEqualStrings("/tmp/floppy.img", std.mem.span(cfg.getFloppyPath()));
    // Verify NUL termination after the string.
    try std.testing.expectEqual(@as(u8, 0), cfg.disk2_path_buf[cfg.disk2_path_len]);
    try std.testing.expectEqual(@as(u8, 0), cfg.usb_device_buf[cfg.usb_device_len]);
    try std.testing.expectEqual(@as(u8, 0), cfg.floppy_path_buf[cfg.floppy_path_len]);
}

test "VmConfig: setName/setDiskPath empty string preserves length" {
    var cfg = VmConfig{};
    cfg.setName("Test");
    cfg.setName("");
    try std.testing.expectEqual(@as(u16, 0), cfg.name_len);
    try std.testing.expect(!cfg.hasName());
    try std.testing.expectEqual(@as(u8, 0), cfg.name_buf[0]);
}

test "VmConfig: autoprotect defaults" {
    const cfg = VmConfig{};
    try std.testing.expect(!cfg.autoprotect);
    try std.testing.expectEqual(@as(u32, 1440), cfg.autoprotect_interval_min);
    try std.testing.expectEqual(@as(u32, 3), cfg.autoprotect_max);
    try std.testing.expectEqual(@as(i64, 0), cfg.autoprotect_last_epoch);
    try std.testing.expectEqual(@as(u32, 0), cfg.autoprotect_last_seq);
}

test "VmConfig: guest_tools + enable_3d defaults" {
    const cfg = VmConfig{};
    try std.testing.expect(!cfg.guest_tools);
    try std.testing.expect(!cfg.enable_3d);
}

test "fuzz: VmConfig defaults survive random partial mutation" {
    // Verify that setting fields to random values and then resetting via a
    // fresh VmConfig{} restores ALL defaults (no sticky state).
    var prng = std.Random.DefaultPrng.init(0x5EED_DEFA);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var cfg = VmConfig{};
        // Apply random mutations to every field.
        cfg.cpu_cores = rnd.int(u32);
        cfg.cpu_sockets = rnd.int(u32);
        cfg.memory_mb = rnd.int(u32);
        cfg.disk_size_gb = rnd.int(u32);
        cfg.accel = VmAccel.fromIndex(rnd.int(usize));
        cfg.enable_serial = rnd.boolean();
        cfg.virtio_rng = rnd.boolean();
        cfg.guest_agent = rnd.boolean();
        cfg.watchdog = WatchdogAction.fromIndex(rnd.int(usize));
        cfg.tpm = rnd.boolean();
        cfg.secure_boot = rnd.boolean();
        cfg.hyperv_enlightenments = rnd.boolean();
        cfg.hugepages = rnd.boolean();
        cfg.io_threads = rnd.int(u32);
        cfg.disk_bps_throttle = rnd.int(u64);
        cfg.disk_iops_throttle = rnd.int(u32);
        cfg.ballooning = rnd.boolean();
        cfg.host_autostart = rnd.boolean();
        cfg.embed_display = rnd.boolean();
        cfg.enable_3d = rnd.boolean();
        cfg.guest_tools = rnd.boolean();
        cfg.autoprotect = rnd.boolean();
        cfg.autoprotect_last_epoch = rnd.int(i64);
        cfg.autoprotect_last_seq = rnd.int(u32);
        cfg.status = VmStatus.fromIndex(rnd.int(usize));
        cfg.pid = if (rnd.boolean()) @as(i32, @intCast(rnd.int(u16))) else null;
        // Reset.
        cfg = VmConfig{};
        try std.testing.expectEqual(@as(u32, 2), cfg.cpu_cores);
        try std.testing.expectEqual(VmAccel.auto, cfg.accel);
        try std.testing.expectEqual(VmStatus.stopped, cfg.status);
        try std.testing.expectEqual(@as(?i32, null), cfg.pid);
        try std.testing.expect(!cfg.autoprotect);
        try std.testing.expectEqual(@as(u32, 1440), cfg.autoprotect_interval_min);
        try std.testing.expectEqual(@as(i64, 0), cfg.autoprotect_last_epoch);
        try std.testing.expectEqual(@as(u32, 0), cfg.autoprotect_last_seq);
        try std.testing.expect(!cfg.virtio_rng);
        try std.testing.expect(!cfg.guest_agent);
        try std.testing.expectEqual(WatchdogAction.none, cfg.watchdog);
        try std.testing.expect(!cfg.tpm);
        try std.testing.expect(!cfg.secure_boot);
        try std.testing.expect(!cfg.hyperv_enlightenments);
        try std.testing.expect(!cfg.hugepages);
        try std.testing.expectEqual(@as(u32, 0), cfg.io_threads);
        try std.testing.expectEqual(@as(u64, 0), cfg.disk_bps_throttle);
        try std.testing.expectEqual(@as(u32, 0), cfg.disk_iops_throttle);
        try std.testing.expect(!cfg.ballooning);
        try std.testing.expect(!cfg.host_autostart);
    }
}

test "isValidVmName: rejects path separators and empty names" {
    try std.testing.expect(isValidVmName("My VM"));
    try std.testing.expect(isValidVmName("test-vm_123"));
    try std.testing.expect(!isValidVmName(""));
    try std.testing.expect(!isValidVmName("   "));
    try std.testing.expect(!isValidVmName("path/name"));
    try std.testing.expect(!isValidVmName("path\\name"));
    try std.testing.expect(!isValidVmName("name\x00embedded"));
}

test "isValidMac: validates MAC format" {
    try std.testing.expect(isValidMac("")); // empty = auto
    try std.testing.expect(isValidMac("00:11:22:33:44:55"));
    try std.testing.expect(isValidMac("AA:BB:CC:DD:EE:FF"));
    try std.testing.expect(isValidMac("aa:bb:cc:dd:ee:ff"));
    try std.testing.expect(!isValidMac("00:11:22:33:44")); // too short
    try std.testing.expect(!isValidMac("00:11:22:33:44:55:66")); // too long
    try std.testing.expect(!isValidMac("00-11-22-33-44-55")); // wrong separator
    try std.testing.expect(!isValidMac("GG:11:22:33:44:55")); // invalid hex
}

test "isValidDisplayPort: validates port range" {
    try std.testing.expect(isValidDisplayPort(5900));
    try std.testing.expect(isValidDisplayPort(5950));
    try std.testing.expect(isValidDisplayPort(5999));
    try std.testing.expect(!isValidDisplayPort(0));
    try std.testing.expect(!isValidDisplayPort(5899));
    try std.testing.expect(!isValidDisplayPort(6000));
    try std.testing.expect(!isValidDisplayPort(65535));
}

test "clampMemory: bounds large and small values" {
    try std.testing.expectEqual(@as(u32, 1), clampMemory(0));
    try std.testing.expectEqual(@as(u32, 1), clampMemory(1));
    try std.testing.expectEqual(@as(u32, 2048), clampMemory(2048));
    try std.testing.expectEqual(@as(u32, 1048576), clampMemory(1048576));
    try std.testing.expectEqual(@as(u32, 1048576), clampMemory(999999999));
}

test "clampCpuCores: bounds large and small values" {
    try std.testing.expectEqual(@as(u32, 1), clampCpuCores(0));
    try std.testing.expectEqual(@as(u32, 1), clampCpuCores(1));
    try std.testing.expectEqual(@as(u32, 4), clampCpuCores(4));
    try std.testing.expectEqual(@as(u32, 256), clampCpuCores(256));
    try std.testing.expectEqual(@as(u32, 256), clampCpuCores(999));
}

test "clampDiskSize: bounds large and small values" {
    try std.testing.expectEqual(@as(u32, 1), clampDiskSize(0));
    try std.testing.expectEqual(@as(u32, 20), clampDiskSize(20));
    try std.testing.expectEqual(@as(u32, 65536), clampDiskSize(65536));
    try std.testing.expectEqual(@as(u32, 65536), clampDiskSize(999999));
}

test "fuzz: isValidVmName never crashes on arbitrary input" {
    var prng = std.Random.DefaultPrng.init(0x5A1E_0001);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const n = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..n]) |*c| c.* = rnd.int(u8);
        _ = isValidVmName(buf[0..n]); // must not crash
    }
}

test "fuzz: isValidMac never crashes on arbitrary input" {
    var prng = std.Random.DefaultPrng.init(0x5A1E_0002);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const n = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..n]) |*c| c.* = rnd.int(u8);
        _ = isValidMac(buf[0..n]); // must not crash
    }
}

test "GpuDevice: fromIndex round-trip" {
    for (0..GpuDevice.count) |i| {
        const d = GpuDevice.fromIndex(i);
        try std.testing.expectEqual(i, d.toIndex());
    }
}

test "GpuDevice: toIndex inverts fromIndex" {
    const variants = [_]GpuDevice{ .virtio_gpu_gl, .virtio_vga_gl };
    for (variants) |v| {
        try std.testing.expectEqual(v, GpuDevice.fromIndex(v.toIndex()));
    }
}

test "GpuDevice: toStr values" {
    try std.testing.expectEqualStrings("virtio_gpu_gl", std.mem.span(GpuDevice.virtio_gpu_gl.toStr()));
    try std.testing.expectEqualStrings("virtio_vga_gl", std.mem.span(GpuDevice.virtio_vga_gl.toStr()));
}

test "GpuDevice: label values" {
    try std.testing.expectEqualStrings("Virtio-GPU (virgl 3D)", std.mem.span(GpuDevice.virtio_gpu_gl.label()));
    try std.testing.expectEqualStrings("Virtio-VGA (virgl 3D)", std.mem.span(GpuDevice.virtio_vga_gl.label()));
    try std.testing.expectEqualStrings("Virtio-GPU", std.mem.span(GpuDevice.virtio_gpu.label()));
    try std.testing.expectEqualStrings("Virtio-VGA", std.mem.span(GpuDevice.virtio_vga.label()));
    try std.testing.expectEqualStrings("QXL (SPICE)", std.mem.span(GpuDevice.qxl.label()));
    try std.testing.expectEqualStrings("Standard VGA", std.mem.span(GpuDevice.std_vga.label()));
}

test "GpuDevice: needsVirgl only true for GL variants" {
    try std.testing.expect(GpuDevice.virtio_gpu_gl.needsVirgl());
    try std.testing.expect(GpuDevice.virtio_vga_gl.needsVirgl());
    try std.testing.expect(!GpuDevice.virtio_gpu.needsVirgl());
    try std.testing.expect(!GpuDevice.virtio_vga.needsVirgl());
    try std.testing.expect(!GpuDevice.qxl.needsVirgl());
    try std.testing.expect(!GpuDevice.std_vga.needsVirgl());
}

test "GpuDevice: out-of-range fromIndex defaults" {
    try std.testing.expectEqual(GpuDevice.virtio_vga_gl, GpuDevice.fromIndex(99));
}

// -- UsbPolicy --
test "UsbPolicy: fromIndex round-trip" {
    try std.testing.expectEqual(UsbPolicy.none, UsbPolicy.fromIndex(0));
    try std.testing.expectEqual(UsbPolicy.usb2, UsbPolicy.fromIndex(1));
    try std.testing.expectEqual(UsbPolicy.usb3, UsbPolicy.fromIndex(2));
    try std.testing.expectEqual(UsbPolicy.usb2, UsbPolicy.fromIndex(99));
}

test "UsbPolicy: toIndex inverts fromIndex" {
    for (0..UsbPolicy.count) |i| {
        try std.testing.expectEqual(i, UsbPolicy.fromIndex(i).toIndex());
    }
}

test "UsbPolicy: toStr values" {
    try std.testing.expectEqualStrings("none", std.mem.span(UsbPolicy.none.toStr()));
    try std.testing.expectEqualStrings("usb2", std.mem.span(UsbPolicy.usb2.toStr()));
    try std.testing.expectEqualStrings("usb3", std.mem.span(UsbPolicy.usb3.toStr()));
}

test "UsbPolicy: label values" {
    try std.testing.expectEqualStrings("None", std.mem.span(UsbPolicy.none.label()));
    try std.testing.expectEqualStrings("USB 2.0 (EHCI)", std.mem.span(UsbPolicy.usb2.label()));
    try std.testing.expectEqualStrings("USB 3.0 (xHCI)", std.mem.span(UsbPolicy.usb3.label()));
}

test "UsbPolicy: fromStr values" {
    try std.testing.expectEqual(UsbPolicy.none, UsbPolicy.fromStr("none"));
    try std.testing.expectEqual(UsbPolicy.usb2, UsbPolicy.fromStr("usb2"));
    try std.testing.expectEqual(UsbPolicy.usb3, UsbPolicy.fromStr("usb3"));
}

test "UsbPolicy: fromStr unknown defaults to usb2" {
    try std.testing.expectEqual(UsbPolicy.usb2, UsbPolicy.fromStr("invalid"));
    try std.testing.expectEqual(UsbPolicy.usb2, UsbPolicy.fromStr(""));
}

test "NetworkMode: fromStr values" {
    try std.testing.expectEqual(NetworkMode.user, NetworkMode.fromStr("user"));
    try std.testing.expectEqual(NetworkMode.bridge, NetworkMode.fromStr("bridge"));
    try std.testing.expectEqual(NetworkMode.none, NetworkMode.fromStr("none"));
}

test "NetworkMode: fromStr unknown defaults to user" {
    try std.testing.expectEqual(NetworkMode.user, NetworkMode.fromStr("invalid"));
    try std.testing.expectEqual(NetworkMode.user, NetworkMode.fromStr(""));
}

test "BootFirmware: fromStr values" {
    try std.testing.expectEqual(BootFirmware.bios, BootFirmware.fromStr("bios"));
    try std.testing.expectEqual(BootFirmware.uefi, BootFirmware.fromStr("uefi"));
}

test "BootFirmware: fromStr unknown defaults to bios" {
    try std.testing.expectEqual(BootFirmware.bios, BootFirmware.fromStr("invalid"));
    try std.testing.expectEqual(BootFirmware.bios, BootFirmware.fromStr(""));
}

test "GuestOs: fromStr values" {
    try std.testing.expectEqual(GuestOs.linux, GuestOs.fromStr("linux"));
    try std.testing.expectEqual(GuestOs.windows, GuestOs.fromStr("windows"));
    try std.testing.expectEqual(GuestOs.freebsd, GuestOs.fromStr("freebsd"));
    try std.testing.expectEqual(GuestOs.macos, GuestOs.fromStr("macos"));
    try std.testing.expectEqual(GuestOs.other, GuestOs.fromStr("other"));
}

test "GuestOs: fromStr case-insensitive" {
    try std.testing.expectEqual(GuestOs.linux, GuestOs.fromStr("Linux"));
    try std.testing.expectEqual(GuestOs.windows, GuestOs.fromStr("WINDOWS"));
    try std.testing.expectEqual(GuestOs.macos, GuestOs.fromStr("MacOS"));
}

test "GuestOs: fromStr unknown defaults to linux" {
    try std.testing.expectEqual(GuestOs.linux, GuestOs.fromStr(""));
    try std.testing.expectEqual(GuestOs.linux, GuestOs.fromStr("invalid"));
}

test "VmAccel: fromIndex round-trip" {
    for (0..VmAccel.count) |i| {
        const a = VmAccel.fromIndex(i);
        try std.testing.expectEqual(i, a.toIndex());
    }
}

test "VmAccel: toIndex inverts fromIndex" {
    const variants = [_]VmAccel{ .auto, .tcg, .kvm, .hvf, .whpx };
    for (variants) |v| {
        try std.testing.expectEqual(v, VmAccel.fromIndex(v.toIndex()));
    }
}

test "VmAccel: toStr values" {
    try std.testing.expectEqualStrings("auto", std.mem.span(VmAccel.auto.toStr()));
    try std.testing.expectEqualStrings("tcg", std.mem.span(VmAccel.tcg.toStr()));
    try std.testing.expectEqualStrings("kvm", std.mem.span(VmAccel.kvm.toStr()));
    try std.testing.expectEqualStrings("hvf", std.mem.span(VmAccel.hvf.toStr()));
    try std.testing.expectEqualStrings("whpx", std.mem.span(VmAccel.whpx.toStr()));
}

test "VmAccel: label values" {
    try std.testing.expectEqualStrings("Auto (best available)", std.mem.span(VmAccel.auto.label()));
    try std.testing.expectEqualStrings("TCG (software)", std.mem.span(VmAccel.tcg.label()));
    try std.testing.expectEqualStrings("KVM (Linux)", std.mem.span(VmAccel.kvm.label()));
    try std.testing.expectEqualStrings("HVF (macOS)", std.mem.span(VmAccel.hvf.label()));
    try std.testing.expectEqualStrings("WHPX (Windows)", std.mem.span(VmAccel.whpx.label()));
}

test "VmAccel: out-of-range fromIndex defaults" {
    try std.testing.expectEqual(VmAccel.auto, VmAccel.fromIndex(99));
}

test "VmAccel: platformDefault returns a valid variant" {
    const pd = VmAccel.platformDefault();
    _ = pd.toStr(); // must not crash
    _ = pd.label();
}

test "VmConfig: findUnusedVncPort returns first gap" {
    var vms: [4]VmConfig = .{VmConfig{}} ** 4;
    vms[0].vnc_port = 5900;
    vms[1].vnc_port = 5901;
    // 5902 is free
    vms[2].vnc_port = 5903;
    vms[3].vnc_port = 5904;
    try std.testing.expectEqual(@as(u16, 5902), findUnusedVncPort(&vms));
}

test "VmConfig: findUnusedVncPort empty list returns 5900" {
    var vms: [0]VmConfig = .{};
    try std.testing.expectEqual(@as(u16, 5900), findUnusedVncPort(&vms));
}

test "VmConfig: findUnusedVncPort skips used port" {
    var vms: [1]VmConfig = .{VmConfig{}} ** 1;
    vms[0].vnc_port = 5900;
    try std.testing.expectEqual(@as(u16, 5901), findUnusedVncPort(&vms));
}

test "VmConfig: findUnusedSpicePort returns first gap" {
    var vms: [3]VmConfig = .{VmConfig{}} ** 3;
    vms[0].spice_port = 5930;
    vms[1].spice_port = 5931;
    // 5932 is free
    try std.testing.expectEqual(@as(u16, 5932), findUnusedSpicePort(&vms));
}

test "VmConfig: findUnusedSpicePort empty list returns 5930" {
    var vms: [0]VmConfig = .{};
    try std.testing.expectEqual(@as(u16, 5930), findUnusedSpicePort(&vms));
}

test "VmConfig: findUnusedSpicePort wraps at 5999" {
    var vms: [1]VmConfig = .{VmConfig{}} ** 1;
    vms[0].spice_port = 5999;
    try std.testing.expectEqual(@as(u16, 5930), findUnusedSpicePort(&vms));
}

test "DisplayType: fromStr round-trip" {
    inline for (@typeInfo(DisplayType).@"enum".fields) |f| {
        const variant: DisplayType = @enumFromInt(f.value);
        try std.testing.expectEqual(variant, DisplayType.fromStr(std.mem.span(variant.toStr())));
    }
    try std.testing.expectEqual(DisplayType.gtk, DisplayType.fromStr("unknown"));
    try std.testing.expectEqual(DisplayType.gtk, DisplayType.fromStr(""));
}

test "DisplayType: fromStr backward compat spice" {
    try std.testing.expectEqual(DisplayType.spice, DisplayType.fromStr("spice"));
    try std.testing.expectEqual(DisplayType.spice, DisplayType.fromStr("SPICE"));
}

test "BootOrder: fromStr round-trip" {
    inline for (@typeInfo(BootOrder).@"enum".fields) |f| {
        const variant: BootOrder = @enumFromInt(f.value);
        try std.testing.expectEqual(variant, BootOrder.fromStr(std.mem.span(variant.toStr())));
    }
    try std.testing.expectEqual(BootOrder.disk_first, BootOrder.fromStr("unknown"));
    try std.testing.expectEqual(BootOrder.disk_first, BootOrder.fromStr(""));
}

test "AudioDevice: fromStr round-trip" {
    inline for (@typeInfo(AudioDevice).@"enum".fields) |f| {
        const variant: AudioDevice = @enumFromInt(f.value);
        try std.testing.expectEqual(variant, AudioDevice.fromStr(std.mem.span(variant.toStr())));
    }
    try std.testing.expectEqual(AudioDevice.none, AudioDevice.fromStr("unknown"));
    try std.testing.expectEqual(AudioDevice.none, AudioDevice.fromStr(""));
}

test "GpuDevice: fromStr round-trip" {
    inline for (@typeInfo(GpuDevice).@"enum".fields) |f| {
        const variant: GpuDevice = @enumFromInt(f.value);
        try std.testing.expectEqual(variant, GpuDevice.fromStr(std.mem.span(variant.toStr())));
    }
    try std.testing.expectEqual(GpuDevice.virtio_vga_gl, GpuDevice.fromStr("unknown"));
    try std.testing.expectEqual(GpuDevice.virtio_vga_gl, GpuDevice.fromStr(""));
}

test "VmAccel: fromStr round-trip" {
    inline for (@typeInfo(VmAccel).@"enum".fields) |f| {
        const variant: VmAccel = @enumFromInt(f.value);
        try std.testing.expectEqual(variant, VmAccel.fromStr(std.mem.span(variant.toStr())));
    }
    try std.testing.expectEqual(VmAccel.auto, VmAccel.fromStr("unknown"));
    try std.testing.expectEqual(VmAccel.auto, VmAccel.fromStr(""));
}

test "VmConfig: extra disk accessors round-trip" {
    var vm: VmConfig = .{};
    var buf: [MAX_PATH + 1]u8 = undefined;

    // Initially no extra disks.
    for (0..MAX_EXTRA_DISKS) |i| {
        try std.testing.expect(!vm.hasExtraDisk(i));
        try std.testing.expectEqualStrings("", vm.getExtraDiskPathSlice(i));
        try std.testing.expectEqual(0, std.mem.sliceTo(vm.getExtraDiskPath(i), 0).len);
    }

    // Set and verify each extra disk slot.
    for (0..MAX_EXTRA_DISKS) |i| {
        const name = std.fmt.bufPrintZ(&buf, "disk{d}.qcow2", .{i}) catch return;
        vm.setExtraDiskPath(i, name);
        try std.testing.expect(vm.hasExtraDisk(i));
        try std.testing.expectEqualStrings(name, vm.getExtraDiskPathSlice(i));
        try std.testing.expectEqualStrings(name, std.mem.sliceTo(vm.getExtraDiskPath(i), 0));
    }

    // Clear and verify.
    for (0..MAX_EXTRA_DISKS) |i| {
        vm.clearExtraDiskPath(i);
        try std.testing.expect(!vm.hasExtraDisk(i));
        try std.testing.expectEqualStrings("", vm.getExtraDiskPathSlice(i));
    }

    // Path truncation at MAX_PATH.
    var long: [MAX_PATH + 1]u8 = undefined;
    @memset(&long, 'x');
    long[MAX_PATH] = 0;
    vm.setExtraDiskPath(0, long[0..MAX_PATH]);
    try std.testing.expect(vm.hasExtraDisk(0));
    try std.testing.expectEqual(MAX_PATH, vm.getExtraDiskPathSlice(0).len);
}

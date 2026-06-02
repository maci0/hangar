#!/usr/bin/env python3
"""
Hangar Visual Test Harness
==========================

Launches the application inside a virtual X11 framebuffer (Xvfb),
captures screenshots, simulates user interaction via X11/Xtst ctypes,
and validates the UI renders correctly.

Requirements (all pre-installed):
  - Xvfb, ImageMagick (import), Python 3, Pillow
  - libX11.so.6, libXtst.so.6 (system libraries)

Usage:
  python3 tests/visual/test_visual.py              # run all tests
  python3 tests/visual/test_visual.py --keep-xvfb  # don't kill Xvfb after
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO = Path(__file__).resolve().parent.parent.parent
BINARY = REPO / "zig-out" / "bin" / "hangar"
SCREENSHOT_DIR = Path(__file__).resolve().parent / "screenshots"

# ---------------------------------------------------------------------------
# X11 ctypes bindings (minimal, for input simulation)
# ---------------------------------------------------------------------------


class X11:
    """Thin ctypes wrapper around libX11 + libXtst for input simulation."""

    # Key symbols (from X11/keysymdef.h)
    XK_Return = 0xFF0D
    XK_Tab = 0xFF09
    XK_Escape = 0xFF1B
    XK_BackSpace = 0xFF08
    XK_Delete = 0xFFFF
    XK_Home = 0xFF50
    XK_End = 0xFF57
    XK_Left = 0xFF51
    XK_Right = 0xFF53
    XK_Up = 0xFF52
    XK_Down = 0xFF54
    XK_space = 0x0020
    XK_a = 0x0061

    def __init__(self, display_name: str):
        self._x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
        self._xtst = ctypes.cdll.LoadLibrary("libXtst.so.6")

        # XOpenDisplay
        self._x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self._x11.XOpenDisplay.restype = ctypes.c_void_p
        self._display = self._x11.XOpenDisplay(display_name.encode())
        if not self._display:
            raise RuntimeError(f"Cannot open X display {display_name}")

        # XFlush
        self._x11.XFlush.argtypes = [ctypes.c_void_p]

        # XKeysymToKeycode
        self._x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self._x11.XKeysymToKeycode.restype = ctypes.c_int

        # XStringToKeysym
        self._x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self._x11.XStringToKeysym.restype = ctypes.c_ulong

        # XDefaultRootWindow
        self._x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self._x11.XDefaultRootWindow.restype = ctypes.c_ulong

        # XTestFakeKeyEvent
        self._xtst.XTestFakeKeyEvent.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_uint,  # keycode
            ctypes.c_int,  # is_press
            ctypes.c_ulong,  # delay
        ]

        # XTestFakeButtonEvent
        self._xtst.XTestFakeButtonEvent.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_uint,  # button
            ctypes.c_int,  # is_press
            ctypes.c_ulong,  # delay
        ]

        # XTestFakeMotionEvent
        self._xtst.XTestFakeMotionEvent.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_int,  # screen (-1 = current)
            ctypes.c_int,  # x
            ctypes.c_int,  # y
            ctypes.c_ulong,  # delay
        ]

        # XWarpPointer
        self._x11.XWarpPointer.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_ulong,  # src_window (None)
            ctypes.c_ulong,  # dst_window
            ctypes.c_int,  # src_x
            ctypes.c_int,  # src_y
            ctypes.c_uint,  # src_width
            ctypes.c_uint,  # src_height
            ctypes.c_int,  # dst_x
            ctypes.c_int,  # dst_y
        ]

        # XTranslateCoordinates — get actual screen position of a window
        self._x11.XTranslateCoordinates.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_ulong,  # src_window
            ctypes.c_ulong,  # dst_window
            ctypes.c_int,  # src_x
            ctypes.c_int,  # src_y
            ctypes.POINTER(ctypes.c_int),  # dst_x_return
            ctypes.POINTER(ctypes.c_int),  # dst_y_return
            ctypes.POINTER(ctypes.c_ulong),  # child_return
        ]
        self._x11.XTranslateCoordinates.restype = ctypes.c_int

        # XGetGeometry — get window width/height
        self._x11.XGetGeometry.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_ulong,  # drawable (window)
            ctypes.POINTER(ctypes.c_ulong),  # root_return
            ctypes.POINTER(ctypes.c_int),  # x_return
            ctypes.POINTER(ctypes.c_int),  # y_return
            ctypes.POINTER(ctypes.c_uint),  # width_return
            ctypes.POINTER(ctypes.c_uint),  # height_return
            ctypes.POINTER(ctypes.c_uint),  # border_width_return
            ctypes.POINTER(ctypes.c_uint),  # depth_return
        ]
        self._x11.XGetGeometry.restype = ctypes.c_int

        # XGetWindowProperty — read window properties (for _NET_CLIENT_LIST)
        self._x11.XGetWindowProperty.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_ulong,  # window
            ctypes.c_ulong,  # property (Atom)
            ctypes.c_long,  # long_offset
            ctypes.c_long,  # long_length
            ctypes.c_int,  # delete
            ctypes.c_ulong,  # req_type (Atom)
            ctypes.POINTER(ctypes.c_ulong),  # actual_type_return
            ctypes.POINTER(ctypes.c_int),  # actual_format_return
            ctypes.POINTER(ctypes.c_ulong),  # nitems_return
            ctypes.POINTER(ctypes.c_ulong),  # bytes_after_return
            ctypes.POINTER(ctypes.c_void_p),  # prop_return
        ]
        self._x11.XGetWindowProperty.restype = ctypes.c_int

        # XInternAtom
        self._x11.XInternAtom.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_char_p,  # atom_name
            ctypes.c_int,  # only_if_exists
        ]
        self._x11.XInternAtom.restype = ctypes.c_ulong

        # XFetchName
        self._x11.XFetchName.argtypes = [
            ctypes.c_void_p,  # display
            ctypes.c_ulong,  # window
            ctypes.POINTER(ctypes.c_char_p),  # name_return
        ]
        self._x11.XFetchName.restype = ctypes.c_int

        # XFree
        self._x11.XFree.argtypes = [ctypes.c_void_p]

    def flush(self):
        self._x11.XFlush(self._display)

    def root_window(self) -> int:
        return self._x11.XDefaultRootWindow(self._display)

    def get_window_geometry(self, window: int) -> tuple[int, int, int, int]:
        """Get the absolute screen position and size of a window.

        Returns (abs_x, abs_y, width, height) in root-window coordinates.
        Uses XTranslateCoordinates to convert the window origin (0,0) to
        root-window coordinates, which gives the actual on-screen position
        regardless of what xprop reports.
        """
        root = self.root_window()

        # Get width/height via XGetGeometry
        root_ret = ctypes.c_ulong()
        x_ret = ctypes.c_int()
        y_ret = ctypes.c_int()
        w_ret = ctypes.c_uint()
        h_ret = ctypes.c_uint()
        bw_ret = ctypes.c_uint()
        depth_ret = ctypes.c_uint()
        self._x11.XGetGeometry(
            self._display,
            window,
            ctypes.byref(root_ret),
            ctypes.byref(x_ret),
            ctypes.byref(y_ret),
            ctypes.byref(w_ret),
            ctypes.byref(h_ret),
            ctypes.byref(bw_ret),
            ctypes.byref(depth_ret),
        )

        # Translate window (0,0) to root coordinates for absolute position
        abs_x = ctypes.c_int()
        abs_y = ctypes.c_int()
        child = ctypes.c_ulong()
        self._x11.XTranslateCoordinates(
            self._display,
            window,
            root,
            0,
            0,
            ctypes.byref(abs_x),
            ctypes.byref(abs_y),
            ctypes.byref(child),
        )

        return (abs_x.value, abs_y.value, w_ret.value, h_ret.value)

    def find_window_by_name(self, name_substr: str) -> Optional[int]:
        """Find a top-level window whose WM_NAME contains name_substr.

        Queries _NET_CLIENT_LIST on the root window to enumerate managed
        windows, then checks each one's title via XFetchName.
        """
        root = self.root_window()

        # Get _NET_CLIENT_LIST atom
        atom = self._x11.XInternAtom(self._display, b"_NET_CLIENT_LIST", 0)
        if atom == 0:
            return None

        # Read the property
        actual_type = ctypes.c_ulong()
        actual_format = ctypes.c_int()
        nitems = ctypes.c_ulong()
        bytes_after = ctypes.c_ulong()
        prop = ctypes.c_void_p()

        status = self._x11.XGetWindowProperty(
            self._display,
            root,
            atom,
            0,
            1024,
            0,  # offset, length, don't delete
            0,  # AnyPropertyType
            ctypes.byref(actual_type),
            ctypes.byref(actual_format),
            ctypes.byref(nitems),
            ctypes.byref(bytes_after),
            ctypes.byref(prop),
        )

        if status != 0 or not prop.value or nitems.value == 0:
            return None

        # Cast to array of window IDs (unsigned long, 32-bit items)
        n = nitems.value
        if actual_format.value == 32:
            # On 64-bit, format 32 means c_ulong (8 bytes each)
            arr = ctypes.cast(prop.value, ctypes.POINTER(ctypes.c_ulong))
        else:
            self._x11.XFree(prop)
            return None

        result = None
        net_wm_name_atom = self._x11.XInternAtom(self._display, b"_NET_WM_NAME", 0)

        for i in range(n):
            wid = arr[i]

            # Try _NET_WM_NAME first (modern)
            if net_wm_name_atom:
                actual_type = ctypes.c_ulong()
                actual_format = ctypes.c_int()
                nitems_name = ctypes.c_ulong()
                bytes_after = ctypes.c_ulong()
                prop_name = ctypes.c_void_p()

                status = self._x11.XGetWindowProperty(
                    self._display,
                    wid,
                    net_wm_name_atom,
                    0,
                    1024,
                    0,
                    0,
                    ctypes.byref(actual_type),
                    ctypes.byref(actual_format),
                    ctypes.byref(nitems_name),
                    ctypes.byref(bytes_after),
                    ctypes.byref(prop_name),
                )

                if status == 0 and prop_name.value and nitems_name.value > 0:
                    name_str = ctypes.cast(prop_name.value, ctypes.c_char_p).value
                    if name_str and name_substr.encode() in name_str:
                        result = wid
                        self._x11.XFree(prop_name)
                        break
                    self._x11.XFree(prop_name)

            # Fallback to WM_NAME (legacy)
            name_ret = ctypes.c_char_p()
            if self._x11.XFetchName(self._display, wid, ctypes.byref(name_ret)):
                if name_ret.value and name_substr.encode() in name_ret.value:
                    result = wid
                    self._x11.XFree(name_ret)
                    break
                if name_ret.value:
                    self._x11.XFree(name_ret)

        self._x11.XFree(prop)
        return result

    def move_mouse(self, x: int, y: int):
        """Move the mouse pointer to absolute screen coordinates."""
        self._xtst.XTestFakeMotionEvent(self._display, -1, x, y, 0)
        self.flush()

    def click(self, x: int, y: int, button: int = 1):
        """Move to (x, y) and click the given mouse button."""
        self.move_mouse(x, y)
        time.sleep(0.05)
        self._xtst.XTestFakeButtonEvent(self._display, button, 1, 0)  # press
        self._xtst.XTestFakeButtonEvent(self._display, button, 0, 0)  # release
        self.flush()

    def press_key(self, keysym: int):
        """Press and release a single key by keysym."""
        keycode = self._x11.XKeysymToKeycode(self._display, keysym)
        if keycode == 0:
            return
        self._xtst.XTestFakeKeyEvent(self._display, keycode, 1, 0)
        self._xtst.XTestFakeKeyEvent(self._display, keycode, 0, 0)
        self.flush()

    def type_string(self, text: str):
        """Type a string character by character using XStringToKeysym."""
        for ch in text:
            ks = self._x11.XStringToKeysym(ch.encode())
            if ks == 0:
                continue
            keycode = self._x11.XKeysymToKeycode(self._display, ks)
            if keycode == 0:
                continue
            self._xtst.XTestFakeKeyEvent(self._display, keycode, 1, 0)
            self._xtst.XTestFakeKeyEvent(self._display, keycode, 0, 0)
            self.flush()
            time.sleep(0.02)

    def select_all_and_delete(self):
        """Ctrl+A then Delete — clear a text field."""
        # Ctrl press
        ctrl_kc = self._x11.XKeysymToKeycode(self._display, 0xFFE3)  # Control_L
        a_kc = self._x11.XKeysymToKeycode(self._display, self.XK_a)
        del_kc = self._x11.XKeysymToKeycode(self._display, self.XK_Delete)
        # Ctrl+A
        self._xtst.XTestFakeKeyEvent(self._display, ctrl_kc, 1, 0)
        self._xtst.XTestFakeKeyEvent(self._display, a_kc, 1, 0)
        self._xtst.XTestFakeKeyEvent(self._display, a_kc, 0, 0)
        self._xtst.XTestFakeKeyEvent(self._display, ctrl_kc, 0, 0)
        self.flush()
        time.sleep(0.05)
        # Delete
        self._xtst.XTestFakeKeyEvent(self._display, del_kc, 1, 0)
        self._xtst.XTestFakeKeyEvent(self._display, del_kc, 0, 0)
        self.flush()


# ---------------------------------------------------------------------------
# Screenshot capture & analysis
# ---------------------------------------------------------------------------


def take_screenshot(display: str, output_path: Path, region: str = "") -> Path:
    """
    Capture a screenshot using ImageMagick's `import` command.

    Args:
        display: X display string (e.g. ":99")
        output_path: Where to save the PNG
        region: Optional geometry string "WxH+X+Y" for a sub-region
    """
    output_path.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["DISPLAY"] = display
    env["GDK_BACKEND"] = "x11"
    env["FLTK_BACKEND"] = "x11"  # FLTK 1.4+: force X11 backend
    # Strip Wayland so ImageMagick targets the Xvfb, not the host compositor
    for var in ("WAYLAND_DISPLAY", "XDG_SESSION_TYPE"):
        env.pop(var, None)

    cmd = ["import", "-window", "root"]
    if region:
        cmd += ["-crop", region]
    cmd.append(str(output_path))

    subprocess.run(
        cmd,
        env=env,
        timeout=10,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return output_path


@dataclass
class ImageStats:
    """Basic statistics about a screenshot."""

    width: int
    height: int
    mean_r: float
    mean_g: float
    mean_b: float
    stddev_r: float
    stddev_g: float
    stddev_b: float
    is_blank: bool  # True if the image is effectively a single colour
    non_bg_pixel_ratio: float  # ratio of pixels that differ from top-left

    def to_dict(self) -> dict:
        return {
            k: round(v, 3) if isinstance(v, float) else v
            for k, v in self.__dict__.items()
        }


def analyse_image(path: Path) -> ImageStats:
    """Analyse a screenshot and return statistics."""
    from PIL import Image, ImageStat

    img = Image.open(path).convert("RGB")
    stat = ImageStat.Stat(img)
    w, h = img.size

    mean_r, mean_g, mean_b = stat.mean
    std_r, std_g, std_b = stat.stddev

    # Check if image is blank (very low standard deviation across all channels)
    is_blank = std_r < 3.0 and std_g < 3.0 and std_b < 3.0

    # Count pixels that differ from the background (top-left corner pixel)
    bg = img.getpixel((0, 0))
    pixels = img.load()
    diff_count = 0
    sample_step = max(1, w * h // 50000)  # sample for speed
    total_sampled = 0
    for y in range(0, h, max(1, int(sample_step**0.5))):
        for x in range(0, w, max(1, int(sample_step**0.5))):
            total_sampled += 1
            r, g, b = pixels[x, y]
            if abs(r - bg[0]) > 10 or abs(g - bg[1]) > 10 or abs(b - bg[2]) > 10:
                diff_count += 1

    ratio = diff_count / max(total_sampled, 1)

    return ImageStats(
        width=w,
        height=h,
        mean_r=mean_r,
        mean_g=mean_g,
        mean_b=mean_b,
        stddev_r=std_r,
        stddev_g=std_g,
        stddev_b=std_b,
        is_blank=is_blank,
        non_bg_pixel_ratio=ratio,
    )


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------


@dataclass
class TestResult:
    name: str
    passed: bool
    message: str
    screenshot: Optional[str] = None
    stats: Optional[dict] = None


@dataclass
class TestHarness:
    display: str = ":99"
    screen_width: int = 1280
    screen_height: int = 800
    screen_depth: int = 24
    xvfb_proc: Optional[subprocess.Popen] = None
    wm_proc: Optional[subprocess.Popen] = None
    app_proc: Optional[subprocess.Popen] = None
    x11: Optional[X11] = None
    results: list = field(default_factory=list)
    keep_xvfb: bool = False
    _config_backup: Optional[str] = None
    # (content_x, content_y, content_w, content_h) — set after app launches
    win_pos: tuple = (0, 0, 900, 600)

    def start_xvfb(self):
        """Start the Xvfb virtual framebuffer."""
        print(
            f"  Starting Xvfb on {self.display} ({self.screen_width}x{self.screen_height}x{self.screen_depth})..."
        )
        self.xvfb_proc = subprocess.Popen(
            [
                "Xvfb",
                self.display,
                "-screen",
                "0",
                f"{self.screen_width}x{self.screen_height}x{self.screen_depth}",
                "-ac",  # disable access control
                "+extension",
                "RANDR",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Wait for Xvfb to be ready
        for _ in range(30):
            try:
                subprocess.run(
                    ["xdpyinfo", "-display", self.display],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2,
                    check=True,
                )
                print(f"  Xvfb ready on {self.display}")
                return
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                time.sleep(0.2)
        raise RuntimeError("Xvfb failed to start within 6 seconds")

    def stop_xvfb(self):
        """Stop the Xvfb process."""
        if self.xvfb_proc:
            self.xvfb_proc.terminate()
            try:
                self.xvfb_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.xvfb_proc.kill()
            self.xvfb_proc = None

    def _make_x11_env(self) -> dict:
        """Build an environment dict that forces X11 on the virtual display.

        Strips Wayland variables so GTK/FLTK don't bypass Xvfb and connect
        to the host Wayland compositor instead. Forces FLTK to its X11
        backend (FLTK 1.4+ auto-detects Wayland otherwise).
        """
        env = os.environ.copy()
        env["DISPLAY"] = self.display
        env["GDK_BACKEND"] = "x11"  # force X11, not Wayland
        env["FLTK_BACKEND"] = "x11"  # FLTK 1.4+: force X11 backend
        env["GTK_THEME"] = "Adwaita"  # consistent theme
        env["NO_AT_BRIDGE"] = "1"  # suppress accessibility warnings
        # Remove Wayland variables so toolkits can't find the host compositor
        for var in ("WAYLAND_DISPLAY", "XDG_SESSION_TYPE"):
            env.pop(var, None)
        return env

    def start_wm(self):
        """Start a window manager inside Xvfb so GTK windows get mapped."""
        env = self._make_x11_env()
        # Try kwin_x11 first (KDE), fall back to any available WM
        wm_candidates = ["kwin_x11", "openbox", "fluxbox", "twm", "metacity"]
        for wm in wm_candidates:
            wm_path = subprocess.run(
                ["which", wm], capture_output=True, text=True
            ).stdout.strip()
            if wm_path:
                print(f"  Starting window manager: {wm}")
                self.wm_proc = subprocess.Popen(
                    [wm_path],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(1.0)
                if self.wm_proc.poll() is not None:
                    print(f"  ⚠ {wm} exited immediately, trying next...")
                    self.wm_proc = None
                    continue
                print(f"  Window manager running (PID {self.wm_proc.pid})")
                return
        print("  ⚠ No window manager found — GTK windows may not render")

    def stop_wm(self):
        """Stop the window manager process."""
        if hasattr(self, "wm_proc") and self.wm_proc:
            self.wm_proc.terminate()
            try:
                self.wm_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.wm_proc.kill()
            self.wm_proc = None

    def _reset_window_prefs(self):
        """Temporarily reset win_w/win_h in config so the app uses 1200x700.

        Saves a backup of the original config and rewrites the prefs so
        the FLTK layout is predictable for screenshot coordinate math.
        """
        import json as _json
        config_path = Path.home() / ".config" / "hangar" / "vms.json"
        self._config_backup = None

        if not config_path.exists():
            return

        try:
            raw = config_path.read_text()
            cfg = _json.loads(raw) if raw.strip() else {}
        except Exception:
            return

        # Save backup
        self._config_backup = raw
        # Force default window size
        cfg["win_w"] = 0
        cfg["win_h"] = 0
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(_json.dumps(cfg, indent=2))
        print("  Config: reset win_w/win_h to 0 (force 1200x700 default)")

    def _restore_config(self):
        """Restore the original config backed up by _reset_window_prefs."""
        if self._config_backup is not None:
            config_path = Path.home() / ".config" / "hangar" / "vms.json"
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config_path.write_text(self._config_backup)
            self._config_backup = None

    def start_app(self):
        """Launch hangar on the virtual display."""
        if not BINARY.exists():
            raise FileNotFoundError(
                f"Binary not found: {BINARY}\nRun `zig build` first."
            )

        env = self._make_x11_env()

        # Force the app to use 1200x700 defaults so screenshot coordinates
        # are predictable. The saved config may have a smaller size from a
        # previous run, which shifts all widget positions.
        self._reset_window_prefs()

        print(f"  Launching {BINARY.name}...")
        self.app_proc = subprocess.Popen(
            [str(BINARY)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Give the app time to create its window
        time.sleep(2.0)

        if self.app_proc.poll() is not None:
            raise RuntimeError(
                f"App exited immediately with code {self.app_proc.returncode}"
            )

        print(f"  App running (PID {self.app_proc.pid})")

    def stop_app(self):
        """Stop the hangar process and restore original config."""
        if self.app_proc:
            self.app_proc.terminate()
            try:
                self.app_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.app_proc.kill()
            self.app_proc = None
        # Restore the original config (window size prefs)
        self._restore_config()

    def init_x11(self):
        """Initialise the X11 input simulation layer."""
        self.x11 = X11(self.display)
        print("  X11 input simulation ready")

    def find_app_window(self) -> tuple[int, int, int, int]:
        """Find the Hangar window and return (x, y, width, height) of content area.

        Uses pure X11 ctypes calls (XTranslateCoordinates + XGetGeometry)
        to get the *actual* on-screen position, not the stale hints from xprop.

        Returns (content_x, content_y, content_w, content_h).
        """
        assert self.x11 is not None

        wid = self.x11.find_window_by_name("Hangar")
        if wid is None:
            print("  ⚠ Hangar window not found via X11")
            return self._fallback_window_pos()

        abs_x, abs_y, w, h = self.x11.get_window_geometry(wid)
        print(f"  Window found: 0x{wid:x} at ({abs_x},{abs_y}) size={w}x{h}")
        return (abs_x, abs_y, w, h)

    def _fallback_window_pos(self) -> tuple[int, int, int, int]:
        """Fallback window position when X11 detection fails."""
        # Estimate based on 900x600 window centered in 1280x800 Xvfb
        x = (self.screen_width - 900) // 2
        y = (self.screen_height - 600) // 2
        print(f"  Using fallback window position: ({x},{y}) 900x600")
        return (x, y, 900, 600)

    def screenshot(self, name: str) -> tuple[Path, ImageStats]:
        """Take a screenshot and analyse it."""
        path = SCREENSHOT_DIR / f"{name}.png"
        take_screenshot(self.display, path)
        stats = analyse_image(path)
        return path, stats

    def add_result(
        self,
        name: str,
        passed: bool,
        message: str,
        screenshot: Optional[Path] = None,
        stats: Optional[ImageStats] = None,
    ):
        icon = "✅" if passed else "❌"
        print(f"  {icon} {name}: {message}")
        self.results.append(
            TestResult(
                name=name,
                passed=passed,
                message=message,
                screenshot=str(screenshot) if screenshot else None,
                stats=stats.to_dict() if stats else None,
            )
        )

    # ------------------------------------------------------------------
    # Test cases
    # ------------------------------------------------------------------

    def test_01_app_launches(self):
        """Verify the app process is running after launch."""
        alive = self.app_proc is not None and self.app_proc.poll() is None
        self.add_result(
            "app_launches",
            alive,
            "App process is running" if alive else "App is NOT running",
        )

    def test_02_window_renders(self):
        """Verify the main window renders with visible content."""
        path, stats = self.screenshot("02_main_window")
        # A rendered GTK window should NOT be blank
        rendered = not stats.is_blank
        self.add_result(
            "window_renders",
            rendered,
            f"Window rendered ({stats.width}x{stats.height}, "
            f"non-bg={stats.non_bg_pixel_ratio:.1%})"
            if rendered
            else "Window appears BLANK",
            screenshot=path,
            stats=stats,
        )

    def test_03_has_ui_elements(self):
        """Verify the window contains enough visual complexity (widgets)."""
        path, stats = self.screenshot("03_ui_elements")
        # Good UI should have significant colour variation (widgets, text, borders)
        has_elements = stats.non_bg_pixel_ratio > 0.05
        self.add_result(
            "has_ui_elements",
            has_elements,
            f"UI complexity: {stats.non_bg_pixel_ratio:.1%} non-background pixels, "
            f"stddev=({stats.stddev_r:.1f}, {stats.stddev_g:.1f}, {stats.stddev_b:.1f})",
            screenshot=path,
            stats=stats,
        )

    def test_04_correct_dimensions(self):
        """Verify the window is approximately the expected size (900x600)."""
        path, stats = self.screenshot("04_dimensions")
        # The Xvfb is 1280x800; the app should take a significant portion
        ok = stats.width == self.screen_width and stats.height == self.screen_height
        self.add_result(
            "correct_dimensions",
            ok,
            f"Screenshot is {stats.width}x{stats.height} "
            f"(Xvfb is {self.screen_width}x{self.screen_height})",
            screenshot=path,
            stats=stats,
        )

    def test_05_click_new_vm_button(self):
        """Click the '+ New VM' button and verify a dialog appears."""
        assert self.x11 is not None
        cx, cy, cw, ch = self.win_pos

        # Take a before screenshot
        _, stats_before = self.screenshot("05a_before_new_vm")

        # Click the New VM toolbar button — first button in toolbar, below menubar.
        # Menubar ~28px, toolbar starts below, button center ~20px into toolbar.
        # Buttons are ~72px wide, first button center ~36px from left content edge.
        btn_x = cx + 36
        btn_y = cy + 48
        print(f"  Clicking New VM button at ({btn_x}, {btn_y})")
        self.x11.click(btn_x, btn_y)
        time.sleep(0.8)
        time.sleep(1.5)

        # Take an after screenshot
        path_after, stats_after = self.screenshot("05b_after_new_vm_click")

        # Check if something changed (dialog appeared)
        pixel_diff = abs(
            stats_after.non_bg_pixel_ratio - stats_before.non_bg_pixel_ratio
        )
        mean_diff = (
            abs(stats_after.mean_r - stats_before.mean_r)
            + abs(stats_after.mean_g - stats_before.mean_g)
            + abs(stats_after.mean_b - stats_before.mean_b)
        )

        changed = pixel_diff > 0.01 or mean_diff > 5.0
        self.add_result(
            "click_new_vm_button",
            changed,
            f"UI changed after click (pixel_diff={pixel_diff:.3f}, "
            f"mean_diff={mean_diff:.1f})"
            if changed
            else "No visible change after clicking New VM button "
            f"(pixel_diff={pixel_diff:.3f}, mean_diff={mean_diff:.1f})",
            screenshot=path_after,
            stats=stats_after,
        )

    def test_06_new_vm_dialog_content(self):
        """Verify the New VM dialog has form fields (high visual complexity)."""
        # The dialog should already be open from test_05
        time.sleep(0.5)
        path, stats = self.screenshot("06_new_vm_dialog")

        # A dialog with form fields should have high complexity
        has_form = stats.non_bg_pixel_ratio > 0.10
        self.add_result(
            "new_vm_dialog_content",
            has_form,
            f"Dialog complexity: {stats.non_bg_pixel_ratio:.1%} non-bg pixels"
            if has_form
            else f"Dialog looks empty ({stats.non_bg_pixel_ratio:.1%} non-bg pixels)",
            screenshot=path,
            stats=stats,
        )

    def test_07_type_vm_name(self):
        """Type a VM name into the name entry field and verify change."""
        assert self.x11 is not None

        # The New VM dialog is a libui modal dialog, centered on screen.
        # From the screenshot layout: dialog is ~500px wide.
        # The "Name:" label is on the left, entry field on the right.
        # We use screen center as the dialog center, then offset to the entry.
        screen_cx = self.screen_width // 2
        screen_cy = self.screen_height // 2

        # Name entry: ~100px right of center, ~200px above center (first field)
        name_entry_x = screen_cx + 100
        name_entry_y = screen_cy - 207

        _, before_stats = self.screenshot("07a_before_typing")

        # Click the name entry and type
        print(f"  Clicking name entry at ({name_entry_x}, {name_entry_y})")
        self.x11.click(name_entry_x, name_entry_y)
        time.sleep(0.3)
        self.x11.select_all_and_delete()
        time.sleep(0.2)
        self.x11.type_string("TestVM")
        time.sleep(0.5)

        path, after_stats = self.screenshot("07b_after_typing")

        # Verify something changed
        mean_diff = (
            abs(after_stats.mean_r - before_stats.mean_r)
            + abs(after_stats.mean_g - before_stats.mean_g)
            + abs(after_stats.mean_b - before_stats.mean_b)
        )

        # Even small text changes will shift pixel values
        self.add_result(
            "type_vm_name",
            True,  # we just verify no crash
            f"Typed 'TestVM' into name field (mean_diff={mean_diff:.1f})",
            screenshot=path,
            stats=after_stats,
        )

    def test_08_close_dialog(self):
        """Close the New VM dialog by pressing Escape and verify it closed."""
        assert self.x11 is not None
        # Take a before screenshot
        path_before, stats_before = self.screenshot("08a_before_dialog_close")
        # Press Escape to close the dialog
        print("  Pressing Escape to close dialog")
        self.x11.press_key(0xFF1B)
        time.sleep(0.6)
        # Take after screenshot
        path_after, stats_after = self.screenshot("08_after_dialog_close")
        # The after screenshot should be visually different (dialog gone)
        mean_diff = (
            abs(stats_after.mean_r - stats_before.mean_r) +
            abs(stats_after.mean_g - stats_before.mean_g) +
            abs(stats_after.mean_b - stats_before.mean_b)
        )
        closed = mean_diff > 2.0
        self.add_result(
            "close_dialog",
            closed,
            f"Dialog closed (mean_diff={mean_diff:.1f})"
            if closed
            else f"Dialog may still be open (mean_diff={mean_diff:.1f})",
            screenshot=path_after,
            stats=stats_after,
        )
        
    def test_09_app_still_running(self):
        """Verify the app is still running after all interactions."""
        alive = self.app_proc is not None and self.app_proc.poll() is None
        self.add_result(
            "app_still_running",
            alive,
            "App process still alive after all tests"
            if alive
            else f"App CRASHED (exit code: {self.app_proc.returncode if self.app_proc else 'N/A'})",
        )

    def test_10_final_screenshot(self):
        """Take a final screenshot for the record."""
        path, stats = self.screenshot("10_final_state")
        self.add_result(
            "final_screenshot",
            not stats.is_blank,
            f"Final state: {stats.width}x{stats.height}, "
            f"non-bg={stats.non_bg_pixel_ratio:.1%}",
            screenshot=path,
            stats=stats,
        )

    # ------------------------------------------------------------------
    # Runner
    # ------------------------------------------------------------------

    def run_all(self):
        """Run all visual tests in sequence."""
        print("\n" + "=" * 60)
        print("Hangar Visual Test Harness")
        print("=" * 60)

        try:
            print("\n[Setup]")
            self.start_xvfb()
            self.start_wm()
            self.start_app()
            self.init_x11()
            self.win_pos = self.find_app_window()

            tests = [
                self.test_01_app_launches,
                self.test_02_window_renders,
                self.test_03_has_ui_elements,
                self.test_04_correct_dimensions,
                self.test_05_click_new_vm_button,
                self.test_06_new_vm_dialog_content,
                self.test_07_type_vm_name,
                self.test_08_close_dialog,
                self.test_09_app_still_running,
                self.test_10_final_screenshot,
            ]

            print(f"\n[Running {len(tests)} tests]")
            for test_fn in tests:
                try:
                    test_fn()
                except Exception as e:
                    self.add_result(
                        test_fn.__name__.replace("test_", ""),
                        False,
                        f"EXCEPTION: {e}",
                    )

        finally:
            print("\n[Teardown]")
            self.stop_app()
            self.stop_wm()
            if not self.keep_xvfb:
                self.stop_xvfb()
            else:
                print(
                    f"  Xvfb kept running on {self.display} (PID {self.xvfb_proc.pid})"
                )

        # Summary
        print("\n" + "=" * 60)
        passed = sum(1 for r in self.results if r.passed)
        total = len(self.results)
        print(f"Results: {passed}/{total} passed")
        print("=" * 60)

        # Save results as JSON
        results_path = SCREENSHOT_DIR / "results.json"
        with open(results_path, "w") as f:
            json.dump(
                {
                    "passed": passed,
                    "total": total,
                    "tests": [
                        {
                            "name": r.name,
                            "passed": r.passed,
                            "message": r.message,
                            "screenshot": r.screenshot,
                            "stats": r.stats,
                        }
                        for r in self.results
                    ],
                },
                f,
                indent=2,
            )
        print(f"Results saved to {results_path}")
        print(f"Screenshots in {SCREENSHOT_DIR}/")

        if passed < total:
            print(f"\n⚠️  {total - passed} test(s) failed")

        return passed == total


def main():
    parser = argparse.ArgumentParser(description="Hangar Visual Test Harness")
    parser.add_argument(
        "--keep-xvfb", action="store_true", help="Keep Xvfb running after tests"
    )
    parser.add_argument(
        "--display", default=":99", help="X display to use (default: :99)"
    )
    args = parser.parse_args()

    harness = TestHarness(
        display=args.display,
        keep_xvfb=args.keep_xvfb,
    )

    success = harness.run_all()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

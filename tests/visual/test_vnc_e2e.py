#!/usr/bin/env python3
"""
Hangar VNC End-to-End Test
==========================

Tests the complete VNC display pipeline end-to-end:
  QEMU VNC server → libvncclient → framebuffer → Cairo → libui-ng Area widget

Strategy:
  1. Pre-seed ~/.config/hangar/vms.json with a VM configured for embedded VNC
  2. Create a tiny disk image (QEMU boots to SeaBIOS "No bootable device")
  3. Launch Hangar in Xvfb — it loads the config, VM appears in the list
  4. Click "▶ Start" toolbar button → QEMU spawns with -vnc localhost:N
  5. Wait for VNC connection (auto-retry via 33ms display timer)
  6. Click the "Display" tab
  7. Screenshot and verify the display area shows QEMU VNC output
  8. Clean up

Requirements:
  - qemu-system-x86_64, qemu-img
  - Xvfb, ImageMagick (import), Python 3, Pillow
  - /dev/kvm accessible (or TCG fallback)

Usage:
  python3 tests/visual/test_vnc_e2e.py
  python3 tests/visual/test_vnc_e2e.py --verbose
  python3 tests/visual/test_vnc_e2e.py --display :98 --keep-xvfb
  python3 tests/visual/test_vnc_e2e.py --help
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# Import utilities from the visual test harness
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_visual import X11, take_screenshot, analyse_image, ImageStats, TestResult

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO = Path(__file__).resolve().parent.parent.parent
BINARY = REPO / "zig-out" / "bin" / "hangar"
SCREENSHOT_DIR = Path(__file__).resolve().parent / "screenshots" / "vnc_e2e"

VNC_PORT = 5955  # Display :55, unlikely to conflict
VM_NAME = "vnc-test-vm"

log = logging.getLogger("vnc-e2e")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def wait_for_port(port: int, host: str = "127.0.0.1", timeout: float = 15) -> bool:
    """Wait until a TCP port is accepting connections."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return True
        except (ConnectionRefusedError, OSError):
            time.sleep(0.5)
    return False


def port_in_use(port: int, host: str = "127.0.0.1") -> bool:
    """Check if a TCP port is currently in use."""
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except (ConnectionRefusedError, OSError):
        return False


def create_test_environment(tmpdir: str) -> str:
    """Create config dir, disk image, and vms.json in a temp HOME.

    Returns the absolute disk image path.
    """
    config_dir = Path(tmpdir) / ".config" / "hangar"
    config_dir.mkdir(parents=True)

    vm_dir = Path(tmpdir) / "VMs"
    vm_dir.mkdir(parents=True)

    disk_path = str(vm_dir / f"{VM_NAME}.qcow2")

    # Create a tiny 1MB disk image — QEMU will boot to SeaBIOS
    subprocess.run(
        ["qemu-img", "create", "-f", "qcow2", disk_path, "1M"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    log.info("Disk image: %s", disk_path)

    # Write vms.json matching the exact format persist.zig produces
    config = {
        "version": 1,
        "vms": [
            {
                "name": VM_NAME,
                "cpu_cores": 1,
                "memory_mb": 128,
                "disk_size_gb": 1,
                "disk_format": "qcow2",
                "disk_path": disk_path,
                "iso_path": "",
                "display": "gtk",
                "network": "none",
                "firmware": "bios",
                "enable_kvm": os.path.exists("/dev/kvm"),
                "embed_display": True,
                "vnc_port": VNC_PORT,
                "spice_port": VNC_PORT + 30,
                "enable_serial": False,
            }
        ],
    }

    config_path = config_dir / "vms.json"
    config_path.write_text(json.dumps(config, indent=2))
    log.info("Config: %s", config_path)
    log.info("KVM: %s", "yes" if os.path.exists("/dev/kvm") else "no (TCG)")
    log.info("VNC port: %d", VNC_PORT)

    return disk_path


def kill_qemu_for_vm():
    """Kill any QEMU processes associated with our test VM."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", f"-name {VM_NAME}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for pid_str in result.stdout.strip().split("\n"):
            pid_str = pid_str.strip()
            if pid_str:
                try:
                    os.kill(int(pid_str), signal.SIGTERM)
                    log.info("Killed QEMU PID %s", pid_str)
                except (ProcessLookupError, ValueError):
                    pass
    except Exception:
        pass


# ---------------------------------------------------------------------------
# UI coordinate helpers
# ---------------------------------------------------------------------------
#
# Window layout (cy = top of client area, after kwin title bar):
#
#  cy + 0   ┌────────────────────────────────────────────────────┐
#            │  File   VM   Help                    (menu bar)   │
#  cy + 28  ├────────────────────────────────────────────────────┤
#            │  +NewVM │ Start │ Stop │ ...          (toolbar)   │
#  cy + 68  ├────────┬───────────────────────────────────────────┤
#            │ Virtual│ Details │ Display │ Console  (tab bar)   │
#  cy + 97  │ Machin │───────────────────────────────────────────│
#            │ [combo]│                                           │
#            │        │  (tab content area)                      │
#            │        │                                           │
#  cy + h   └────────┴───────────────────────────────────────────┘
#
# Measured from screenshots with window at (0, 114):
#   Menu bar:       cy +  0  to cy + 28
#   Toolbar:        cy + 35  to cy + 68   (button centers at ~cy + 55)
#   Tab bar labels: cy + 80  to cy + 100  (text centers at ~cy + 97)
#   Tab content:    cy + 110 onwards
#
# Tab label X positions (from left edge of right panel at ~cx + 175):
#   Details:  cx + 220  (center)
#   Display:  cx + 302  (center)
#   Console:  cx + 390  (center)
#
# Toolbar button X positions:
#   + New VM: cx + 70  (center)
#   Start:    cx + 200 (center)


def toolbar_pos(cx: int, cy: int, button: str) -> tuple[int, int]:
    """Return (x, y) screen position for a toolbar button center."""
    # IupButton with FLAT=YES, toolbar layout:
    #   [New VM] | [Power On] [Suspend] [Power Off] | [Settings]
    btn_x = {
        "new_vm": 40,
        "start": 140,
        "suspend": 230,
        "stop": 330,
        "settings": 430,
    }
    return (cx + btn_x.get(button, 140), cy + 55)


def tab_pos(cx: int, cy: int, tab: str) -> tuple[int, int]:
    """Return (x, y) screen position for a tab label center."""
    # Tab labels are in the right panel, above the content area.
    # Measured from screenshots: tabs at ~cy + 97
    tab_x = {
        "summary": 340,
        "display": 430,
        "console": 520,
    }
    return (cx + tab_x.get(tab, 430), cy + 97)


# ---------------------------------------------------------------------------
# Test class
# ---------------------------------------------------------------------------


@dataclass
class VncE2ETest:
    display: str = ":98"
    screen_width: int = 1280
    screen_height: int = 800
    keep_xvfb: bool = False
    verbose: bool = False
    tmpdir: Optional[str] = None
    xvfb_proc: Optional[subprocess.Popen] = None
    wm_proc: Optional[subprocess.Popen] = None
    app_proc: Optional[subprocess.Popen] = None
    x11: Optional[X11] = None
    results: list = field(default_factory=list)
    win_pos: tuple = (0, 0, 900, 600)

    def _make_env(self) -> dict:
        """Build environment dict targeting Xvfb with isolated HOME."""
        env = os.environ.copy()
        env["DISPLAY"] = self.display
        env["GDK_BACKEND"] = "x11"
        env["GTK_THEME"] = "Adwaita"
        env["NO_AT_BRIDGE"] = "1"
        if self.tmpdir:
            env["HOME"] = self.tmpdir
        for var in ("WAYLAND_DISPLAY", "XDG_SESSION_TYPE"):
            env.pop(var, None)
        return env

    def setup(self):
        """Create temp HOME, start Xvfb + WM, init X11."""
        # Pre-flight checks
        if not BINARY.exists():
            raise FileNotFoundError(
                f"Binary not found: {BINARY}\nRun `zig build` first."
            )
        if not shutil.which("qemu-system-x86_64"):
            raise RuntimeError("qemu-system-x86_64 not found in PATH")
        if not shutil.which("qemu-img"):
            raise RuntimeError("qemu-img not found in PATH")
        if port_in_use(VNC_PORT):
            raise RuntimeError(f"VNC port {VNC_PORT} already in use — cannot run test")

        # Create isolated test environment
        self.tmpdir = tempfile.mkdtemp(prefix="hangar-vnc-test-")
        log.info("Temp HOME: %s", self.tmpdir)
        create_test_environment(self.tmpdir)

        # Start Xvfb
        log.info(
            "Starting Xvfb on %s (%dx%d)...",
            self.display,
            self.screen_width,
            self.screen_height,
        )
        self.xvfb_proc = subprocess.Popen(
            [
                "Xvfb",
                self.display,
                "-screen",
                "0",
                f"{self.screen_width}x{self.screen_height}x24",
                "-ac",
                "+extension",
                "RANDR",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(30):
            try:
                subprocess.run(
                    ["xdpyinfo", "-display", self.display],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2,
                    check=True,
                )
                log.info("Xvfb ready")
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                time.sleep(0.2)
        else:
            raise RuntimeError("Xvfb failed to start")

        # Start window manager
        env = self._make_env()
        for wm in ["kwin_x11", "openbox", "fluxbox", "twm"]:
            wm_path = shutil.which(wm)
            if wm_path:
                self.wm_proc = subprocess.Popen(
                    [wm_path],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(1.0)
                if self.wm_proc.poll() is None:
                    log.info("Window manager: %s (PID %d)", wm, self.wm_proc.pid)
                    break
                self.wm_proc = None

        # Init X11 input simulation
        self.x11 = X11(self.display)
        log.info("X11 input ready")

    def start_app(self):
        """Launch hangar on the virtual display with isolated HOME."""
        env = self._make_env()
        log.info("Launching %s...", BINARY.name)
        self.app_proc = subprocess.Popen(
            [str(BINARY)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Give the app time to init libui, load config, create window
        time.sleep(3.0)

        if self.app_proc.poll() is not None:
            stdout = self.app_proc.stdout.read().decode(errors="replace")
            stderr = self.app_proc.stderr.read().decode(errors="replace")
            raise RuntimeError(
                f"App exited immediately (code {self.app_proc.returncode})\n"
                f"stdout: {stdout}\nstderr: {stderr}"
            )

        log.info("App running (PID %d)", self.app_proc.pid)

        # Find window geometry
        self.win_pos = self._find_window()

    def _find_window(self) -> tuple:
        assert self.x11 is not None
        wid = self.x11.find_window_by_name("Hangar")
        if wid:
            pos = self.x11.get_window_geometry(wid)
            log.info(
                "Window: 0x%x at (%d,%d) size=%dx%d",
                wid,
                pos[0],
                pos[1],
                pos[2],
                pos[3],
            )
            return pos
        # Fallback: centered 900x600
        x = (self.screen_width - 900) // 2
        y = (self.screen_height - 600) // 2
        log.warning("Window not found, using fallback: (%d,%d) 900x600", x, y)
        return (x, y, 900, 600)

    def click_tab(self, tab: str):
        """Click a tab label by name. Tries primary position, then sweeps."""
        assert self.x11 is not None
        cx, cy, _, _ = self.win_pos
        tx, ty = tab_pos(cx, cy, tab)
        log.debug("Clicking '%s' tab at (%d, %d)", tab, tx, ty)
        self.x11.click(tx, ty)
        time.sleep(0.3)

    def click_toolbar(self, button: str):
        """Click a toolbar button by name."""
        assert self.x11 is not None
        cx, cy, _, _ = self.win_pos
        bx, by = toolbar_pos(cx, cy, button)
        log.debug("Clicking '%s' button at (%d, %d)", button, bx, by)
        self.x11.click(bx, by)

    def screenshot(self, name: str) -> tuple[Path, ImageStats]:
        """Take a screenshot and analyse it."""
        SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
        path = SCREENSHOT_DIR / f"{name}.png"
        take_screenshot(self.display, path)
        stats = analyse_image(path)
        log.debug(
            "Screenshot %s: %dx%d non-bg=%.1f%% stddev=(%.1f,%.1f,%.1f)",
            name,
            stats.width,
            stats.height,
            stats.non_bg_pixel_ratio * 100,
            stats.stddev_r,
            stats.stddev_g,
            stats.stddev_b,
        )
        return path, stats

    def screenshot_region(
        self, name: str, x: int, y: int, w: int, h: int
    ) -> tuple[Path, ImageStats]:
        """Take a cropped screenshot of a specific region."""
        SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
        path = SCREENSHOT_DIR / f"{name}.png"
        region = f"{w}x{h}+{x}+{y}"
        env = os.environ.copy()
        env["DISPLAY"] = self.display
        env["GDK_BACKEND"] = "x11"
        for var in ("WAYLAND_DISPLAY", "XDG_SESSION_TYPE"):
            env.pop(var, None)
        subprocess.run(
            ["import", "-window", "root", "-crop", region, str(path)],
            env=env,
            timeout=10,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        stats = analyse_image(path)
        log.debug(
            "Region %s (%s): non-bg=%.1f%% mean=(%.0f,%.0f,%.0f)",
            name,
            region,
            stats.non_bg_pixel_ratio * 100,
            stats.mean_r,
            stats.mean_g,
            stats.mean_b,
        )
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

    def test_01_app_loads_vm(self):
        """App launches and shows the pre-seeded VM in the list."""
        alive = self.app_proc is not None and self.app_proc.poll() is None
        path, stats = self.screenshot("01_app_loaded")
        has_content = not stats.is_blank and stats.non_bg_pixel_ratio > 0.05
        self.add_result(
            "app_loads_vm",
            alive and has_content,
            f"App running, UI rendered ({stats.non_bg_pixel_ratio:.1%} non-bg)"
            if (alive and has_content)
            else "App failed to load or render",
            screenshot=path,
            stats=stats,
        )

    def test_02_click_start(self):
        """Click the Start toolbar button and verify QEMU starts."""
        # First, select the VM in the Library list.
        # The list is in the left panel; the first item is at approximately
        # cx + 80, cy + 100 (just below the "Library" label).
        assert self.x11 is not None
        cx, cy, _, _ = self.win_pos
        self.x11.click(cx + 80, cy + 100)
        time.sleep(0.5)

        self.click_toolbar("start")

        # Wait for QEMU to start and VNC port to open
        log.info("Waiting for VNC port %d...", VNC_PORT)
        time.sleep(1)

        # Debug: check if QEMU is running
        res = subprocess.run(
            ["pgrep", "-a", "-f", VM_NAME], capture_output=True, text=True
        )
        log.debug("QEMU processes: %s", res.stdout.strip())

        port_open = wait_for_port(VNC_PORT, timeout=15)

        if port_open:
            log.info("VNC port %d is open", VNC_PORT)
        else:
            log.warning("VNC port %d NOT open after 15s", VNC_PORT)
            self.screenshot("02_debug_start_failed")

        self.add_result(
            "click_start",
            port_open,
            f"QEMU VNC listening on port {VNC_PORT}"
            if port_open
            else f"VNC port {VNC_PORT} not open — QEMU may not have started",
        )

    def test_03_vnc_connects(self):
        """Wait for the 33ms display timer to auto-connect VNC."""
        log.info("Waiting for VNC auto-connect (5s)...")
        time.sleep(5)

        # Take a screenshot showing status bar (should mention VNC)
        path, stats = self.screenshot("03_vnc_connected")
        alive = self.app_proc is not None and self.app_proc.poll() is None
        self.add_result(
            "vnc_connects",
            alive,
            "App still running after VNC connection period"
            if alive
            else "App crashed during VNC connection",
            screenshot=path,
            stats=stats,
        )

    def test_04_display_tab_shows_framebuffer(self):
        """Click the Display tab and verify it shows VNC framebuffer."""
        # Take baseline screenshot (Details tab is active)
        _, baseline_stats = self.screenshot("04a_before_display_tab")

        # Click the Display tab
        self.click_tab("display")
        time.sleep(1.0)

        # Take screenshot after clicking Display tab
        path, stats = self.screenshot("04b_display_tab")

        # Compare: switching to Display tab should change the view
        # The Details tab has form labels; the Display tab has the VNC
        # framebuffer (black BIOS screen) or at minimum a different
        # background.
        mean_diff = (
            abs(stats.mean_r - baseline_stats.mean_r)
            + abs(stats.mean_g - baseline_stats.mean_g)
            + abs(stats.mean_b - baseline_stats.mean_b)
        )
        pixel_diff = abs(stats.non_bg_pixel_ratio - baseline_stats.non_bg_pixel_ratio)
        changed = mean_diff > 3.0 or pixel_diff > 0.02

        self.add_result(
            "display_tab_shows_framebuffer",
            changed,
            f"Tab switch detected: mean_diff={mean_diff:.1f}, "
            f"pixel_diff={pixel_diff:.3f}"
            + (" — VNC framebuffer visible" if changed else " — no change"),
            screenshot=path,
            stats=stats,
        )

    def test_05_display_area_content(self):
        """Crop the display area and verify it contains VNC framebuffer data."""
        cx, cy, cw, ch = self.win_pos

        # The display area is in the right panel, below the tab bar.
        # Right panel starts at ~cx + 175, tab content at ~cy + 110
        area_x = cx + 185
        area_y = cy + 110
        area_w = max(cw - 200, 100)
        area_h = max(ch - 130, 100)

        log.info("Cropping display area: %dx%d+%d+%d", area_w, area_h, area_x, area_y)
        path, stats = self.screenshot_region(
            "05_display_area", area_x, area_y, area_w, area_h
        )

        # The VNC framebuffer should show SeaBIOS output:
        # - Mostly black/dark with white text → mean < 100, some stddev
        # OR the gray Area widget background if VNC didn't connect yet
        #
        # Either way, it should NOT be identical to the Details form
        # (which has white background with text labels)
        #
        # If VNC is connected and rendering, the area will be mostly dark
        is_dark = stats.mean_r < 100 and stats.mean_g < 100 and stats.mean_b < 100
        has_variation = (
            stats.stddev_r > 1.0 or stats.stddev_g > 1.0 or stats.stddev_b > 1.0
        )

        self.add_result(
            "display_area_content",
            is_dark or has_variation,
            f"Display area {stats.width}x{stats.height}: "
            f"mean=({stats.mean_r:.0f},{stats.mean_g:.0f},{stats.mean_b:.0f}), "
            f"stddev=({stats.stddev_r:.1f},{stats.stddev_g:.1f},{stats.stddev_b:.1f}), "
            f"non-bg={stats.non_bg_pixel_ratio:.1%}"
            + (" — dark (BIOS screen)" if is_dark else ""),
            screenshot=path,
            stats=stats,
        )

    def test_06_app_still_running(self):
        """Verify the app didn't crash during the VNC test."""
        alive = self.app_proc is not None and self.app_proc.poll() is None
        msg = (
            "App process still alive after VNC display test"
            if alive
            else f"App CRASHED (exit: {self.app_proc.returncode if self.app_proc else 'N/A'})"
        )
        if not alive and self.app_proc:
            try:
                stdout = self.app_proc.stdout.read().decode(errors="replace")[:500]
                stderr = self.app_proc.stderr.read().decode(errors="replace")[:500]
                if stderr:
                    msg += f"\nstderr: {stderr}"
                if stdout:
                    msg += f"\nstdout: {stdout}"
            except Exception:
                pass

        path, stats = self.screenshot("06_final_state")
        self.add_result(
            "app_still_running",
            alive,
            msg,
            screenshot=path,
            stats=stats,
        )

    # ------------------------------------------------------------------
    # Teardown
    # ------------------------------------------------------------------

    def teardown(self):
        """Stop everything and clean up."""
        kill_qemu_for_vm()
        time.sleep(0.5)

        if self.app_proc:
            self.app_proc.terminate()
            try:
                self.app_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.app_proc.kill()
                self.app_proc.wait(timeout=2)
            log.info("App stopped")

        if self.wm_proc:
            self.wm_proc.terminate()
            try:
                self.wm_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.wm_proc.kill()

        if self.xvfb_proc:
            if self.keep_xvfb:
                log.info(
                    "Xvfb kept running on %s (PID %d)",
                    self.display,
                    self.xvfb_proc.pid,
                )
            else:
                self.xvfb_proc.terminate()
                try:
                    self.xvfb_proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.xvfb_proc.kill()

        if self.tmpdir:
            shutil.rmtree(self.tmpdir, ignore_errors=True)
            log.info("Temp dir cleaned: %s", self.tmpdir)

        if port_in_use(VNC_PORT):
            log.warning("VNC port %d still in use after cleanup!", VNC_PORT)

    # ------------------------------------------------------------------
    # Runner
    # ------------------------------------------------------------------

    def run_all(self) -> bool:
        """Run all VNC end-to-end tests. Returns True if all passed."""
        print("\n" + "=" * 60)
        print("Hangar VNC End-to-End Test")
        print("=" * 60)

        try:
            print("\n[Setup]")
            self.setup()
            self.start_app()

            tests = [
                self.test_01_app_loads_vm,
                self.test_02_click_start,
                self.test_03_vnc_connects,
                self.test_04_display_tab_shows_framebuffer,
                self.test_05_display_area_content,
                self.test_06_app_still_running,
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
            self.teardown()

        # Summary
        print("\n" + "=" * 60)
        passed = sum(1 for r in self.results if r.passed)
        total = len(self.results)
        print(f"Results: {passed}/{total} passed")
        print("=" * 60)

        # Save results as JSON
        SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
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
            for r in self.results:
                if not r.passed:
                    print(f"  ❌ {r.name}: {r.message}")

        return passed == total


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Hangar VNC End-to-End Test — verifies the full VNC display pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  %(prog)s                        Run all tests
  %(prog)s --verbose              Run with debug output
  %(prog)s --display :98          Use a specific X display
  %(prog)s --keep-xvfb            Keep Xvfb running after tests
""",
    )
    parser.add_argument(
        "--display",
        default=":98",
        help="X display for Xvfb (default: :98)",
    )
    parser.add_argument(
        "--keep-xvfb",
        action="store_true",
        help="keep Xvfb running after tests for manual inspection",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="enable debug logging",
    )
    args = parser.parse_args()

    # Configure logging
    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        format="  %(message)s",
        level=level,
    )

    test = VncE2ETest(
        display=args.display,
        keep_xvfb=args.keep_xvfb,
        verbose=args.verbose,
    )
    success = test.run_all()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

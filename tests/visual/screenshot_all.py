#!/usr/bin/env python3
"""Comprehensive screenshot pass — clicks through every dialog."""
import subprocess, os, time, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_visual import TestHarness, X11, SCREENSHOT_DIR

SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)

h = TestHarness(display=":99")
h.start_xvfb()
h.start_wm()
h.start_app()
h.init_x11()
h.win_pos = h.find_app_window()
cx, cy, cw, ch = h.win_pos

def ss(name):
    h.screenshot(name)
    print(f"  📸 {name}")

# 1. Home page
ss("01_home_page")

# 2. Click first VM in library (Favorites group)
# Library is ~200px wide, first VM row is at ~90px from top (40px toolbar + 30px header + 20px row)
h.x11.click(cx + 100, cy + 130)
time.sleep(0.5)
ss("02_vm_selected_summary")

# 3. Display tab — click at tab position
# Tabs are at top of content area. Display tab is roughly at x offset 300
h.x11.click(cx + 300, cy + 32)
time.sleep(0.5)
ss("03_display_tab")

# 4. Console tab
h.x11.click(cx + 400, cy + 32)
time.sleep(0.5)
ss("04_console_tab")

# 5. Home tab
h.x11.click(cx + 80, cy + 32)
time.sleep(0.5)
ss("05_back_to_home")

# 6. Open New VM dialog via toolbar
h.x11.click(cx + 60, cy + 70)
time.sleep(1.0)
ss("06_new_vm_dialog")

# 7. Close with Escape
h.x11.press_key(0xFF1B)  # Escape
time.sleep(0.5)
ss("07_after_escape")

# 8. Right-click on VM in library for context menu
h.x11.click(cx + 100, cy + 130, button=3)
time.sleep(0.5)
ss("08_context_menu")

# 9. Close context menu
h.x11.press_key(0xFF1B)
time.sleep(0.3)

# 10. Open Edit Settings via toolbar
h.x11.click(cx + 350, cy + 70)  # Settings button
time.sleep(1.0)
ss("09_edit_settings")

# 11. Close
h.x11.press_key(0xFF1B)
time.sleep(0.5)

# 12. Open Snapshot Manager
# Click VM menu via Alt+V or click the VM menu
h.x11.click(cx + 200, cy + 5)  # VM menu roughly at x=200 in menubar
time.sleep(0.5)
ss("10_snapshot_manager")

# 13. Close
h.x11.press_key(0xFF1B)
time.sleep(0.3)

print("\nAll screenshots captured!")
h.stop_app()
h.stop_wm()
h.stop_xvfb()

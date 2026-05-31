#!/usr/bin/env python3
"""Capture ALL dialogs and states for visual verification."""
import subprocess, os, time, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_visual import TestHarness, SCREENSHOT_DIR

SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
h = TestHarness(display=":99")
h.start_xvfb()
h.start_wm()
h.start_app()
h.init_x11()
h.win_pos = h.find_app_window()
cx, cy, cw, ch = h.win_pos
x11 = h.x11

def ss(name):
    h.screenshot(name)
    print(f"  📸 {name}")

def click_vm(idx=0):
    """Click VM in library sidebar. Each row is ~20px tall, starting ~130px from top."""
    x11.click(cx + 100, cy + 130 + idx * 20)
    time.sleep(0.4)

def press_esc():
    x11.press_key(0xFF1B)
    time.sleep(0.4)

def click_menu(x_offset):
    """Click a menu bar item. Menu bar items are roughly spaced 60px apart."""
    x11.click(cx + x_offset, cy + 5)
    time.sleep(0.6)

# === HOME PAGE ===
ss("all_01_home")

# === SELECT VM & SHOW SUMMARY ===
click_vm(0)  # First VM (Favorites)
time.sleep(0.5)
ss("all_02_summary_vm_selected")

# === DISPLAY TAB ===
x11.click(cx + 300, cy + 32)
time.sleep(0.5)
ss("all_03_display_tab")

# === CONSOLE TAB ===
x11.click(cx + 400, cy + 32)
time.sleep(0.5)
ss("all_04_console_tab")

# === BACK TO SUMMARY ===
x11.click(cx + 220, cy + 32)
time.sleep(0.5)

# === FILE MENU ===
click_menu(10)
ss("all_05_file_menu")
press_esc()

# === EDIT MENU ===
click_menu(80)
ss("all_06_edit_menu")
press_esc()

# === VM MENU ===
click_menu(150)
ss("all_07_vm_menu")
press_esc()

# === VIEW MENU → THEME ===
click_menu(210)
time.sleep(0.3)
x11.click(cx + 210, cy + 30)  # Hover over View
time.sleep(0.3)
x11.move_mouse(cx + 320, cy + 30)
time.sleep(0.3)
ss("all_08_view_theme_menu")
press_esc()
press_esc()

# === HELP MENU ===
click_menu(280)
ss("all_09_help_menu")
press_esc()

# === NEW VM DIALOG ===
x11.click(cx + 60, cy + 70)  # New VM toolbar
time.sleep(1.0)
ss("all_10_new_vm_general")
x11.click(cx + 300, cy + 120)  # Hardware tab
time.sleep(0.4)
ss("all_11_new_vm_hardware")
x11.click(cx + 420, cy + 120)  # Options tab
time.sleep(0.4)
ss("all_12_new_vm_options")
press_esc()

# === EDIT SETTINGS DIALOG ===
x11.click(cx + 350, cy + 70)  # Settings toolbar
time.sleep(1.0)
ss("all_13_edit_settings_general")
x11.click(cx + 300, cy + 120)  # Hardware tab
time.sleep(0.4)
ss("all_14_edit_settings_hardware")
x11.click(cx + 420, cy + 120)  # Options tab
time.sleep(0.4)
ss("all_15_edit_settings_options")
press_esc()

# === SNAPSHOT MANAGER ===
click_menu(150)  # VM menu
time.sleep(0.3)
# Move down to Snapshot Manager
x11.move_mouse(cx + 150, cy + 180)
time.sleep(0.3)
x11.click(cx + 150, cy + 180)
time.sleep(1.0)
ss("all_16_snapshot_manager")
press_esc()

# === VIRTUAL NETWORK EDITOR ===
click_menu(80)  # Edit menu
time.sleep(0.3)
x11.move_mouse(cx + 80, cy + 30)
time.sleep(0.3)
x11.click(cx + 80, cy + 30)
time.sleep(1.0)
ss("all_17_virtual_network_editor")

# Click NAT Settings
x11.move_mouse(cx + 400, cy + 440)
time.sleep(0.3)
x11.click(cx + 400, cy + 440)
time.sleep(0.5)
ss("all_18_nat_settings")
press_esc()
press_esc()

# === PREFERENCES ===
click_menu(80)  # Edit menu
time.sleep(0.3)
x11.move_mouse(cx + 80, cy + 60)
time.sleep(0.3)
x11.click(cx + 80, cy + 60)
time.sleep(1.0)
ss("all_19_preferences")
press_esc()

# === ABOUT ===
click_menu(280)  # Help menu
time.sleep(0.3)
x11.move_mouse(cx + 280, cy + 30)
time.sleep(0.3)
x11.click(cx + 280, cy + 30)
time.sleep(0.5)
ss("all_20_about")
press_esc()

# === EXPORT OVF (needs disk) ===
click_menu(10)  # File menu
time.sleep(0.3)
x11.move_mouse(cx + 10, cy + 100)
time.sleep(0.3)
# OVF dialog would need a directory picker - skip interactive part
press_esc()

# === RIGHT-CLICK CONTEXT MENU ===
click_vm(0)
time.sleep(0.3)
x11.click(cx + 100, cy + 130, button=3)
time.sleep(0.5)
ss("all_21_context_menu")
press_esc()

# === SELECT SECOND VM (non-favorite) ===
click_vm(4)  # In Powered On/Off section
time.sleep(0.5)
ss("all_22_second_vm_summary")

print("\n✅ All 22 screenshots captured!")
h.stop_app()
h.stop_wm()
h.stop_xvfb()

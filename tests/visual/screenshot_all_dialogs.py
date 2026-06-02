#!/usr/bin/env python3
"""Capture ALL dialogs and states for visual verification (FLTK layout).

FLTK window layout (1200x700):
  Menu bar:      y=0..25
  Toolbar row 1: y=28..68   buttons at y=31, h=34 (center_y=48)
  Toolbar row 2: y=68..110  buttons at y=71, h=34 (center_y=88)
  Sidebar:       x=0..200
    VM Library header: y=112..134
    Browser:           y=134..651
    Search input:      y=651..669
  Content area:  x=200
    Tabs:               y=112  ("Summary" ~x=240, "Display" ~x=310, "Console" ~x=372)
  Status bar:    y=674..700
"""
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

# Force 1200x700 window for predictable FLTK coordinate math.
# The app may have saved a smaller window size or the WM may have
# resized it.  Use xdotool to set the exact size we expect.
if cw != 1200 or ch != 700:
    subprocess.run(
        ["xdotool", "search", "--name", "Hangar", "windowsize", "1200", "700"],
        env={"DISPLAY": h.display},
        timeout=3,
    )
    time.sleep(0.3)
    h.win_pos = h.find_app_window()
    cx, cy, cw, ch = h.win_pos
    print(f"  Window resized to {cw}x{ch} for screenshot coords")
x11 = h.x11

# ── Derived FLTK layout offsets (relative to window top-left cx,cy) ──
# Menu bar items (Fl_Menu_Bar auto-layout, approximate centers):
M_FILE = cx + 25;  M_EDIT = cx + 75;  M_VM   = cx + 120
M_VIEW = cx + 168; M_HELP = cx + 218
MENU_Y = cy + 12   # vertical center of menu bar (height 25)

# Toolbar row 1 buttons (y=31, h=34):
TB1_Y = cy + 48    # 31 + 17
BTN_NEW     = cx + 45   # x=5,  w=80
BTN_POWER   = cx + 130  # x=90, w=80
BTN_PAUSE   = cx + 300  # x=260,w=80
BTN_RESUME  = cx + 385  # x=345,w=80
BTN_SD      = cx + 470  # x=430,w=80
BTN_SET     = cx + 640  # x=600,w=80
BTN_SNAP    = cx + 877  # x=840,w=75
BTN_HOME    = cx + 1040 # x=1005,w=70

# Toolbar row 2 (y=71, h=34):
TB2_Y = cy + 88    # 71 + 17
BTN_VNET    = cx + 345 # x=310,w=70
BTN_PREFS   = cx + 420 # x=385,w=70

# Sidebar VM browser:
BROWSER_X = cx + 100   # center of 200px sidebar
BROWSER_Y0 = cy + 144  # 134 + 10 (first line center)
BROWSER_DY = 20

# Tabs (x=200, y=112; tab labels at top):
TAB_Y = cy + 122
TAB_SUMMARY  = cx + 240
TAB_DISPLAY  = cx + 310
TAB_CONSOLE  = cx + 372


def ss(name):
    h.screenshot(name)
    print(f"  📸 {name}")

def click_vm(idx=0):
    x11.click(BROWSER_X, BROWSER_Y0 + idx * BROWSER_DY)
    time.sleep(0.4)

def press_esc():
    x11.press_key(0xFF1B)
    time.sleep(0.3)

def click_menu(x_abs):
    """Click a menu bar item at absolute screen position."""
    x11.click(x_abs, MENU_Y)
    time.sleep(0.5)

def type_str(s):
    x11.type_string(s)
    time.sleep(0.15)

# ══════════════════════════════════════════════════════════════════
# HOME PAGE
# ══════════════════════════════════════════════════════════════════
ss("all_01_home")

# ══════════════════════════════════════════════════════════════════
# SELECT FIRST VM → SUMMARY TAB
# ══════════════════════════════════════════════════════════════════
click_vm(0)
time.sleep(0.3)
ss("all_02_summary_vm_selected")

# ══════════════════════════════════════════════════════════════════
# DISPLAY TAB
# ══════════════════════════════════════════════════════════════════
x11.click(TAB_DISPLAY, TAB_Y)
time.sleep(0.5)
ss("all_03_display_tab")

# ══════════════════════════════════════════════════════════════════
# CONSOLE TAB
# ══════════════════════════════════════════════════════════════════
x11.click(TAB_CONSOLE, TAB_Y)
time.sleep(0.5)
ss("all_04_console_tab")

# Back to Summary
x11.click(TAB_SUMMARY, TAB_Y)
time.sleep(0.4)

# ══════════════════════════════════════════════════════════════════
# FILE MENU
# ══════════════════════════════════════════════════════════════════
click_menu(M_FILE)
ss("all_05_file_menu")
press_esc()

# ══════════════════════════════════════════════════════════════════
# EDIT MENU
# ══════════════════════════════════════════════════════════════════
click_menu(M_EDIT)
ss("all_06_edit_menu")
press_esc()

# ══════════════════════════════════════════════════════════════════
# VM MENU
# ══════════════════════════════════════════════════════════════════
click_menu(M_VM)
ss("all_07_vm_menu")
press_esc()

# ══════════════════════════════════════════════════════════════════
# HELP MENU
# ══════════════════════════════════════════════════════════════════
click_menu(M_HELP)
ss("all_08_help_menu")
press_esc()

# ══════════════════════════════════════════════════════════════════
# NEW VM DIALOG (single page, no tabs in FLTK)
# ══════════════════════════════════════════════════════════════════
x11.click(BTN_NEW, TB1_Y)
time.sleep(0.8)
ss("all_09_new_vm_dialog")
press_esc()

# ══════════════════════════════════════════════════════════════════
# EDIT SETTINGS DIALOG (scrollable single page, no tabs)
# ══════════════════════════════════════════════════════════════════
click_vm(0)
time.sleep(0.3)
x11.click(BTN_SET, TB1_Y)
time.sleep(0.8)
ss("all_10_edit_settings")
press_esc()

# ══════════════════════════════════════════════════════════════════
# SNAPSHOT MANAGER
# ══════════════════════════════════════════════════════════════════
click_menu(M_VM)
time.sleep(0.3)
# Snapshot Manager is 6th item in VM menu (below Reset, above Clone)
x11.click(M_VM + 20, cy + 22 + 6 * 22)
time.sleep(0.8)
ss("all_11_snapshot_manager")
press_esc()

# ══════════════════════════════════════════════════════════════════
# VIRTUAL NETWORK EDITOR
# ══════════════════════════════════════════════════════════════════
click_menu(M_EDIT)
time.sleep(0.3)
# "Virtual Network Editor..." is 2nd item in Edit menu
x11.click(M_EDIT + 20, cy + 22 + 2 * 22)
time.sleep(0.8)
ss("all_12_virtual_network_editor")
press_esc()

# ══════════════════════════════════════════════════════════════════
# PREFERENCES
# ══════════════════════════════════════════════════════════════════
click_menu(M_EDIT)
time.sleep(0.3)
# "Preferences..." is 1st item in Edit menu
x11.click(M_EDIT + 20, cy + 22 + 1 * 22)
time.sleep(0.8)
ss("all_13_preferences")
press_esc()

# ══════════════════════════════════════════════════════════════════
# ABOUT
# ══════════════════════════════════════════════════════════════════
click_menu(M_HELP)
time.sleep(0.3)
# "About Hangar" is 1st item in Help menu
x11.click(M_HELP + 20, cy + 22 + 1 * 22)
time.sleep(0.6)
ss("all_14_about")
press_esc()

# ══════════════════════════════════════════════════════════════════
# RIGHT-CLICK CONTEXT MENU (on first VM in browser)
# ══════════════════════════════════════════════════════════════════
click_vm(0)
time.sleep(0.3)
x11.click(BROWSER_X, BROWSER_Y0, button=3)
time.sleep(0.5)
ss("all_15_context_menu")
press_esc()

# ══════════════════════════════════════════════════════════════════
# SELECT SECOND VM (non-favorite, ~5th line)
# ══════════════════════════════════════════════════════════════════
click_vm(4)
time.sleep(0.5)
ss("all_16_second_vm_summary")

# ══════════════════════════════════════════════════════════════════
# CLONE DIALOG
# ══════════════════════════════════════════════════════════════════
click_vm(0)
time.sleep(0.3)
# Click Clone in toolbar row 1 (x=765, center ~cx+800)
x11.click(cx + 800, TB1_Y)
time.sleep(0.8)
ss("all_17_clone_dialog")
press_esc()

# ══════════════════════════════════════════════════════════════════
# RENAME DIALOG
# ══════════════════════════════════════════════════════════════════
click_menu(M_VM)
time.sleep(0.3)
# "Rename..." is below Settings in VM menu
x11.click(M_VM + 20, cy + 22 + 8 * 22)
time.sleep(0.6)
ss("all_18_rename_dialog")
press_esc()

# ══════════════════════════════════════════════════════════════════
# CONNECT TO REMOTE
# ══════════════════════════════════════════════════════════════════
click_menu(M_FILE)
time.sleep(0.3)
# "Connect to Remote Server..." is 4th item in File menu
x11.click(M_FILE + 20, cy + 22 + 4 * 22)
time.sleep(0.8)
ss("all_19_remote_connect")
press_esc()

# ══════════════════════════════════════════════════════════════════
# EXPORT OVF (needs a selected VM with disk)
# ══════════════════════════════════════════════════════════════════
click_menu(M_FILE)
time.sleep(0.3)
# "Export OVF..." is 3rd item in File menu (needs native file chooser)
x11.click(M_FILE + 20, cy + 22 + 3 * 22)
time.sleep(0.6)
ss("all_20_export_ovf")
press_esc()

# ══════════════════════════════════════════════════════════════════
# HOME BUTTON (deselect VM, show home screen)
# ══════════════════════════════════════════════════════════════════
x11.click(BTN_HOME, TB1_Y)
time.sleep(0.5)
ss("all_21_home_deselected")

# ══════════════════════════════════════════════════════════════════
# SEARCH FILTER (type in search box at bottom of sidebar)
# ══════════════════════════════════════════════════════════════════
x11.click(cx + 100, cy + 660)
time.sleep(0.2)
type_str("test")
time.sleep(0.3)
ss("all_22_search_filter")
press_esc()

print("\n✅ All 22 screenshots captured!")
h.stop_app()
h.stop_wm()
h.stop_xvfb()

#!/usr/bin/env python3
"""FLTK Hangar visual test harness — screenshots every dialog."""
import subprocess, os, time, ctypes, sys
from pathlib import Path
from PIL import Image, ImageStat

XPORT = ':95'
SCREENSHOT_DIR = Path('tests/visual/screenshots/fltk')
SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)

class X11:
    def __init__(self, display):
        self.x11 = ctypes.cdll.LoadLibrary('libX11.so.6')
        self.xtst = ctypes.cdll.LoadLibrary('libXtst.so.6')
        self.d = self.x11.XOpenDisplay(display.encode())
        if not self.d: raise RuntimeError(f'Cannot open {display}')
    def click(self, x, y, btn=1):
        self.xtst.XTestFakeMotionEvent(self.d, -1, x, y, 0)
        self.x11.XFlush(self.d)
        time.sleep(0.05)
        self.xtst.XTestFakeButtonEvent(self.d, btn, 1, 0)
        self.xtst.XTestFakeButtonEvent(self.d, btn, 0, 0)
        self.x11.XFlush(self.d)
    def key(self, keysym):
        kc = self.x11.XKeysymToKeycode(self.d, keysym)
        if kc:
            self.xtst.XTestFakeKeyEvent(self.d, kc, 1, 0)
            self.xtst.XTestFakeKeyEvent(self.d, kc, 0, 0)
            self.x11.XFlush(self.d)
    def type(self, text):
        for ch in text:
            ks = self.x11.XStringToKeysym(ch.encode())
            if ks:
                kc = self.x11.XKeysymToKeycode(self.d, ks)
                if kc:
                    self.xtst.XTestFakeKeyEvent(self.d, kc, 1, 0)
                    self.xtst.XTestFakeKeyEvent(self.d, kc, 0, 0)
                    self.x11.XFlush(self.d)
                    time.sleep(0.02)

def capture(name, actions_fn=None):
    xvfb = subprocess.Popen(['Xvfb', XPORT, '-screen', '0', '1280x800x24', '-ac'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    env = os.environ.copy(); env['DISPLAY'] = XPORT; env.pop('WAYLAND_DISPLAY', None); env['FLTK_BACKEND'] = 'x11'
    app = subprocess.Popen(['./zig-out/bin/hangar'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    try:
        if actions_fn:
            x11 = X11(XPORT)
            actions_fn(x11)
    except Exception as e:
        print(f'  ⚠️  {name}: interaction failed: {e}')
    subprocess.run(['import', '-display', XPORT, '-window', 'root', str(SCREENSHOT_DIR / f'{name}.png')], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app.terminate(); app.wait()
    xvfb.terminate(); xvfb.wait()
    try:
        img = Image.open(SCREENSHOT_DIR / f'{name}.png').convert('RGB')
        s = ImageStat.Stat(img)
        ok = not (s.stddev[0] < 5 and s.stddev[1] < 5 and s.stddev[2] < 5)
        print(f'  {"✅" if ok else "❌"} {name}: {img.width}x{img.height} std=({s.stddev[0]:.0f},{s.stddev[1]:.0f},{s.stddev[2]:.0f})')
        return ok
    except: return False

results = []
results.append(('01_home_page', capture('01_home_page')))
results.append(('02_click_new_vm', capture('02_click_new_vm', lambda x: x.click(50, 45))))
results.append(('03_new_vm_dialog', capture('03_new_vm_dialog', lambda x: (x.click(50, 45), time.sleep(1.5)))))
results.append(('04_type_vm_name', capture('04_type_vm_name', lambda x: (x.click(50, 45), time.sleep(1), x.click(170, 20), time.sleep(0.3), x.click(170, 20), time.sleep(0.3), x.type('TestVM')))))
passed = sum(1 for _, ok in results if ok)
print(f'\nResults: {passed}/{len(results)} passed')
sys.exit(0 if passed == len(results) else 1)

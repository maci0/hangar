#!/usr/bin/env python3
"""Capture FLTK Hangar screenshots under Xvfb."""
import subprocess, os, time, sys
from PIL import Image, ImageStat

XPORT = ':96'

def capture(name, click_x=None, click_y=None, key=None):
    xvfb = subprocess.Popen(['Xvfb', XPORT, '-screen', '0', '1280x800x24', '-ac'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    env = os.environ.copy()
    env['DISPLAY'] = XPORT
    env.pop('WAYLAND_DISPLAY', None)
    env['FLTK_BACKEND'] = 'x11'
    app = subprocess.Popen(['./zig-out/bin/hangar'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    
    if click_x:
        import ctypes
        x11 = ctypes.cdll.LoadLibrary('libX11.so.6')
        xtst = ctypes.cdll.LoadLibrary('libXtst.so.6')
        d = x11.XOpenDisplay(XPORT.encode())
        if d:
            xtst.XTestFakeMotionEvent(d, -1, click_x, click_y, 0)
            x11.XFlush(d)
            time.sleep(0.1)
            xtst.XTestFakeButtonEvent(d, 1, 1, 0)
            xtst.XTestFakeButtonEvent(d, 1, 0, 0)
            x11.XFlush(d)
            time.sleep(0.5)
    
    subprocess.run(['import', '-display', XPORT, '-window', 'root', f'/tmp/hangar_{name}.png'], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app.terminate(); app.wait()
    xvfb.terminate(); xvfb.wait()
    
    img = Image.open(f'/tmp/hangar_{name}.png').convert('RGB')
    s = ImageStat.Stat(img)
    print(f'  {name}: {img.width}x{img.height} std=({s.stddev[0]:.0f},{s.stddev[1]:.0f},{s.stddev[2]:.0f}) blank={s.stddev[0]<5}')

capture('home')
capture('after_power_click', click_x=290, click_y=45)  # Power On button
print('Done')

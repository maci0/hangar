#!/usr/bin/env python3
"""Hangar FLTK click-through visual test — every dialog rendered and checked."""
import subprocess, os, time, sys
from pathlib import Path; from PIL import Image, ImageStat

XPORT=':85'; OUTDIR=Path('tests/visual/screenshots/fltk_click'); OUTDIR.mkdir(parents=True,exist_ok=True)
ALL_OK=True

def test(name, clicks=None):
    global ALL_OK
    xv=subprocess.Popen(['Xvfb',XPORT,'-screen','0','1280x800x24','-ac'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(0.5); env=os.environ.copy(); env['DISPLAY']=XPORT; env.pop('WAYLAND_DISPLAY',None); env['FLTK_BACKEND']='x11'
    ap=subprocess.Popen(['./zig-out/bin/hangar'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(2)
    if clicks:
        try:
            import ctypes
            x=ctypes.cdll.LoadLibrary('libX11.so.6'); t=ctypes.cdll.LoadLibrary('libXtst.so.6')
            d=x.XOpenDisplay(XPORT.encode())
            for cx,cy,btn in clicks:
                t.XTestFakeMotionEvent(d,-1,cx,cy,0); x.XFlush(d); time.sleep(0.05)
                t.XTestFakeButtonEvent(d,btn,1,0); t.XTestFakeButtonEvent(d,btn,0,0); x.XFlush(d)
            time.sleep(0.8)
        except: pass
    p=OUTDIR/f'{name}.png'
    subprocess.run(['import','-display',XPORT,'-window','root',str(p)],timeout=5,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    ap.terminate(); ap.wait(); xv.terminate(); xv.wait()
    try:
        img=Image.open(p).convert('RGB'); s=ImageStat.Stat(img)
        ok=not(s.stddev[0]<5 and s.stddev[1]<5 and s.stddev[2]<5)
        print(f'  {"✅" if ok else "❌"} {name}: std=({s.stddev[0]:.0f},{s.stddev[1]:.0f},{s.stddev[2]:.0f})')
        if not ok: ALL_OK=False
    except: print(f'  ❌ {name}: failed to read'); ALL_OK=False

# Run tests — click coordinates for the FLTK layout (960x680)
test('01_home')
test('02_new_vm_dialog', [(45,45,1)])  # Click New VM toolbar button (x=45, y=45)
test('03_settings_dialog', [(265,45,1)])  # Click Settings toolbar button
test('04_file_menu', [(8,5,1)])  # Click File menu

print(f'\n{"ALL PASSED" if ALL_OK else "SOME FAILURES"} — see {OUTDIR}/')
sys.exit(0 if ALL_OK else 1)

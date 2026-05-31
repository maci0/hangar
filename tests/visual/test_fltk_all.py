#!/usr/bin/env python3
"""FLTK KVMGUI automated visual tests — clicks through all UI states."""
import subprocess, os, time, ctypes, sys
from pathlib import Path
from PIL import Image, ImageStat

XPORT = ':94'
OUT = Path('tests/visual/screenshots/fltk')
OUT.mkdir(parents=True, exist_ok=True)
results = []

class X11:
    def __init__(self, d): self.x11=ctypes.cdll.LoadLibrary('libX11.so.6'); self.xtst=ctypes.cdll.LoadLibrary('libXtst.so.6'); self.d=self.x11.XOpenDisplay(d.encode())
    def click(self,x,y,b=1): self.xtst.XTestFakeMotionEvent(self.d,-1,x,y,0); self.x11.XFlush(self.d); time.sleep(0.05); self.xtst.XTestFakeButtonEvent(self.d,b,1,0); self.xtst.XTestFakeButtonEvent(self.d,b,0,0); self.x11.XFlush(self.d)
    def key(self,k): kc=self.x11.XKeysymToKeycode(self.d,k)
    def type(self,t):
        for c in t:
            ks=self.x11.XStringToKeysym(c.encode())
            if ks: kc=self.x11.XKeysymToKeycode(self.d,ks)
            if kc: self.xtst.XTestFakeKeyEvent(self.d,kc,1,0); self.xtst.XTestFakeKeyEvent(self.d,kc,0,0); self.x11.XFlush(self.d); time.sleep(0.02)

def test(name, fn=None):
    xvfb=subprocess.Popen(['Xvfb',XPORT,'-screen','0','1280x800x24','-ac'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    env=os.environ.copy(); env['DISPLAY']=XPORT; env.pop('WAYLAND_DISPLAY',None); env['FLTK_BACKEND']='x11'
    app=subprocess.Popen(['./zig-out/bin/kvmgui'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(2)
    try:
        if fn:
            x11=X11(XPORT)
            fn(x11)
            time.sleep(0.5)
    except Exception as e: print(f'  ⚠️  {name}: {e}')
    p=OUT/f'{name}.png'
    subprocess.run(['import','-display',XPORT,'-window','root',str(p)],timeout=5,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    app.terminate(); app.wait()
    xvfb.terminate(); xvfb.wait()
    try:
        img=Image.open(p).convert('RGB'); s=ImageStat.Stat(img)
        ok=not(s.stddev[0]<5 and s.stddev[1]<5 and s.stddev[2]<5)
        print(f'  {"✅" if ok else "❌"} {name}: {img.width}x{img.height} std=({s.stddev[0]:.0f},{s.stddev[1]:.0f},{s.stddev[2]:.0f})')
        results.append((name,ok))
    except: results.append((name,False))

# Run tests
test('01_home')
test('02_click_new_vm', lambda x: (x.click(45,45), time.sleep(1.5)))
test('03_new_vm_visible', lambda x: (x.click(45,45), time.sleep(2)))
test('04_edit_settings', lambda x: (x.click(265,45), time.sleep(1.5)))
test('05_snapshot_mgr', lambda x: (x.click(45,45), time.sleep(0.3), x.click(200,70), time.sleep(1.5)))

passed=sum(1 for _,ok in results if ok)
print(f'\nResults: {passed}/{len(results)} passed')
sys.exit(0 if passed==len(results) else 1)

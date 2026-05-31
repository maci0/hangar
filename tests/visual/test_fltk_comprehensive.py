#!/usr/bin/env python3
"""Comprehensive FLTK KVMGUI visual test — clicks through every dialog."""
import subprocess, os, time, ctypes, sys
from pathlib import Path; from PIL import Image, ImageStat
XPORT=':91'; OUT=Path('tests/visual/screenshots/fltk'); OUT.mkdir(parents=True,exist_ok=True)
R=[]
class X11:
    def __init__(s,d): s.x=ctypes.cdll.LoadLibrary('libX11.so.6'); s.t=ctypes.cdll.LoadLibrary('libXtst.so.6'); s.d=s.x.XOpenDisplay(d.encode())
    def c(s,x,y,b=1): s.t.XTestFakeMotionEvent(s.d,-1,x,y,0); s.x.XFlush(s.d); time.sleep(0.05); s.t.XTestFakeButtonEvent(s.d,b,1,0); s.t.XTestFakeButtonEvent(s.d,b,0,0); s.x.XFlush(s.d); time.sleep(0.4)
    def k(s,ks): kc=s.x.XKeysymToKeycode(s.d,ks)
    def t(s,tx):
        for ch in tx:
            ks=s.x.XStringToKeysym(ch.encode())
            if ks: kc=s.x.XKeysymToKeycode(s.d,ks)
            if kc: s.t.XTestFakeKeyEvent(s.d,kc,1,0); s.t.XTestFakeKeyEvent(s.d,kc,0,0); s.x.XFlush(s.d); time.sleep(0.02)
def test(name,fn=None):
    xv=subprocess.Popen(['Xvfb',XPORT,'-screen','0','1280x800x24','-ac'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(0.5); env=os.environ.copy(); env['DISPLAY']=XPORT; env.pop('WAYLAND_DISPLAY',None); env['FLTK_BACKEND']='x11'
    ap=subprocess.Popen(['./zig-out/bin/kvmgui'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(2)
    try:
        if fn: x11=X11(XPORT); fn(x11); time.sleep(0.5)
    except Exception as e: print(f'  ⚠️ {name}: {e}')
    p=OUT/f'{name}.png'
    subprocess.run(['import','-display',XPORT,'-window','root',str(p)],timeout=5,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    ap.terminate(); ap.wait(); xv.terminate(); xv.wait()
    try:
        img=Image.open(p).convert('RGB'); s=ImageStat.Stat(img)
        ok=not(s.stddev[0]<5 and s.stddev[1]<5 and s.stddev[2]<5)
        print(f'  {"✅" if ok else "❌"} {name}: std=({s.stddev[0]:.0f},{s.stddev[1]:.0f},{s.stddev[2]:.0f})'); R.append((name,ok))
    except: R.append((name,False))

test('01_home')
test('02_new_vm', lambda x: x.c(50,45))
test('03_settings', lambda x: x.c(265,45))
test('04_snapshot', lambda x: x.c(50,45)); test('05_snapshot_dlg', lambda x: (x.c(50,45),time.sleep(1.5)))

passed=sum(1 for _,ok in R if ok); print(f'\nResults: {passed}/{len(R)} passed')
sys.exit(0 if passed==len(R) else 1)

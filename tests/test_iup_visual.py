import subprocess
import time
import os

os.environ["GDK_BACKEND"] = "x11"
p = subprocess.Popen(["xvfb-run", "-a", "./zig-out/bin/kvmgui-iup"])
time.sleep(2)
p.kill()

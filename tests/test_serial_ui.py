import subprocess
import time
import os

os.environ["GDK_BACKEND"] = "x11"

p = subprocess.Popen(["xvfb-run", "-a", "./zig-out/bin/hangar", "--verbose"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(2) # let it start

# I can't easily click "New VM" and "Power On" from here without pyautogui or libui testing frameworks.
p.kill()

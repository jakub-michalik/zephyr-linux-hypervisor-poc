#!/usr/bin/env python3
"""Send keystrokes to the emulated board's serial console and print the reply.
   serial.py 'xen:q'   -> switch input to Xen (Ctrl-a x3), send debug key 'q', switch back
   serial.py 'text\n'  -> send raw text to Dom0 console
"""
import os, socket, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(ROOT, "build", "serial.sock"))
s.settimeout(0.5)
arg = sys.argv[1]
if arg.startswith("xen:"):
    payload = b"\x01\x01\x01" + arg[4:].encode() + b"\x01\x01\x01"
else:
    payload = arg.encode().decode("unicode_escape").encode()
s.sendall(payload)
out = b""
end = time.time() + float(sys.argv[2] if len(sys.argv) > 2 else 3)
while time.time() < end:
    try:
        out += s.recv(65536)
    except socket.timeout:
        pass
print(out.decode(errors="replace"))

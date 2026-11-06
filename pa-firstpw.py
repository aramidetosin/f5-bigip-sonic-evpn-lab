#!/usr/bin/env python3
"""pa-firstpw.py <PA address>: complete the PA-VM's first-login password change over SSH (factory admin/admin -> PA_PW).

pa-load.sh calls it only if the API still answers "Please change your password" (the container's launcher normally does
this change on the serial console). The new password comes from PA_PW in the environment; nothing is printed.
"""
import os, pty, re, select, sys, time

pa, new = sys.argv[1], os.environ.get("PA_PW", "")
if not new:
    sys.exit("pa-firstpw: PA_PW not set")
user = os.environ.get("PA_USER", "admin")
pid, fd = pty.fork()
if pid == 0:
    os.execvp("ssh", ["ssh", "-tt", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                      "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password",
                      "-o", "ConnectTimeout=15", f"{user}@{pa}"])
buf, sent, deadline = b"", [], time.time() + 120
steps = [(rb"Enter old password\s*:", b"admin"), (rb"Enter new password\s*:", new.encode()), (rb"Confirm password\s*:", new.encode()),
         (rb"[pP]assword:", b"admin")]          # the SSH login itself (factory password), last so the change prompts win
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 2)
    if not r:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if "confirm" not in sent and re.search(rb"[Ff]ailed|incorrect|denied", buf[-200:]):   # after the confirm, pa-load.sh's key check decides
        print("pa-firstpw: refused"); sys.exit(1)
    if "confirm" in sent and re.search(rb"[\w.-]+@[\w.-]+[>#]\s*$", buf):
        os.write(fd, b"exit\n"); print("pa-firstpw: password changed"); sys.exit(0)
    for i, (pat, ans) in enumerate(steps):
        m = re.search(pat + rb"\s*$", buf)
        if m:
            name = ["old", "new", "confirm", "login"][i]
            os.write(fd, ans + b"\n"); sent.append(name); buf = b""
            break
print("pa-firstpw: no result (sent: %s)" % ",".join(sent)); sys.exit(1)

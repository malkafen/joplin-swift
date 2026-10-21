#!/usr/bin/env python3
"""Samples CPU time and memory of every process of an app until killed, for scripts/stress/report.py.
Usage: sample.py <path part, e.g. "/Joplin.app/"> <out.jsonl> [interval s, default 0.25]
Each line: {"t": unix time, "cpu": CPU seconds used so far by all its processes (user + system, counted per process,
so helpers that come and go are included), "mb": summed physical footprint (Activity Monitor's Memory), "n": processes}.
Reads the kernel's per-process accounting (proc_pid_rusage), the same numbers Activity Monitor shows."""
import ctypes, json, signal, sys, time

lib = ctypes.CDLL("/usr/lib/libproc.dylib")
libc = ctypes.CDLL("/usr/lib/libSystem.dylib")

class RUsage(ctypes.Structure):  # rusage_info_v2
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size", "resident_size",
        "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time", "child_system_time",
        "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins", "child_elapsed_abstime",
        "diskio_bytesread", "diskio_byteswritten")]

class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = Timebase(); libc.mach_timebase_info(ctypes.byref(tb))
TICK = tb.numer / tb.denom / 1e9  # rusage times are in mach absolute time units

def processes(part):
    buf = (ctypes.c_int * 8192)()
    n = lib.proc_listallpids(buf, ctypes.sizeof(buf))
    path = ctypes.create_string_buffer(4096)
    for pid in buf[:max(0, n)]:
        if pid > 0 and lib.proc_pidpath(pid, path, 4096) > 0 and part in path.value.decode(errors="replace"):
            yield pid

def main():
    part, out = sys.argv[1], sys.argv[2]
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.25
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    seen = {}  # pid -> CPU seconds at the last sample
    total = 0.0
    with open(out, "w") as f:
        while True:
            mb, n = 0.0, 0
            for pid in processes(part):
                r = RUsage()
                if lib.proc_pid_rusage(pid, 2, ctypes.byref(r)) != 0: continue
                cpu = (r.user_time + r.system_time) * TICK
                total += cpu - seen.get(pid, 0.0)
                seen[pid] = cpu
                mb += r.phys_footprint / 1048576
                n += 1
            f.write(json.dumps({"t": round(time.time(), 3), "cpu": round(total, 3), "mb": round(mb), "n": n}) + "\n")
            f.flush()
            time.sleep(interval)

main()

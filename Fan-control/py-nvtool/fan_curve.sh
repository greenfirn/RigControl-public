# --- write fan_curve.py --- NVML-based fan curve daemon (no Xorg/Coolbits needed)

sudo tee /usr/local/bin/fan_curve.py > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
fan_curve.py — NVML-based fan curve daemon.

Replaces the old nvidia-settings / Xorg / Coolbits / passthrough-detection
stack with direct NVML calls (via nvtool.py). No X server, no Coolbits,
no clock-bounce fallback needed — manual fan control works the same
whether the GPU is idle or fully loaded with compute.

Usage:
    sudo python3 fan_curve.py                      # all GPUs, default curve
    sudo python3 fan_curve.py --index 0             # GPU 0 only
    sudo python3 fan_curve.py --interval 2 --hysteresis 3
    sudo python3 fan_curve.py --curve "30:30,50:40,65:55,75:75,83:100"

On exit (Ctrl+C or SIGTERM/systemd stop), all controlled fans are reset
to automatic (driver/firmware) control before the process exits.

Watchdog:
    If run under systemd with Type=notify and WatchdogSec= set, this
    script pings systemd once per successful tick (i.e. once every full
    pass over all controlled GPUs). If an NVML call hangs (rather than
    raising an error — the known failure mode with GSP firmware issues
    like Xid 109/119/154) the ping stops, systemd's watchdog fires, and
    the unit is killed + restarted by Restart=always. Without a running
    NOTIFY_SOCKET (e.g. run by hand from a shell) this is a harmless
    no-op.
"""

import argparse
import os
import signal
import socket
import sys
import time

import nvtool as nv


# Default temp(C) -> fan(%) curve. Edit to taste, or override with --curve.
DEFAULT_CURVE = [
    (30, 30),
    (45, 35),
    (55, 45),
    (65, 55),
    (75, 75),
    (83, 100),
]

_shutdown_requested = False


def _handle_signal(signum, frame):
    global _shutdown_requested
    _shutdown_requested = True


def sd_notify(message):
    """Send a message to systemd via NOTIFY_SOCKET; no-op if not running under systemd."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr[0] == "@":
        addr = "\0" + addr[1:]
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC)
        try:
            sock.connect(addr)
            sock.sendall(message.encode())
        finally:
            sock.close()
    except OSError:
        # Don't let a notify-socket hiccup take down fan control.
        pass


def parse_curve(spec):
    """Parse 'temp:pct,temp:pct,...' into a sorted list of (temp, pct) tuples."""
    points = []
    for pair in spec.split(","):
        temp_s, pct_s = pair.split(":")
        points.append((float(temp_s), float(pct_s)))
    points.sort(key=lambda p: p[0])
    if len(points) < 2:
        raise ValueError("Curve needs at least two points")
    return points


def temp_to_pct(temp, curve):
    """Linear interpolation between curve points. Clamps below/above the ends."""
    if temp <= curve[0][0]:
        return curve[0][1]
    if temp >= curve[-1][0]:
        return curve[-1][1]
    for (t0, p0), (t1, p1) in zip(curve, curve[1:]):
        if t0 <= temp <= t1:
            if t1 == t0:
                return p1
            frac = (temp - t0) / (t1 - t0)
            return p0 + frac * (p1 - p0)
    return curve[-1][1]


def get_gpu_indices(index_arg):
    if index_arg is not None and index_arg >= 0:
        return [index_arg]
    count = nv.nvmlDeviceGetCount()
    return list(range(count))


def reset_to_auto(handles):
    for idx, handle in handles.items():
        try:
            num_fans = nv.nvmlDeviceGetNumFans(handle)
            for fan in range(num_fans):
                nv.nvmlDeviceSetDefaultFanSpeed_v2(handle, fan)
            print(f"[FAN] GPU {idx}: reset {num_fans} fan(s) to AUTO")
        except nv.NVMLError as error:
            print(f"[FAN] GPU {idx}: WARN could not reset to auto ({error})")


def main():
    parser = argparse.ArgumentParser(description="NVML fan curve daemon")
    parser.add_argument("--index", type=int, default=-1,
                         help="GPU index to control (-1 = all GPUs, default)")
    parser.add_argument("--interval", type=float, default=2.0,
                         help="Poll interval in seconds (default: 2)")
    parser.add_argument("--hysteresis", type=float, default=2.0,
                         help="Minimum %% change before re-issuing a fan-speed "
                              "write (default: 2)")
    parser.add_argument("--curve", type=str, default=None,
                         help="Custom curve as 'temp:pct,temp:pct,...' "
                              "e.g. '30:30,50:40,65:55,75:75,83:100'")
    parser.add_argument("--cooldown-delta", type=float, default=10.0,
                         help="Temp drop (C) below the recent peak that triggers "
                              "a hold before lowering the fan (default: 10, "
                              "0 disables holding)")
    parser.add_argument("--cooldown-seconds", type=float, default=15.0,
                         help="How long a drop must hold before the fan is "
                              "actually lowered (default: 15)")
    args = parser.parse_args()

    curve = parse_curve(args.curve) if args.curve else DEFAULT_CURVE

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    try:
        nv.nvmlInit()
    except nv.NVMLError as error:
        print(f"[FAN] FATAL: nvmlInit failed: {error}")
        sys.exit(1)

    handles = {}
    last_pct = {}
    peak_temp = {}
    hold_since = {}

    try:
        indices = get_gpu_indices(args.index)
        if not indices:
            print("[FAN] FATAL: no GPUs found.")
            sys.exit(1)

        for idx in indices:
            handles[idx] = nv.nvmlDeviceGetHandleByIndex(idx)
            name = nv.nvmlDeviceGetName(handles[idx])
            print(f"[FAN] Controlling GPU {idx}: {name}")

        print(f"[FAN] Curve: {curve}")
        print(f"[FAN] Interval={args.interval}s Hysteresis={args.hysteresis}%")

        sd_notify("READY=1\nSTATUS=Controlling {} GPU(s)".format(len(handles)))

        while not _shutdown_requested:
            for idx, handle in handles.items():
                try:
                    temp = nv.nvmlDeviceGetTemperature(handle, nv.NVML_TEMPERATURE_GPU)
                except nv.NVMLError as error:
                    print(f"[FAN] GPU {idx}: WARN temp read failed ({error}), skipping this tick")
                    continue

                target_pct = round(temp_to_pct(temp, curve))
                prev_pct = last_pct.get(idx)

                # --- cooldown hold: debounce downward moves against temp spikes ---
                peak = peak_temp.get(idx, temp)
                if temp >= peak:
                    peak_temp[idx] = temp
                    hold_since[idx] = None
                elif args.cooldown_delta > 0:
                    drop = peak - temp
                    if drop >= args.cooldown_delta:
                        if hold_since.get(idx) is None:
                            hold_since[idx] = time.monotonic()
                            print(f"[FAN] GPU {idx}: {temp}C is {drop:.0f}C below "
                                  f"peak {peak:.0f}C, holding fan for "
                                  f"{args.cooldown_seconds:.0f}s before lowering")
                        held_for = time.monotonic() - hold_since[idx]
                        if held_for < args.cooldown_seconds:
                            target_pct = prev_pct if prev_pct is not None else target_pct
                        else:
                            peak_temp[idx] = temp
                            hold_since[idx] = None
                    else:
                        hold_since[idx] = None
                # --- end cooldown hold ---

                if prev_pct is None or abs(target_pct - prev_pct) >= args.hysteresis:
                    try:
                        num_fans = nv.nvmlDeviceGetNumFans(handle)
                        for fan in range(num_fans):
                            nv.nvmlDeviceSetFanSpeed_v2(handle, fan, target_pct)
                        print(f"[FAN] GPU {idx}: {temp}C -> {target_pct}% "
                              f"({num_fans} fan(s))")
                        last_pct[idx] = target_pct
                    except nv.NVMLError as error:
                        print(f"[FAN] GPU {idx}: WARN fan-set failed ({error})")

            sd_notify("WATCHDOG=1")

            # Sleep in small chunks so SIGTERM/SIGINT is handled promptly
            slept = 0.0
            while slept < args.interval and not _shutdown_requested:
                time.sleep(min(0.5, args.interval - slept))
                slept += 0.5

        print("[FAN] Shutdown requested, resetting fans to AUTO...")
        sd_notify("STOPPING=1")

    finally:
        reset_to_auto(handles)
        nv.nvmlShutdown()
        print("[FAN] Clean exit.")


if __name__ == "__main__":
    main()

EOF

sudo chmod +x /usr/local/bin/fan_curve.py

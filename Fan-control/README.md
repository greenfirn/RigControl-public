[Get started](../README.md#get-started)

-- service status, log -- developed with help from and description by claude.ai

![log-Screenshot](py-nvtool/Screenshot-status-log.png)

-- credit to https://github.com/Akisoft41/py-nvtool for py-nvtool fan control --

# NVML Fan Curve

A lightweight, headless NVIDIA fan curve controller that talks to the driver directly
through NVML (`libnvidia-ml.so`) — no `nvidia-settings`, no X server, no Coolbits,
and no dependency on the GPU being idle to get manual fan control.

## Why this exists

The usual way to get custom fan curves on Linux (`nvidia-settings -a GPUTargetFanSpeed=...`)
requires a running X server with `Coolbits` enabled via `NV-CONTROL`. On headless mining/compute
rigs that means standing up a fake Xorg instance just for fan control — and under heavy
sustained compute load, repeated NV-CONTROL calls can destabilize the GPU's GSP firmware
(observed as Xid 109/119/154 errors).

This project instead calls `nvmlDeviceSetFanSpeed_v2` directly via `ctypes`, the same
interface `nvidia-smi` itself uses. No X server required, and it works identically whether
the GPU is idle or fully loaded.

## Files - py-nvtool/

| File | Purpose |
|---|---|
| `/usr/sbin/py-nvtool` | **Upstream** [Akisoft41/py-nvtool](https://github.com/Akisoft41/py-nvtool), not bundled here. Python NVML bindings plus a CLI (clocks, offsets, power limit, fan speed per GPU). Used from the command line by `gpu_reset_poststop.sh` and loaded as a library by `fan_curve.py`. |
| `fan_curve.py` | The fan curve daemon. Polls GPU temps on an interval and drives fan speed via NVML according to a configurable temp→fan% curve. (written to `/usr/local/bin/` by [fan_curve.sh](py-nvtool/fan_curve.sh)) |
| `fan-curve.service` | systemd unit to run the daemon on boot, with clean shutdown (resets fans to AUTO on stop). (written by [install_fan-curve.sh](py-nvtool/install_fan-curve.sh) or [fan-curve.service.sh](py-nvtool/fan-curve.service.sh)) |
| [install_fan-curve.sh](py-nvtool/install_fan-curve.sh) | One-time full setup for a new rig: writes `fan_curve.py` and `fan-curve.service`, enables and starts the service. |
| [fan_curve.sh](py-nvtool/fan_curve.sh) | Standalone script that just (re)writes `/usr/local/bin/fan_curve.py`. Re-run this alone when the daemon's Python logic changes, without touching the service config. |
| [fan-curve.service.sh](py-nvtool/fan-curve.service.sh) | Standalone script that just (re)writes `fan-curve.service` and reloads/restarts it. Re-run this alone to tweak `--curve`, `--hysteresis`, `--cooldown-*`, etc. per rig. |

## Requirements

- NVIDIA driver installed (provides `libnvidia-ml.so.1`) — no Xorg/Coolbits required
- Python 3 (stdlib only — no `pip install` needed)
- Root privileges (fan-speed writes require it)
- Recommended: NVIDIA persistence mode enabled (`nvidia-persistenced`) for stable driver state

## Install

**New rig — setup:**

```bash
# 1. install upstream py-nvtool (same binary gpu_reset_poststop.sh uses)
wget https://github.com/Akisoft41/py-nvtool/releases/download/v0.2.0/py-nvtool.py
chmod +x py-nvtool.py
sudo cp py-nvtool.py /usr/sbin/py-nvtool

# check it works from the command line
sudo py-nvtool

# 2. write fan_curve.py + fan-curve.service, enable and start
sudo bash install_fan-curve.sh
```

`fan_curve.py` loads `/usr/sbin/py-nvtool` directly — no copy or rename needed. Upstream
has no `if __name__ == "__main__"` guard (its CLI runs at module level), so `fan_curve.py`
loads only its definitions (constants, classes, functions) and skips the CLI blocks. Upgrading
py-nvtool is just replacing `/usr/sbin/py-nvtool` and restarting the service.

To use a different location, pass `--nvtool /path/to/py-nvtool` in the unit's `ExecStart`
(or set `NVTOOL_PATH`).

If you previously installed the bundled `/usr/local/bin/nvtool.py`, it's no longer used and
can be removed: `sudo rm /usr/local/bin/nvtool.py`

[fan-curve.service.sh](py-nvtool/fan-curve.service.sh) rewrites the systemd unit and reloads/restarts it —
edit the `--curve` (and other flags) in that script before running it.

## Usage - manual testing

```bash
sudo python3 fan_curve.py                                  # all GPUs, default curve
sudo python3 fan_curve.py --index 0                         # GPU 0 only
sudo python3 fan_curve.py --curve "30:30,40:55,50:65,55:90,65:100"
```

### CLI flags

| Flag | Default | Description |
|---|---|---|
| `--index` | `-1` (all GPUs) | GPU index to control, or `-1` for all |
| `--interval` | `2` | Seconds between temperature checks |
| `--hysteresis` | `2` | Minimum fan% change required before re-issuing a fan-speed write, prevents fan "hunting" on small temp noise |
| `--curve` | `30:30,40:55,50:65,55:90,65:100` | Temp(°C):Fan(%) points, comma-separated, linearly interpolated between points |
| `--cooldown-delta` | `10` | Temp drop (°C) below the recent peak that triggers a hold before lowering the fan. `0` disables holding. |
| `--cooldown-seconds` | `15` | How long a drop must persist before the fan is actually lowered |
| `--nvtool` | `/usr/sbin/py-nvtool` | Path to upstream py-nvtool (or set `NVTOOL_PATH`) |

**Cooldown hold** debounces fan *decreases* specifically: if temp dips ≥`--cooldown-delta`
below its recent peak, the fan holds at its current (higher) speed for
`--cooldown-seconds` before actually dropping — and cancels immediately if temp climbs
back up in the meantime. Fan *increases* are always applied instantly, no delay.

### Editing the fan curve

The curve is set in [fan-curve.service.sh](py-nvtool/fan-curve.service.sh)'s `ExecStart` line. Edit the `--curve`
value in that script, then re-run it:

```bash
sudo bash fan-curve.service.sh

```

This rewrites `fan-curve.service`, reloads systemd, and restarts the daemon —
no need to touch `py-nvtool` or `fan_curve.py`.

On `systemctl stop`/`restart`, fans are reset to automatic control before exit:

```
[FAN] Shutdown requested, resetting fans to AUTO...
[FAN] GPU 0: reset 2 fan(s) to AUTO
[FAN] Clean exit.
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `could not load py-nvtool from ...` | `/usr/sbin/py-nvtool` missing — install it (see Install) or pass `--nvtool` |
| `nvmlInit failed` | NVIDIA driver not installed, or `libnvidia-ml.so.1` not on the library path |
| `WARN fan-set failed (Not Supported)` | GPU/driver combo doesn't allow manual fan override via NVML |
| `WARN could not reset to auto` | Same as above — `nvmlDeviceSetDefaultFanSpeed_v2` unsupported on that card |
| No log output at all | Missing `PYTHONUNBUFFERED=1` in the unit file |
| Fans "hunt" up/down rapidly | Increase `--hysteresis` |

## License / attribution

`py-nvtool` is [Akisoft41/py-nvtool](https://github.com/Akisoft41/py-nvtool) (GPL-3.0-or-later),
which embeds NVIDIA's pynvml bindings (BSD-3-Clause, © NVIDIA Corporation); it is installed
from upstream, not redistributed here. `fan_curve.py` and `fan-curve.service` are original
to this project.

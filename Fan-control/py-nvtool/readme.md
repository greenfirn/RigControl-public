1. install upstream [py-nvtool](https://github.com/Akisoft41/py-nvtool/releases) to `/usr/sbin/py-nvtool`
   ```bash
   wget https://github.com/Akisoft41/py-nvtool/releases/download/v0.2.0/py-nvtool.py
   chmod +x py-nvtool.py && sudo cp py-nvtool.py /usr/sbin/py-nvtool
   ```
2. [install_fan-curve.sh](install_fan-curve.sh)

added better error handling... watchdog for possible hangs

fan_curve.py now loads the upstream `/usr/sbin/py-nvtool` (same one `gpu_reset_poststop.sh` uses) — the bundled `nvtool.py` is gone.

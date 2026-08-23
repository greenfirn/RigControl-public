sudo tee /usr/local/bin/gpu_apply_ocs.sh > /dev/null <<'EOF'
#!/bin/bash
echo "Setting AMD RX 6600 XT for mining... Quai"
echo "manual" | sudo tee /sys/class/drm/card0/device/power_dpm_force_performance_level
# core state 1 = 1950MHz (throttled by power limit below)
echo "1" | sudo tee /sys/class/drm/card0/device/pp_dpm_sclk
# mem state 3 = 1000MHz
echo "3" | sudo tee /sys/class/drm/card0/device/pp_dpm_mclk
# power limit in microwatts (69000000 = 69W)
echo 69000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
cat /sys/class/drm/card0/device/pp_dpm_sclk
cat /sys/class/drm/card0/device/pp_dpm_mclk
sudo rocm-smi
EOF
sudo chmod +x /usr/local/bin/gpu_apply_ocs.sh
sudo /usr/local/bin/gpu_apply_ocs.sh

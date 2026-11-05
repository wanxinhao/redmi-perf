#!/usr/bin/env bash
#
# 测 EC 性能模式 -> GPU 功耗上限的对应关系。
#
set -u

sudo modprobe redmi_perf_wmi 2>/dev/null || true

echo "=== 基线 ==="
echo "EC 模式: $(redmi-perf get 2>&1)"
nvidia-smi -q -d POWER 2>/dev/null | grep -iE "Current Power Limit|Max Power Limit|Default Power Limit"

for mode in quiet balanced turbo full-speed; do
	echo
	echo "=== $mode ==="
	sudo redmi-perf set "$mode" || { echo "  !! 设置失败"; continue; }
	sleep 3
	echo "EC 模式: $(redmi-perf get 2>&1)"
	nvidia-smi -q -d POWER 2>/dev/null |
		grep -iE "Current Power Limit|Max Power Limit|Default Power Limit"
done

echo
echo "=== 恢复 balanced ==="
sudo redmi-perf set balanced
redmi-perf get

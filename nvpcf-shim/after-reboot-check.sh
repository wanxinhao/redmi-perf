#!/usr/bin/env bash
#
# 重启后一次性验证：断言还在不在 / shim 注入有没有生效 / EC 各模式对应多少瓦
#
set -uo pipefail

echo "==================== 1. 驱动断言 ===================="
sudo dmesg | grep -iE "SBIOS|platform_request_handler" | tail -20
echo "（没有输出 = 两条 SBIOS 断言都消失了）"

echo
echo "==================== 2. shim 注入点 ===================="
sudo dmesg | grep -E "NVPCF-SHIM: (GPS|PPM)" | tail -20

echo
echo "==================== 3. GPU 功耗/温度 ===================="
nvidia-smi -q -d POWER,TEMPERATURE | grep -iE "Power Limit|Target Temperature|Max Operating"

echo
echo "==================== 3b. shim 当前参数 ===================="
for p in nvpcf_shim_mode nvpcf_shim_ctr0b nvpcf_shim_ppm nvpcf_shim_ppm_enable; do
	printf "  %-24s = %s\n" "$p" "$(cat /sys/module/nvidia/parameters/$p 2>/dev/null || echo '(不存在)')"
done

echo
echo "==================== 4. EC 模式 -> 功耗上限 ===================="
echo "（找出 EC 里有没有比 turbo(125W) 更高的档位）"
for m in 0 1 2 3 4 5 6 7 8; do
	if sudo redmi-perf set "$m" >/dev/null 2>&1; then
		sleep 3
		lim=$(nvidia-smi -q -d POWER 2>/dev/null |
			sed -n 's/^[[:space:]]*Current Power Limit[[:space:]]*:[[:space:]]*\([0-9.]\+\).*/\1/p' |
			head -1)
		mode=$(sudo redmi-perf get 2>/dev/null | tr -d '\n')
		echo "  mode=$m  固件返回='$mode'  Current Power Limit=${lim:-?}"
	else
		echo "  mode=$m  写入失败"
	fi
done
sudo redmi-perf set balanced >/dev/null 2>&1
echo "（已恢复 balanced）"

echo
echo "==================== 5. 运行时扫描（不用重启） ===================="
echo "  ./runtime-sweep.sh"

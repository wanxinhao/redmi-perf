#!/usr/bin/env bash
#
# mode-bench.sh - EC 性能模式 -> GPU 实际表现（功耗上限 / 频率 / 温度）
#
# 为什么不能只看 nvidia-smi 的 Current Power Limit:
#   那个值是动态的（同一模式两次读数可以差 10W+），要采样求平均；
#   真正要回答的是「这个模式下 GPU 实际能跑多快」。
#
set -u

MODES="${*:-quiet balanced turbo full-speed}"
SAMPLES=20
SETTLE=12
LOAD_PID=""
LOAD_KIND=""
GPU_PCI="0000:01:00.0"
PM_CONTROL="/sys/bus/pci/devices/$GPU_PCI/power/control"
PM_SAVED=""

cleanup() { stop_load; }
trap cleanup EXIT INT TERM

restore_pm() {
	if [[ -n "$PM_SAVED" && -w "$PM_CONTROL" ]]; then
		echo "$PM_SAVED" | sudo tee "$PM_CONTROL" >/dev/null 2>&1 || true
	fi
}

stop_load() {
	if [[ -n "$LOAD_PID" ]]; then
		kill "$LOAD_PID" 2>/dev/null
		wait "$LOAD_PID" 2>/dev/null
		LOAD_PID=""
	fi
}

gpu_util() {
	nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
		head -1 | tr -d ' '
}

pick_query() {
	local candidates=(
		"clocks.sm,temperature.gpu,utilization.gpu"
		"clocks.sm,temperature.gpu"
		"utilization.gpu"
	)
	local q
	for q in "${candidates[@]}"; do
		if nvidia-smi --query-gpu="$q" --format=csv,noheader >/dev/null 2>&1; then
			echo "$q"
			return 0
		fi
	done
	return 1
}

start_load() {
	case "$1" in
	vkcube)
		# present_mode 0 = IMMEDIATE，脱离 vsync 限速才能压满负载
		VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json \
		__NV_PRIME_RENDER_OFFLOAD=1 __NV_PRIME_OUTPUT=1 \
			vkcube --c 100000000 --present_mode 0 --wsi wayland \
			>/tmp/vkcube-mode-bench.log 2>&1 &
		;;
	glxgears)
		__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
		__NV_PRIME_OUTPUT=1 glxgears >/tmp/glxgears-mode-bench.log 2>&1 &
		;;
	esac
	LOAD_PID=$!
}

# 这版 nvidia-smi 的 --query-gpu 和 -l/-lms 循环模式不兼容，
# 只能自己按秒轮询。
sample_loop() {
	local n="$1" out="" i line
	for ((i = 0; i < n; i++)); do
		line="$(nvidia-smi --query-gpu="$QUERY" --format=csv,noheader,nounits 2>/dev/null | head -1)"
		[[ -n "$line" ]] && out+="$line"$'\n'
		sleep 1
	done
	echo "$out"
}

wait_for_util() {
	local target="$1" tries=0 u=0
	while ((tries < 20)); do
		sleep 1
		u="$(gpu_util)"
		if [[ "${u:-0}" -ge "$target" ]]; then
			echo "$u"
			return 0
		fi
		tries=$((tries + 1))
	done
	echo "${u:-0}"
	return 1
}

pick_load() {
	local u
	# 允许用 LOAD=vkcube / LOAD=glxgears 强制指定
	case "${LOAD:-auto}" in
	vkcube|glxgears)
		start_load "$LOAD"
		u="$(wait_for_util 20)"
		if [[ "${u:-0}" -ge 20 ]]; then
			LOAD_KIND="$LOAD"
			stop_load
			return 0
		fi
		stop_load
		echo "!! 指定的 $LOAD 没能把负载压上（util=${u:-0}%），日志："
		tail -5 "/tmp/${LOAD}-mode-bench.log" 2>/dev/null | sed 's/^/    /'
		return 1
		;;
	esac

	if command -v vkcube >/dev/null; then
		start_load vkcube
		u="$(wait_for_util 25)"
		if [[ "${u:-0}" -ge 25 ]]; then
			LOAD_KIND="vkcube"
			stop_load
			return 0
		fi
		stop_load
		echo "  vkcube util=${u:-0}%，日志："
		tail -5 /tmp/vkcube-mode-bench.log 2>/dev/null | sed 's/^/    /'
	fi
	if command -v glxgears >/dev/null; then
		start_load glxgears
		u="$(wait_for_util 25)"
		if [[ "${u:-0}" -ge 25 ]]; then
			LOAD_KIND="glxgears"
			stop_load
			return 0
		fi
		stop_load
		echo "  glxgears util=${u:-0}%，日志："
		tail -5 /tmp/glxgears-mode-bench.log 2>/dev/null | sed 's/^/    /'
	fi
	return 1
}

# 限频原因：SW Power Cap 亮着就说明是被软件功耗墙卡的
throttle_reasons() {
	nvidia-smi -q -d PERFORMANCE 2>/dev/null |
		sed -n '/Clocks Event Reasons/,/^$/p' |
		grep -iE "Sw Power Cap|SW Thermal|Hw Slowdown|Power Brake|No applications" |
		head -4 | tr -s ' ' | paste -sd'|' -
}

avg_power_limit() {
	local n=8 sum=0 v
	for ((i = 0; i < n; i++)); do
		v="$(nvidia-smi -q -d POWER 2>/dev/null |
			grep -m1 "Current Power Limit" | grep -oE "[0-9]+\.[0-9]+ W" |
			head -1 | grep -oE "[0-9]+\.[0-9]+" || echo 0)"
		sum=$(awk -v s="$sum" -v x="$v" 'BEGIN{print s+x}')
	sleep 1
	done
	awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.1f", s/n}'
}

sudo -v
sudo modprobe redmi_perf_wmi 2>/dev/null || true

# dGPU 空闲时会被 runtime suspend，nvidia-smi 只能读到 0，
# 测试期间把它钉在 active 上。
if [[ -r "$PM_CONTROL" ]]; then
	PM_SAVED="$(cat "$PM_CONTROL" 2>/dev/null || echo auto)"
	echo on | sudo tee "$PM_CONTROL" >/dev/null 2>&1 || true
	echo "已禁用 dGPU 运行时挂起（测试结束后恢复为 $PM_SAVED）"
	trap 'restore_pm; cleanup' EXIT INT TERM
fi

echo "nvidia-powerd 状态: $(systemctl is-active nvidia-powerd 2>/dev/null || echo '未安装')"
echo

QUERY="$(pick_query || true)"
if [[ -z "$QUERY" ]]; then
	echo "错误: nvidia-smi --query-gpu 一个字段都不认，退出" >&2
	exit 1
fi

echo "=== EC 性能模式实测 ==="
echo "采样字段: $QUERY"
echo "每模式: 切换后静置 ${SETTLE}s，负载满载，采样 ${SAMPLES} 次"
echo

if ! pick_load; then
	echo "错误: 没法把负载压到 NVIDIA GPU 上。" >&2
	echo "请到「设置 → 图形」切成「独显直连 / 仅 NVIDIA」后重试。" >&2
	exit 1
fi
echo "负载方式: $LOAD_KIND（全程统一，保证可比）"
echo

printf "%-12s %-8s %-9s %-11s %-7s %-7s  %s\n" "模式" "EC值" "限值W(均)" "SM钟MHz(均)" "温度(均)" "util(均)" "限频原因"
printf "%-12s %-8s %-9s %-11s %-7s %-7s  %s\n" "----" "----" "--------" "-----------" "------" "-------" "--------"

for mode in $MODES; do
	if ! sudo redmi-perf set "$mode"; then
		echo "$mode: 设置失败，跳过"
		continue
	fi
	sleep "$SETTLE"

	ecval="$(redmi-perf get 2>&1 | grep -oE '\([0-9]+\)' | tr -d '()')"
	pl="$(avg_power_limit)"

	start_load "$LOAD_KIND"
	u="$(wait_for_util 25 || true)"
	raw="$(sample_loop "$SAMPLES")"
	throttle="$(throttle_reasons)"
	stop_load

	# 每一列求平均（列顺序固定：sm, temp, util）
	sm="$(echo "$raw" | awk -F', ' '{s+=$1; n++} END{if(n) printf "%.0f", s/n}')"
	tmp="$(echo "$raw" | awk -F', ' '{s+=$2; n++} END{if(n) printf "%.0f", s/n}')"
	utl="$(echo "$raw" | awk -F', ' '{s+=$3; n++} END{if(n) printf "%.0f", s/n}')"

	printf "%-12s %-10s %-10s %-10s %-8s %-8s  %s\n" \
		"$mode" "${ecval:-?}" "${pl:-?}" "${sm:-?}" "${tmp:-?}" "${utl:-?}" "${throttle:-}"

	if [[ "${sm:-0}" == "0" ]]; then
		echo "    !! 采样全 0：GPU 仍处于挂起/无负载状态，"
		echo "       试 LOAD=glxgears 或确认 vkcube 窗口没被关掉"
	fi
done

echo
echo "=== 恢复 balanced ==="
sudo redmi-perf set balanced
redmi-perf get

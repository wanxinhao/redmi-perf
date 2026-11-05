#!/usr/bin/env bash
#
# gpu-probe.sh - 分辨「GPU 真的挂了」还是「nvidia-smi 查询路径返回 0」
#
set -u

PCI="0000:01:00.0"
RS="/sys/bus/pci/devices/$PCI/power/runtime_status"
CTRL="/sys/bus/pci/devices/$PCI/power/control"

Q="clocks.sm,temperature.gpu,utilization.gpu"

show() {
	echo "  runtime_status : $(cat "$RS" 2>/dev/null)"
	echo "  power/control  : $(cat "$CTRL" 2>/dev/null)"
	echo "  --query-gpu    : $(nvidia-smi --query-gpu="$Q" --format=csv,noheader,nounits 2>&1 | head -1)"
	echo "  --query 带 -l  : $(nvidia-smi --query-gpu="$Q" --format=csv,noheader,nounits -l 1 -c 1 2>&1 | head -1)"
	echo "  --query 带 -lms: $(nvidia-smi --query-gpu="$Q" --format=csv,noheader,nounits -lms 1 -c 1 2>&1 | head -1)"
	echo "  普通表格温度   : $(nvidia-smi 2>/dev/null | sed -n '10p' | tr -s ' ')"
}

echo "===== 空载 ====="
show

echo
echo "===== 钉住 active (power/control=on) ====="
OLD="$(cat "$CTRL" 2>/dev/null || echo auto)"
echo on | sudo tee "$CTRL" >/dev/null 2>&1
sleep 1
show

echo
echo "===== 启动 glxgears (X11/NVIDIA) ====="
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __NV_PRIME_OUTPUT=1 \
	glxgears >/tmp/gears-probe.log 2>&1 &
GPID=$!
sleep 6
show
echo "  glxgears 日志   : $(tail -2 /tmp/gears-probe.log 2>/dev/null | paste -sd' ' -)"
kill $GPID 2>/dev/null
wait $GPID 2>/dev/null

echo
echo "===== 启动 vkcube (Wayland/NVIDIA) ====="
VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json \
	__NV_PRIME_RENDER_OFFLOAD=1 __NV_PRIME_OUTPUT=1 \
		vkcube --c 1000000 --wsi wayland >/tmp/vkcube-probe.log 2>&1 &
VPID=$!
sleep 6
show
echo "  vkcube 日志     : $(tail -2 /tmp/vkcube-probe.log 2>/dev/null | paste -sd' ' -)"
kill $VPID 2>/dev/null
wait $VPID 2>/dev/null

echo
echo "===== 恢复 power/control=$OLD ====="
echo "$OLD" | sudo tee "$CTRL" >/dev/null 2>&1
cat "$CTRL"

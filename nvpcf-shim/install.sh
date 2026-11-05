#!/usr/bin/env bash
#
# 给 NVIDIA 驱动打上 NVPCF shim 补丁并安装。
#
# ⚠ 为什么不用 DKMS 路线：
#   .run 安装器装出来的驱动，DKMS 树里的状态是残废的
#   （dkms build 会静默跳过，dkms install --force 只是把旧模块重装一遍）。
#   所以这里走"手工编译 + 直装"的路线。
#
# ⚠ 风险：这一步会替换内核里的 nvidia 模块。
#    驱动装坏了会开不了机 —— 请确认你能在 tty 下恢复
#    （见 README 的「回退」一节）。
#
# 用法:
#   sudo ./install.sh            # 打补丁 + 编译 + 安装 + 写模块参数
#   sudo ./install.sh --record   # 只记录 ACPI 流量，不改写应答（最安全，仅诊断用）
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHIM_MODE=1
if [[ "${1:-}" == "--record" ]]; then
	SHIM_MODE=0
elif [[ $# -gt 0 ]]; then
	echo "用法: sudo $0 [--record]" >&2
	exit 1
fi

if [[ $EUID -ne 0 ]]; then
	echo "需要 root：sudo $0 $*" >&2
	exit 1
fi

echo "==> 1/3 编译带 shim 的 nvidia 模块"
"$HERE/build.sh"

echo
echo "==> 2/3 安装模块"
"$HERE/install-prebuilt.sh"

echo
echo "==> 3/3 写模块参数"
if [[ "$SHIM_MODE" == "0" ]]; then
	cat >/etc/modprobe.d/nvidia-nvpcf-shim.conf <<EOF
# NVPCF shim —— 只记录模式（不改写任何固件应答）
options nvidia nvpcf_shim_mode=0 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \
	nvpcf_shim_ppm_enable=0 nvpcf_shim_ppm=0x1E01
EOF
else
	cat >/etc/modprobe.d/nvidia-nvpcf-shim.conf <<EOF
# NVPCF shim —— 改写模式
options nvidia nvpcf_shim_mode=1 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \
	nvpcf_shim_ppm_enable=1 nvpcf_shim_ppm=0x1E01
EOF
fi
cat /etc/modprobe.d/nvidia-nvpcf-shim.conf

echo
echo "完成。现在重启，然后："
echo "  sudo dmesg | grep -iE 'NVPCF-SHIM|SBIOS'   # 断言还在不在"
echo "  nvidia-smi -q -d POWER,TEMPERATURE          # 功耗上限/目标温度"
echo
echo "回退：sudo $HERE/restore-prebuilt.sh"

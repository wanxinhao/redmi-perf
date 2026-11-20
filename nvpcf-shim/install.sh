#!/usr/bin/env bash
#
# 把 NVPCF shim 装进 NVIDIA 内核模块。
#
#   sudo ./install.sh            # 打补丁 + 编译 + 安装 + 写模块参数
#   ./install.sh --check         # 只检查环境（不需要 root）
#   sudo ./install.sh --record   # 只记录 ACPI 流量，不改写应答（诊断用）
#   sudo ./install.sh --no-hook  # 不装 pacman 钩子（仅 Arch）
#
# 支持 Arch Linux（nvidia-open-dkms）与 Debian/Ubuntu（nvidia-dkms / .run）。
#
# ⚠ 这一步会替换内核里的 nvidia 模块，装坏了会开不了机。
#   请先确认能在 tty 下恢复，见 docs/troubleshooting.md。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -r "$ROOT/scripts/lib/common.sh" ] ||
	{ echo "错误: 缺少 $ROOT/scripts/lib/common.sh，请在完整仓库里运行（不要单独拷贝 nvpcf-shim/）" >&2; exit 1; }
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

SHIM_MODE=1
CHECK=0
HOOK_ARG=()
for arg in "$@"; do
	case "$arg" in
	--record) SHIM_MODE=0 ;;
	--check) CHECK=1 ;;
	--no-hook) HOOK_ARG=(--no-hook) ;;
	-h | --help)
		sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "未知参数: $arg（用法: $0 [--record] [--check] [--no-hook]）" ;;
	esac
done

echo "==> 0/3 环境检查"
echo "  发行版: $(distro_id)（$(distro_family)，包管理器 $(pkg_mgr)）"
echo "  内核:   $(kver)"

if [ "$(distro_family)" = arch ]; then
	KIND="$(nvidia_pkg_kind_arch)"
	case "$KIND" in
	dkms) echo "  NVIDIA: nvidia-open-dkms / nvidia-dkms（有源码，可以打补丁）" ;;
	open)
		warn "检测到预编译的 nvidia-open（没有源码），无法打 shim 补丁。
     换成源码包: $(pkg_install_cmd nvidia-open-dkms)
     装的时候会替换 nvidia-open，nvidia-utils 不用动。"
		[ "$CHECK" -eq 1 ] && exit 1
		;;
	proprietary)
		warn "检测到官方闭源 nvidia 包。本项目按开源模块（nvidia-open）适配；
     闭源 .run 的完整源码树理论上也能用，但没验证。"
		;;
	none)
		warn "没有检测到 NVIDIA 驱动包。先装: $(pkg_install_cmd nvidia-open-dkms)"
		[ "$CHECK" -eq 1 ] && exit 1
		;;
	esac
fi

if ! kernel_headers_ok; then
	die "找不到内核构建目录 $(kernel_build_dir)。先装头文件：
  $(kernel_headers_hint)"
fi

echo
echo "==> 1/3 编译带 shim 的 nvidia 模块"
if [ "$CHECK" -eq 1 ]; then
	"$HERE/build.sh" --check
else
	"$HERE/build.sh"
fi

echo
echo "==> 2/3 安装模块"
if [ "$CHECK" -eq 1 ]; then
	"$HERE/install-prebuilt.sh" --check
	exit 0
fi
"$HERE/install-prebuilt.sh" "${HOOK_ARG[@]}"

echo
echo "==> 3/3 写模块参数"
PSHARE_INIT=0
if [ "$SHIM_MODE" = "1" ] && nvidia_needs_pshare_init; then
	PSHARE_INIT=1
fi
if [ "$SHIM_MODE" = "0" ]; then
	cat >/etc/modprobe.d/nvidia-nvpcf-shim.conf <<EOF
# NVPCF shim —— 只记录模式（不改写任何固件应答）
options nvidia nvpcf_shim_mode=0 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \\
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \\
	nvpcf_shim_ppm_enable=0 nvpcf_shim_ppm=0x1E01 nvpcf_shim_pshare_init=0
EOF
else
	cat >/etc/modprobe.d/nvidia-nvpcf-shim.conf <<EOF
# NVPCF shim —— 改写模式
options nvidia nvpcf_shim_mode=1 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \\
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \\
	nvpcf_shim_ppm_enable=1 nvpcf_shim_ppm=0x1E01 nvpcf_shim_pshare_init=$PSHARE_INIT
EOF
fi
cat /etc/modprobe.d/nvidia-nvpcf-shim.conf

echo
echo "完成。现在重启，然后："
echo "  dmesg | grep -iE 'NVPCF-SHIM|SBIOS'   # 断言还在不在"
echo "  nvidia-smi -q -d POWER,TEMPERATURE    # 功耗上限/目标温度"
echo
echo "回退：sudo $HERE/restore-prebuilt.sh"

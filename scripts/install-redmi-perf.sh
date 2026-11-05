#!/usr/bin/env bash
#
# Build and install the redmi_perf kernel module plus the redmi-perf CLI.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KERNEL_DIR="$ROOT/kernel/redmi-perf-wmi"
CLI_DIR="$ROOT/cli"
KVER="$(uname -r)"
KDIR="/lib/modules/${KVER}/build"
MODDIR="/lib/modules/${KVER}/extra"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${PREFIX}/bin"
DKMS_SRC="/usr/src/redmi-perf-0.1.0"

use_dkms=0
install_cli=1

usage() {
	cat <<EOF
用法: ./install.sh [选项]

  --dkms        通过 DKMS 注册模块（内核升级后自动重编，推荐）
  --no-cli      不安装 redmi-perf 用户态命令行工具
  --uninstall   卸载模块与命令行工具
  -h, --help    显示本帮助

不带 --dkms 时模块只对当前内核生效，重启或升级内核后会失效。
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--dkms) use_dkms=1 ;;
	--no-cli) install_cli=0 ;;
	--uninstall) uninstall=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) echo "未知选项: $1" >&2
		usage
		exit 1
		;;
	esac
	shift
done

if [[ -n "${uninstall:-}" ]]; then
	echo "==> 卸载模块"
	sudo modprobe -r redmi_perf_wmi 2>/dev/null || true
	# 两种安装方式都清一遍，免得只卸了一半
	sudo dkms remove -m redmi-perf -v 0.1.0 --all >/dev/null 2>&1 || true
	sudo rm -rf "$DKMS_SRC"
	sudo rm -f "${MODDIR}/redmi_perf_wmi.ko"
	sudo depmod -a "$KVER"
	if [[ $install_cli -eq 1 ]]; then
		sudo rm -f "${BINDIR}/redmi-perf"
	fi
	echo "已卸载。"
	exit 0
fi

echo "==> 1/4 编译内核模块"
if [[ ! -d "$KDIR" ]]; then
	echo "错误: 找不到内核构建目录 $KDIR" >&2
	echo "请先安装: sudo apt install linux-headers-${KVER}" >&2
	exit 1
fi
make -C "$KDIR" M="$KERNEL_DIR" modules
echo

echo "==> 2/4 安装内核模块"
if [[ $use_dkms -eq 1 ]]; then
	if ! command -v dkms >/dev/null; then
		echo "错误: 没有找到 dkms，请先 sudo apt install dkms" >&2
		exit 1
	fi
	echo "把源码安装到 $DKMS_SRC"
	sudo mkdir -p "$DKMS_SRC"
		sudo cp "$KERNEL_DIR/redmi_perf_wmi.c" "$KERNEL_DIR/Makefile" "$KERNEL_DIR/dkms.conf" "$DKMS_SRC/"
	sudo dkms remove -m redmi-perf -v 0.1.0 --all >/dev/null 2>&1 || true
	sudo dkms add -m redmi-perf -v 0.1.0
	sudo dkms build -m redmi-perf -v 0.1.0 -k "$KVER"
	sudo dkms install -m redmi-perf -v 0.1.0 -k "$KVER"
	sudo depmod -a "$KVER"
else
	sudo mkdir -p "$MODDIR"
		sudo cp "$KERNEL_DIR/redmi_perf_wmi.ko" "$MODDIR/"
	sudo depmod -a "$KVER"
fi
echo

echo "==> 3/4 加载模块"
sudo modprobe -r redmi_perf_wmi 2>/dev/null || true
sudo modprobe redmi_perf_wmi
sleep 1
lsmod_out="$(/sbin/lsmod)"
if ! grep -q '^redmi_perf_wmi' <<<"$lsmod_out"; then
	echo "错误: 模块加载失败，用 dmesg 看看原因" >&2
	sudo dmesg | tail -20 >&2
	exit 1
fi
echo "模块已加载。"
echo

echo "==> 4/4 构建用户态命令行工具"
if [[ $install_cli -eq 1 ]]; then
	if ! command -v cargo >/dev/null; then
		echo "警告: 没有 cargo，跳过 redmi-perf 命令行工具" >&2
	else
		cargo build --release --offline --manifest-path "$CLI_DIR/Cargo.toml"
		sudo install -Dm755 "$CLI_DIR/target/release/redmi-perf" "${BINDIR}/redmi-perf"
		echo "已安装到 ${BINDIR}/redmi-perf"
	fi
fi

echo
echo "完成。试试看:"
echo "  redmi-perf get        # 当前性能模式"
echo "  redmi-perf psu        # 供电方式（决定能否开满功耗）"
echo "  dmesg | grep redmi_perf   # 模块的首次探测日志"

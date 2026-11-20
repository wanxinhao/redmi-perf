#!/usr/bin/env bash
#
# 编译安装 redmi_perf 内核模块（+ redmi-perf 命令行工具）。
#
# 支持 Arch Linux（pacman，含 CachyOS 等 clang+LTO 内核）、Debian/Ubuntu、Fedora。
#
# 用法:
#   sudo ./install-redmi-perf.sh --dkms    # 推荐：内核升级后自动重编
#   sudo ./install-redmi-perf.sh           # 只对当前内核生效
#   ./install-redmi-perf.sh --check        # 只检查环境，不做任何修改
#   sudo ./install-redmi-perf.sh --uninstall
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

KERNEL_DIR="$ROOT/kernel/redmi-perf-wmi"
CLI_DIR="$ROOT/cli"
KVER="$(kver)"
KDIR="$(kernel_build_dir)"
MODDIR="$(kernel_modules_root)/extra"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${PREFIX}/bin"

PKG_NAME="$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$KERNEL_DIR/dkms.conf" | head -1)"
PKG_VERSION="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$KERNEL_DIR/dkms.conf" | head -1)"
[ -n "$PKG_NAME" ] || PKG_NAME="redmi-perf"
[ -n "$PKG_VERSION" ] || PKG_VERSION="0.0.0"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

use_dkms=0
install_cli=1
uninstall=0
check_only=0

usage() {
	cat <<EOF
用法: ./install-redmi-perf.sh [选项]

  --dkms        通过 DKMS 注册模块（内核升级后自动重编，推荐）
  --no-cli      不安装 redmi-perf 用户态命令行工具
  --check       只检查环境（头文件 / dkms / cargo），不做任何修改
  --uninstall   卸载模块与命令行工具
  -h, --help    显示本帮助

不带 --dkms 时模块只对当前内核生效，重启或升级内核后会失效。
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--dkms) use_dkms=1 ;;
	--no-cli) install_cli=0 ;;
	--check) check_only=1 ;;
	--uninstall) uninstall=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "未知选项: $1（--help 看用法）" ;;
	esac
	shift
done

if [[ $check_only -eq 0 ]] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
	die "需要 root：sudo $0 $*"
fi

# 已注册的 redmi-perf DKMS 版本列表（用于升级时清理旧版本）
dkms_module_versions() {
	dkms status -m "$PKG_NAME" 2>/dev/null |
		sed -n "s|^${PKG_NAME}/\\([^,]*\\),.*|\\1|p" | sort -u
}

# ------------------------------------------------------------ 环境检查 ----

check_env() {
	echo "==> 环境检查"
	echo "  发行版: $(distro_id)（$(distro_family)，包管理器 $(pkg_mgr)）"
	echo "  内核:   $KVER"

	if kernel_headers_ok; then
		echo "  头文件: $KDIR"
	else
		echo "  头文件: 缺失（$(kernel_headers_pkg)）"
		echo "          安装: $(kernel_headers_hint)"
	fi

	if command -v dkms >/dev/null 2>&1; then
		echo "  dkms:   $(dkms --version)"
	else
		echo "  dkms:   未安装（--dkms 需要）"
		echo "          安装: $(pkg_install_cmd dkms)"
	fi

	if command -v cargo >/dev/null 2>&1; then
		echo "  cargo:  $(cargo --version | head -1)"
	else
		echo "  cargo:  未安装（只为编译 redmi-perf 命令行工具）"
		echo "          安装: $(pkg_install_cmd "$( [ "$(pkg_mgr)" = pacman ] && echo rust || echo cargo)")"
	fi

	KMAKE="$(kernel_make_extra)" || true
	if [ -n "$KMAKE" ]; then
		echo "  编译参数: $KMAKE（内核是用 clang 构建的）"
	fi

	if modinfo redmi_perf_wmi >/dev/null 2>&1; then
		echo "  模块:   已安装（$(modinfo -F filename redmi_perf_wmi 2>/dev/null | head -1)）"
	else
		echo "  模块:   未安装"
	fi
}

if [[ $check_only -eq 1 ]]; then
	check_env
	if ! kernel_headers_ok; then
		echo
		die "先装内核头文件: $(kernel_headers_hint)"
	fi
	echo
	echo "检查通过。正式安装: sudo $0 $( [[ $use_dkms -eq 1 ]] && echo --dkms )"
	exit 0
fi

# ------------------------------------------------------------ 卸载 ----

if [[ $uninstall -eq 1 ]]; then
	echo "==> 卸载模块"
	sudo_do modprobe -r redmi_perf_wmi 2>/dev/null || true
	# 两种安装方式都清一遍，免得只卸了一半；
	# 旧版本（0.1.0 / r2 之类）也一起清掉
	if command -v dkms >/dev/null 2>&1; then
		for v in $(dkms_module_versions); do
			sudo_do dkms remove -m "$PKG_NAME" -v "$v" --all >/dev/null 2>&1 || true
			sudo_do rm -rf "/usr/src/${PKG_NAME}-${v}"
		done
	fi
	sudo_do dkms remove -m "$PKG_NAME" -v "$PKG_VERSION" --all >/dev/null 2>&1 || true
	sudo_do rm -rf "$DKMS_SRC"
	sudo_do rm -f "$MODDIR"/redmi_perf_wmi.ko*
	# 旧版本手工装到 updates/dkms 的也清掉
	sudo_do sh -c "rm -f /lib/modules/*/updates/dkms/redmi_perf_wmi.ko* 2>/dev/null || true"
	sudo_do depmod -a "$KVER"
	if [[ $install_cli -eq 1 ]]; then
		sudo_do rm -f "${BINDIR}/redmi-perf"
	fi
	if [[ -f /etc/modules-load.d/redmi-perf.conf ]] &&
		grep -qx redmi_perf_wmi /etc/modules-load.d/redmi-perf.conf; then
		sudo_do rm -f /etc/modules-load.d/redmi-perf.conf
	fi
	echo "已卸载。"
	exit 0
fi

echo "==> 1/4 编译内核模块（$KVER）"
if ! kernel_headers_ok; then
	die "找不到内核构建目录 $KDIR
  先装头文件: $(kernel_headers_hint)"
fi
KMAKE_EXTRA_USE="$(kernel_make_extra)" || true
# shellcheck disable=SC2086
if ! make -C "$KDIR" M="$KERNEL_DIR" $KMAKE_EXTRA_USE modules; then
	# 兜底：自动探测没命中 clang 内核时，用 LLVM=1 再试一次
	if [[ "$KMAKE_EXTRA_USE" != *LLVM=1* ]] && command -v clang >/dev/null 2>&1; then
		warn "用默认编译器失败，改试 clang/LLVM（CachyOS 等 clang 内核需要）"
		if ! make -C "$KDIR" M="$KERNEL_DIR" LLVM=1 LD=ld.lld modules; then
			die "编译失败。看上面的编译器报错。"
		fi
	else
		die "编译失败。看上面的编译器报错。"
	fi
fi
echo

echo "==> 2/4 安装内核模块"
if [[ $use_dkms -eq 1 ]]; then
	if ! command -v dkms >/dev/null 2>&1; then
		die "没有找到 dkms，请先安装: $(pkg_install_cmd dkms)"
	fi
	echo "把源码安装到 $DKMS_SRC"
	sudo_do mkdir -p "$DKMS_SRC"
	sudo_do install -m 0644 \
		"$KERNEL_DIR/redmi_perf_wmi.c" \
		"$KERNEL_DIR/Makefile" \
		"$KERNEL_DIR/dkms.conf" \
		"$DKMS_SRC/"
	# 升级场景：0.1.0 / 旧 r2 版本还注册在 DKMS 里的话，内核升级时
	# 两个版本会编出同名模块互相覆盖，这里先清掉。
	for v in $(dkms_module_versions); do
		[ "$v" = "$PKG_VERSION" ] && continue
		echo "  清理旧 DKMS 版本: $PKG_NAME/$v"
		sudo_do dkms remove -m "$PKG_NAME" -v "$v" --all >/dev/null 2>&1 || true
		sudo_do rm -rf "/usr/src/${PKG_NAME}-${v}"
	done
	sudo_do dkms remove -m "$PKG_NAME" -v "$PKG_VERSION" --all >/dev/null 2>&1 || true
	sudo_do dkms add -m "$PKG_NAME" -v "$PKG_VERSION"
	sudo_do dkms build -m "$PKG_NAME" -v "$PKG_VERSION" -k "$KVER"
	sudo_do dkms install -m "$PKG_NAME" -v "$PKG_VERSION" -k "$KVER" --force
	sudo_do depmod -a "$KVER"
else
	sudo_do mkdir -p "$MODDIR"
	sudo_do install -m 0644 "$KERNEL_DIR/redmi_perf_wmi.ko" "$MODDIR/"
	sudo_do depmod -a "$KVER"
fi
echo

echo "==> 3/4 加载模块"
sudo_do modprobe -r redmi_perf_wmi 2>/dev/null || true
MODPROBE_OUT="$(sudo_do modprobe -v redmi_perf_wmi 2>&1 || true)"
if [ -n "$MODPROBE_OUT" ]; then
	printf '%s\n' "$MODPROBE_OUT" | sed 's/^/  /'
fi
# 直接读 /proc/modules（不用 `lsmod | grep -q`：pipefail 下 grep 提前退出
# 可能让 lsmod 收到 SIGPIPE，导致模块明明加载了却误判失败）
loaded=0
for _ in $(seq 1 10); do
	if grep -q '^redmi_perf_wmi ' /proc/modules 2>/dev/null; then
		loaded=1
		break
	fi
	sleep 0.5
done
if [[ $loaded -ne 1 ]]; then
	echo "错误: 模块加载失败。诊断信息：" >&2
	echo "  modprobe 输出: ${MODPROBE_OUT:-（空）}" >&2
	echo "  /proc/modules:  $(grep -c '^redmi_perf_wmi ' /proc/modules 2>/dev/null || echo 0) 条" >&2
	if command -v journalctl >/dev/null 2>&1; then
		sudo_do journalctl -k -n 20 --no-pager 2>/dev/null | sed 's/^/  /' >&2 || true
	else
		sudo_do dmesg | tail -20 | sed 's/^/  /' >&2 || true
	fi
	exit 1
fi

# 内核 7.3+ 自带 bitland-mifs-wmi 也匹配同一个 MIFS WMI 设备；谁先绑定谁生效。
# 如果设备被它占着，我们的驱动不会 probe，/sys/class/redmi_perf 就不会出现。
if [ ! -e /sys/class/redmi_perf ]; then
	MIFS_DEV="$(ls -d /sys/bus/wmi/devices/B60BFB48-* 2>/dev/null | head -1)"
	CUR_DRV=""
	if [ -n "$MIFS_DEV" ] && [ -e "$MIFS_DEV/driver" ]; then
		CUR_DRV="$(basename "$(readlink -f "$MIFS_DEV/driver")")"
	fi
	if [ -n "$MIFS_DEV" ] && [ -n "$CUR_DRV" ] && [ "$CUR_DRV" != "redmi_perf" ]; then
		echo "  MiInterface WMI 设备被 $CUR_DRV 占用，解绑后重试"
		printf '%s' "${MIFS_DEV##*/}" | sudo_do tee "/sys/bus/wmi/drivers/$CUR_DRV/unbind" >/dev/null || true
		sudo_do modprobe -r redmi_perf_wmi 2>/dev/null || true
		sudo_do modprobe redmi_perf_wmi
	fi
	if [ -n "$MIFS_DEV" ] && [ -e /sys/bus/wmi/drivers/redmi_perf/bind ]; then
		printf '%s' "${MIFS_DEV##*/}" |
			sudo_do tee /sys/bus/wmi/drivers/redmi_perf/bind >/dev/null 2>&1 || true
	fi
	sleep 1
fi
if [ ! -e /sys/class/redmi_perf ]; then
	echo "错误: 模块已加载，但没有出现 /sys/class/redmi_perf。" >&2
	echo "  常见原因：MIFS WMI 设备被内核自带的 bitland-mifs-wmi 驱动占用。" >&2
	echo "  手动修复：" >&2
	echo "    echo B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B-4 | sudo tee /sys/bus/wmi/drivers/bitland-mifs-wmi/unbind" >&2
	echo "    sudo modprobe redmi_perf_wmi" >&2
	exit 1
fi
echo "模块已加载。"
echo

echo "==> 4/4 构建用户态命令行工具"
if [[ $install_cli -eq 1 ]]; then
	if ! command -v cargo >/dev/null 2>&1; then
		warn "没有 cargo，跳过 redmi-perf 命令行工具（$(pkg_install_cmd "$( [ "$(pkg_mgr)" = pacman ] && echo rust || echo cargo)")）"
	else
		cargo build --release --offline --manifest-path "$CLI_DIR/Cargo.toml"
		sudo_do install -Dm755 "$CLI_DIR/target/release/redmi-perf" "${BINDIR}/redmi-perf"
		echo "已安装到 ${BINDIR}/redmi-perf"
	fi
fi

# 开机自动加载模块（幂等；卸载时会清掉）
if [[ -d /etc/modules-load.d ]]; then
	echo redmi_perf_wmi | sudo_do tee /etc/modules-load.d/redmi-perf.conf >/dev/null
fi

echo
echo "完成。试试看:"
echo "  redmi-perf get        # 当前性能模式"
echo "  redmi-perf psu        # 供电方式（决定能否开满功耗）"
echo "  dmesg | grep redmi_perf   # 模块的首次探测日志"

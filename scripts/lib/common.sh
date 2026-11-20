#!/usr/bin/env bash
#
# common.sh - 发行版 / 内核 / NVIDIA 驱动布局探测
#
# 由 scripts/install-redmi-perf.sh 和 nvpcf-shim/*.sh 共用。
# 约定：这里的函数只读探测、只打印结果，绝不修改系统。
#
# 支持 Arch Linux（pacman，含 CachyOS / Manjaro / EndeavourOS 等 Arch 衍生版）、
# Debian/Ubuntu、Fedora、openSUSE；其他发行版走通用兜底。
#
# shellcheck shell=bash

# ---------------------------------------------------------------- 输出 ----

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf '警告: %s\n' "$*" >&2
}

info() {
	printf '%s\n' "$*"
}

# 以 root 执行；已经是 root 时不依赖 sudo（Arch 的 tty 恢复环境常常没有 sudo）
sudo_do() {
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

require_root() {
	if [ "${EUID:-$(id -u)}" -ne 0 ]; then
		die "需要 root：sudo $0 $*"
	fi
}

# ------------------------------------------------------------ 发行版 ----

_os_field() {
	[ -r /etc/os-release ] || return 1
	sed -n "s/^$1=//p" /etc/os-release | head -1 | tr -d '"'
}

distro_id() {
	_os_field ID
}

distro_like() {
	_os_field ID_LIKE
}

# 归到 arch / debian / fedora / suse / unknown
distro_family() {
	local id like
	id="$(distro_id)"
	like="$(distro_like)"
	case " $id $like " in
	*arch* | *cachyos* | *manjaro* | *endeavouros* | *garuda*) echo arch ;;
	*debian* | *ubuntu* | *linuxmint* | *pop*) echo debian ;;
	*fedora* | *rhel* | *centos* | *nobara*) echo fedora ;;
	*suse* | *opensuse*) echo suse ;;
	*) echo unknown ;;
	esac
}

pkg_mgr() {
	case "$(distro_family)" in
	arch) echo pacman ;;
	debian) echo apt ;;
	fedora) echo dnf ;;
	suse) echo zypper ;;
	*)
		if command -v pacman >/dev/null 2>&1; then
			echo pacman
		elif command -v apt-get >/dev/null 2>&1; then
			echo apt
		else
			echo unknown
		fi
		;;
	esac
}

# pkg_install_cmd <包名...>：打印对应发行版的安装命令
pkg_install_cmd() {
	case "$(pkg_mgr)" in
	pacman) echo "sudo pacman -S --needed $*" ;;
	apt) echo "sudo apt install $*" ;;
	dnf) echo "sudo dnf install $*" ;;
	zypper) echo "sudo zypper install $*" ;;
	*) echo "（请手动安装: $*）" ;;
	esac
}

# -------------------------------------------------------------- 内核 ----

# 目标内核版本；用 KVER 环境变量可以给别的内核编译（Arch 多内核场景）
kver() {
	printf '%s\n' "${KVER:-$(uname -r)}"
}

kernel_modules_root() {
	printf '/lib/modules/%s\n' "$(kver)"
}

kernel_build_dir() {
	printf '%s/build\n' "$(kernel_modules_root)"
}

kernel_headers_ok() {
	[ -f "$(kernel_build_dir)/Makefile" ]
}

# 当前内核对应的头文件包名
kernel_headers_pkg() {
	local kpkg
	case "$(distro_family)" in
	arch)
		# 先用内核镜像反查拥有它的包（linux / linux-lts / linux-cachyos-* …）
		kpkg="$(pacman -Qoq "$(kernel_modules_root)/vmlinuz" 2>/dev/null | head -1)"
		[ -n "$kpkg" ] ||
			kpkg="$(pacman -Qoq "/boot/vmlinuz-$(kver)" 2>/dev/null | head -1)"
		[ -n "$kpkg" ] || kpkg="linux"
		# linux-cachyos-cjktty -> linux-cachyos-cjktty-headers
		case "$kpkg" in
		*-headers) echo "$kpkg" ;;
		*) echo "${kpkg}-headers" ;;
		esac
		;;
	debian) echo "linux-headers-$(kver)" ;;
	fedora) echo "kernel-devel-$(kver)" ;;
	suse) echo "kernel-devel" ;;
	*) echo "linux-headers" ;;
	esac
}

kernel_headers_hint() {
	echo "$(pkg_install_cmd "$(kernel_headers_pkg)")"
}

# 内核是否用 clang/LLVM 构建 —— Arch 上的 CachyOS 内核大量使用 clang+LTO，
# 用 gcc 编外部模块会撞上 -fms-anonymous-structs 之类的 clang 专有参数。
kernel_uses_clang() {
	local cfg
	for cfg in "$(kernel_build_dir)/.config" "$(kernel_build_dir)/include/config/auto.conf"; do
		[ -r "$cfg" ] || continue
		if grep -q '^CONFIG_CC_IS_CLANG=y' "$cfg"; then
			return 0
		fi
	done

	if [ "$(kver)" = "$(uname -r)" ] && grep -q 'clang version' /proc/version 2>/dev/null; then
		return 0
	fi

	return 1
}

# 编译内核模块时额外要传给 make 的参数（比如 clang 内核要 LLVM=1）
kernel_make_extra() {
	if [ -n "${KMAKE_EXTRA:-}" ]; then
		printf '%s' "$KMAKE_EXTRA"
		return 0
	fi
	if kernel_uses_clang; then
		if ! command -v clang >/dev/null 2>&1; then
			warn "内核是用 clang 构建的，但系统里没有 clang（$(pkg_install_cmd clang)）" >&2
			return 0
		fi
		# clang 内核（CachyOS 等）会把 .o 编成 LTO bitcode：
		# NVIDIA 自己的 Makefile 默认 LD=ld，必须显式给 ld.lld，
		# 否则链接 nv-interface.o 时报 "file format not recognized"。
		if command -v ld.lld >/dev/null 2>&1; then
			printf 'LLVM=1 LD=ld.lld'
		else
			printf 'LLVM=1'
			warn "没有 ld.lld（$(pkg_install_cmd lld)），链接 nvidia 模块可能失败" >&2
		fi
	fi
}

# ------------------------------------------------------------- NVIDIA ----

# 用户态驱动版本（nvidia-utils）。内核模块版本必须和它一致：
# 驱动升级后，旧 shim 模块还在时 modinfo 读到的是旧版本，不能拿来当"当前版本"。
nvidia_userspace_version() {
	local v
	if [ "$(pkg_mgr)" = pacman ]; then
		v="$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//' | head -1)"
		[ -n "$v" ] && {
			printf '%s\n' "$v"
			return 0
		}
	fi

	v="$(nvidia-smi --version 2>/dev/null |
		sed -n 's/^DRIVER version[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)"
	[ -n "$v" ] && {
		printf '%s\n' "$v"
		return 0
	}

	if command -v dpkg-query >/dev/null 2>&1; then
		v="$(dpkg-query -W -f='${Version}\n' 'nvidia-utils-*' 2>/dev/null |
			sort -V | tail -1 | sed 's/-[0-9].*$//')"
		[ -n "$v" ] && {
			printf '%s\n' "$v"
			return 0
		}
	fi

	if command -v rpm >/dev/null 2>&1; then
		v="$(rpm -q --qf '%{VERSION}\n' akmod-nvidia nvidia-kmod-common 2>/dev/null |
			head -1)"
		[ -n "$v" ] && printf '%s\n' "$v"
	fi
}

# 当前 NVIDIA 驱动版本号。
# 优先用户态版本（内核模块必须和它匹配）；用户态查不到时才用模块/DKMS 的信息。
nvidia_driver_version() {
	local v

	if [ -n "${NVVER:-}" ]; then
		printf '%s\n' "$NVVER"
		return 0
	fi

	v="$(nvidia_userspace_version || true)"
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
		return 0
	fi

	v="$(modinfo -F version nvidia 2>/dev/null | head -1)"
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
		return 0
	fi

	v="$(sed -n 's/^NVRM version: *NVIDIA UNIX.*Kernel Module *\([0-9][0-9.]*\).*/\1/p' \
		/proc/driver/nvidia/version 2>/dev/null | head -1)"
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
		return 0
	fi

	v="$(dkms status nvidia 2>/dev/null | sed -n 's|^nvidia/\([^,]*\),.*|\1|p' | head -1)"
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	fi
}

# 打印 nv-acpi.c 的路径，找不到返回非 0
nv_acpi_path() {
	local root="$1"
	if [ -f "$root/kernel-open/nvidia/nv-acpi.c" ]; then
		printf '%s\n' "$root/kernel-open/nvidia/nv-acpi.c"
		return 0
	fi
	if [ -f "$root/nvidia/nv-acpi.c" ]; then
		printf '%s\n' "$root/nvidia/nv-acpi.c"
		return 0
	fi
	return 1
}

# 源码布局：open（nvidia-open / open-gpu-kernel-modules）| legacy（.run 完整树）
# 两者都没有时输出空
nvidia_layout() {
	local root="$1"
	if nv_acpi_path "$root" >/dev/null; then
		if [ -f "$root/kernel-open/nvidia/nv-acpi.c" ]; then
			echo open
		else
			echo legacy
		fi
		return 0
	fi
	return 1
}

# 模块 .ko 相对于源码树根目录的子目录
nvidia_module_rel() {
	local root="$1"
	if [ -f "$root/kernel-open/nvidia/nv-acpi.c" ]; then
		echo "kernel-open"
	else
		echo ""
	fi
}

# 从源码树路径里取版本号（用于挑最新的源码树）
_root_version_key() {
	local path="$1" base ver
	path="${path%/build}"
	base="${path##*/}"
	case "$base" in
	nvidia-open-*) ver="${base#nvidia-open-}" ;;
	nvidia-*) ver="${base#nvidia-}" ;;
	*) ver="0" ;;
	esac
	printf '%s\n' "$ver"
}

# 找 NVIDIA 内核模块源码树：NV_SRC_ROOT > /usr/src/nvidia-<版本> >
# /usr/src/nvidia-open-<版本> > DKMS build 目录 > /usr/src 下版本号最大者
nvidia_src_root() {
	local ver root cand best="" bestver=""

	if [ -n "${NV_SRC_ROOT:-}" ]; then
		printf '%s\n' "$NV_SRC_ROOT"
		return 0
	fi

	ver="$(nvidia_driver_version)"

	for root in \
		"/usr/src/nvidia-${ver}" \
		"/usr/src/nvidia-open-${ver}" \
		"/var/lib/dkms/nvidia/${ver}/build"; do
		[ -n "$ver" ] || continue
		if nv_acpi_path "$root" >/dev/null 2>&1; then
			printf '%s\n' "$root"
			return 0
		fi
	done

	for root in /usr/src/nvidia-* /var/lib/dkms/nvidia/*/build; do
		[ -d "$root" ] || continue
		nv_acpi_path "$root" >/dev/null 2>&1 || continue
		cand="$(_root_version_key "$root")"
		if [ -z "$best" ] ||
			[ "$(printf '%s\n%s\n' "$bestver" "$cand" | sort -V | tail -1)" = "$cand" ]; then
			best="$root"
			bestver="$cand"
		fi
	done

	if [ -n "$best" ]; then
		printf '%s\n' "$best"
		return 0
	fi

	return 1
}

# 官方（未打补丁）nvidia 模块所在的 DKMS 编译产物目录
nvidia_official_module_dir() {
	local ver k d
	ver="$(nvidia_driver_version)"
	k="$(kver)"
	[ -n "$ver" ] || return 1

	for d in /var/lib/dkms/nvidia/"$ver"/"$k"/*/module \
		/var/lib/dkms/nvidia/"$ver"/"$k"/module; do
		if [ -d "$d" ] && ls "$d"/nvidia.ko* >/dev/null 2>&1; then
			printf '%s\n' "$d"
			return 0
		fi
	done

	return 1
}

# 官方 nvidia 模块当前实际生效的位置（modinfo 查到的路径），
# 但跳过我们自己装补丁模块的目录
nvidia_installed_module_dir() {
	local path dir
	path="$(modinfo -n nvidia 2>/dev/null | head -1)"
	[ -n "$path" ] || return 1
	dir="$(dirname "$path")"
	case "$dir" in
	*/updates/nvpcf-shim | */updates/dkms) return 1 ;;
	esac
	printf '%s\n' "$dir"
}

# 某个目录里有没有 nvidia 模块
has_nvidia_modules() {
	local d="$1"
	ls "$d"/nvidia.ko* >/dev/null 2>&1
}

# 目录里的 nvidia 模块是不是打过 shim 的（看模块参数）
dir_has_shim_modules() {
	local d="$1" ko out
	for ko in "$d"/nvidia.ko*; do
		[ -f "$ko" ] || continue
		# 先取完整输出再判断：pipefail 下 `modinfo | grep -q` 可能因
		# grep 提前退出、modinfo 收到 SIGPIPE 而误判。
		out="$(modinfo "$ko" 2>/dev/null || true)"
		if grep -q 'parm:.*nvpcf_shim' <<<"$out"; then
			return 0
		fi
	done
	return 1
}

# 所有带 shim 参数的模块目录（清旧安装 / 回退时用）
find_shim_module_dirs() {
	local d
	for d in "$(kernel_modules_root)"/updates/*/ \
		"$(kernel_modules_root)"/updates/ \
		"$(kernel_modules_root)"/extra/ \
		"$(kernel_modules_root)"/kernel/drivers/video/; do
		[ -d "$d" ] || continue
		has_nvidia_modules "${d%/}" || continue
		dir_has_shim_modules "${d%/}" && printf '%s\n' "${d%/}"
	done
}

# shim 模块应该装到哪：官方模块在 updates/ 下就覆盖它（Debian 的 dkms 路径），
# 否则单独用 updates/nvpcf-shim（Arch 官方模块在 kernel/drivers/video/）
nvidia_shim_dest() {
	local d root
	if [ -n "${NV_SHIM_DEST:-}" ]; then
		printf '%s\n' "$NV_SHIM_DEST"
		return 0
	fi
	root="$(kernel_modules_root)"
	for d in "$root"/updates/*/ "$root"/updates/; do
		[ -d "$d" ] || continue
		if has_nvidia_modules "${d%/}" && ! dir_has_shim_modules "${d%/}"; then
			printf '%s\n' "${d%/}"
			return 0
		fi
	done
	printf '%s\n' "$root/updates/nvpcf-shim"
}

# 找官方（未打补丁）nvidia 模块所在目录
# 优先 /var/lib/dkms 的编译产物，其次扫描内核模块目录树
find_official_module_dir() {
	local ver k d ko dir v
	ver="$(nvidia_driver_version)"
	k="$(kver)"

	if [ -n "$ver" ]; then
		for d in /var/lib/dkms/nvidia/"$ver"/"$k"/*/module \
			/var/lib/dkms/nvidia/"$ver"/"$k"/module; do
			if [ -d "$d" ] && has_nvidia_modules "$d" && ! dir_has_shim_modules "$d"; then
				printf '%s\n' "$d"
				return 0
			fi
		done
	fi

	if [ -n "${NV_OFFICIAL_DIR:-}" ] && has_nvidia_modules "$NV_OFFICIAL_DIR"; then
		printf '%s\n' "$NV_OFFICIAL_DIR"
		return 0
	fi

	for ko in $(find "$(kernel_modules_root)" -maxdepth 4 -type f -name 'nvidia.ko*' 2>/dev/null); do
		dir="$(dirname "$ko")"
		dir_has_shim_modules "$dir" && continue
		if [ -n "$ver" ]; then
			v="$(modinfo -F version "$ko" 2>/dev/null | head -1)"
			[ -n "$v" ] && [ "$v" != "$ver" ] && continue
		fi
		printf '%s\n' "$dir"
		return 0
	done

	return 1
}

# 620+ 的驱动存在「先更新 limit、后初始化传感器」的顺序问题，需要
# nvpcf_shim_pshare_init=1；更旧的驱动（如 595）保持原行为（0）。
nvidia_needs_pshare_init() {
	local v major
	v="$(nvidia_driver_version)"
	major="${v%%.*}"
	case "$major" in
	'' | *[!0-9]*) return 1 ;;
	esac
	[ "$major" -ge 620 ]
}

# 检测 NVIDIA 驱动包类型（Arch 专用；其他发行版输出空）
#   dkms  - nvidia-open-dkms / nvidia-dkms：有源码，可以打 shim
#   open  - nvidia-open：预编译开放模块，没有源码
#   none  - 没装
nvidia_pkg_kind_arch() {
	local p
	for p in nvidia-open-dkms nvidia-dkms nvidia-open-lts-dkms; do
		pacman -Qq "$p" >/dev/null 2>&1 && { echo dkms; return 0; }
	done
	for p in nvidia-open nvidia-open-lts nvidia-open-beta; do
		pacman -Qq "$p" >/dev/null 2>&1 && { echo open; return 0; }
	done
	for p in nvidia nvidia-lts; do
		pacman -Qq "$p" >/dev/null 2>&1 && { echo proprietary; return 0; }
	done
	echo none
}

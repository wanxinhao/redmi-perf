#!/usr/bin/env bash
#
# pacman 钩子：NVIDIA 驱动包（nvidia-open-dkms / nvidia-utils / …）变更后，
# 之前编译的 shim 模块和新的用户态库版本对不上，驱动会起不来
# （NVML: Driver/library version mismatch）。
#
# 这里自动回退到官方模块（安全），并把提示写进 journal 和
# /var/log/nvpcf-shim.log。想继续用 shim，重跑 nvpcf-shim/install.sh。
#
# 由 nvpcf-shim/install-prebuilt.sh 安装到 /usr/local/lib/nvpcf-shim/。
#
set -uo pipefail

MARK="/var/backups/nvidia-ko-$(uname -r)/shim-installed"
LOG=/var/log/nvpcf-shim.log

# 没装过 shim 就什么都不用做
[ -e "$MARK" ] || exit 0

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{
	echo "== $(date '+%F %T') NVIDIA 包变更，撤销 NVPCF shim（避免内核模块/用户态版本错配）"
	if /usr/local/lib/nvpcf-shim/restore-prebuilt.sh --quiet; then
		echo "== 已回退到官方模块。要重新启用 shim: sudo nvpcf-shim/install.sh"
	else
		echo "== 自动回退失败，请手动运行: sudo nvpcf-shim/restore-prebuilt.sh"
	fi
} >>"$LOG" 2>&1

# 让 pacman 的输出里也能看到
tail -n 3 "$LOG" 2>/dev/null | sed 's/^/  /' >&2 || true

exit 0

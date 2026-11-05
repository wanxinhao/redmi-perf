#!/usr/bin/env bash
#
# 还原 NVIDIA 驱动到未打补丁的状态。
#
# 做法：直接把 DKMS 自己 build 出来的原版模块装回去，并删掉模块参数。
# 比"unpatch 源码再重编"可靠 —— 后者依赖 dkms build 能正常工作，
# 而 .run 安装器装出来的驱动 dkms build 是静默跳过的。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
	echo "需要 root：sudo $0" >&2
	exit 1
fi

exec "$HERE/restore-prebuilt.sh"

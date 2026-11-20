#!/usr/bin/env bash
#
# 还原 NVIDIA 驱动到未打补丁的状态。
#
# 直接把 DKMS 编出来的官方模块装回去，并删掉模块参数。
# 比"unpatch 源码再重编"可靠：后者依赖 dkms build 能正常工作，
# 而 .run 安装器装出来的驱动 dkms build 是静默跳过的。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$HERE/restore-prebuilt.sh" "$@"

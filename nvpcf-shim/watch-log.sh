#!/usr/bin/env bash
#
# 汇总 shim 的日志，方便看 NVPCF 流量和驱动断言。
#
set -u

echo "===== NVPCF-SHIM 流量 ====="
sudo dmesg | grep -a "NVPCF-SHIM" || echo "(没有 NVPCF-SHIM 日志，说明驱动没走 NVPCF 路径)"
echo
echo "===== 驱动断言 ====="
sudo dmesg | grep -aE "nvAssert|SBIOS|PlatformRequestHandler" || echo "(没有断言)"
echo
echo "===== 功耗状态 ====="
nvidia-smi -q -d POWER 2>/dev/null | grep -iE "Power Limit|Power Draw|Target Temperature" || true

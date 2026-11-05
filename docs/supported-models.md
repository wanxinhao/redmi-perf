# 支持机型

## 已验证

| 机型 | DMI 产品名 | BIOS 版本 | 状态 |
|---|---|---|---|
| Redmi G Pro 2024 (2024) | `TM2211` | RMGRP6B0P0909 | ✅ 完整验证 |

## 原理：为什么不靠 DMI 白名单

`redmi_perf_wmi` 内核模块通过 **MIFS WMI GUID** 匹配
（`B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B`），只要固件实现了
`MiInterface` 这个 ACPI 方法就能挂上，不需要 DMI 匹配表。

上游 `bitland-mifs-wmi` 的 DMI 表只有 `TM2135` / `TM2137`，
所以本机（`TM2211`）匹配不上 —— 这是我们自己写模块的直接原因。

## 可能能用但没验证

任何用同一代 MIFS 固件的小米 / Redmi 笔记本都可能可用。
候选机型（基于同代平台）大致包括：

- Redmi G Pro 2023 / 2022
- RedmiBook Pro 15 / 16（2024）
- Xiaomi Book Pro 16

⚠ **但性能模式的编码、功耗数值、固件行为各家可能不同。**
换机型前请先跑探测脚本：

```bash
sudo ./scripts/probe.sh            # 只读，看固件答不答应
sudo ./scripts/probe.sh --sweep    # 扫 0x00..0x1f，找出固件支持哪些命令
```

## 反馈

换机型试过之后，欢迎开 issue，请附上：

```bash
sudo dmidecode -s system-product-name
sudo dmidecode -s bios-version
cat /sys/class/dmi/id/product_version
sudo ./scripts/probe.sh
```

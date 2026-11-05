# redmi-perf

在 Linux 上把小米 / Redmi 笔记本的**独显性能模式**开出来，
并修掉 NVIDIA 驱动因为固件缺失而抛出的两条断言。

Windows 上用「小米控制中心 / GCommandCenter」能一键切性能模式、满速风扇、
拉高 GPU TGP；Linux 下这些全都摸不到。这个项目把那条通道重建出来。

> **状态**：可用。已在 Redmi G Pro 2024（TM2211）+ Ubuntu 26.04 + 内核 7.0.0-42
> + NVIDIA 595.112.07 上验证。

## 效果

### 1. 性能模式（EC 通道）

`redmi-perf` 通过小米自己的 MIFS WMI 接口直接和 EC 对话，切平台性能模式。

```console
$ redmi-perf set turbo
mode set to turbo

$ nvidia-smi -q -d POWER | grep -i "Current Power Limit"
        Current Power Limit                            : 125.00 W
```

社区抓包实测的各档 GPU 功耗（见 [docs/reverse-engineering.md](docs/reverse-engineering.md)）：

| 模式值 | 模式 | GPU 功耗 |
|---|---|---|
| 1 | balanced | 80 W |
| 2 | quiet / power-saver | 55 W |
| 3 | turbo | 125 W |
| 4 | full-speed / performance | 115 W+ |

### 2. NVPCF 固件断言（驱动侧）

固件没实现 NVIDIA 的 SBIOS 平台查询接口，驱动每次开机都会抛两条断言：

```
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Invalid data passed [NV_ERR_INVALID_DATA]
      (0x00000025) returned from PlatformRequestHandler failed to get target temp from SBIOS
      @ platform_request_handler_ctrl.c:2174
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Invalid data passed [NV_ERR_INVALID_DATA]
      (0x00000025) returned from PlatformRequestHandler failed to get platform power mode from SBIOS
      @ platform_request_handler_ctrl.c:2117
```

`nvpcf-shim` 给 NVIDIA 内核模块打一个补丁，在 ACPI 应答返回后就地补齐
固件少给的字节。**两条断言都会消失，驱动不再因为取不到平台参数而降级。**

## 组成

```
kernel/redmi-perf-wmi/    EC 性能模式内核模块（C，DKMS）
cli/                      redmi-perf 命令行工具（Rust）
nvpcf-shim/               NVIDIA NVPCF ACPI 应答补丁（C + Python）
scripts/                  安装与诊断脚本
tools/                    逆向分析工具
docs/                     逆向笔记与排错
```

## 安装

### 前置

```bash
sudo apt install dkms build-essential linux-headers-$(uname -r) cargo
```

### 一、EC 性能模式

```bash
git clone https://github.com/wanxinhao/redmi-perf.git
cd redmi-perf

# 推荐：走 DKMS，内核升级后自动重编
sudo ./scripts/install-redmi-perf.sh --dkms
```

### 二、NVPCF 断言修复（可选）

> ⚠ **这一步会替换内核里的 nvidia 模块。装坏了会开不了机。**
> 请先读 [docs/troubleshooting.md](docs/troubleshooting.md) 里的「开不了机怎么办」，
> 确认你能在 tty 下恢复。

```bash
cd redmi-perf/nvpcf-shim
sudo ./install.sh              # 打补丁 + 编译 + 安装
sudo reboot

# 验证
sudo dmesg | grep -iE 'NVPCF-SHIM|SBIOS'   # 应该没有 NVRM 断言
```

### 三、开机自启

```bash
echo redmi_perf_wmi | sudo tee /etc/modules-load.d/redmi-perf.conf
sudo systemctl enable --now nvidia-powerd.service
```

## 使用

```bash
redmi-perf get              # 当前模式
redmi-perf list             # 可用模式
redmi-perf set turbo        # 切模式
redmi-perf psu              # 供电方式（见下方注意事项）
redmi-perf status           # 上次调用的固件状态
redmi-perf params           # 协议参数（可实时调）
```

### ⚠ 性能模式需要插圆口电源

turbo / full-speed 需要 **DC 圆口充电器**。USB-C PD 供电时固件会直接拒绝
（状态 `0xE0`，sysfs 写入返回 `EOPNOTSUPP`）。

```bash
redmi-perf psu        # 期望看到 "2 (DC)"
```

> 注意：本机固件**不支持查询** PSU 类型（命令 `0x13` 返回 `0xE0`），
> 所以 `redmi-perf psu` 会报错。只能直接 SET，看固件给什么状态码。

### 判断有没有真的生效

`nvidia-smi` 里的 `Current Power Limit` 在切模式后**不一定立刻变**
（它读的是固件静态表）。要判断实际效果，看功耗 / 频率 / 温度：

```bash
sudo ./scripts/bench.sh                 # 依次测所有模式
sudo ./scripts/bench.sh quiet turbo     # 只测指定模式
```

## 支持机型

| 机型 | DMI | 状态 |
|---|---|---|
| Redmi G Pro 2024 | `TM2211` | ✅ 已验证 |
| Redmi G Pro 2023 | `TM2305` | ❓ 未验证 |
| 其他小米 / Redmi | — | ❓ 未验证，请开 issue 反馈 |

内核模块通过 MIFS WMI GUID 匹配机型，**不依赖 DMI 白名单**，所以理论上
所有用同一套 MIFS 固件的机型都能用。但性能模式编码和固件行为各家不同，
换机型前请先跑 `scripts/probe.sh` 看看固件答不答应。

## 风险

- **`redmi-perf` 内核模块**：只做查询和转发，不改硬件设置，风险很低。
- **`nvpcf-shim`**：替换 NVIDIA 内核模块。改的是 ACPI 应答缓冲区，
  逻辑上是「补齐固件少给的字节」，但万一写错会让驱动拿到非法值。
  万一开不了机，见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 回退

```bash
# 撤掉 EC 模块
sudo ./scripts/install-redmi-perf.sh --uninstall

# 换回官方 NVIDIA 驱动
sudo ./nvpcf-shim/restore-prebuilt.sh && sudo reboot
```

`restore-prebuilt.sh` 会从 DKMS 自己的 build 产物里取**原版**模块装回去，
并删掉 `/etc/modprobe.d/nvidia-nvpcf-shim.conf`。

## 文档

- [docs/reverse-engineering.md](docs/reverse-engineering.md) —— MIFS WMI 协议与
  NVPCF / GPS counter 的逆向笔记（协议细节都在这）
- [docs/supported-models.md](docs/supported-models.md) —— 机型与模式编码
- [docs/troubleshooting.md](docs/troubleshooting.md) —— 排错与灾难恢复

## 致谢

- MIFS WMI 协议格式来自社区对 Xiaomi GCommandCenter 的逆向
- NVPCF / GPS 协议细节来自 NVIDIA 公开文档与驱动反汇编
- `redmi_perf_wmi` 借鉴了上游 `bitland-mifs-wmi` 的实现思路

## License

GPL-2.0-only。内核模块部分必须保持 GPL（要链接 Linux 内核），
用户态工具同许可。见 [LICENSE](LICENSE)。

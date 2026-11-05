# 逆向笔记

本文记录两条通路的协议细节。**实测机型：Redmi G Pro 2024（TM2211，
RMGRP6B0P0909）**，固件版本与其它机型可能不同。

---

# 第一部分：MIFS WMI 协议（EC 通道）

## 概述

小米的性能模式最终由 **EC** 执行。Windows 上的 GCommandCenter 通过一个
**WMI method** 把命令送进 ACPI，再由 ACPI 转成 EC 的 SCI/共享内存命令。
Linux 上没有这个 WMI provider，所以要自己写内核模块直接调
`wmidev_evaluate_method`。

## 协议参数

| 项目 | 值 |
|---|---|
| WMI GUID（method 型） | `B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B` |
| ACPI 方法 | `MiInterface` |
| InData / OutData 长度 | 32 / 30 字节 |
| 本机总线属性 | `DEVTYPE=method`、`object_id=AA`、`instance_count=1` |

## 请求布局（InData，32 字节）

| 偏移 | 含义 |
|---|---|
| `[0]` | 保留（实测恒为 0） |
| `[1]` | 操作：`0xFA` = GET，`0xFB` = SET |
| `[2]` | 保留 |
| `[3]` | 命令 id |
| `[4]` | 参数值 |
| `[5..31]` | 保留 |

实测样例：

```
GET  cmd 0x08  ->  00 fa 00 08 00
SET  cmd 0x08 val=2  ->  00 fb 00 08 02
```

## 应答布局（OutData，30 字节）

固件只有两种应答，**由 `[0]` 区分**：

**成功**（`[0] = 0x03`）：

```
03 00 00 00 | 20 00 00 00 | d8 20 ef 41 25 8d | ff ff | 00 × 9 | 80 00 | <cmd> | <载荷 2 字节>
             ^ 回显的请求长度 ^ 6 字节计数/时间戳 ^ 保留  ^ 状态 ^ 保留 ^ 回显 ^ u16 LE
```

**不支持**（`[0] = 0x01`）：

```
01 00 00 00 00 00 00 00 00 | e0 | 00 × 20
                          ^ 错误码 0xE0
```

### 偏移不写死

因为固件会在应答里回显命令 id，模块**不硬编码偏移**：每次调用后自动扫描
回显位置，反推状态字节和数值字节的位置（`auto_scan` 参数，默认开）。
固件改版调整布局也不会失效。

## 命令表（实测）

| 命令 | 结果 |
|---|---|
| `0x08` | ✅ `SystemPerMode` —— 性能模式，载荷 = 模式值（u16 LE） |
| `0x09` | ✅ 支持，载荷 `41 08` = 2113（疑似风扇转速；固件未暴露 fan 节点，无从旁证） |
| `0x00` `0x01` `0x07` `0x13` | ❌ 不支持（`0xE0`） |

`0x13`（PSU 类型）不被支持，所以没法提前查询是否插了圆口电源，
只能直接 SET，看固件给什么状态码。

## 模式编码

| 值 | 模式 | 社区抓到的 GPU 功耗 |
|---|---|---|
| 0 | **未定义**（上游说是 Performance，社区抓取里没有 0） | 别盲写 |
| 1 | balanced | 80 W |
| 2 | quiet / power-saver | 55 W |
| 3 | turbo | 125 W |
| 4 | full-speed / performance | 115 W+ |

`1 / 2 / 4` 两个来源一致；`3` 只在社区抓取里出现；`0` 只在上游驱动里出现。
所以模块把 0 标成 `unknown`，默认不用它。

## 上游驱动帮不上忙

内核 7.0.0-42 里只有 `CONFIG_REDMI_WMI`（**只有热键功能**），
没有上游 2026-08 才合入的 `bitland-mifs-wmi`；而且上游那个驱动的 DMI 匹配表
只有 `TM2135` / `TM2137`，**本机是 `TM2211`，照样匹配不上**。
所以自己写一个最小的外部模块。

## 为什么内核用 C、用户态用 Rust

- **rust-for-linux 没有 WMI 绑定**：`wmidev_evaluate_method`、`struct acpi_buffer`、
  `struct wmi_device` 全得手写 `extern "C"` FFI，结构体布局错了就是 UB；
- **Ubuntu 的 headers 包里没有 `lib/rust`**，外部 Rust 模块需要的
  `libkernel.rlib` 不存在，得自己编整个内核的 `rust/` 目录；
- 内核 API 是 C 的原生接口，用 C 写最省事也最不容易出错；
- 用户态用 Rust 正合适：单静态二进制、零依赖、参数解析清晰。

---

# 第二部分：NVPCF / GPS（驱动侧）

## 概述

NVIDIA 驱动在笔记本上会走 **PlatformRequestHandler**：通过 ACPI 向固件
查询平台参数（目标温度、平台功耗模式、动态功耗曲线……）。
固件不实现 → 驱动拿不到 → 抛断言。

ACPI 接口是 `\_SB.NPCF._DSM`。

## GPS（GPU Platform Settings）

GUID：`a3132d01-8cda-49ba-a52e-bc9d46df6b81`

驱动对 GPS func `0x2a`（读 perf sensor counter）有**两种调用**，
靠请求缓冲区区分：

### A) 支持位查询（初始化时一次）

请求 `in[0..3] == 0x00010101`，应答是「支持哪些 counter 槽」的位掩码：

| 位 | 对应 |
|---|---|
| bit 8 (`0x00100`) | 槽 0 = counter `0x0b` |
| bit 16 (`0x10000`) | 槽 8 = counter `0x13`（platform power mode）|

驱动取 `resp[0..3] & 0x10100` 存进 `obj[0x6c0]`，采样时用
`mask = obj[0x6c0] | 2` 去问固件。

**本机固件只给了 bit 8** → counter `0x13` 永远被判为「不支持」→
`pfmreqhndlrGetPerfSensorCounterById(0x13)` 返回 `NV_ERR_INVALID_DATA`
→ 断言 `failed to get platform power mode from SBIOS` 每次必炸。

### B) 采样（周期性）

应答布局：

| 偏移 | 内容 |
|---|---|
| `out[0x00]` | counter 序号 |
| `out[0x01] bit0` | 有效位 |
| `out[0x08..0x0b]` u32 | 槽 0（counter `0x0b`）的值 —— 本机是 **87** |
| `out[0x28..0x2b]` u32 | 槽 8（counter `0x13`）的值 —— **固件只回 40 字节，缺失** |

驱动把 `out[0x08..0x0b]` 写进 counter `0x0b` 的 value 字段，然后
`_pfmreqhndlrUpdateTgpuLimit` 把它 `<<8` 用 ctrl cmd `0x20800ad1` 下发给 GPU。

## counter 表结构

`obj + 0x58 + id * 0x10`：

| 字段 | 含义 |
|---|---|
| `[0]` | supported |
| `[1]` | sampleable |
| `[2]` | invalid |
| `[3]` | pending |
| `[4]` | value |
| `[8]` | timestamp |
| `[12]` | period（20 ms）|

GPS 槽 0 == counter `0x0b`，槽 8 == counter `0x13`。

## 两条断言的成因

| 断言 | 成因 |
|---|---|
| `failed to get target temp from SBIOS` | 固件应答 40 字节，驱动要 44，counter 结构整体解析失败 |
| `failed to get platform power mode from SBIOS` | 支持位应答缺 bit16，counter `0x13` 被判为不支持 |

**shim 的做法**：在 ACPI 调用返回后就地改写应答缓冲区 ——
把采样应答补齐到 44 字节并填上槽 8，给支持应答补上 bit16。
两条断言随之消失。

## counter `0x0b` 是「目标温度」，不是功耗

这是踩过的坑，值得单独记：

| 证据 | 值 |
|---|---|
| 固件返回 | 87 |
| `nvidia-smi -q -d TEMPERATURE` 的 `GPU Target Temperature` | 87 C |

`_pfmreqhndlrUpdateTgpuLimit` 把它 `<<8` 当温度下发给 GPU。
**所以这条通路永远改不了功耗上限，它只管温度。**

往里塞非 87 的值（比如 100）会让固件拒绝 `set thermal limit` 指令，
多出一条 `PRH failed to update thermal limit!` 断言。
所以 `nvpcf_shim_ctr0b` 默认是 **0**（保持固件原值）。

## 已排除的死路：NVPCF func 0x2 动态功耗表

早期怀疑「固件把功耗表整体后移 6 字节」，**这是错的**。
反汇编 `nv-kernel.o_binary` 后确认：

- case 3 的解析里，条目数在 `obj+0x130`，但只有 `_configUnpackStructure("4d")`
  写过 `obj+0x140..0x131`，`obj+0x130` 从头到尾都是 0 →
  条目循环一次都不进，`obj[0x18]/[0x1c]/[0x20]` 永远不会被填；
- 同一段代码还要求应答头是 `[0]=版本(u32) [4]=5 [8]=16 [12]=28` 的展开格式，
  而固件给的是 `24 05 10 1c 01` 的紧凑格式，版本检查就先挂了。

⇒ 搬字段没有意义（`shift` 参数默认关掉）。

## 功耗上限到底由谁决定

**EC。** `Current Power Limit` 随 EC 性能模式变化：

| EC 模式 | Current Power Limit |
|---|---|
| balanced | 80 W |
| quiet | 55 W |
| turbo | 125 W |
| full-speed | 115 W |

`nvidia-smi -pl` 被拒（`Changing power management limit is not supported for GPU`）
是**设计如此**：驱动认为功耗由平台管控。Windows 上同样如此。

`nvidia-smi` 里的 `Default Power Limit: 55W` / `Max Power Limit: 140W`
只是驱动**没协商到动态加速时的兜底值**，不是硬件限制。

## 还开着的一条路

counter `0x13` = platform power mode = `(允许模式掩码 << 8) | 当前模式`。
驱动读到后写进 `obj[0x6c5]`（掩码）/ `obj[0x6c6]`（当前模式）。

**如果驱动拿「当前模式」去决定向平台请求哪档功耗，注入 mode=3/4 就能把
80 W 顶上去。** 这是目前最有希望的一条路，用
`nvpcf-shim/runtime-sweep.sh` 在线扫（改 `/sys/module/nvidia/parameters/`
里的参数，不用重启、不用重编）。

## 固件里能看到的功耗曲线

NVPCF func `0x8` 的应答里有 20 组 (u32, u32)，看着像功耗/频率点表：

```
10 04 11 05 64 70 17 00 00 d8 59 00 00 f0 55 00 00 70 94 00 00 ...
```

其中一组 `0x16a850` = 1484880，对应 ≈1.48 GHz；
另一组 `0x59d8` = 23000，对应 ≈23 W。
推测是 (频率 kHz, 功耗 mW) 之类的点表，但**没有找到驱动解析它的代码路径**，
暂时无法利用。

## 逆向工具

`tools/elfrela.py` —— 解析 ELF 重定位并映射回函数，用来在
`nv-kernel.o_binary` 里定位符号。配合 `objdump -d` 使用。

```bash
objdump -d /usr/src/nvidia-595.112.07/nvidia/nv-kernel.o_binary > all.asm
python3 tools/elfrela.py ...
```

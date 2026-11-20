# nvpcf-shim

给 NVIDIA 内核模块（闭源完整源码树 / 开源 `nvidia-open`）打一个补丁，
修掉固件缺失导致的 NVPCF 断言。

> Arch Linux 用户：装 **`nvidia-open-dkms`**（源码包）才能打补丁，
> 预编译的 `nvidia-open` 没有源码。完整说明见
> [../docs/arch-linux.md](../docs/arch-linux.md)。

> ⚠ **高风险**：这一步会替换内核里的 nvidia 模块，装坏了会开不了机。
> 装之前请务必读完 [../docs/troubleshooting.md](../docs/troubleshooting.md)
> 里的「开不了机怎么办」，并确认你能在 tty 下恢复。

## 它修什么

固件没实现 NVIDIA 的 SBIOS 平台查询接口，驱动每次开机抛两条断言：

```
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Invalid data passed [NV_ERR_INVALID_DATA]
      (0x00000025) returned from PlatformRequestHandler failed to get target temp from SBIOS
      @ platform_request_handler_ctrl.c:2174
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Invalid data passed [NV_ERR_INVALID_DATA]
      (0x00000025) returned from PlatformRequestHandler failed to get platform power mode from SBIOS
      @ platform_request_handler_ctrl.c:2117
```

原理：NVIDIA 内核模块通过 ACPI `\_SB.NPCF._DSM` 向固件问平台参数，
固件少给了字节 / 少给了支持位，驱动就报 INVALID_DATA。
本补丁在 ACPI 应答返回后就地补齐 —— **不改驱动逻辑，只补固件的缺**。

另外，nvidia-open 620 在初始化时会「先更新 limit、后初始化传感器」：
`PSHARESTATUS(0x20)` 报 `UPDATE_LIMIT pending` 后驱动立刻去读 TGPU/PPMD，
此时传感器还没初始化，于是开机各打一次同样的两条断言。
`nvpcf_shim_pshare_init=1` 只在初始化窗口内清掉这个 pending 位绕过它，
运行期的平台限制更新不受影响（细节见
[../docs/reverse-engineering.md](../docs/reverse-engineering.md)）。

详细的协议分析和反汇编结论见 [../docs/reverse-engineering.md](../docs/reverse-engineering.md)。

## 用法

```bash
./install.sh --check           # 检查源码布局 / 编译参数 / 备份来源
sudo ./install.sh              # 打补丁 + 编译 + 安装 + 写模块参数
sudo reboot

# 验证
sudo dmesg | grep -iE 'NVPCF-SHIM|SBIOS'
```

`build.sh` 会自动识别两种 NVIDIA 源码布局：

- `kernel-open/nvidia/nv-acpi.c` —— `nvidia-open` / `open-gpu-kernel-modules`
  （Arch `nvidia-open-dkms`，模块产物在 `kernel-open/` 下）；
- `nvidia/nv-acpi.c` —— 官方 `.run` / 发行版完整源码树。

Arch 上还会自动处理 clang + ThinLTO 内核（`LLVM=1 LD=ld.lld`）和
编译器小版本不一致（`IGNORE_CC_MISMATCH=1` 重试）。

只要诊断不想改任何行为：

```bash
sudo ./install.sh --record
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `shim_block.c` | 核心：在 ACPI 应答返回后就地改写缓冲区 |
| `hook_block.c` | 插入点：在 `nv_acpi_dsm_method` 里挂钩 |
| `fallback_block.c` | 硬编码 ACPI 路径失败时，用命名空间句柄重试 |
| `patch_nv_acpi.py` | 幂等地把上面三块打进 `nv-acpi.c`（带锚点校验） |
| `unpatch_nv_acpi.py` | 从 `.orig` 备份还原 |
| `build.sh` | 编译 NVIDIA 驱动源码，产出 `prebuilt/*.ko.zst` |
| `install-prebuilt.sh` | 把编好的模块装进 `/lib/modules/`，写模块参数 |
| `restore-prebuilt.sh` | **换回官方原版模块**（回退用这个） |
| `arch/nvpcf-shim.hook` | Arch pacman 钩子：驱动升级后自动回退，避免版本错配 |
| `arch/on-nvidia-upgrade.sh` | 上面钩子调用的脚本（日志在 `/var/log/nvpcf-shim.log`） |
| `runtime-sweep.sh` | 在线扫 shim 参数（改 `/sys/module/nvidia/parameters/`，不用重启） |
| `after-reboot-check.sh` | 重启后一次性体检 |

其余 `*.sh` 是诊断脚本（功耗映射、模式对照、GPU 探针等）。

## 模块参数

全部是 `module_param(0644)`，**可以在运行时直接改，不用重启**：

```bash
ls /sys/module/nvidia/parameters/ | grep nvpcf_shim
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `nvpcf_shim_mode` | 1 | 0 = 只记录不改写，1 = 改写 |
| `nvpcf_shim_log` | 1 | 打印 DSM 流量 |
| `nvpcf_shim_fallback` | 1 | 硬编码路径失败时用 ACPI 命名空间句柄重试 |
| `nvpcf_shim_rev` | 0 | 非 0 = 强制改写 DSM revision |
| `nvpcf_shim_shift` | 0 | 动态功耗表字段搬位（**已证实是死路，别开**）|
| `nvpcf_shim_ctr0b` | 0 | 覆盖 counter `0x0b`。**它是目标温度(℃)不是功耗，别乱填** |
| `nvpcf_shim_ppm_enable` | 1 | 给支持应答打开 counter `0x13` 位 |
| `nvpcf_shim_ppm` | 0x1E01 | counter `0x13` 的值 = `(允许模式掩码<<8)\|当前模式` |
| `nvpcf_shim_pshare_init` | 1 | 初始化窗口内清掉 PShareStatus 的 `UPDATE_LIMIT pending` 位（修 620 驱动的启动顺序断言）。安装器对 620+ 写 1，595 等旧驱动写 0 保持原行为 |

> ⚠ `nvpcf_shim_ctr0b` 填非 0 值会让固件拒绝 `set thermal limit` 指令，
> 多出一条 `PRH failed to update thermal limit!` 断言。**保持 0。**

## 回退

```bash
sudo ./restore-prebuilt.sh && sudo reboot
```

它从 DKMS 自己的 build 产物取**原版**模块装回去（版本必须与当前驱动一致，
找不到才用安装时的备份），清掉所有目录里的 shim 模块，并删掉
`/etc/modprobe.d/nvidia-nvpcf-shim.conf`、pacman 钩子和辅助脚本。

## 已知限制

- **只针对 NVIDIA 内核模块的特定版本。** 补丁靠源码锚点定位，
  驱动版本变了锚点可能对不上，`patch_nv_acpi.py` 会直接中止而不是乱改；
  `--check` 可以提前验证锚点。
- **必须装源码包**：Arch 的 `nvidia-open`（预编译）没有源码，打不了补丁。
- Arch 上驱动升级后 shim 需要重装（脚本会装 pacman 钩子自动回退，保证安全）。
- **不解决功耗上限。** 功耗由 EC 的性能模式决定，见
  [../docs/reverse-engineering.md](../docs/reverse-engineering.md)。
- 内核升级后 `vermagic` 对不上，shim 自动失效（等于自动降级，安全）。

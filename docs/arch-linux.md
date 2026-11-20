# Arch Linux + nvidia-open 适配指南

本文记录在 Arch Linux（含 CachyOS / Manjaro / EndeavourOS 等衍生版）上
使用 `redmi-perf` 的差异、安装步骤和排错方法。

> 已在 **Arch Linux + 内核 7.3.0-2-cachyos-cjktty（clang + ThinLTO）+
> nvidia-open-dkms 620.73.04** 上完成构建与运行时验证：
>
> - 内核模块、NVPCF shim 编译通过，补丁正确落进 `nv-acpi.c`
> - 开机后两条 `failed to get ... from SBIOS` 断言消失，日志中只出现一次
>   `init window: PShareStatus UPDATE_LIMIT pending 0x1 -> 0x0`
> - EC 模式切换正常；`Current Power Limit` 实测为
>   balanced 90W / turbo 125W / full-speed 140W（quiet 显示 90W，
>   以固件静态表为准）
>
> 复现：[`nvpcf-shim/after-reboot-check.sh`](../nvpcf-shim/after-reboot-check.sh)。

## 与 Ubuntu 的差异

| 项目 | Ubuntu | Arch |
|---|---|---|
| 包管理 | `apt` | `pacman` |
| 内核头文件 | `linux-headers-$(uname -r)` | `linux-headers` / `linux-lts-headers` / `linux-zen-headers` / `linux-cachyos-*-headers` |
| Rust 工具链 | `cargo` | `rust`（含 cargo） |
| 内核构建方式 | gcc | 官方内核 gcc；**CachyOS 内核 clang + ThinLTO** |
| NVIDIA 开源模块 | `nvidia-dkms-*`（源码在 `/usr/src/nvidia-<版本>`） | `nvidia-open-dkms`（源码在 `/usr/src/nvidia-<版本>`，布局是 `kernel-open/`） |
| 预编译开源模块 | — | `nvidia-open`（**没有源码，不能打 shim**） |
| 模块目录 | `/lib/modules/<ver>` | `/usr/lib/modules/<ver>`（`/lib` 是符号链接，脚本已兼容） |
| 驱动升级 | apt 升级 DKMS 包 | pacman 升级 `nvidia-open-dkms` / `nvidia-utils` |

脚本已经把这些差异都做了运行时探测，正常情况下不需要手工设置环境变量。

## 前置条件

### 1. 基础依赖

```bash
sudo pacman -S --needed base-devel dkms zstd python rust
```

| 包 | 用途 |
|---|---|
| `base-devel` | `make` / `gcc` 等编译链 |
| `dkms` | 内核升级后自动重编 `redmi_perf_wmi` |
| `linux-*-headers` | 编译内核模块（见下） |
| `zstd` | 打包 / 解压 `.ko.zst` |
| `python` | NVPCF shim 补丁器 |
| `rust` | 编译 `redmi-perf` 命令行工具（可选，但不装就没有 CLI） |

### 2. 内核头文件（按实际内核选一个）

```bash
sudo pacman -S --needed linux-headers              # 官方 linux
sudo pacman -S --needed linux-lts-headers          # linux-lts
sudo pacman -S --needed linux-zen-headers          # linux-zen
sudo pacman -S --needed linux-cachyos-cjktty-headers   # CachyOS（本机实测）
```

不确定包名就让脚本告诉你：

```bash
./scripts/install-redmi-perf.sh --check
```

它会打印 `头文件: 缺失（linux-cachyos-cjktty-headers）` 和对应的安装命令。

### 3. NVIDIA 驱动

NVPCF shim 必须**有驱动源码**才能打补丁。按需求二选一：

```bash
# 方案 A（推荐）：源码包，能打 shim
sudo pacman -S --needed nvidia-open-dkms

# 方案 B：预编译包，只能跑 EC 性能模式，不能打 shim
sudo pacman -S --needed nvidia-open
```

> `nvidia-open`（预编译）和 `nvidia-open-dkms` 互斥，pacman 会让你确认替换。
> `nvidia-utils` 是用户态库，两个方案都要装，版本必须与内核模块一致。
>
> `nvidia-open` 只支持 **Turing 及更新**的显卡（GTX 16 / RTX 20 / 30 / 40 系），
> Redmi G Pro 2024 的 RTX 4060 没问题。

## 安装 EC 性能模式模块

```bash
git clone https://github.com/wanxinhao/redmi-perf.git
cd redmi-perf

sudo ./scripts/install-redmi-perf.sh --dkms
```

说明：

- 脚本自动识别发行版；Arch 上会走 `pacman` 的依赖提示和 `dkms` 流程。
- **clang 内核（CachyOS 等）**：脚本检测到 `CONFIG_CC_IS_CLANG=y` 后会自动
  加 `LLVM=1 LD=ld.lld`；DKMS 3.x 自己也会给模块构建追加 `LLVM=1`。
- 不装 `--dkms` 时只对当前内核生效，内核升级后要重跑。
- 想先看环境不安装：`./scripts/install-redmi-perf.sh --check`。

装完验证：

```bash
redmi-perf get
redmi-perf list
dmesg | grep redmi_perf
```

## 用 PKGBUILD 安装（可选）

仓库里带了 AUR 风格的 `-git` 包，适合想用 pacman 管理、或准备发 AUR 的场景：

```bash
sudo pacman -S --needed base-devel dkms cargo git
cd packaging/arch/redmi-perf-git
makepkg -si
```

会装两个包：`redmi-perf-git`（CLI）和 `redmi-perf-dkms-git`（DKMS 模块），
后者由 `dkms` 的 pacman 钩子在安装后自动编译。细节、从脚本安装的迁移、
本地 fork 测试方法见 [../packaging/arch/README.md](../packaging/arch/README.md)。

## 安装 NVPCF shim（可选，需 nvidia-open-dkms）

```bash
cd nvpcf-shim
./install.sh --check      # 先看探测结果：源码布局、编译参数、备份来源
sudo ./install.sh         # 打补丁 + 编译 + 安装 + 写模块参数 + 装 pacman 钩子
sudo reboot
```

脚本现在会自动处理 Arch 的差异：

1. **源码布局**：Arch 的 `nvidia-open-dkms` 源码在
   `/usr/src/nvidia-<版本>/kernel-open/`，模块产物也在 `kernel-open/` 下。
   `patch_nv_acpi.py` / `build.sh` 会自动识别这种布局（也兼容旧的完整源码树）。
2. **clang 内核**：NVIDIA 自己的 Makefile 默认 `LD=ld`，在 clang + ThinLTO
   内核上会报 `file format not recognized`。脚本会显式传 `LLVM=1 LD=ld.lld`。
3. **编译器小版本不一致**：NVIDIA 会检查内核编译器版本。Arch 滚动更新后
   clang 通常比内核新，`build.sh` 遇到 `Failed CC version check` 会自动用
   `IGNORE_CC_MISMATCH=1` 重试。
4. **模块安装位置**：Arch 官方模块在 `kernel/drivers/video/`，shim 装到
   `updates/nvpcf-shim/`（优先级更高），不会动 DKMS 管理的官方文件；
   Debian 那种官方模块本来就在 `updates/dkms/` 的布局则原地覆盖。
5. **旧 shim 清理**：会扫描所有模块目录，把带 `nvpcf_shim` 参数的旧模块
   清掉，避免 `depends` 优先级串台。

### pacman 钩子（驱动升级自动回退）

`install-prebuilt.sh` 会装一个 pacman 钩子：

```
/etc/pacman.d/hooks/90-nvpcf-shim-revert.hook
```

当 `nvidia-open-dkms` / `nvidia-utils` / `nvidia-open` 等包升级时，
旧 shim 模块的版本会和新的用户态库对不上（`Driver/library version mismatch`），
钩子会自动把官方模块放回去，并把提示写进 `/var/log/nvpcf-shim.log`。

想继续用 shim，升级后重跑一次：

```bash
cd nvpcf-shim && sudo ./install.sh
```

不想要钩子：`sudo ./install.sh --no-hook`（或 `install-prebuilt.sh --no-hook`）。

### 验证 shim

```bash
# 补丁在跑（有 REQ/RESP / GPS / PPM 日志）
sudo dmesg | grep -i NVPCF-SHIM

# 两条 SBIOS 断言应该消失
sudo dmesg | grep -iE 'SBIOS|PlatformRequestHandler'

# 模块参数都在
ls /sys/module/nvidia/parameters/ | grep nvpcf_shim

# 一次性体检
sudo ./nvpcf-shim/after-reboot-check.sh
```

## 回退 / 灾难恢复（Arch 版）

### 能进 tty、只是图形界面挂了

```bash
cd /path/to/redmi-perf
sudo ./nvpcf-shim/restore-prebuilt.sh
sudo reboot
```

`restore-prebuilt.sh` 会：

- 从 `/var/lib/dkms/nvidia/<版本>/<内核>/x86_64/module/` 取官方模块
  （版本必须与当前驱动一致），找不到才用安装时的备份；
- 清掉所有目录里的 shim 模块（含旧版装在 `updates/dkms` 的）；
- 删除 `/etc/modprobe.d/nvidia-nvpcf-shim.conf`、pacman 钩子和辅助脚本。

### 连 tty 都进不去

1. 开机时在 systemd-boot（`Esc` 长按 / 菜单）或 GRUB（`Shift`/`Esc`）里
   选一个**旧内核**或 `linux-lts` 启动 —— Arch 通常同时装了 `linux` 和
   `linux-lts`，这是最快的恢复路径。
2. 进系统后按上面的命令回退。
3. 如果连旧内核都没有，用 Arch live USB 启动：

   ```bash
   mount /dev/nvme0n1p2 /mnt          # 按你的分区改
   arch-chroot /mnt
   rm -f /usr/lib/modules/$(uname -r)/updates/nvpcf-shim/nvidia*.ko.zst
   rm -f /etc/modprobe.d/nvidia-nvpcf-shim.conf
   rm -f /etc/pacman.d/hooks/90-nvpcf-shim-revert.hook
   rm -rf /usr/local/lib/nvpcf-shim
   # 重装官方驱动模块
   pacman -S --overwrite nvidia-open-dkms
   # 或：dkms install nvidia/<版本> -k $(uname -r) --force
   depmod -a $(uname -r)
   reboot
   ```

   注意：live USB 里 `uname -r` 是 live 内核，路径里要换成**目标系统**的
   内核版本（`ls /mnt/usr/lib/modules/`）。

### 彻底不要 shim 了

```bash
sudo ./nvpcf-shim/restore-prebuilt.sh     # 撤模块和钩子
sudo pacman -S --needed nvidia-open       # 换回预编译开源驱动（可选）
```

## 常见问题

### `dkms status` 显示 `Differences between built and installed modules`

正常。shim 装在 `updates/nvpcf-shim/`，优先级高于 DKMS 管理的位置，
所以 DKMS 认为"已安装模块"和它自己 build 的不一样。回退后即可恢复。

### 开机仍然看到一次 `failed to get target temp / platform power mode from SBIOS`

nvidia-open 620 有「先更新 limit、后初始化传感器」的顺序问题：初始化时
`PSHARESTATUS(0x20)` 报 `UPDATE_LIMIT pending`，驱动立刻去读 TGPU/PPMD，
但传感器要到随后的 `PSHAREPARAMS(0x2a)` 才初始化，于是各打一次断言。

`nvpcf_shim_pshare_init=1`（默认）只在初始化窗口内清掉这个 pending 位，
运行期的平台限制更新不受影响。确认它生效：

```bash
sudo dmesg | grep 'NVPCF-SHIM: init window'
# 应该看到一次: PShareStatus UPDATE_LIMIT pending 0x1 -> 0x0
```

断言仍然出现的话，先把 `nvpcf_shim_pshare_init` 置 1 再试：

```bash
echo 1 | sudo tee /sys/module/nvidia/parameters/nvpcf_shim_pshare_init
```

（这个参数只在初始化窗口内起作用，运行时改对已经过去的初始化无效，
需要重启验证。）

### `/sys/class/redmi_perf` 不存在 / `redmi-perf` 报 No such file or directory

先确认模块状态：

```bash
lsmod | grep redmi_perf_wmi
```

- 没加载：`sudo modprobe redmi_perf_wmi`
- 已加载但没有 `/sys/class/redmi_perf`：多半是内核 **7.3+ 自带的
  `bitland-mifs-wmi`** 抢先绑定了同一个 MIFS WMI 设备（`B60BFB48-…`）。
  WMI 设备只能绑定一个驱动，谁先绑定谁生效，后加载的 `redmi_perf_wmi`
  不会 probe，也就不会创建 sysfs 类。

  把设备从内核自带驱动手里解绑，再让我们的驱动绑定：

  ```bash
  # 1. 解绑内核自带的 bitland-mifs-wmi
  echo B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B-4 | \
    sudo tee /sys/bus/wmi/drivers/bitland-mifs-wmi/unbind

  # 2. 重新加载 redmi_perf_wmi
  sudo modprobe -r redmi_perf_wmi
  sudo modprobe redmi_perf_wmi

  # 3. 检查
  ls /sys/class/redmi_perf
  ```

  如果第 3 步还是空的，再显式绑定一次：

  ```bash
  echo B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B-4 | \
    sudo tee /sys/bus/wmi/drivers/redmi_perf/bind
  ```

  开机自动加载：

  - 脚本安装：`/etc/modules-load.d/redmi-perf.conf`
  - PKGBUILD 安装：包内的 `/usr/lib/modules-load.d/redmi-perf.conf`

  目的都是让 `redmi_perf_wmi` 在 udev 自动加载 `bitland-mifs-wmi` 之前先加载。
  极端情况下仍可能被抢占，按上面的步骤解绑一次即可。

> 补充：内核 7.3 的 `bitland-mifs-wmi` 还会在 WMI 设备下提供 `gpu_mode`、
> `fan_boost`、`kb_mode` 和 ACPI `platform_profile`。但在 TM2211 上读
> `gpu_mode` 会报协议错误（`Protocol error`），所以本项目仍使用自己的
> `redmi_perf_wmi` 模块。

### 内核更新后 shim 不生效

正常，也是安全的默认行为：shim 模块的 `vermagic` 对不上新内核，
内核会加载 DKMS 给新内核编的官方模块。要继续用 shim，重跑
`nvpcf-shim/install.sh`。

### `modprobe: FATAL: Module nvidia not found`

说明模块都没了（不是 shim 的问题）。按当前驱动版本重建：

```bash
sudo pacman -S --needed nvidia-open-dkms
sudo dkms install nvidia/$(ls /var/lib/dkms/nvidia | head -1) -k $(uname -r) --force
depmod -a $(uname -r)
```

### Wayland 下黑屏 / 只出 1024x768

Arch 的 NVIDIA 需要开 DRM modeset：

```bash
grep -r modeset /etc/modprobe.d/ /usr/lib/modprobe.d/
# 没有就加：
echo 'options nvidia_drm modeset=1' | sudo tee /etc/modprobe.d/nvidia.conf
```

另外建议启用动态功耗服务：

```bash
sudo systemctl enable --now nvidia-powerd.service
```

### `DKMS make.log` 里有 `unrecognized command-line option '-fms-anonymous-structs'`

内核是 clang 构建的，但 DKMS 用 gcc 编译了。确认内核头文件完整
（`include/config/auto.conf` 存在）后重跑 `sudo ./scripts/install-redmi-perf.sh --dkms`；
脚本会用 `LLVM=1` 编译。若仍失败，检查 `dkms --version` 是否 ≥ 3.0
（3.x 才会自动给 clang 内核追加 `LLVM=1`）。

### `Failed CC version check` / `IGNORE_CC_MISMATCH`

NVIDIA 要求外部模块的编译器版本与内核完全一致。Arch 滚动更新后
clang/gcc 小版本经常比内核新，这是**警告**；`build.sh` 会自动用
`IGNORE_CC_MISMATCH=1` 重试一次。若你手工编译，也可以自己加：

```bash
make -j"$(nproc)" LLVM=1 LD=ld.lld IGNORE_CC_MISMATCH=1 \
  KERNEL_UNAME="$(uname -r)" modules
```

## 已知限制

- **预编译的 `nvidia-open` 不能打 shim**：没有源码。要么换
  `nvidia-open-dkms`，要么只用 EC 性能模式。
- 闭源 `nvidia` / `nvidia-dkms` 理论上可用（完整源码树布局有兼容分支），
  但本项目主要针对 open 模块验证。
- shim 依赖 `nv-acpi.c` 里的源码锚点。驱动大版本升级后锚点可能变化，
  `patch_nv_acpi.py` 会带锚点名中止，不会乱改；关注仓库更新即可。
- Arch 的 `nvidia-open-dkms` 每次升级都会重建官方模块；shim 需要重装。
  这是"驱动升级 → 钩子回退 → 手动重装"的设计，刻意不自动编译，
  避免 pacman 事务里跑几分钟的 nvidia 编译。

# 排错

> Arch Linux 的依赖、clang 内核、驱动升级钩子和恢复流程单独整理在
> [arch-linux.md](arch-linux.md)，先看那份更省事。

## 🔴 开不了机怎么办（nvpcf-shim 相关）

`nvpcf-shim` 替换的是 NVIDIA 内核模块。装坏了会黑屏 / 无法进桌面。
**装了之后先别重启**，先确认能进 tty（Ctrl+Alt+F2）。

### 情况一：能进 tty（图形界面挂了）

进 tty 后用 root 登录，把原版模块装回去：

```bash
cd /path/to/redmi-perf
sudo ./nvpcf-shim/restore-prebuilt.sh
sudo reboot
```

### 情况二：完全进不去系统

**方法 A —— GRUB 进 recovery**

1. 开机按 `Shift`（BIOS）或 `Esc`（UEFI）进 GRUB；
2. 选 `Advanced options for Ubuntu` → `recovery mode` → `root shell`；
3. 恢复模块：

   ```bash
   mount /dev/nvme0n1p2 /mnt      # 按你的分区改
   mount -t proc /proc /mnt/proc
   mount -t sysfs /sys /mnt/sys
   chroot /mnt

   # 删掉打了补丁的模块（Arch 装在 updates/nvpcf-shim/，旧版在 updates/dkms/）
   rm -f /lib/modules/$(uname -r)/updates/nvpcf-shim/nvidia*.ko.zst
   rm -f /lib/modules/$(uname -r)/updates/dkms/nvidia*.ko.zst
   rm -f /etc/modprobe.d/nvidia-nvpcf-shim.conf
   rm -f /etc/pacman.d/hooks/90-nvpcf-shim-revert.hook
   depmod -a $(uname -r)

   # Debian / Ubuntu：让 DKMS 重装官方模块
   dkms install --force nvidia/$(ls /var/lib/dkms/nvidia/ | head -1) --all
   # Arch：重装源码包，或
   dkms install nvidia/$(ls /var/lib/dkms/nvidia/ | head -1) -k $(uname -r) --force

   reboot
   ```

**方法 B —— 用 live USB 起 chroot**

用 Ubuntu live USB 启动，`sudo mount /dev/nvme0n1p2 /mnt` 后同样 chroot 操作。

> 💡 装之前先备份一份能跑的模块，能省掉一半的麻烦：
> ```bash
> sudo mkdir -p ~/nvidia-backup
> sudo cp -a /lib/modules/$(uname -r)/updates/dkms/nvidia*.ko.zst ~/nvidia-backup/ 2>/dev/null || true
> sudo cp -a /lib/modules/$(uname -r)/kernel/drivers/video/nvidia*.ko.zst ~/nvidia-backup/ 2>/dev/null || true
> ```

## 内核升级后 shim 失效

**这是正常的，而且算好事。**

`prebuilt/` 里的模块是针对某个内核版本编译的，`vermagic` 对不上就不会被加载，
DKMS 会装回它自己 build 的官方模块 —— 等于自动降级，不会开不了机。

想继续用 shim：

```bash
cd nvpcf-shim
sudo ./install.sh
```

`build.sh` 会自动检测 `/usr/src/nvidia-*` 里版本号最大的那个。

## `nvidia` 模块加载失败：`unknown parameter`

`/etc/modprobe.d/nvidia-nvpcf-shim.conf` 里写了当前内核模块**不存在的参数**，
内核会直接拒绝加载 nvidia（于是没有图形界面）。

```bash
sudo dmesg | grep -i "unknown parameter"
```

对照 `nvpcf-shim/shim_block.c` 里的 `module_param_named` 列出实际支持的参数：

```bash
grep -o 'nvpcf_shim_[a-z0-9_]*' nvpcf-shim/shim_block.c | sort -u
```

合法的默认值（595.112.07 / nvidia-open 620.73.04 上实测可用）：

```
options nvidia nvpcf_shim_mode=1 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \
	nvpcf_shim_ppm_enable=1 nvpcf_shim_ppm=0x1E01 nvpcf_shim_pshare_init=1
```

## `PRH failed to update thermal limit!` 断言

说明 `nvpcf_shim_ctr0b` 被填了固件不认的值。

counter `0x0b` 是**目标温度（℃）**，固件原值 87。
把它改成 100 会导致固件拒绝 `set thermal limit` 指令。

```bash
echo 0 | sudo tee /sys/module/nvidia/parameters/nvpcf_shim_ctr0b
```

`0` = 保持固件原值。默认值就该是 0。

## `redmi-perf set` 返回 `EOPNOTSUPP` / 状态 `0xE0`

固件拒绝了。两种可能：

1. **没插圆口电源** —— turbo / full-speed 需要 DC 圆口充电器，
   USB-C PD 供电固件会直接拒绝；
2. 该模式值这台机器不支持（`0` 是未定义的，别用）。

```bash
redmi-perf list     # 看支持哪些模式
redmi-perf status   # 看上次调用的固件状态字节
```

## 切了模式但 `nvidia-smi` 的功耗上限没变

**正常现象。** `Current Power Limit` 读的是固件静态表，不跟随 EC 动态调整。

要判断实际效果，看功耗 / 频率 / 温度：

```bash
sudo ./scripts/bench.sh
```

另外注意：桌面默认跑在 **Intel 核显**上，dGPU 空闲时会进 runtime suspend，
此时 `nvidia-smi` 读不到传感器。需要把负载真正压到 NVIDIA GPU 上
（`vkcube` / `glxgears`）。

## `nvidia-smi --query-gpu=...` 报 `not recognized`

本版驱动**不支持 `--query-gpu` 和 `-l` / `-lms` 循环模式一起用**：

```
Option --query-gpu=clocks.sm,... is not recognized. Please run 'nvidia-smi -h' for help.
```

必须自己按秒轮询单次查询，别用 `-l`。

## `vkcube` 提示 `Present mode specified is not supported`

NVIDIA 的 Wayland 实现不支持 `--present_mode 0`。用 Xwayland 的 `glxgears` 代替。

## GPU 温度 / 功耗读数离谱

```
Instantaneous Power Draw : 590.01 W     ← 驱动 bug
Average Power Draw       : 1.00 W
```

`Instantaneous Power Draw` 在笔记本上是已知的驱动 bug，忽略它，
用 `Average Power Draw` 或实际 TDP 判断。

## `dkms build` 对 nvidia 静默跳过

`.run` 安装器装出来的驱动，DKMS 树状态是残废的：`dkms build` 不生成
`build/` 目录、`make.log` 时间戳也不变；`dkms install --force` 只是把旧模块
重装一遍。

所以 `nvpcf-shim` 走的是**手工编译 + 直装**的路线：

```bash
cd nvpcf-shim
sudo ./install.sh
```

Arch 的 `nvidia-open-dkms` 没有这个问题，DKMS 是正常工作的；
`nvpcf-shim` 仍然走手工编译，因为它必须改驱动源码。

`redmi-perf` 的模块是干净的 DKMS 包，不受影响。

## Arch：驱动升级后 shim 自动失效 / 版本错配

`nvidia-open-dkms` / `nvidia-utils` 升级后，旧 shim 模块的版本号和新的
用户态库对不上，`nvidia-smi` 会报
`Failed to initialize NVML: Driver/library version mismatch`。

`install-prebuilt.sh` 会装一个 pacman 钩子，在升级事务结束后自动回退到
官方模块（见 `/var/log/nvpcf-shim.log`）。想继续用 shim：

```bash
cd nvpcf-shim && sudo ./install.sh
```

如果钩子没生效（比如用 `--no-hook` 装的）：

```bash
sudo ./nvpcf-shim/restore-prebuilt.sh
```

## 怎么确认 shim 到底生效了

```bash
sudo dmesg | grep -i 'NVPCF-SHIM'   # 有日志 = 补丁在跑
sudo dmesg | grep -i SBIOS          # 没有 NVRM 断言 = 修好了
```

或者用 `nvpcf-shim/runtime-sweep.sh` 在线扫参数（不用重启）。

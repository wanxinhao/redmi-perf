# Arch Linux 打包

这里提供 [AUR](https://aur.archlinux.org/) 风格的 PKGBUILD，把 `redmi-perf`
拆成两个包：

| 包 | 内容 |
|---|---|
| `redmi-perf-git` | `/usr/bin/redmi-perf` 命令行工具 |
| `redmi-perf-dkms-git` | `redmi_perf_wmi` 内核模块源码（DKMS） |

`redmi-perf-git` 依赖 `redmi-perf-dkms-git`，装 CLI 会一起装上模块。

> **不打包 `nvpcf-shim`**：它要替换 / 重编 NVIDIA 内核模块，属于高风险、
> 与具体驱动版本强绑定的操作，不适合交给包管理器。需要时按
> [../../docs/arch-linux.md](../../docs/arch-linux.md) 里的步骤手动安装。

## 构建与安装

```bash
sudo pacman -S --needed base-devel dkms cargo git
cd packaging/arch/redmi-perf-git
makepkg -si
```

`dkms` 的 pacman 钩子会在安装后自动为已装内核编译模块
（安装 `/usr/src/redmi-perf-<pkgver>/dkms.conf` 触发）。
内核头文件由各内核包提供，`dkms` 已把它列为可选依赖，本包不重复依赖。

安装完成后：

```bash
sudo modprobe redmi_perf_wmi     # 立即加载
redmi-perf get                   # 看当前性能模式
```

包内带有 `/usr/lib/modules-load.d/redmi-perf.conf`，开机时会自动加载模块。

> **为什么要自动加载**：内核 7.3+ 自带的 `bitland-mifs-wmi` 也匹配同一个
> MIFS WMI 设备（`B60BFB48-…`），WMI 设备只能绑一个驱动。谁先加载谁生效；
> 先加载我们的模块，才能拿到 `/sys/class/redmi_perf`。

## 与内核自带 `bitland-mifs-wmi` 冲突

如果 `redmi-perf get` 报 `/sys/class/redmi_perf/...: No such file or directory`，
而 `lsmod | grep redmi_perf_wmi` 显示模块已加载，通常就是设备被内核自带驱动绑走了：

```bash
echo B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B-4 | \
  sudo tee /sys/bus/wmi/drivers/bitland-mifs-wmi/unbind
sudo modprobe -r redmi_perf_wmi
sudo modprobe redmi_perf_wmi
ls /sys/class/redmi_perf
```

仍为空时再显式 bind：

```bash
echo B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B-4 | \
  sudo tee /sys/bus/wmi/drivers/redmi_perf/bind
```

CLI 本身也会在失败时打印这段提示。详见
[../../docs/arch-linux.md](../../docs/arch-linux.md)。

## 版本规则

这是 **VCS 包**（`-git` 后缀），`pkgver` 由 `pkgver()` 从 git 生成：

- 有 tag 时：`0.2.0.r3.gabcdef0`（tag + 提交数 + 哈希）
- 无 tag 时：`r3.8941a19`（提交数 + 哈希）

模块的 `PACKAGE_VERSION` 和 `/usr/src/redmi-perf-<pkgver>` 目录名都用
PKGBUILD 的 `$pkgver` 生成，符合 [DKMS 打包指南](https://manual.archlinux.page/package-guidelines/dkms/)。

上游目前还没有 release tag，所以只提供 `-git` 包。等 `v0.2.0` 之类的
tag 发布后，可以再加一个稳定版 PKGBUILD：从
`$url/archive/v$pkgver.tar.gz` 取源码、用 `updpkgsums` 生成校验和，
`pkgver` 直接用 tag 里的版本号。

## 本地测试（还没 push 的改动）

`-git` 包默认从上游仓库拉取：

```
_repo="https://github.com/wanxinhao/redmi-perf.git"
```

想用自己 fork 或本地工作区测试，改 `_repo` 再 `makepkg -si`：

```bash
# fork
sed -i 's|wanxinhao/redmi-perf|BiHai1300/redmi-perf|' PKGBUILD

# 本地仓库（包含未 push 的 commit）
sed -i 's|https://github.com/wanxinhao/redmi-perf.git|file:///path/to/redmi-perf|' PKGBUILD
```

## 手动安装 vs PKGBUILD

两条路径最终都得到「DKMS 模块 + CLI + 开机自动加载」，但细节不同：

| 步骤 | `scripts/install-redmi-perf.sh --dkms` | `makepkg -si` |
|---|---|---|
| 依赖检查 | 脚本检查头文件/dkms/cargo，缺了直接报错 | pacman 处理 `depends`；头文件缺失时由 `.install` 提示 |
| 模块源码 | `/usr/src/redmi-perf-0.2.0` | `/usr/src/redmi-perf-<pkgver>` |
| DKMS 构建 | 安装时 `dkms add/build/install` 当前内核 | dkms 的 pacman 钩子自动 build/install（所有已装内核）|
| 模块加载 | 立即 `modprobe`，并自动从 `bitland-mifs-wmi` 抢回 WMI 设备 | 遵循打包指南不在 `.install` 里 `modprobe`；开机靠 `/usr/lib/modules-load.d/`，首次手动 `modprobe` |
| CLI | `/usr/local/bin/redmi-perf` | `/usr/bin/redmi-perf` |
| 自动加载配置 | `/etc/modules-load.d/redmi-perf.conf` | `/usr/lib/modules-load.d/redmi-perf.conf` |
| 卸载 | 清 DKMS 版本、`/usr/local/bin`、`/etc` 配置、旧 `extra/` 模块 | pacman 删包内文件，dkms 钩子卸载模块；**旧手动文件不归 pacman 管** |
| `nvpcf-shim` | 单独手动安装 | **不包含**（需手动装） |

**有意保留的差异**：包不在 `.install` 里加载模块或做 rebind（Arch 打包指南要求
“不要用 .install 加载/卸载模块”）；首次使用需要 `sudo modprobe redmi_perf_wmi`，
之后开机自动加载。设备冲突时 CLI 和 `.install` 都会打印可执行的修复命令。

**可能会“漏”的部分，包已经用警告覆盖**：旧的手动安装如果没清干净，`.install`
会检测并提示：

- `/usr/local/bin/redmi-perf`（会遮蔽包里的 `/usr/bin/redmi-perf`）
- 多个 `/usr/src/redmi-perf-*`（内核升级时重复编译同一个模块名）
- `/usr/lib/modules/*/extra/redmi_perf_wmi.ko*`（旧的非 DKMS 安装）
- `/etc/modules-load.d/redmi-perf.conf`（与包内 vendor 配置重复，无害）

## 从脚本安装迁移

如果你之前跑过 `scripts/install-redmi-perf.sh --dkms`，DKMS 里会有一个
`redmi-perf/0.2.0`。先清掉，否则内核升级时两个版本会重复编译、抢同一个模块名：

```bash
sudo ./scripts/install-redmi-perf.sh --uninstall
```

然后再 `makepkg -si`。

## 卸载

```bash
sudo pacman -Rns redmi-perf-git redmi-perf-dkms-git
```

DKMS 钩子会自动 `dkms remove`；`.install` 会提示你 `modprobe -r
redmi_perf_wmi`、以及删掉可选的 `/etc/modules-load.d/redmi-perf.conf`。

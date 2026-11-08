# nvme-ssd-rescue · NVMe 固态修复 / 重装系统 U 盘工具

装 Windows 时 **“选择安装位置”一个盘都没有**、**看得到盘却装不上**、**BIOS 认不到固态**、**开机只能进 BIOS**，
做一个这样的 U 盘，插上开机就能自动检测原因，并给出一键修复。英特尔、AMD 平台都能用，不限品牌。

📺 视频讲解（4 分钟，重点讲开了 / 关了 VMD 还是不行）：[B 站 BV1aWxm6pE62](https://www.bilibili.com/video/BV1aWxm6pE62/)

> 起因：一台英特尔 13 代游戏本在双系统 + 改机器码之后卡死，之后 BIOS 认不到固态、Windows 安装程序装不上。
> 排查下来固态本身是好的，问题出在 VMD、分区和启动文件上。这个仓库把当时的排查和修复流程整理成了通用工具。

## 能做什么

| 场景 | 用哪个 | 会不会删数据 |
|---|---|---|
| 不知道哪里坏了 | 修复 U 盘开机自动检测，出中文报告 | 不会 |
| 原系统还在，开机直接进 BIOS | 修复系统菜单 **8**：从 Windows 分区重建 EFI 启动文件、BCD、主板启动项 | 不会（改动前备份 EFI 分区） |
| 固态“消失”、容量 0、读写报错 | 修复系统菜单 **9**：NVMe 控制器复位 → 命名空间找回/重建 → 安全擦除 → 全盘写入读回校验 → 自检 | **会清空** |
| 安装界面看不到盘 / 装不上 | 安装界面 Shift+F10 → `D:\fix` → **1**：自动诊断（VMD/驱动/硬件），清空 + 转 GPT + 建分区 + 读写校验 | **会清空** |
| 开着 VMD 想保留原系统 | `D:\fix` → **3**：加载 `drivers` 文件夹里的 Intel RST/VMD 驱动 | 不会 |

安全措施：U 盘、移动硬盘、虚拟盘一律拒绝清空；所有清空操作都要输入大写 `YES`。工具不联网、不上传任何数据。

## 快速开始

1. 在 [Releases](../../releases) 下载最新的 `nvme-ssd-rescue-v*.zip`，解压。
2. 插一个 **2GB 以上** 的 U 盘（会被清空），双击 **`制作U盘.cmd`**，按提示选 U 盘、输入 `YES`。
   脚本会自动下载 [SystemRescue 13.02](https://www.system-rescue.org/)（约 1.3GB）并校验 SHA256，需要 [7-Zip](https://www.7-zip.org)（没有会尝试用 winget 安装）。
3. 有问题的电脑：BIOS 里 **关闭 Secure Boot**，用启动菜单（华硕 Esc，联想 / 戴尔 F12，惠普 F9，微星 F11）选带 **UEFI** 字样的 U 盘。
4. 约 1 分钟后自动弹出中文检测窗口，按结论操作。详细步骤见 U 盘根目录的 [`使用说明.txt`](src/使用说明.txt)。

只想在 Windows 安装界面里用：把压缩包里的 `fix.cmd` 和 `usb-ssd-fix` 文件夹复制到任意 U 盘根目录，
安装界面按 Shift+F10，输入 `D:\fix`（D 换成 U 盘盘符）。

## 开了 / 关了 VMD 还是不行？

Intel VMD（BIOS 里也叫 RST / RAID）会把 NVMe 固态藏在英特尔控制器后面，很多 Windows 安装盘没有它的驱动，所以一个盘都看不到。
**全新安装**就在 BIOS 里关掉 VMD（或把 RAID 改成 AHCI）；**要保留原系统**就别关，加载 Intel RST 的 VMD 驱动（`iaStorVD.inf`）。

改了 VMD 还不行，按现象对照：

| 现象 | 原因 | 处理 |
|---|---|---|
| 加载了驱动还是没有盘 | 驱动和平台不匹配，或者选了 exe | 用对应平台的 Intel RST **F6/VMD** 驱动包，解压后选文件夹 |
| 关 / 开 VMD 后原系统蓝屏 `INACCESSIBLE_BOOT_DEVICE` | 系统是在另一种模式下装的 | 改回原来的 VMD 设置；要切换先在系统里装好对应驱动 |
| 看得到盘，提示“无法创建新的分区 / 找不到现有分区 / 无法安装到这个磁盘” | 分区残留、MBR/GPT 不对、只读、插着别的盘 | 删除这块盘的全部分区；或 `D:\fix` 选 1；拔掉其它 U 盘和移动硬盘 |
| “这台电脑的硬件可能不支持启动到此磁盘” | U 盘以传统 Legacy/CSM 方式启动 | 启动菜单选带 UEFI 的项，或关闭 CSM |
| BIOS 里都看不到固态 | 接触不良、主控不响应、命名空间丢失、固件被改（如改机器码工具） | 断电长按电源键 40 秒、重插或换 M.2 槽；再用修复 U 盘检测，菜单 9 深度修复 |
| 开机直接进 BIOS，但系统还在 | EFI 分区里的启动文件丢了 | 修复系统菜单 8，或 `D:\fix` 选 4 |

## 目录

```
src/                     U 盘上的内容（源码统一 UTF-8）
  fix.cmd                安装界面入口：D:\fix
  使用说明.txt
  autorun/ sysrescue.d/  SystemRescue 开机自动打开检测窗口
  usb-ssd-fix/
    fix_win.cmd          Windows 安装环境（WinPE）里的诊断 / 清空 / 驱动 / 修复启动
    ssd_check.sh         Linux 修复系统里的深度检测 + 深度修复（nvme-cli、smartctl、efibootmgr）
    bcd/                 修复启动用的 BCD 模板
tools/
  build.py               生成发布包：.cmd 转 GBK+CRLF、批处理静态检查、bash -n、shellcheck
  make_usb.ps1           制作修复 U 盘（-KitOnlyTo <文件夹> 只写入工具，不动 U 盘）
  制作U盘.cmd
```

`fix_win.cmd` 只用 Windows 安装盘里一定有的命令（diskpart、reg、drvload、bcdboot），
不依赖 findstr / find（Windows 10 安装盘里没有）。中文简体安装盘（代码页 936）下显示中文，其它语言显示英文提示。

## 从源码构建

```bash
python3 tools/build.py          # 输出 dist/nvme-ssd-rescue-<版本>.zip
```

## 免责声明

清空、安全擦除、重建命名空间都不可恢复，重要数据请先找专业数据恢复。
固件或硬件损坏软件修不了，工具会明确告诉你“没修好”，这时请找售后。

## English

A bootable USB toolkit for "no drives found" / "can't install Windows to this disk" / "SSD missing in BIOS" problems on NVMe laptops and desktops.
It boots SystemRescue and runs an automatic diagnosis (Intel VMD, PCI/NVMe controller, namespaces, partition table, EFI boot files), then offers
boot repair without data loss or a deep NVMe repair (controller reset, namespace rebuild, secure erase, write/read-back verification).
A second entry point (`D:\fix`) runs inside Windows Setup (Shift+F10). UI text is Chinese. Build the USB with `tools/make_usb.ps1`. MIT licensed.

## 致谢

[SystemRescue](https://www.system-rescue.org/)（GPL，本仓库不包含其文件，制作时从官网下载）· nvme-cli · smartmontools · efibootmgr

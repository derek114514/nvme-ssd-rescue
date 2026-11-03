@echo off
setlocal EnableExtensions EnableDelayedExpansion
title NVMe 固态修复 / 重装准备工具 v6 - Windows 安装环境版
rem ==================================================================
rem  用法：从 U 盘启动 Windows 安装程序，在任意界面按 Shift+F10
rem        （笔记本可能要 Shift+Fn+F10），在黑色窗口里输入：
rem            D:\fix
rem        D 换成你 U 盘的盘符（U 盘根目录的 fix.cmd 会启动本脚本）。
rem  说明：本文件为 GBK 编码，配合简体中文安装盘使用。
rem        会删数据的只有菜单 1 和 7，执行前都要输入大写 YES 确认；
rem        菜单 4 修复启动要输入 Y 确认；菜单 6 只改只读/脱机标记。
rem ==================================================================

set "HERE=%~dp0"
set "USBLETTER=%~d0"
set "WORK=%TEMP%"
if not defined WORK set "WORK=X:\Windows\Temp"
if not exist "%WORK%\" set "WORK=%HERE%"
set "DPS=%WORK%\ssdfix_dp.txt"
set "OUT=%WORK%\ssdfix_out.txt"
set "LST=%WORK%\ssdfix_list.txt"
set "PCI=%WORK%\ssdfix_pci.txt"
set "LOG=%HERE%log_win.txt"
set "USBDISK="
set "DPERR=0"

rem ---- 日志写到 U 盘，写不进去就写到内存盘 ----
(echo.)>>"%LOG%" 2>nul || set "LOG=%WORK%\log_win.txt"
>>"%LOG%" echo ==================== v6  %date% %time% ====================

rem ---- 当前代码页：不是 936 时中文会乱码，菜单里额外显示一行英文 ----
set "CP="
set "CPL="
for /f "delims=" %%c in ('chcp 2^>nul') do set "CPL=%%c"
for %%w in (!CPL!) do set "CP=%%w"
if not defined CP set "CP=0"
set "CP=!CP:.=!"
if not defined CP set "CP=0"

rem ---- 找出 U 盘自己是几号磁盘，防止误删；顺便先看一眼有哪些硬盘 ----
echo 正在检测硬盘，请稍等……
call :findusb
>>"%LOG%" echo U 盘盘符=%USBLETTER%  U 盘磁盘编号=%USBDISK%  代码页=%CP%
set "QUIET=1"
call :survey
set "QUIET="

goto menu


rem ==================================================================
:menu
cls
echo ==============================================================
echo        NVMe 固态修复 / 重装准备工具 v6（Windows 安装环境版）
echo ==============================================================
if not "%CP%"=="936" echo  [EN] 1=ONE-CLICK: repair internal SSD (wipe, GPT, partitions, write/read test), type YES
if not "%CP%"=="936" echo  [EN] 2=Diagnose 3=Load VMD driver 4=Repair boot 5=Disk details 6=Clear read-only 7=Manual wipe 8=Save logs 0=Quit
if %NINT% EQU 1 echo   检测到内置固态：!QINFO!
if %NINT% GTR 1 echo   检测到 %NINT% 块内置硬盘，编号%INTLIST%
if %NINT% EQU 0 echo   【暂时没看到内置固态】直接选 1 也行：它会自动加载驱动，找不到会告诉你原因。
if "%ANYRO%"=="1" echo   注意：有内置硬盘处于只读状态，选 1 时会先自动尝试解除。
if defined USBDISK echo   你的 U 盘：磁盘 %USBDISK%（工具不会对它做任何写操作）
echo.
echo   ---------- 全新安装（固态里的数据不要了）----------
echo   1. 一键修复固态并准备安装（推荐，会清空固态）
echo.
echo   ---------- 其它工具 ----------
echo   2. 只诊断：为什么看不到固态 / 装不上（不改动任何东西）
echo   3. 加载 drivers 文件夹里的 Intel VMD/RST 驱动
echo   4. 修复启动（想保留原来的系统时用，不删数据）
echo   5. 查看某个磁盘的详细信息
echo   6. 解除磁盘的“只读 / 脱机”状态
echo   7. 手动选择磁盘清空
echo   8. 把安装程序的日志保存到 U 盘（装系统报错时用）
echo   0. 退出
echo.
set "CH="
set /p "CH=输入数字后回车: "
if "!CH!"=="1" goto quick
if "!CH!"=="2" goto scan
if "!CH!"=="3" goto loaddrv
if "!CH!"=="4" goto bootfix
if "!CH!"=="5" goto detail
if "!CH!"=="6" goto unlock
if "!CH!"=="7" goto wipe
if "!CH!"=="8" goto logs
if "!CH!"=="0" goto quit
if /i "!CH!"=="q" goto quit
goto menu


rem ==================================================================
rem  1. 一键修复固态并准备安装
rem ==================================================================
:quick
cls
set "MANUAL="
echo ================ 一键修复固态并准备安装 ================
echo 自动完成：找到内置固态 → 解除只读 → 清空 → 转成 GPT → 建好 Windows 需要的分区
echo           → 写入一批文件再读回比对，确认固态真的能正常读写。
echo 固态上原来的系统和文件会全部删除。
echo 开始前请拔掉移动硬盘 / 硬盘盒（包括雷电硬盘盒）。装系统的 U 盘和工具 U 盘不用拔。
echo ==========================================================
echo.
echo 正在检测硬盘，请稍等……
call :survey
if %NINT% GEQ 1 goto quick_found
rem ---- 看不到固态：drivers 里有驱动就自动加载一次再找 ----
dir /s /b "%HERE%drivers\*.inf" >nul 2>&1 || goto quick_nodisk
echo.
echo 没看到固态，先自动加载 drivers 文件夹里的驱动再找一次……
set "DRVCNT=0"
for /r "%HERE%drivers" %%f in (*.inf) do call :loadone "%%f"
call :survey
if %NINT% GEQ 1 goto quick_found
echo 等 5 秒再找一次（驱动加载后硬盘可能要过一会儿才出现）……
ping -n 6 127.0.0.1 >nul 2>&1
call :survey
if %NINT% GEQ 1 goto quick_found

:quick_nodisk
echo.
if %NUNK% GEQ 1 echo 有 %NUNK% 块磁盘读不出类型（编号%UNKLIST%）。如果你确定那就是固态，可以选 7 手动清空。
echo 没找到内置固态，下面是原因和解决办法：
echo.
call :pcicheck
if "%PCIOK%"=="0" goto noSSDgeneric
if "%HASNVME%"=="1" goto nvmenodisk
if "%HASVMD%"=="1" goto vmd
goto nobus

:quick_found
if %NINT% GTR 1 goto quick_pick
set "DN=%INTLIST: =%"
goto prepdisk

:quick_pick
echo.
echo 找到 %NINT% 块内置硬盘（编号%INTLIST%），对照上面的型号，输入要清空的那块：
call :askdisk || goto menu
set "OKD=0"
for %%d in (%INTLIST%) do if "%%d"=="!DN!" set "OKD=1"
if "%OKD%"=="1" goto prepdisk
echo 磁盘 %DN% 不是内置硬盘，已取消。
pause
goto menu


rem ==================================================================
rem  2. 只诊断
rem ==================================================================
:scan
cls
echo [诊断] 正在重新扫描所有硬盘，请稍等……
echo.
call :survey
echo.
if %NINT% GEQ 1 goto seen

rem ---- 一块内置硬盘都没有：查 PCI 设备表，判断是 VMD、固件还是硬件 ----
call :pcicheck
if "%PCIOK%"=="0" goto noSSDgeneric
if "%HASNVME%"=="1" goto nvmenodisk
if "%HASVMD%"=="1" goto vmd
goto nobus

:seen
echo 结论：安装程序能看到 %NINT% 块内置硬盘（磁盘编号%INTLIST%），固态没有“消失”。
if "%ANYRO%"=="1" echo 注意：有内置硬盘处于【只读】状态，这样装不进系统。选 1 会先自动尝试解除。
call :findwin
if %NWIN% GEQ 1 goto seenwin
echo 这些硬盘上没有找到已安装的 Windows。
echo.
echo 接下来：选 1 一键清空并准备安装，然后回安装界面点“刷新”、选最大的分区、下一步。
echo 还是装不上：选 8 保存安装日志，把 U 盘里的 setup_logs 文件夹发给帮你排查的人。
pause
goto menu

:seenwin
echo 在盘符%WINLIST% 上找到了原来安装的 Windows。
echo.
echo   不要里面的数据 → 选 1 一键清空，直接全新安装；
echo   想保留原来的系统 → 选 4 修复启动，不删任何数据。
pause
goto menu

:vmd
echo ========== 结论：固态被 Intel VMD 藏起来了 ==========
echo 主板上检测到 Intel VMD 控制器，而且 PCI 总线上没有直接露出来的 NVMe 固态，
echo 说明固态挂在 VMD 后面。Windows 安装盘自带的驱动认不出它，所以“选位置”时一个盘都没有。
echo 固态本身大概率没坏。解决办法二选一：
echo.
echo   A. 打算全新安装：关掉 VMD 最省事。
echo      重启进 BIOS，找带 VMD / RST / RAID 字样的选项，改成 Disabled 或 AHCI，保存后再从 U 盘启动。
echo      例：华硕 Advanced → VMD setup menu；戴尔 Storage → SATA/NVMe Operation 选 AHCI/NVMe。
echo   B. 想保留原来的系统和资料：不要关 VMD。把 Intel RST/VMD 驱动放进 U 盘的
echo      drivers 文件夹，然后选 3 加载驱动，硬盘出来以后再选 4 修复启动。
echo      （原来的 Windows 是在开着 VMD 时装的，关掉 VMD 它会蓝屏。）
dir /s /b "%HERE%drivers\*.inf" >nul 2>&1 && echo   drivers 文件夹里已经有驱动：如果是加载过还看不到固态，说明驱动版本不对，直接用 A。
>>"%LOG%" echo 结论：VMD
pause
goto menu

:nvmenodisk
echo ========== 结论：主板能看到固态控制器，但 Windows 拿不到磁盘 ==========
echo PCI 总线上有 NVMe 控制器，说明固态通了电、主控在响应，但没有生成可用的磁盘。
echo 常见原因：固态固件异常（容量变成 0 / 掉固件）或命名空间丢失。这种情况重装系统没用。
echo.
echo 下一步：用 Linux 启动盘运行 ssd_check.sh，它会读出型号、序列号和健康度，
echo 并告诉你具体是哪一种。
if "%HASVMD%"=="1" echo 另外主板还开着 VMD，也可以先在 BIOS 里关掉 VMD 再试一次。
>>"%LOG%" echo 结论：有 NVMe 控制器但没有磁盘
pause
goto menu

:nobus
echo ========== 结论：PCI 总线上完全看不到固态 ==========
echo 主板没有开 VMD，PCI 上也没有 NVMe 控制器。这不是驱动或分区的问题，
echo 是硬件层面：固态没接触好，或者主控已经不响应。按顺序试：
echo   1) 关机，拔掉电源适配器，长按电源键 40 秒放电，再开机重试；
echo   2) 进 BIOS 看 Storage 信息里有没有固态型号；
echo   3) 断电拆后盖，把固态拔下来重新插紧，或者换到另一个 M.2 槽；
echo   4) 用 Linux 启动盘运行 ssd_check.sh 再确认一次。
>>"%LOG%" echo 结论：PCI 上没有固态
pause
goto menu

:noSSDgeneric
echo ========== 安装程序只看到了 U 盘，看不到你的固态 ==========
echo （没能读取 PCI 设备表，下面是通用判断。）
echo 11 代以后的英特尔电脑最常见的原因：BIOS 里开着 Intel VMD（RST 模式），
echo Windows 安装盘自带的驱动认不出 VMD 下面的固态。解决办法二选一：
echo   A. 重启进 BIOS，把 VMD / RST / RAID 选项改成 Disabled 或 AHCI，保存（全新安装推荐）；
echo      例：华硕 Advanced → VMD setup menu；戴尔 Storage → SATA/NVMe Operation。
echo   B. 把 Intel RST/VMD 驱动放进 U 盘的 drivers 文件夹，然后选 3。
echo 如果你是锐龙（AMD）版，或者 A、B 都试过还是看不到，
echo 请用 Linux 启动盘运行 ssd_check.sh 做底层检测。
pause
goto menu


rem ==================================================================
rem  3. 加载驱动
rem ==================================================================
:loaddrv
cls
if not exist "%HERE%drivers\" goto nodrvdir
set "DRVCNT=0"
for /r "%HERE%drivers" %%f in (*.inf) do call :loadone "%%f"
if "%DRVCNT%"=="0" goto nodrvfile
echo.
echo 已尝试加载 %DRVCNT% 个驱动文件，按任意键重新检测硬盘。
echo （回到安装界面后记得点“刷新”。）
pause
goto scan

:loadone
echo 加载驱动："%~1"
drvload "%~1"
>>"%LOG%" echo drvload "%~1"  返回值=!errorlevel!
set /a DRVCNT+=1
exit /b 0

:nodrvdir
echo 没找到文件夹：%HERE%drivers
goto drvhelp
:nodrvfile
echo drivers 文件夹里没有任何 .inf 驱动文件。
:drvhelp
echo.
echo 怎么准备驱动：在另一台电脑上，去 Intel 官网搜索
echo “Intel Rapid Storage Technology Driver”（11 到 13 代平台），
echo 下载名字里带 f6 / flpy / vmd 的 zip 包；或者在电脑厂商官网你的型号页面下载 RST / VMD 驱动。
echo 解压后把整个文件夹放进 U 盘的 usb-ssd-fix\drivers\ 里
echo （里面要能找到 iaStorVD.inf），再回来选 3。
echo 不想折腾驱动、而且打算全新安装的话，也可以直接在 BIOS 里关闭 VMD。
pause
goto menu


rem ==================================================================
rem  4. 修复启动（不删数据）
rem ==================================================================
:bootfix
cls
echo ================ 修复启动（不删除任何数据） ================
echo 适用：固态里原来的 Windows 还在，只是开机直接进 BIOS / 提示找不到系统。
echo 做法：用 bcdboot 把 Windows 的启动文件重新写进 EFI 分区，并在主板里登记启动项。
echo 不会删除、格式化任何分区。
echo ==========================================================
echo.
call :findusb
call :findwin
if %NWIN% EQU 0 goto nowin
set "WINL=%WINLIST: =%"
if %NWIN% GTR 1 goto pickwin
goto haswin

:pickwin
echo 找到了多个 Windows，盘符：%WINLIST%
set "WINL="
set /p "WINL=输入要修复的那个盘符字母（例如 C），直接回车取消: "
if not defined WINL goto menu
set "WINL=!WINL:~0,1!"
if not exist "!WINL!:\Windows\System32\config\SYSTEM" goto badwin
goto haswin

:badwin
echo 盘符 !WINL! 上没有 Windows，已取消。
pause
goto menu

:haswin
call :vol2disk %WINL%
set "WDISK=%VDISK%"
if not defined WDISK goto novdisk
if "%WDISK%"=="%USBDISK%" goto isusbwin
call :findesp %WDISK%
if not defined ESPN goto noesp
call :freeletter
if not defined ESPL goto noletter
echo 将要执行：
echo   Windows 所在：%WINL%:\Windows（磁盘 %WDISK%）
echo   EFI 系统分区：磁盘 %WDISK% 的分区 %ESPN%（临时分配盘符 %ESPL%:）
echo   命令：bcdboot %WINL%:\Windows /s %ESPL%: /f UEFI
echo.
echo 注意：修好后开机默认进 Windows。双系统里的 Linux 不会被删除，
echo       开机按启动菜单键（华硕 Esc、联想 F12、戴尔 F12、惠普 F9）可以选别的系统。
echo.
set "CONFIRM="
set /p "CONFIRM=确认执行请输入 Y 后回车，其它任意输入取消: "
if /i not "!CONFIRM!"=="Y" goto cancelled
>>"%LOG%" echo 用户确认修复启动：%WINL%:\Windows  磁盘 %WDISK% 分区 %ESPN%  盘符 %ESPL%
call :dp "select disk %WDISK%" "select partition %ESPN%" "assign letter=%ESPL%"
if not "%DPERR%"=="0" goto assignfail
echo.
echo 正在执行 bcdboot……
bcdboot %WINL%:\Windows /s %ESPL%: /f UEFI > "%OUT%" 2>&1
set "BCDERR=!errorlevel!"
type "%OUT%"
>>"%LOG%" echo --- bcdboot %WINL%:\Windows /s %ESPL%: /f UEFI  返回值=!BCDERR! ---
>>"%LOG%" type "%OUT%"
call :dpq "select disk %WDISK%" "select partition %ESPN%" "remove letter=%ESPL% noerr"
if not "%BCDERR%"=="0" goto bcdfail
echo.
echo ==========================================================
echo 启动修复成功。现在拔掉 U 盘，重启电脑。
echo   - 开机还是直接进 BIOS：在 BIOS 的 Boot 选项里把“Windows Boot Manager”
echo     调到第一位，F10 保存。
echo   - 开机蓝屏 INACCESSIBLE_BOOT_DEVICE：VMD 的设置和装系统时不一样，
echo     进 BIOS 把 VMD 改回原来的状态（原来开着就打开，原来关着就关掉）。
echo   - 想进双系统里的 Linux：开机按启动菜单键选它；没有 Linux 选项的话，
echo     用 Linux 启动盘运行 ssd_check.sh，选“修复 UEFI 启动项”。
echo ==========================================================
pause
goto menu

:nowin
echo 没在硬盘上找到 Windows（找的是 \Windows\System32\config\SYSTEM 这个文件）。
echo 可能的原因：
echo   1) 硬盘还没被识别：先选 2 诊断；
echo   2) 原来的 Windows 分区开了 BitLocker / 设备加密，安装环境打不开它。
echo      需要先拿到恢复密钥（在另一台设备登录 account.microsoft.com/devices/recoverykey 查）；
echo   3) 分区表坏了：用 Linux 脚本 ssd_check.sh 的 testdisk 菜单找回分区；
echo   4) 系统已经被删除或格式化：只能重装。
pause
goto menu

:novdisk
echo 没能确定 %WINL%: 在哪块磁盘上，修复没有执行。
pause
goto menu

:isusbwin
echo %WINL%: 在你的 U 盘上，不是固态，已拒绝操作。
pause
goto menu

:noesp
echo 磁盘 %WDISK% 上没有找到 EFI 系统分区（或者这块盘是 MBR 格式）。
echo 这种情况无法只修启动。建议先用 Linux 脚本菜单 3 把整盘备份，再重装系统。
pause
goto menu

:noletter
echo 找不到空闲盘符给 EFI 分区使用，修复没有执行。
pause
goto menu

:assignfail
echo 给 EFI 分区分配盘符失败，修复没有执行。详细信息在日志里：%LOG%
pause
goto menu

:bcdfail
echo.
echo bcdboot 失败（返回代码 %BCDERR%），上面是它的报错。
echo 常见原因：EFI 分区损坏，或者 Windows 系统文件本身坏了。
echo 资料还在，先别急着清空：用 Linux 脚本菜单 3 把整盘备份出来，再决定是否重装。
pause
goto menu


rem ==================================================================
rem  5. 查看磁盘详情
rem ==================================================================
:detail
cls
call :dp "list disk"
call :askdisk || goto menu
call :dp "select disk %DN%" "detail disk" "attributes disk" "list partition"
echo.
echo --------------------------------------------------------------
echo 怎么看上面的结果：
echo   “当前只读状态: 是” 或 “Current Read-only State : Yes” → 选 6 尝试解除；
echo   “状态: 脱机” 或 “Status : Offline” → 也选 6；
echo   想重装系统、这块盘上的数据不要了 → 选 1 一键清空并准备安装。
pause
goto menu


rem ==================================================================
rem  6. 解除只读 / 脱机
rem ==================================================================
:unlock
cls
call :findusb
if not defined USBDISK goto nousb
call :dp "list disk"
call :askdisk || goto menu
if "%DN%"=="%USBDISK%" goto isusb
call :dp "select disk %DN%" "online disk noerr" "attributes disk clear readonly noerr" "attributes disk"
echo.
echo --------------------------------------------------------------
echo 如果上面仍然显示 只读: 是 / Read-only : Yes，说明是固态自己（固件）
echo 进入了只读保护，软件解除不了：先用 Linux 脚本把数据备份出来，再找售后。
set "QUIET=1"
call :survey
set "QUIET="
pause
goto menu


rem ==================================================================
rem  7. 手动选择磁盘清空
rem ==================================================================
:wipe
cls
set "MANUAL=1"
echo ======================== 手动清空 ========================
echo 会删除所选磁盘上的全部分区和数据，然后建好 Windows 需要的分区。
echo ==========================================================
echo.
call :survey
call :askdisk || goto menu
call :winondisk %DN%
if defined WOD echo.
if defined WOD echo 【注意】这块盘上有一个 Windows（盘符%WOD%），清空后就彻底没了。
if defined WOD echo 想保留的话，取消后选 4 修复启动。
goto prepdisk


rem ==================================================================
rem  清空 + 建分区（菜单 1 和 7 共用；进来前 DN 已经是磁盘编号）
rem  分区布局和微软文档一致：EFI 300MB + MSR 16MB + Windows（剩余全部）
rem ==================================================================
:prepdisk
if not defined USBDISK goto nousb
if "%DN%"=="%USBDISK%" goto isusb
if not defined SZ%DN% goto nosuchdisk
set "QUIET=1"
set "NOCOUNT=1"
call :classify %DN%
set "QUIET="
set "NOCOUNT="
if "!KIND!"=="未知设备" if defined MANUAL goto prep_unknown_ok
if not "!KIND!"=="内置硬盘" goto isusbdev
:prep_unknown_ok
rem  再核对一遍（classify 刚读过这块盘的 detail disk）：任何一处带 USB 都拒绝
if /i "!BUS!"=="USB" goto isusbdev
if not "!LOC:USB=!"=="!LOC!" goto isusbdev
if not "!MODEL:USB=!"=="!MODEL!" goto isusbdev
echo.
echo ==========================================================
echo   将要清空：磁盘 %DN%   容量 !SZ%DN%!   接口 !BUS!   型号 !MODEL!
if "!KIND!"=="未知设备" echo   【注意】这块盘读不出类型，请务必确认容量和你的固态一致！
echo ==========================================================
set "CONFIRM="
set /p "CONFIRM=确认清空请输入大写 YES 后回车（先切到英文输入法），其它任意输入取消: "
if defined CONFIRM set "CONFIRM=!CONFIRM: =!"
if not "!CONFIRM!"=="YES" goto cancelled
>>"%LOG%" echo 用户确认清空 磁盘 %DN%  容量=!SZ%DN%!  型号=!MODEL!
echo.
echo 正在清空并分区，一般 10 秒左右……
call :dpq "select disk %DN%" "online disk noerr" "attributes disk clear readonly noerr"
call :dpq "select disk %DN%" "clean" "convert gpt" "create partition efi size=300" "format quick fs=fat32 label=System" "create partition msr size=16" "create partition primary" "format quick fs=ntfs label=Windows"
if not "%DPERR%"=="0" goto wipefail
call :dp "select disk %DN%" "list partition"
echo.
echo 正在做写入 + 读回校验，确认固态真的能正常读写（大约半分钟）……
set "VERR=1"
set "VN=0"
call :freeletter
set "TL=%ESPL%"
if not defined TL goto verify_skip
call :dpq "select disk %DN%" "select partition 3" "assign letter=%TL%"
if not "%DPERR%"=="0" goto verify_skip
call :verify %TL%
call :dpq "select volume %TL%" "remove letter=%TL% noerr"
if "%VERR%"=="2" goto verify_skip
if "%VERR%"=="1" goto verifyfail
echo   写入读回校验通过：%VN% 个文件写进固态、清掉缓存后读回来，全部一致。
set "VMSG=读写校验正常"
goto prep_done
:verify_skip
echo   （这个环境里做不了读写校验，已跳过。）
set "VMSG=读写校验已跳过"
:prep_done
echo.
echo ==========================================================
echo   完成！固态已修复：清空、建好分区，%VMSG%。
echo.
echo   接下来只要三步：
echo     1. 按任意键，这个黑色窗口会自动关掉；
echo     2. 回到选择安装位置的页面点“刷新”（没有刷新就点“上一步”再点“下一步”）；
echo     3. 选中 驱动器/磁盘 %DN% 里名字是 Windows 的那个分区，点“下一步”。
echo        提示要格式化就点“确定”。
echo ==========================================================
pause
exit

:verifyfail
echo.
echo ==========================================================
echo   【读写校验没通过】固态能清空、能建分区，但写进去的数据读回来不一样（或者写不进去）。
echo   这说明固态硬件或固件有问题，硬装系统也会频繁出错。
echo   下一步：用修复 U 盘做“深度修复”（见 使用说明.txt 第二节）；还不行就找售后。
echo   （写入 %VN% 个文件，读回比对 %VC% 个，出错 %VBAD% 个，详细记录在 %LOG%）
echo ==========================================================
pause
goto menu

:wipefail
type "%OUT%"
echo.
echo 操作失败，diskpart 返回代码 %DPERR%。请看上面的报错：
echo   出现“介质受写入保护 / write protected”：固态固件处于只读保护，软件修不了，
echo       请先备份数据，再联系电脑厂商或固态厂商售后；
echo   出现“I/O 设备错误 / 请求失败”：固态通讯异常，请用 Linux 脚本做底层检测。
echo 日志已保存到 %LOG%
pause
goto menu

:nousb
echo.
echo 没能识别出 U 盘是几号磁盘，为了不误删 U 盘，拒绝执行这个操作。
echo 请确认你是从 U 盘上运行的本脚本（例如 D:\usb-ssd-fix\fix_win.cmd）。
echo 也可以直接在安装界面里，把固态上的分区逐个选中点“删除”，效果和清空一样。
pause
goto menu

:isusb
echo.
echo 磁盘 %DN% 是你的 U 盘，已拒绝操作。
pause
goto menu

:isusbdev
echo.
echo 磁盘 %DN% 不是内置硬盘（U 盘 / 移动硬盘 / 虚拟盘），为了防止误删，已拒绝清空。
echo 如果你的固态现在装在 USB 硬盘盒里，请先把它装回电脑内部再操作。
pause
goto menu

:nosuchdisk
echo.
echo 列表里没有磁盘 %DN%，已取消。
pause
goto menu

:cancelled
echo 已取消，没有做任何修改。
pause
goto menu


rem ==================================================================
rem  8. 收集安装日志
rem ==================================================================
:logs
cls
set "LD=%HERE%setup_logs"
if not exist "%LD%\" mkdir "%LD%" 2>nul
if not exist "%LD%\" set "LD=%WORK%\setup_logs"
if not exist "%LD%\" mkdir "%LD%" 2>nul
set "NLOG=0"
call :grab "X:\$WINDOWS.~BT\Sources\Panther" bt_panther
call :grab "X:\Windows\Panther" win_panther
call :grab "X:\Windows\INF" inf
echo 已复制 %NLOG% 个日志文件到：%LD%
>>"%LOG%" echo 收集日志：%NLOG% 个，位置 %LD%
set "ERRF="
if exist "X:\$WINDOWS.~BT\Sources\Panther\setuperr.log" set "ERRF=X:\$WINDOWS.~BT\Sources\Panther\setuperr.log"
if not defined ERRF if exist "X:\Windows\Panther\setuperr.log" set "ERRF=X:\Windows\Panther\setuperr.log"
if not defined ERRF goto noerrlog
set "TAILN=0"
rem  不用 find / findstr（Win10 安装盘里没有），直接数行
for /f "usebackq delims=" %%l in ("%ERRF%") do set /a TAILN+=1
set /a "TAILN-=20"
set "LN=0"
echo.
echo ---------------- 安装程序错误日志的最后 20 行 ----------------
for /f "usebackq delims=" %%l in ("%ERRF%") do (
  set /a LN+=1
  if !LN! GTR !TAILN! echo.  %%l
)
echo --------------------------------------------------------------
echo 看不懂没关系，把 U 盘里的 setup_logs 文件夹和 log_win.txt 发给帮你排查的人。
pause
goto menu

:noerrlog
echo 安装程序还没有写出错误日志（setuperr.log），可能还没走到出错的那一步。
echo 先回到安装界面重现一次报错，再来选 8。
pause
goto menu

:grab
if not exist "%~1\" exit /b 0
for %%f in ("%~1\*.log") do (
  copy /y "%%f" "%LD%\%~2_%%~nxf" >nul 2>&1 && set /a NLOG+=1
)
exit /b 0


rem ==================================================================
rem  子程序
rem ==================================================================

rem  输入磁盘编号，结果放在 DN；取消或输入无效返回 1
:askdisk
set "DN="
echo.
set /p "DN=请输入磁盘编号（只输数字，直接回车取消）: "
if not defined DN exit /b 1
if "!DN:~0,1!"==";" goto badnum
if not "!DN:~3!"=="" goto badnum
for /f "delims=0123456789" %%x in ("!DN!") do goto badnum
rem 去掉前导 0（01 变成 1），前面拼 1000 防止 08 被当成八进制
set /a "DN=1000!DN! %% 1000"
exit /b 0
:badnum
echo 输入无效，请输入 0 到 999 之间的数字。
pause
exit /b 1

rem  重新扫描并识别所有磁盘：结果在 NDISK / NINT / INTLIST / ANYRO / QINFO
rem  定义了 QUIET 时不显示，只记日志；定义了 NOCOUNT 时只识别不计数
:survey
call :findusb
call :dpq "rescan" "list disk"
copy /y "%OUT%" "%LST%" >nul
if not defined QUIET type "%LST%"
set "NDISK=0"
set "NINT=0"
set "INTLIST="
set "ANYRO=0"
set "QINFO="
set "NUNK=0"
set "UNKLIST="
if not defined QUIET echo ------------------------ 逐个识别磁盘 ------------------------
for /f "usebackq tokens=1-6" %%a in ("%LST%") do (
  if "%%a"=="*" (call :lsdisk %%b %%c %%e %%f) else call :lsdisk %%a %%b %%d %%e
)
if not defined QUIET echo --------------------------------------------------------------
>>"%LOG%" echo 检测：磁盘总数=%NDISK%  内置硬盘数=%NINT%  内置硬盘编号=%INTLIST%
exit /b 0

rem  list disk 的一行：第 1 个词是 Disk/磁盘、第 2 个是纯数字才算一块盘（跳过表头和分隔线）
:lsdisk
if /i not "%~1"=="Disk" if not "%~1"=="磁盘" exit /b 0
if "%~2"=="" exit /b 0
for /f "delims=0123456789" %%x in ("%~2") do exit /b 0
call :classify %2 %3 %4
exit /b 0

rem  识别一块磁盘：接口类型、型号、是否只读；内置硬盘计入 NINT / INTLIST
:classify
set "N=%~1"
if not "%~2"=="" set "SZ%~1=%~2 %~3"
if not defined NOCOUNT set /a NDISK+=1
set "MODEL=-"
set "BUS=-"
set "RO=-"
set "LOC=-"
set "GRAB=0"
call :dpq "select disk %N%" "detail disk"
for /f "usebackq delims=" %%L in ("%OUT%") do (
  set "line=%%L"
  if "!GRAB!"=="1" (
    set "MODEL=%%L"
    set "GRAB=2"
  )
  if "!GRAB!"=="0" (
    if not "!line:selected disk=!"=="!line!" set "GRAB=1"
    if not "!line:所选磁盘=!"=="!line!" set "GRAB=1"
  )
  if /i "!line:~0,4!"=="Type" set "BUS=!line:*:=!"
  if "!line:~0,2!"=="类型" set "BUS=!line:*:=!"
  if /i "!line:~0,13!"=="Location Path" set "LOC=!line:*:=!"
  if "!line:~0,4!"=="位置路径" set "LOC=!line:*:=!"
  if /i "!line:~0,23!"=="Current Read-only State" set "RO=!line:*:=!"
  if "!line:~0,6!"=="当前只读状态" set "RO=!line:*:=!"
)
rem  每个变量都先保证有值，避免对空变量做截取/替换
if defined BUS set "BUS=!BUS: =!"
if defined RO set "RO=!RO: =!"
if not defined BUS set "BUS=-"
if not defined RO set "RO=-"
if not defined LOC set "LOC=-"
if not defined MODEL set "MODEL=-"
set "KIND=内置硬盘"
if /i "!BUS!"=="USB" set "KIND=外接设备"
if /i "!BUS!"=="SD" set "KIND=外接设备"
if /i "!BUS!"=="MMC" set "KIND=外接设备"
if not "!LOC:USB=!"=="!LOC!" set "KIND=外接设备"
if not "!MODEL:USB=!"=="!MODEL!" set "KIND=外接设备"
if /i "!BUS:~0,4!"=="File" set "KIND=虚拟磁盘"
if /i "!BUS!"=="Virtual" set "KIND=虚拟磁盘"
rem  读不出信息的盘不当成内置硬盘，一键清空绝不会自动选它
if not "%DPERR%"=="0" set "KIND=未知设备"
if "!BUS!"=="-" set "KIND=未知设备"
if "%N%"=="%USBDISK%" set "KIND=本工具U盘"
if "!BUS!"=="-" set "BUS=未知"
set "ROTXT="
if /i "!RO!"=="Yes" set "ROTXT=  【只读】"
if "!RO!"=="是" set "ROTXT=  【只读】"
if not defined QUIET echo   磁盘 %N%：!KIND!  容量 !SZ%N%!  接口 !BUS!  型号 !MODEL!!ROTXT!
>>"%LOG%" echo 磁盘 %N%：!KIND!  接口=!BUS!  型号=!MODEL!  只读=!RO!  位置=!LOC!
if defined NOCOUNT exit /b 0
if "!KIND!"=="未知设备" set /a NUNK+=1
if "!KIND!"=="未知设备" set "UNKLIST=!UNKLIST! %N%"
if not "!KIND!"=="内置硬盘" exit /b 0
set /a NINT+=1
set "INTLIST=!INTLIST! %N%"
if not defined QINFO set "QINFO=磁盘 %N%，容量 !SZ%N%!，接口 !BUS!，型号 !MODEL!"
if defined ROTXT set "ANYRO=1"
exit /b 0

rem  查注册表里的 PCI 设备表：有没有 Intel VMD/RAID 控制器、有没有 NVMe 控制器
:pcicheck
set "PCIOK=0"
set "HASVMD=0"
set "HASNVME=0"
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\PCI" /s /v CompatibleIDs > "%PCI%" 2>&1
rem  逐行比对子串（cmd 的子串替换不区分大小写），不依赖 findstr
for /f "usebackq delims=" %%L in ("%PCI%") do (
  set "pl=%%L"
  if not "!pl:CC_=!"=="!pl!" set "PCIOK=1"
  if not "!pl:VEN_8086&CC_0104=!"=="!pl!" set "HASVMD=1"
  if not "!pl:CC_0108=!"=="!pl!" set "HASNVME=1"
)
>>"%LOG%" echo PCI 设备表：读取成功=%PCIOK%  Intel VMD/RAID=%HASVMD%  NVMe 控制器=%HASNVME%
exit /b 0

rem  找出所有装着 Windows 的盘符（不含 X: 和本 U 盘），结果在 NWIN / WINLIST
:findwin
set "NWIN=0"
set "WINLIST="
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if /i not "%%L:"=="%USBLETTER%" if exist "%%L:\Windows\System32\config\SYSTEM" (
    set /a NWIN+=1
    set "WINLIST=!WINLIST! %%L"
  )
)
>>"%LOG%" echo 找到的 Windows：数量=%NWIN%  盘符=%WINLIST%
exit /b 0

rem  某块磁盘上有没有 Windows，结果在 WOD（盘符列表，可能为空）
:winondisk
set "WOD="
call :findwin
for %%L in (%WINLIST%) do (
  call :vol2disk %%L
  if "!VDISK!"=="%~1" set "WOD=!WOD! %%L:"
)
exit /b 0

rem  盘符 -> 磁盘编号，结果在 VDISK
:vol2disk
set "VDISK="
call :dpq "select volume %~1" "detail volume"
for /f "usebackq tokens=1-3" %%a in ("%OUT%") do (
  if "%%a"=="*" if /i "%%b"=="Disk" set "VDISK=%%c"
  if "%%a"=="*" if "%%b"=="磁盘" set "VDISK=%%c"
)
exit /b 0

rem  U 盘（本脚本所在盘符）是几号磁盘，结果在 USBDISK
:findusb
call :vol2disk %USBLETTER:~0,1%
set "USBDISK=%VDISK%"
exit /b 0

rem  某块磁盘上的 EFI 系统分区编号，结果在 ESPN
:findesp
set "ESPN="
call :dpq "select disk %~1" "list partition"
for /f "usebackq tokens=1-4" %%a in ("%OUT%") do (
  if /i "%%a"=="Partition" if /i "%%c"=="System" set "ESPN=%%b"
  if "%%a"=="分区" if "%%c"=="系统" set "ESPN=%%b"
  if "%%a"=="*" if /i "%%b"=="Partition" if /i "%%d"=="System" set "ESPN=%%c"
  if "%%a"=="*" if "%%b"=="分区" if "%%d"=="系统" set "ESPN=%%c"
)
exit /b 0

rem  读写校验：往 盘符:\ssdtest 写最多 400 个系统文件，卸载卷清掉缓存，再逐个和原文件比对
rem  结果：VERR=0 通过 / 1 失败 / 2 做不了（跳过），VN=写入数，VC=比对数，VBAD=出错数
:verify
set "VERR=1"
set "VN=0"
set "VC=0"
set "VBAD=0"
set "VSRC=%SystemRoot%\System32"
set "VD=%~1:\ssdtest"
rem  缺工具或缺源文件 = 做不了校验（VERR=2，算跳过），不能当成固态坏了
if not exist "%VSRC%\fc.exe" (set "VERR=2" & exit /b 0)
if not exist "%VSRC%\fsutil.exe" (set "VERR=2" & exit /b 0)
if not exist "%VSRC%\*.dll" (set "VERR=2" & exit /b 0)
mkdir "%VD%" 2>nul
if not exist "%VD%\" exit /b 0
rem  写：最多 400 个文件；连续出错 5 次就不再试（坏盘每次都可能卡很久）
for %%f in ("%VSRC%\*.dll") do (
  if !VN! LSS 400 if !VBAD! LSS 5 (
    copy /b /y "%%f" "%VD%\" >nul 2>&1 && set /a VN+=1 || set /a VBAD+=1
  )
)
rem  卸载卷，丢掉系统缓存，后面的读一定来自固态；卸载失败就没法保证，算跳过
fsutil volume dismount %~1: >nul 2>&1 || (set "VERR=2" & rd /s /q "%VD%" >nul 2>&1 & exit /b 0)
rem  读：逐个和原文件比对；VC 记录实际比对了几个，少了也算出错
for %%f in ("%VD%\*.dll") do (
  set /a VC+=1
  if !VBAD! LSS 5 (
    fc /b "%%f" "%VSRC%\%%~nxf" >nul 2>&1 || set /a VBAD+=1
  )
)
rd /s /q "%VD%" >nul 2>&1
>>"%LOG%" echo 读写校验：写入 %VN% 个，读回比对 %VC% 个，出错 %VBAD% 个
if %VN% GTR 0 if %VBAD% EQU 0 if %VC% EQU %VN% set "VERR=0"
exit /b 0

rem  找一个空闲盘符，结果在 ESPL
:freeletter
set "ESPL="
for %%L in (S T U V W Y Z R Q P) do (
  if not defined ESPL (
    vol %%L: >nul 2>&1 || set "ESPL=%%L"
  )
)
exit /b 0

rem  用法：call :dp "diskpart 命令1" "命令2" ...   执行并显示、记日志
:dp
call :dpq %*
type "%OUT%"
exit /b %DPERR%

rem  同上，但不显示，只记日志
:dpq
(for %%c in (%*) do echo %%~c)> "%DPS%"
diskpart /s "%DPS%" > "%OUT%" 2>&1
set "DPERR=!errorlevel!"
>>"%LOG%" echo --- diskpart: %* ---
>>"%LOG%" type "%OUT%"
exit /b %DPERR%


rem ==================================================================
:quit
del "%DPS%" "%OUT%" "%LST%" "%PCI%" >nul 2>&1
echo 日志保存在：%LOG%
endlocal
exit /b 0

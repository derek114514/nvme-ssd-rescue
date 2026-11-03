# 制作 NVMe 固态修复 U 盘（Windows 10 / 11）
# 用法：双击同目录的“制作U盘.cmd”，或者在 PowerShell 里运行  .\make_usb.ps1
# 会做的事：下载并校验 SystemRescue 13.02 → 清空你选的 U 盘 → 写入修复系统和本工具。
# 本文件必须保存为 UTF-8 带 BOM（Windows PowerShell 5.1 才能正确读中文）。
param(
    [int]$DiskNumber = -1,      # 指定 U 盘的磁盘编号（不填就让你选）
    [string]$IsoPath = '',      # 已经下载好的 ISO 路径（不填就自动找 / 下载）
    [switch]$Yes,               # 跳过“输入 YES”确认（自动化用，小心）
    [string]$KitOnlyTo = ''     # 只把修复工具写到这个文件夹（不动 U 盘、不写 SystemRescue），
                                # 用于给已有的修复盘更新工具，或者测试
)
$ErrorActionPreference = 'Stop'
$SR_VER   = '13.02'
$SR_LABEL = 'RESCUE1302'        # 必须和 ISO 里的卷标一致，修复系统靠它找到 U 盘
$SR_ISO   = "systemrescue-$SR_VER-amd64.iso"
$SR_SHA   = 'ad4d670b72859d887c7960142a9a9d36a3e50446694a035e254442f65d6e7572'
$SR_URLS  = @("https://fastly-cdn.system-rescue.org/releases/$SR_VER/$SR_ISO",
              "https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/$SR_VER/$SR_ISO/download")

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Die($t) { Say "`n[失败] $t" Red; Read-Host '按回车退出'; exit 1 }

# ---- 1. 需要管理员权限（清空和格式化 U 盘要用）----
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $KitOnlyTo -and -not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say '需要管理员权限，正在请求……（弹出的窗口点“是”）' Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($DiskNumber -ge 0) { $a += @('-DiskNumber', $DiskNumber) }
    if ($IsoPath) { $a += @('-IsoPath', "`"$IsoPath`"") }
    if ($Yes) { $a += '-Yes' }
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit
}

# ---- 2. 找到工具文件：发布包（已转换好编码）或者源码仓库（现场转换）----
$here = $PSScriptRoot
if (Test-Path (Join-Path $here 'usb-ssd-fix\fix_win.cmd')) { $kit = $here; $fromSrc = $false }
elseif (Test-Path (Join-Path $here '..\src\usb-ssd-fix\fix_win.cmd')) { $kit = (Resolve-Path (Join-Path $here '..\src')).Path; $fromSrc = $true }
else { Die '找不到工具文件（usb-ssd-fix 文件夹）。请把整个压缩包解压后再运行。' }

# ---- 写入本工具（从源码运行时现场转换编码）----
function Copy-Kit([string]$root) {
Say '写入修复工具……' Cyan
$gbk = [Text.Encoding]::GetEncoding(936)
$utf8 = New-Object Text.UTF8Encoding($false)
$utf8bom = New-Object Text.UTF8Encoding($true)
$items = 'fix.cmd', '使用说明.txt', 'autorun', 'sysrescue.d', 'usb-ssd-fix'
foreach ($it in $items) {
    $src = Join-Path $kit $it
    if (-not (Test-Path $src)) { Die "工具文件缺少 $it" }
    Get-ChildItem $src -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($kit.Length).TrimStart('\')
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        if (-not $fromSrc -or $rel -like 'usb-ssd-fix\bcd\*') { Copy-Item -Force $_.FullName $dst; return }
        $t = [IO.File]::ReadAllText($_.FullName, $utf8) -replace "`r`n", "`n"
        switch -Regex ($_.Name) {
            '\.cmd$'            { [IO.File]::WriteAllText($dst, ($t -replace "`n", "`r`n"), $gbk) }
            '\.txt$'            { [IO.File]::WriteAllText($dst, ($t -replace "`n", "`r`n"), $utf8bom) }
            default             { [IO.File]::WriteAllText($dst, $t, $utf8) }   # .sh / .yaml / autorun：LF
        }
    }
}
Get-ChildItem $root -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReadOnly } |
    ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }
}

if ($KitOnlyTo) {
    New-Item -ItemType Directory -Force $KitOnlyTo | Out-Null
    Copy-Kit (Resolve-Path $KitOnlyTo).Path
    Say "已把修复工具写到 $KitOnlyTo" Green
    exit
}

# ---- 3. 7-Zip（SystemRescue 的 ISO 没有 Joliet 文件名，Windows 自带的解压会把文件名弄坏）----
$7z = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $7z -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Say '没装 7-Zip，正在用 winget 安装……' Yellow
    winget install --id 7zip.7zip -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
    $7z = @("$env:ProgramFiles\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $7z) { Die '需要 7-Zip。请先从 https://www.7-zip.org 安装，再运行本脚本。' }

# ---- 4. 选 U 盘：只列 USB 接口的盘 ----
$usb = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
if ($usb.Count -eq 0) { Die '没找到 U 盘。请插上 U 盘（至少 2GB）再运行。' }
Say "`n找到这些 USB 磁盘：" Cyan
foreach ($d in $usb) { Say ("  磁盘 {0}：{1}  {2:N1} GB" -f $d.Number, $d.FriendlyName, ($d.Size / 1GB)) }
if ($DiskNumber -lt 0) {
    if ($usb.Count -eq 1) { $DiskNumber = $usb[0].Number }
    else { $DiskNumber = [int](Read-Host "`n输入要做成修复盘的磁盘编号") }
}
$disk = $usb | Where-Object Number -eq $DiskNumber
if (-not $disk) { Die "磁盘 $DiskNumber 不是 USB 磁盘，为了安全拒绝操作。" }
if ($disk.IsBoot -or $disk.IsSystem) { Die "磁盘 $DiskNumber 是当前系统所在的盘，拒绝操作。" }
if ($disk.Size -lt 2GB) { Die 'U 盘太小，至少要 2GB。' }

# ---- 5. 准备 ISO：指定的 → 脚本旁边 → 下载文件夹 → 现场下载；都要校验 SHA256 ----
$dl = Join-Path $env:USERPROFILE 'Downloads'
$cands = @($IsoPath, (Join-Path $here $SR_ISO), (Join-Path $dl $SR_ISO)) | Where-Object { $_ -and (Test-Path $_) }
$iso = $null
foreach ($c in $cands) {
    Say "校验 $c ……"
    if ((Get-FileHash $c -Algorithm SHA256).Hash -eq $SR_SHA) { $iso = $c; break }
    Say '  校验不通过，忽略这个文件。' Yellow
}
if (-not $iso) {
    $iso = Join-Path $dl $SR_ISO
    foreach ($u in $SR_URLS) {
        Say "下载 SystemRescue $SR_VER（约 1.3GB）：$u" Cyan
        curl.exe -L --fail --retry 3 -o "$iso.part" $u
        if ($LASTEXITCODE -eq 0 -and (Get-FileHash "$iso.part" -Algorithm SHA256).Hash -eq $SR_SHA) { Move-Item -Force "$iso.part" $iso; break }
        Say '  下载失败或校验不通过，换下一个地址。' Yellow
    }
    if (-not (Test-Path $iso)) { Die "下载失败。可以手动从 https://www.system-rescue.org/Download/ 下载 $SR_ISO 放到本脚本旁边再运行。" }
}
Say "ISO 校验通过：$iso" Green

# ---- 6. 确认后清空 U 盘：MBR + 一个 FAT32 分区（UEFI 都能启动；FAT32 最大 32GB）----
Say ("`n将要清空：磁盘 {0}  {1}  {2:N1} GB，上面的所有文件都会删除！" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB)) Red
if (-not $Yes) {
    if ((Read-Host '确认请输入大写 YES') -cne 'YES') { Say '已取消，没有做任何修改。'; exit }
}
Say '正在清空并格式化……'
$disk | Set-Disk -IsReadOnly $false -ErrorAction SilentlyContinue
$disk | Set-Disk -IsOffline $false -ErrorAction SilentlyContinue
if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false }
Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction SilentlyContinue
$size = [Math]::Min($disk.Size - 8MB, 32GB)
$part = New-Partition -DiskNumber $disk.Number -Size $size -IsActive -AssignDriveLetter
Start-Sleep 2
$vol = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $SR_LABEL -Confirm:$false -Force
$L = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
if (-not $L) { Die '格式化后没有拿到盘符。' }
$root = "${L}:\"

# ---- 7. 写入修复系统 ----
Say "解压 SystemRescue 到 $root（几分钟）……" Cyan
& $7z x -y "-o$root" $iso -x!'[BOOT]' | Out-Null
if ($LASTEXITCODE -ne 0) { Die "7-Zip 解压失败（代码 $LASTEXITCODE）。" }
foreach ($p in 'EFI\boot\bootx64.efi', 'sysresccd') {
    if (-not (Test-Path (Join-Path $root $p))) { Die "U 盘上缺少 $p，解压不完整。" }
}

Copy-Kit $root

$v = Get-Volume -DriveLetter $L
Say ("`n完成！U 盘 {0}:  卷标 {1}  剩余 {2:N0} MB" -f $L, $v.FileSystemLabel, ($v.SizeRemaining / 1MB)) Green
Say '用法见 U 盘根目录的“使用说明.txt”。开机前记得在 BIOS 里关闭 Secure Boot。'
Read-Host '按回车退出'

#!/usr/bin/env bash
# =====================================================================
#  NVMe 固态：深度检测 + 深度修复 v6（在 Linux Live U 盘里运行）
#  推荐环境：SystemRescue（工具齐全，不用联网）；Ubuntu Live 也行（需联网装工具）
#  用法：  bash ssd_check.sh              检测，然后进入修复菜单
#          bash ssd_check.sh --report     只检测、出报告，不进菜单
#          bash ssd_check.sh --no-install 不尝试联网安装缺少的工具
#          bash ssd_check.sh --auto       修复盘开机自动运行时用（不联网装工具，检测完提示深度修复）
#  安全：检测全程只读；菜单里会写盘的操作都要你手动输入确认。
# =====================================================================

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -u

REPORT_ONLY=0
NO_INSTALL=0
AUTO=0
for arg in "$@"; do
  case "$arg" in
    --report)     REPORT_ONLY=1 ;;
    --auto)       AUTO=1; NO_INSTALL=1 ;;
    --no-install) NO_INSTALL=1 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo bash "$0" "$@"; fi
  echo "需要 root 权限，请用 root 运行：bash $0"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$HERE/report_linux_$STAMP.txt"
if ! { : > "$REPORT"; } 2>/dev/null; then
  REPORT="/tmp/report_linux_$STAMP.txt"
  : > "$REPORT"
fi
SAVE_DIR="$(dirname "$REPORT")"

if [[ -t 1 ]]; then
  C_R=$'\e[1;31m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_B=$'\e[1m'; C_N=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""
fi

# ---------------------------------------------------------------------
# 输出工具：屏幕带颜色，报告文件不带
# ---------------------------------------------------------------------
PROBLEMS=()
TARGETS=()
LOADERS=()          # 检测到的启动文件：类型|磁盘|分区号|分区UUID|名称|路径
WIN_PARTS=()        # 装着完整 Windows 的分区
ESP_DEVS=()         # EFI 系统分区
SYSDISKS=()         # 检测到还装着系统的磁盘
SAMPLES=32          # 全盘抽查读取的位置数
NVME_CLASS="${NVME_CLASS:-/sys/class/nvme}"  # 可覆盖，方便测试
EFI_DIR="${EFI_DIR:-/sys/firmware/efi}"      # 存在 = 本次是 UEFI 启动
SELFTEST_POLLS="${SELFTEST_POLLS:-72}"   # 自检最多轮询次数
SELFTEST_SLEEP="${SELFTEST_SLEEP:-5}"    # 每次间隔秒数（72×5 = 6 分钟）
say()     { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$REPORT"; }
section() { printf '\n%s==== %s ====%s\n' "$C_B" "$*" "$C_N"; printf '\n==== %s ====\n' "$*" >> "$REPORT"; }
good()    { printf '%s[正常]%s %s\n' "$C_G" "$C_N" "$*"; printf '[正常] %s\n' "$*" >> "$REPORT"; }
warn()    { printf '%s[注意]%s %s\n' "$C_Y" "$C_N" "$*"; printf '[注意] %s\n' "$*" >> "$REPORT"; }
bad()     { printf '%s[异常]%s %s\n' "$C_R" "$C_N" "$*"; printf '[异常] %s\n' "$*" >> "$REPORT"; PROBLEMS+=("$*"); }
rec()     { printf '\n$ %s\n' "$*" >> "$REPORT"; bash -c "$*" >> "$REPORT" 2>&1; }   # 只记进报告
trim()    { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
have()    { command -v "$1" >/dev/null 2>&1; }
isnum()   { [[ ${1:-} =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]]; }
human()   { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 字节"; }
pttype()  { blkid -p -o value -s PTTYPE "$1" 2>/dev/null; }
# 直接读盘取分区信息（不依赖 udev，Live 系统里 udev 没跑完时 lsblk 的这些列会是空的）
pinfo()   { blkid -p -o value -s "$2" "$1" 2>/dev/null; }
parts_of() { lsblk -nrpo NAME "$1" 2>/dev/null | awk 'NR>1'; }

# 从 nvme smart-log 输出里取某个字段的第一个数字
getval() {
  awk -F: -v k="$2" '
    { key=$1; gsub(/[ \t]/, "", key) }
    key == k { v=$2; gsub(/,/, "", v); gsub(/%/, "", v); split(v, a, " "); print a[1]; exit }' <<<"$1"
}

# ---------------------------------------------------------------------
# 检查/安装需要的工具
# ---------------------------------------------------------------------
ensure_tools() {
  local t missing=()
  for t in lspci nvme smartctl sgdisk blkid lsblk wipefs blockdev timeout testdisk ddrescue efibootmgr; do
    have "$t" || missing+=("$t")
  done
  (( ${#missing[@]} == 0 )) && return 0
  warn "缺少工具：${missing[*]}"
  if (( NO_INSTALL )); then
    warn "已指定 --no-install，不安装；相关检测会少做一些。"
    return 0
  fi
  say "尝试联网安装缺少的工具（没网会失败，不影响基本检测）……"
  if have apt-get; then
    have add-apt-repository && add-apt-repository -y universe >/dev/null 2>&1
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      pciutils nvme-cli smartmontools gdisk testdisk gddrescue parted efibootmgr >/dev/null 2>&1
  elif have pacman; then
    pacman -Sy --noconfirm --needed pciutils nvme-cli smartmontools gptfdisk testdisk ddrescue parted efibootmgr >/dev/null 2>&1
  elif have dnf; then
    dnf install -y pciutils nvme-cli smartmontools gdisk testdisk ddrescue parted efibootmgr >/dev/null 2>&1
  fi
  missing=()
  for t in lspci nvme smartctl sgdisk; do have "$t" || missing+=("$t"); done
  if (( ${#missing[@]} )); then
    warn "仍然缺少：${missing[*]}（建议改用 SystemRescue，它全都自带）"
  else
    good "工具已就绪"
  fi
}

# ---------------------------------------------------------------------
# 解读 NVMe 严重警告位
# ---------------------------------------------------------------------
decode_cw() {
  local cw=$(( $1 ))
  (( cw & 1 ))  && bad "备用块已低于阈值（坏块太多）"
  (( cw & 2 ))  && warn "温度超过阈值"
  (( cw & 4 ))  && bad "固态自报：可靠性下降（介质或内部错误）"
  if (( cw & 8 )); then
    bad "固态已进入【只读保护模式】：只能读不能写，Windows 当然装不进去"
    F_RO=1
  fi
  (( cw & 16 )) && bad "易失性缓存备份失效"
  return 0
}

# ---------------------------------------------------------------------
# 检查一个存储空间（如 /dev/nvme0n1）
# ---------------------------------------------------------------------
check_ns() {
  local ns="$1" bn="${1##*/}" size ro pt
  size="$(blockdev --getsize64 "$ns" 2>/dev/null || echo 0)"
  ro="$(cat "/sys/block/$bn/ro" 2>/dev/null || echo '?')"
  say ""
  say "  存储空间 $ns：容量 $(human "$size")"
  if [[ ! $size =~ ^[0-9]+$ ]] || (( size == 0 )); then
    bad "$ns 容量为 0 → 固件或映射表损坏，软件层面修不了"
    F_NONS=1
    return
  fi
  if [[ $ro == 1 ]]; then
    bad "$ns 被系统标记为只读"
    F_RO=1
  fi
  TARGETS+=("$ns")

  # --- 读取测试（只读）：开头 + 全盘均匀抽查 + 末尾 ---
  local t0 t1 mbps total_mb skip i step nfail=0 failed_at=""
  t0="$(date +%s.%N)"
  if timeout 60 dd if="$ns" of=/dev/null bs=1M count=256 iflag=direct status=none 2>>"$REPORT"; then
    t1="$(date +%s.%N)"
    mbps="$(awk -v a="$t0" -v b="$t1" 'BEGIN{d=b-a; if (d<=0) d=0.001; printf "%.0f", 256/d}')"
    good "开头 256 MB 读取正常（约 ${mbps} MB/s）"
  else
    bad "$ns 开头 256 MB 读取失败或超时 → 有读错误，务必先备份"
    F_READ=1
  fi
  total_mb=$(( size / 1048576 ))
  if (( total_mb > 2048 )); then
    step=$(( total_mb / SAMPLES ))
    for (( i = 0; i < SAMPLES; i++ )); do
      printf '\r  全盘抽查读取：%d/%d ' "$(( i + 1 ))" "$SAMPLES"
      if ! timeout 20 dd if="$ns" of=/dev/null bs=1M skip=$(( i * step )) count=8 iflag=direct status=none 2>>"$REPORT"; then
        nfail=$(( nfail + 1 ))
        failed_at+=" $(( i * step / 1024 ))GB"
      fi
    done
    printf '\r%*s\r' 40 ''
    if (( nfail == 0 )); then
      good "全盘均匀抽查 $SAMPLES 处（每处 8 MB）读取都正常"
    else
      bad "全盘抽查有 $nfail 处读取失败（位置约在：${failed_at# }）→ 固态有坏区，务必先备份"
      F_READ=1
    fi
  fi
  skip=$(( total_mb > 64 ? total_mb - 64 : 0 ))
  if timeout 60 dd if="$ns" of=/dev/null bs=1M skip="$skip" count=64 iflag=direct status=none 2>>"$REPORT"; then
    good "末尾 64 MB 读取正常"
  else
    bad "$ns 末尾读取失败 → 有读错误，或容量信息不对"
    F_READ=1
  fi

  # --- 分区表 ---
  rec "lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT $ns"
  pt="$(pttype "$ns")"
  case "$pt" in
    gpt)
      if have sgdisk; then
        local v
        v="$(sgdisk -v "$ns" 2>&1)"
        printf '\n$ sgdisk -v %s\n%s\n' "$ns" "$v" >> "$REPORT"
        if grep -qi 'No problems found' <<<"$v"; then
          good "分区表：GPT，完好"
        else
          warn "GPT 分区表有错误（详见报告）。可用菜单 4（testdisk）修复，或菜单 5 清空重建"
          F_PT=1
        fi
      else
        good "分区表：GPT"
      fi ;;
    dos)
      warn "分区表是 MBR。现在的电脑都用 UEFI 启动，Windows 只能装在 GPT 盘上 → 会报“无法安装到这个磁盘”"
      F_PT=1 ;;
    "")
      warn "没认出分区表（空盘，或分区表损坏）"
      F_PT=1 ;;
    *)
      warn "分区表类型：$pt"
      F_PT=1 ;;
  esac

  local p fs lab sz
  local -a plist=()
  mapfile -t plist < <(parts_of "$ns")
  if (( ${#plist[@]} )); then
    say "  识别到的分区（能看到说明原来的数据结构还在）："
    for p in "${plist[@]}"; do
      fs="$(pinfo "$p" TYPE)"
      lab="$(pinfo "$p" LABEL)"
      [[ -z $lab ]] && lab="$(pinfo "$p" PART_ENTRY_NAME)"
      sz="$(lsblk -dno SIZE "$p" 2>/dev/null | trim)"
      say "    ${p##*/}  ${sz:-?}  ${fs:-无文件系统}  ${lab}"
    done
  fi

  [[ $pt == gpt || $pt == dos ]] && check_systems "$ns" && check_boot "$ns"
  return 0
}

# ---------------------------------------------------------------------
# 只读挂载一个分区到临时目录；已经挂着就直接用。结果在 MNT，自己挂的 MNT_OWN=1
# ---------------------------------------------------------------------
MNT=""; MNT_OWN=0
ro_mount() {
  local dev="$1" fstype="$2" opts="ro"
  MNT="$(findmnt -nro TARGET -S "$dev" 2>/dev/null | head -n1)"
  MNT_OWN=0
  [[ -n $MNT ]] && return 0
  MNT="$(mktemp -d /tmp/ssdchk.XXXXXX)"
  # ext4 只读挂载默认仍会回放日志（会写盘），noload 才是真正的只读
  [[ $fstype == ext4 || $fstype == ext3 ]] && opts="ro,noload"
  if mount -o "$opts" "$dev" "$MNT" 2>>"$REPORT"; then
    MNT_OWN=1
    return 0
  fi
  rmdir "$MNT" 2>/dev/null
  MNT=""
  return 1
}
ro_umount() {
  if (( MNT_OWN )) && [[ -n $MNT ]]; then
    umount "$MNT" 2>/dev/null && rmdir "$MNT" 2>/dev/null
  fi
  MNT=""; MNT_OWN=0
}

# 不区分大小写地找路径：ci_path 根目录 一级 二级 ...（找到就输出完整路径）
ci_path() {
  local cur="$1" part next
  shift
  for part in "$@"; do
    next="$(find "$cur" -mindepth 1 -maxdepth 1 -iname "$part" -print -quit 2>/dev/null)"
    [[ -n $next ]] || return 1
    cur="$next"
  done
  printf '%s\n' "$cur"
}

# ---------------------------------------------------------------------
# 原来的系统还在不在（只读）：找 Windows、BitLocker、Linux 分区
# ---------------------------------------------------------------------
check_systems() {
  local ns="$1" p fstype psize label found=0
  while read -r p; do
    [[ -b $p ]] || continue
    case "$(pinfo "$p" PART_ENTRY_TYPE)" in
      [cC]12[aA]7328-*|0xef) continue ;;   # EFI 分区由 check_boot 单独检查
    esac
    fstype="$(pinfo "$p" TYPE)"
    psize="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
    case "$fstype" in
      BitLocker)
        warn "分区 $p 是 BitLocker 加密的 Windows 分区：数据在，但要恢复密钥才能打开"
        say "    （恢复密钥在另一台设备登录 account.microsoft.com/devices/recoverykey 查）"
        F_BITLOCKER=1; found=1 ;;
      ntfs)
        (( psize > 20 * 1024 * 1024 * 1024 )) || continue
        if ro_mount "$p" ntfs; then
          if ci_path "$MNT" Windows System32 config SYSTEM >/dev/null; then
            good "分区 $p 里有完整的 Windows 系统 → 原来的系统和资料大概率都还在"
            F_HASWIN=1; found=1
            WIN_PARTS+=("$p")
          else
            say "  分区 $p 是 NTFS 数据分区（里面没有 Windows 系统文件）"
          fi
          ro_umount
        else
          warn "分区 $p（NTFS）只读挂载失败，可能处于休眠/快速启动状态或文件系统损坏"
        fi ;;
      ext4|ext3|btrfs|xfs|f2fs)
        label="$(pinfo "$p" LABEL)"
        say "  分区 $p 是 Linux 分区（$fstype${label:+，卷标 $label}）"
        F_HASLINUX=1; found=1 ;;
    esac
  done < <(parts_of "$ns")
  (( found )) && SYSDISKS+=("$ns")
  return 0
}

# ---------------------------------------------------------------------
# 启动诊断（只读）：EFI 分区里有哪些启动文件，主板里有没有对应的启动项
# ---------------------------------------------------------------------
check_boot() {
  local ns="$1" name ptype esp partuuid partnum d base f rel ev nv
  local -a esps=()
  while read -r name; do
    ptype="$(pinfo "$name" PART_ENTRY_TYPE)"
    ptype="${ptype,,}"
    if [[ $ptype == c12a7328-f81f-11d2-ba4b-00a0c93ec93b || $ptype == 0xef ]]; then
      esps+=("$name")
      ESP_DEVS+=("$name")
    fi
  done < <(parts_of "$ns")

  say ""
  say "  启动检查："
  if (( ${#esps[@]} == 0 )); then
    warn "这块盘上没有 EFI 系统分区 → 主板没有东西可启动（分区被删了，或者分区表坏了）"
    F_NOESP=1
    return 0
  fi

  for esp in "${esps[@]}"; do
    partuuid="$(pinfo "$esp" PART_ENTRY_UUID)"
    partuuid="${partuuid,,}"
    partnum="$(pinfo "$esp" PART_ENTRY_NUMBER)"
    [[ -z $partnum ]] && partnum="$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)"
    say "  EFI 系统分区：$esp（分区号 ${partnum:-?}）"
    if ! ro_mount "$esp" vfat; then
      bad "EFI 分区 $esp 挂载不上 → 文件系统可能损坏，主板也读不了它"
      F_NOESP=1
      continue
    fi
    local fallback=0 found=0
    if f="$(ci_path "$MNT" EFI Microsoft Boot bootmgfw.efi)"; then
      rel="${f#"$MNT"}"; rel="${rel//\//\\}"
      LOADERS+=("win|$ns|$partnum|$partuuid|Windows Boot Manager|$rel")
      say "    找到 Windows 启动文件：$rel"
      found=1
    fi
    if ci_path "$MNT" EFI Boot bootx64.efi >/dev/null; then
      fallback=1
      say "    找到通用启动文件：\\EFI\\Boot\\bootx64.efi"
    fi
    while IFS= read -r d; do
      base="${d##*/}"
      [[ ${base,,} == boot || ${base,,} == microsoft ]] && continue
      f="$(ci_path "$d" shimx64.efi || ci_path "$d" grubx64.efi || ci_path "$d" systemd-bootx64.efi)" || continue
      rel="${f#"$MNT"}"; rel="${rel//\//\\}"
      LOADERS+=("linux|$ns|$partnum|$partuuid|$base|$rel")
      say "    找到 Linux 启动文件（$base）：$rel"
      found=1
    done < <(find "$(ci_path "$MNT" EFI || echo /nonexistent)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    ro_umount
    if (( ! found && ! fallback )); then
      bad "EFI 分区里一个启动文件都没有 → 这就是开机只能进 BIOS 的原因。Windows 还在的话，修复菜单 8 可以重建（不删数据）"
      F_NOESP=1
      continue
    fi

    # 主板 NVRAM 里的启动项
    if [[ ! -d $EFI_DIR ]]; then
      warn "这次 U 盘不是用 UEFI 方式启动的，看不到主板里的启动项"
      continue
    fi
    if ! have efibootmgr; then
      warn "没有 efibootmgr，看不到主板里的启动项"
      continue
    fi
    ev="$(efibootmgr -v 2>&1)"
    printf '\n$ efibootmgr -v\n%s\n' "$ev" >> "$REPORT"
    nv=0
    [[ -n $partuuid ]] && nv="$(grep -ciF "$partuuid" <<<"$ev")"
    if (( nv > 0 )); then
      good "主板里有 $nv 个启动项指向这块固态："
      grep -iF "$partuuid" <<<"$ev" | sed -E 's/[[:space:]]+HD\(.*//; s/^/    /' | while IFS= read -r f; do say "$f"; done
    elif (( fallback )); then
      warn "主板里没有指向这块固态的启动项，不过 EFI 里有通用启动文件，主板一般还能自己找到它"
      F_BOOTLOST=1
    else
      bad "主板里没有任何指向这块固态的启动项 → 这正是“开机直接进 BIOS”的原因"
      say "    系统文件还在，只是主板“忘了”从哪启动。用修复菜单 8 补回启动项（不删数据）。"
      F_BOOTLOST=1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------
# 检查一个 NVMe 控制器（如 nvme0）
# ---------------------------------------------------------------------
check_ctrl() {
  local name="$1" dev="/dev/$1" sys="$NVME_CLASS/$1"
  local model serial fw state
  model="$(cat "$sys/model" 2>/dev/null | trim)"
  serial="$(cat "$sys/serial" 2>/dev/null | trim)"
  fw="$(cat "$sys/firmware_rev" 2>/dev/null | trim)"
  state="$(cat "$sys/state" 2>/dev/null | trim)"

  say ""
  say "---- 控制器 $dev ----"
  say "  型号：${model:-未知}"
  say "  序列号：${serial:-未知}"
  say "  固件版本：${fw:-未知}"
  say "  控制器状态：${state:-未知}"

  if [[ -n $state && $state != live ]]; then
    bad "$dev 控制器状态是「$state」而不是 live → 主控没有正常工作"
    F_FW=1
  fi
  if [[ -z $model || $model =~ SATAFIRM || $model =~ FW.?ERR || $model =~ SAFE.?MODE ]]; then
    bad "$dev 型号显示为「${model:-空}」→ 固件很可能进入了安全模式（俗称掉固件）"
    F_FW=1
  elif [[ $model =~ ^(SM2[0-9]{3}|PS50[0-9]{2})([^0-9A-Za-z]|$) ]]; then
    warn "$dev 型号「$model」像是主控芯片代号。如果这不是你固态平时的型号名，说明固件可能处于安全模式"
  fi
  if [[ -z $serial || $serial =~ ^0+$ || ! $serial =~ ^[A-Za-z0-9._-]+$ ]]; then
    warn "$dev 序列号「${serial:-空}」不正常（空、全 0 或乱码）→ 很可能被改机器码工具改写过固件里的序列号"
    F_SERIAL=1
  else
    say "  （如果你记得改机器码之前固态的原始序列号，可以对比一下：不一致说明固件被写过。）"
  fi

  if have nvme; then
    rec "nvme id-ctrl $dev"
    local smart
    smart="$(nvme smart-log "$dev" 2>&1)"
    printf '\n$ nvme smart-log %s\n%s\n' "$dev" "$smart" >> "$REPORT"
    if grep -q 'critical_warning' <<<"$smart"; then
      local cw spare spth used merr nerr unsafe poh
      cw="$(getval "$smart" critical_warning)"
      spare="$(getval "$smart" available_spare)"
      spth="$(getval "$smart" available_spare_threshold)"
      used="$(getval "$smart" percentage_used)"
      merr="$(getval "$smart" media_errors)"
      nerr="$(getval "$smart" num_err_log_entries)"
      unsafe="$(getval "$smart" unsafe_shutdowns)"
      poh="$(getval "$smart" power_on_hours)"
      say "  健康信息：严重警告=${cw:-?}  剩余备用块=${spare:-?}%  寿命已用=${used:-?}%  介质错误=${merr:-?}"
      say "            错误日志条数=${nerr:-?}  异常断电次数=${unsafe:-?}  通电小时=${poh:-?}"
      if isnum "$cw"; then
        if (( cw == 0 )); then
          good "固态没有报告任何严重警告"
        else
          decode_cw "$cw"
          F_HEALTH=1
        fi
      fi
      if isnum "$merr" && (( merr > 0 )); then
        bad "有 $merr 次介质错误（读写出错的数据块）→ 先备份数据"
        F_HEALTH=1
      fi
      if isnum "$used" && (( used >= 100 )); then
        bad "寿命已用 ${used}%，已到设计寿命"
        F_HEALTH=1
      fi
      if isnum "$spare" && isnum "$spth" && (( spare < spth )); then
        bad "备用块 ${spare}% 低于阈值 ${spth}%"
        F_HEALTH=1
      fi
      if isnum "$unsafe" && (( unsafe > 0 )); then
        say "  （异常断电 $unsafe 次：卡死后强制关机就会记一次，单看这个不代表坏了）"
      fi
    else
      bad "$dev 读不出健康信息（SMART）：$(head -n1 <<<"$smart") → 主控没有正常响应命令"
      F_FW=1
    fi
    rec "nvme error-log $dev -e 8"
  else
    warn "没有 nvme 命令，跳过健康信息检测"
  fi
  have smartctl && rec "smartctl -a $dev"

  # --- 存储空间（命名空间）---
  local found=0 ns
  for ns in /dev/"$name"n*; do
    [[ -b $ns && $ns =~ ^/dev/${name}n[0-9]+$ ]] || continue
    found=1
    check_ns "$ns"
  done
  if (( found == 0 )); then
    bad "$dev 控制器在，但没有任何可用的存储空间（命名空间）→ 这就是“BIOS 看不到硬盘 / 容量 0”的典型表现，多为固件或映射表损坏"
    F_NONS=1
    if have nvme; then
      local all cntlid
      all="$(nvme list-ns "$dev" --all 2>/dev/null | trim)"
      printf '\n$ nvme list-ns %s --all\n%s\n' "$dev" "$all" >> "$REPORT"
      if [[ -n $all ]]; then
        cntlid="$(nvme id-ctrl "$dev" 2>/dev/null | awk -F: '/^cntlid/{gsub(/[ \t]/, "", $2); print $2; exit}')"
        warn "固态里其实还存在命名空间，只是没挂上。可以手动试（不删数据）："
        say "    nvme attach-ns $dev -n 1 -c ${cntlid:-<cntlid>} && nvme ns-rescan $dev"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------
# 全部检测
# ---------------------------------------------------------------------
run_checks() {
  PROBLEMS=()
  TARGETS=()
  LOADERS=()
  SYSDISKS=()
  WIN_PARTS=()
  ESP_DEVS=()
  F_NOCTRL=0; F_FW=0; F_NONS=0; F_RO=0; F_READ=0; F_HEALTH=0; F_SERIAL=0; F_PT=0; F_VMD=0
  F_HASWIN=0; F_HASLINUX=0; F_BITLOCKER=0; F_BOOTLOST=0; F_NOESP=0

  say ""
  say "NVMe 固态检测报告  $(date '+%Y-%m-%d %H:%M:%S')"
  say "内核：$(uname -r)"
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    say "机型：$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)  BIOS：$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
  fi

  # ---- 第 1 步 ----
  section "第 1 步：主板能不能在 PCIe 总线上看到固态（最底层）"
  if have lspci; then
    rec "lspci -nn"
    local pci_nvme pci_vmd l
    # 按 PCI 类别码判断，不依赖设备名称库（Live 系统里的名称库太旧时，VMD 只显示成 Device a77f）
    #   [0108] = NVMe 控制器    [0104] + Intel[8086] = VMD / RST RAID 控制器
    pci_nvme="$(lspci -D -nn 2>/dev/null | grep -E '\[0108\]')"
    pci_vmd="$(lspci -D -nn 2>/dev/null | grep -E '\[0104\]' | grep -iE '\[8086:[0-9a-f]{4}\]')"
    [[ -z $pci_vmd ]] && pci_vmd="$(lspci -D -nn 2>/dev/null | grep -i 'volume management device')"
    if [[ -n $pci_vmd ]]; then
      F_VMD=1
      warn "BIOS 里开着 Intel VMD（RST 模式）："
      say "    $pci_vmd"
      say "    Linux 能认，但 Windows 安装盘默认认不出 VMD 下面的固态 → 安装时“找不到驱动器”。"
    fi
    if [[ -n $pci_nvme ]]; then
      good "PCIe 上能看到 NVMe 固态控制器："
      while read -r l; do say "    $l"; done <<<"$pci_nvme"
    elif [[ -n $pci_vmd ]]; then
      warn "PCIe 上没直接看到 NVMe（可能藏在 VMD 后面），以第 3 步结果为准"
    else
      bad "PCIe 总线上完全看不到 NVMe 固态 → 不是系统或分区问题，是硬件层面（接触、插槽、或主控已无响应）"
      F_NOCTRL=1
    fi
  else
    warn "没有 lspci，跳过这一步"
  fi

  # ---- 第 2 步 ----
  section "第 2 步：内核日志里有没有固态报错"
  local klog hard soft
  klog="$(dmesg 2>/dev/null | grep -iE 'nvme|vmd' | tail -n 80)"
  [[ -z $klog ]] && klog="$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'nvme|vmd' | tail -n 80)"
  printf '\n$ dmesg | grep -iE "nvme|vmd"\n%s\n' "$klog" >> "$REPORT"
  hard="$(grep -iE 'timeout|controller is down|not ready|probe fail|removing after|i/o error|resetting controller|frozen|disabling device' <<<"$klog" | tail -n 12)"
  soft="$(grep -iE 'failed|error' <<<"$klog" | grep -viE 'timeout|controller is down|not ready|probe fail|removing after|i/o error' | tail -n 6)"
  if [[ -n $hard ]]; then
    bad "内核日志里有固态通讯错误（超时 / 复位 / 探测失败）："
    while read -r l; do say "    $l"; done <<<"$hard"
  elif [[ -n $soft ]]; then
    warn "内核日志里有一些报错（不一定严重）："
    while read -r l; do say "    $l"; done <<<"$soft"
  elif [[ -z $klog ]]; then
    warn "内核日志里完全没有 nvme 相关信息（可能根本没检测到固态）"
  else
    good "内核日志里没有明显的固态报错"
  fi

  # ---- 第 3 步 ----
  section "第 3 步：固态自身信息（型号 / 序列号 / 固件 / 健康度 / 读测试 / 分区表）"
  modprobe vmd >/dev/null 2>&1
  modprobe nvme >/dev/null 2>&1
  local c ctrls=()
  for c in "$NVME_CLASS"/nvme*; do
    [[ -e $c ]] || continue
    c="${c##*/}"
    [[ $c =~ ^nvme[0-9]+$ ]] && ctrls+=("$c")
  done
  if (( ${#ctrls[@]} == 0 )); then
    bad "系统里没有任何 NVMe 固态被驱动识别"
    F_NOCTRL=1
  else
    have nvme && rec "nvme list"
    for c in "${ctrls[@]}"; do check_ctrl "$c"; done
  fi

  summary
}

# ---------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------
summary() {
  section "结论"
  if (( F_NOCTRL )); then
    bad "电脑根本没认到固态（硬件层）。"
    say "  建议按顺序试："
    say "   1) 拔掉电源适配器，长按开机键 40 秒放电，再开机重新运行本脚本；"
    say "   2) 如果 BIOS 开着 VMD，先关掉 VMD 再运行一次；"
    say "   3) 断电后拆后盖，把固态拔下来重新插紧（有两个 M.2 槽的话换另一个槽试）；"
    say "   4) 把固态装进 M.2 硬盘盒，接到别的电脑上看认不认；"
    say "   5) 都不认 = 固态主控/固件已不响应，找固态厂商或电脑厂商售后（要数据就找专业数据恢复）。"
  elif (( F_NONS || F_FW )); then
    bad "固态能被认到，但固件/内部状态异常（掉固件、容量 0 或不响应命令）。"
    say "  这种情况重装系统、改分区都没用。建议：断电放电后重试；在另一台电脑上用固态厂商的官方工具"
    say "  检查/刷固件；或直接走售后。改机器码工具改写固态固件里的序列号，就可能造成这种结果。"
  elif (( F_RO || F_READ || F_HEALTH )); then
    bad "固态硬件有健康问题（只读保护 / 读错误 / 严重警告）。"
    say "  先用修复菜单 3 把整盘镜像备份到移动硬盘，再联系售后。不建议继续往这块盘装系统。"
  else
    good "固态本身是好的：能识别、能正常读取、健康信息无异常。"
    say "  → 不要数据、想直接全新安装：从 Windows 安装 U 盘启动，在安装界面按 Shift+F10，"
    say "    输入 D:\\fix（D 换成 U 盘盘符），选 1 一键清空并准备安装。"
    if (( F_HASWIN || F_HASLINUX )); then
      say "  → 原来的系统还在。想保留它的话，按下面的提示修（不删数据）。"
    fi
    if (( F_BOOTLOST )); then
      say "  → “开机直接进 BIOS”的原因：主板里指向这块固态的启动项丢了。"
      say "    用修复菜单 8 补回启动项（不删数据）；或者在 Windows 安装环境里运行 fix_win.cmd 选 4。"
    fi
    if (( F_NOESP )); then
      if (( F_HASWIN )); then
        say "  → EFI 分区里的启动文件没了。Windows 还在，用修复菜单 8 就能从 Windows 分区把启动文件重建回来，"
        say "    不删数据、不需要安装 U 盘。"
      else
        say "  → EFI 启动分区缺失或损坏，也没找到能用来重建的 Windows，只能重装系统。"
      fi
    fi
    if (( F_BITLOCKER )); then
      say "  → Windows 分区开了 BitLocker：数据在，但修复/备份前要先准备好恢复密钥。"
    fi
    if (( F_VMD )); then
      say "  → Windows 安装盘看不到这块固态的原因是 VMD："
      say "    打算全新安装 → BIOS 里关掉 VMD；想保留原来的系统 → 别关，在安装界面运行 fix_win.cmd 选 3 加载驱动。"
    fi
    if (( F_PT )); then
      say "  → 分区表是 MBR / 损坏 / 空的，Windows 安装时可能报错。修复菜单 5 可清空成空白 GPT（会删数据）；"
      say "    想保数据就先用菜单 3 备份，或用菜单 4（testdisk）尝试找回分区。"
    fi
    if (( ! F_VMD && ! F_PT && ! F_BOOTLOST && ! F_NOESP )); then
      say "  → 固态、分区表、启动项都正常。Windows 还装不上的话，在安装界面运行 fix_win.cmd，"
      say "    选 8 保存安装日志，把 U 盘里的 setup_logs 文件夹发给帮你排查的人。"
    fi
  fi
  if (( F_SERIAL )); then
    warn "序列号异常：这块固态的固件信息被改过，以后再出问题优先考虑这个原因。"
  fi
  if (( ${#PROBLEMS[@]} )); then
    local p
    say ""
    say "发现的问题汇总："
    for p in "${PROBLEMS[@]}"; do say "  - $p"; done
  fi
  say ""
  say "完整报告已保存：$REPORT"
  say "（把这个文件发给帮你排查的人，信息最全）"
}

# ---------------------------------------------------------------------
# 修复菜单里的各项
# ---------------------------------------------------------------------
TGT=""
pick_target() {
  TGT=""
  if (( ${#TARGETS[@]} == 0 )); then
    warn "没有可操作的固态存储空间（检测里没有找到能正常读取的 NVMe 盘）"
    return 1
  fi
  if (( ${#TARGETS[@]} == 1 )); then
    TGT="${TARGETS[0]}"
    say "目标磁盘：$TGT  $(lsblk -dno SIZE,MODEL "$TGT" 2>/dev/null)"
    return 0
  fi
  local i n
  for i in "${!TARGETS[@]}"; do
    echo "  $((i + 1))) ${TARGETS[$i]}  $(lsblk -dno SIZE,MODEL "${TARGETS[$i]}" 2>/dev/null)"
  done
  read -rp "选择哪块盘（输入序号）：" n
  if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#TARGETS[@]} )); then
    TGT="${TARGETS[$((n - 1))]}"
    return 0
  fi
  warn "输入无效"
  return 1
}

# 把磁盘开头和末尾各 1 MB（包含 MBR/GPT 主副分区表）保存下来
save_edges() {
  local t="$1" bn="${1##*/}" size
  size="$(blockdev --getsize64 "$t")"
  if dd if="$t" of="$SAVE_DIR/${bn}_head_1MB_$STAMP.bin" bs=1M count=1 iflag=direct status=none &&
     dd if="$t" of="$SAVE_DIR/${bn}_tail_1MB_$STAMP.bin" bs=1M skip=$(( size / 1048576 - 1 )) count=1 iflag=direct status=none; then
    good "已把 $t 开头和末尾各 1 MB（含分区表）保存到 $SAVE_DIR"
    [[ $SAVE_DIR == /tmp ]] && warn "注意：保存在 /tmp，重启就没了，请复制到 U 盘或移动硬盘"
  else
    warn "保存分区表区域失败"
  fi
}

do_backup_pt() {
  pick_target || return
  save_edges "$TGT"
  if have sgdisk && [[ "$(pttype "$TGT")" == gpt ]]; then
    local f="$SAVE_DIR/${TGT##*/}_gpt_$STAMP.sgdisk"
    if sgdisk --backup="$f" "$TGT" >> "$REPORT" 2>&1; then
      good "GPT 分区表备份：$f"
      say "    需要恢复时：sgdisk --load-backup=$f $TGT"
    fi
  fi
}

do_reset() {
  local c dev
  for c in "$NVME_CLASS"/nvme*; do
    [[ -e $c ]] || continue
    dev="/dev/${c##*/}"
    if have nvme; then
      say "复位 $dev ……"
      if nvme reset "$dev" >> "$REPORT" 2>&1; then good "$dev 复位完成"; else warn "$dev 复位失败"; fi
    fi
  done
  say "重新扫描 PCIe 总线……"
  echo 1 > /sys/bus/pci/rescan 2>/dev/null
  sleep 3
  run_checks
}

do_image() {
  pick_target || return
  local need dest src fstype avail img
  need="$(blockdev --getsize64 "$TGT")"
  say "请先接上一块空间 ≥ $(human "$need") 的移动硬盘（NTFS / exFAT / ext4，不能是 FAT32）并挂载好。"
  say "当前已挂载的磁盘："
  df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | sed 's/^/    /'
  read -rp "输入保存镜像的目录（例如 /mnt/backup），直接回车取消：" dest
  [[ -z $dest ]] && return
  if [[ ! -d $dest ]]; then warn "目录不存在：$dest"; return; fi
  src="$(df --output=source "$dest" 2>/dev/null | tail -n1 | trim)"
  fstype="$(df --output=fstype "$dest" 2>/dev/null | tail -n1 | trim)"
  avail="$(df --output=avail -B1 "$dest" 2>/dev/null | tail -n1 | trim)"
  if [[ $src == "$TGT"* ]]; then bad "不能把镜像存到这块固态自己身上"; return; fi
  if [[ $fstype == vfat || $fstype == msdos ]]; then warn "FAT32 存不了超过 4GB 的文件，请换 NTFS / exFAT / ext4"; return; fi
  if isnum "$avail" && (( avail < need )); then warn "空间不够：需要 $(human "$need")，只有 $(human "$avail")"; return; fi
  img="$dest/${TGT##*/}_$STAMP.img"
  say "开始镜像 $TGT → $img（只读固态，时间取决于容量，耐心等）"
  if have ddrescue; then
    ddrescue -d -r1 "$TGT" "$img" "$img.map"
  else
    warn "没有 ddrescue，改用 dd（遇到坏块会补零继续）"
    dd if="$TGT" of="$img" bs=4M conv=noerror,sync iflag=direct status=progress
  fi
  sync
  good "镜像完成：$img"
}

do_testdisk() {
  pick_target || return
  if ! have testdisk; then
    warn "没有 testdisk（SystemRescue 自带；Ubuntu 可以 apt install testdisk）"
    return
  fi
  say "即将打开 testdisk。一般步骤：[Proceed] → [EFI GPT] → [Analyse] → [Quick Search]，"
  say "找到原来的分区后选 [Write] 写回分区表。不确定就别按 Write，直接 Quit。"
  read -rp "按回车继续……" _
  ( cd "$SAVE_DIR" && testdisk /log "$TGT" )
}

do_wipe() {
  pick_target || return
  echo
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$TGT"
  echo
  printf '%s%s%s\n' "$C_R" "!!! 这会清空 $TGT 的分区表：原来的 Windows / Linux 双系统和所有文件都会丢失（除非你先做了镜像）!!!" "$C_N"
  local a b d
  for d in "${SYSDISKS[@]}"; do
    if [[ $d == "$TGT" ]]; then
      printf '%s%s%s\n' "$C_Y" "【注意】检测发现这块盘上还有原来的系统（见上面的检测结果）。只是进不去系统的话，" "$C_N"
      printf '%s%s%s\n' "$C_Y" "        先试菜单 8 修复启动项，或者 Windows 安装环境里 fix_win.cmd 的选项 4。" "$C_N"
      break
    fi
  done
  # 只有一块盘可选时不用再输设备名，只要 YES
  if (( ${#TARGETS[@]} > 1 )); then
    read -rp "确认的话，请完整输入设备名（$TGT）：" a
    if [[ $a != "$TGT" ]]; then say "不一致，已取消。"; return; fi
  fi
  read -rp "确认清空 $TGT 请输入大写 YES：" b
  if [[ $b != YES ]]; then say "已取消。"; return; fi

  release_disk "$TGT" || return
  save_edges "$TGT"
  if make_empty_gpt "$TGT"; then
    good "$TGT 已经是空白 GPT 盘。回到 Windows 安装，选“未分配的空间”→ 下一步 即可。"
    if (( F_VMD )); then
      warn "别忘了：VMD 还开着。装 Windows 前要么在 BIOS 关掉 VMD，要么在安装界面加载 RST 驱动。"
    fi
  else
    bad "清空后没检测到新的 GPT，写入可能失败（固态可能处于只读保护），详见报告"
  fi
}

# Live 系统可能自动挂载了这块盘上的分区：按设备名卸载（挂载路径里可能有空格），关掉 swap
release_disk() {
  local t="$1" m s
  while read -r m; do
    [[ -n $m ]] || continue
    if ! umount "$m" 2>>"$REPORT"; then
      bad "卸载 $m 失败，已取消。关掉正在使用这块盘的窗口/程序后再试。"
      return 1
    fi
  done < <(findmnt -rno SOURCE | awk -v t="$t" 'index($1, t) == 1')
  while read -r s; do
    [[ -n $s ]] && swapoff "$s" 2>/dev/null
  done < <(awk -v t="$t" 'index($1, t) == 1 {print $1}' /proc/swaps)
  return 0
}

# 清掉分区表，写一个空白 GPT。成功的标志：是 GPT，而且磁盘 GUID 变了（新写的表才会换 GUID）
make_empty_gpt() {
  local t="$1" before after
  before="$(blkid -p -o value -s PTUUID "$t" 2>/dev/null)"
  wipefs -a "$t" >> "$REPORT" 2>&1
  if have sgdisk; then
    sgdisk --zap-all "$t" >> "$REPORT" 2>&1
    sgdisk -o "$t" >> "$REPORT" 2>&1
  elif have parted; then
    parted -s "$t" mklabel gpt >> "$REPORT" 2>&1
  elif have sfdisk; then
    printf 'label: gpt\n' | sfdisk --wipe always "$t" >> "$REPORT" 2>&1
  else
    bad "没有 sgdisk / parted / sfdisk，无法新建 GPT"
    return 1
  fi
  partprobe "$t" 2>/dev/null
  blockdev --rereadpt "$t" 2>/dev/null
  after="$(blkid -p -o value -s PTUUID "$t" 2>/dev/null)"
  [[ "$(pttype "$t")" == gpt && -n $after && $after != "$before" ]]
}

# 7) 固态自检（固态自己做的内部检查，不改动数据）
#    不带参数：所有 NVMe 都做；带参数（如 /dev/nvme0）：只做这一块。结果放在 ST_RESULT（pass/fail/na）
ST_RESULT=na
do_selftest() {
  ST_RESULT=na
  if ! have smartctl; then
    warn "没有 smartctl（SystemRescue 自带；Ubuntu 可以 apt install smartmontools）"
    return
  fi
  local c dev out st first i done_ok
  local -a devs=()
  if [[ -n ${1:-} ]]; then
    devs=("$1")
  else
    for c in "$NVME_CLASS"/nvme*; do [[ -e $c ]] && devs+=("/dev/${c##*/}"); done
  fi
  for dev in "${devs[@]}"; do
    say ""
    say "对 $dev 启动短自检（一般 1~3 分钟，期间不要关机；不会改动数据）……"
    out="$(smartctl -t short "$dev" 2>&1)"
    printf '\n$ smartctl -t short %s\n%s\n' "$dev" "$out" >> "$REPORT"
    if ! grep -qi 'Self-test has begun' <<<"$out"; then
      warn "$dev 没能启动自检（固态不支持，或 smartctl 版本太旧，需要 7.3 以上）："
      grep -iE 'fail|support|error|abort|can.t|unknown' <<<"$out" | head -n 3 | sed 's/^/    /'
      continue
    fi
    done_ok=0
    for (( i = 0; i < SELFTEST_POLLS; i++ )); do
      sleep "$SELFTEST_SLEEP"
      st="$(smartctl -l selftest "$dev" 2>&1)"
      if grep -qi 'No self-test in progress' <<<"$st"; then
        done_ok=1
        break
      fi
      printf '\r  自检进行中：%s   ' "$(grep -oiE '[0-9]+% completed' <<<"$st" | head -n1)"
    done
    printf '\r%*s\r' 40 ''
    printf '\n$ smartctl -l selftest %s\n%s\n' "$dev" "$st" >> "$REPORT"
    if (( ! done_ok )); then
      warn "等了 $(( SELFTEST_POLLS * SELFTEST_SLEEP / 60 )) 分钟自检还没结束，稍后选 7 再看一次，或看报告"
      continue
    fi
    first="$(awk '/^Num[[:space:]]+Test_Description/ { getline; print; exit }' <<<"$st")"
    say "  最近一次自检记录：${first:-（读不到）}"
    if grep -qi 'Completed without error' <<<"$first"; then
      good "$dev 自检通过：固态自己没有发现任何问题"
      ST_RESULT=pass
    elif [[ -n $first ]]; then
      bad "$dev 自检没有通过（见上面那一行）→ 先用菜单 3 备份数据，再找售后"
      ST_RESULT=fail
    else
      warn "没读到自检结果，详见报告"
    fi
  done
}

# =====================================================================
# 9) 深度修复固态（会清空固态全部数据）
#    1 复位主控（不行就让主板重新识别）  2 容量为 0 时找回 / 重建存储空间
#    3 NVMe Format 安全擦除，重置固态内部映射表  4 多处写入 + 读回校验
#    5 固态自检  6 写空白 GPT，Windows 安装程序可以直接用
# =====================================================================
DR_REGIONS="${DR_REGIONS:-16}"     # 写读校验的位置数
DR_CHUNK_MB="${DR_CHUNK_MB:-64}"   # 每处写多少 MB
DR_NAME=""

ctrl_attr() { cat "$NVME_CLASS/$1/$2" 2>/dev/null | trim; }
nv() { LC_ALL=C nvme "$@"; }
# 从 nvme id-ctrl 之类的输出里取字段原值（去掉空格和千位逗号）
idval() {
  awk -F: -v k="$2" '{ key=$1; gsub(/[ \t]/, "", key) } key == k { v=$2; gsub(/[ \t,]/, "", v); print v; exit }' <<<"$1"
}
# 控制器名（nvme0）→ 第一个容量不为 0 的存储空间（/dev/nvme0n1）
first_ns() {
  local ns sz
  for ns in /dev/"$1"n*; do
    [[ -b $ns && $ns =~ ^/dev/$1n[0-9]+$ ]] || continue
    sz="$(blockdev --getsize64 "$ns" 2>/dev/null || echo 0)"
    if [[ $sz =~ ^[0-9]+$ ]] && (( sz > 0 )); then
      printf '%s\n' "$ns"
      return 0
    fi
  done
  return 1
}

# 控制器名 → 存在但容量为 0 的存储空间（常见于固态被设成了内核不支持的扇区格式）
zero_ns() {
  local ns sz
  for ns in /dev/"$1"n*; do
    [[ -b $ns && $ns =~ ^/dev/$1n[0-9]+$ ]] || continue
    sz="$(blockdev --getsize64 "$ns" 2>/dev/null || echo 0)"
    if [[ ! $sz =~ ^[0-9]+$ ]] || (( sz == 0 )); then
      printf '%s\n' "$ns"
      return 0
    fi
  done
  return 1
}

# 按 PCI 地址找控制器名
ctrl_by_bdf() {
  local c
  for c in "$NVME_CLASS"/nvme*; do
    [[ -e $c ]] || continue
    if [[ "$(readlink -f "$c/device" 2>/dev/null)" == */"$1" ]]; then
      printf '%s\n' "${c##*/}"
      return 0
    fi
  done
  return 1
}

# 把控制器从 PCI 上摘掉再重新扫描，相当于给它单独断电重插。
# 参数是 PCI 地址（复位前记下来的，控制器挂掉后 sysfs 里就查不到了）。成功后新名字在 DR_NAME
pci_reenum() {
  local bdf="$1" i j c
  [[ -n $bdf ]] || return 1
  if [[ -e /sys/bus/pci/devices/$bdf/remove ]]; then
    echo 1 > "/sys/bus/pci/devices/$bdf/remove" 2>>"$REPORT"
    sleep 2
  fi
  echo 1 > /sys/bus/pci/rescan 2>>"$REPORT"
  for (( i = 0; i < 20; i++ )); do
    sleep 1
    c="$(ctrl_by_bdf "$bdf")" || continue
    if [[ "$(ctrl_attr "$c" state)" == live ]]; then
      DR_NAME="$c"
      # 再等几秒让存储空间扫描出来
      for (( j = 0; j < 10; j++ )); do first_ns "$c" >/dev/null && break; sleep 1; done
      return 0
    fi
  done
  return 1
}

# 释放 LVM / 软 RAID / 加密盘 对这块盘的占用（不然格式化会因为“设备忙”失败）
release_holders() {
  local bn="${1##*/}" h
  have vgchange && vgchange -an >> "$REPORT" 2>&1
  have mdadm && mdadm --stop --scan >> "$REPORT" 2>&1
  for h in /sys/block/"$bn"/holders/* /sys/block/"$bn"/"$bn"*/holders/*; do
    [[ -e $h ]] || continue
    have dmsetup && dmsetup remove -f "/dev/${h##*/}" >> "$REPORT" 2>&1
  done
}

# 存储空间在但容量是 0：换成标准扇区格式（无元数据、优先 512 字节）重新格式化它
fix_zero_ns() {
  local dev="$1" zns="$2" nsid idns idx out
  nsid="$(cat "/sys/block/${zns##*/}/nsid" 2>/dev/null | trim)"
  [[ $nsid =~ ^[0-9]+$ ]] || nsid="${zns##*n}"
  idns="$(nv id-ns "$dev" -n "$nsid" 2>&1)"
  printf '\n$ nvme id-ns %s -n %s\n%s\n' "$dev" "$nsid" "$idns" >> "$REPORT"
  idx="$(awk '$1 == "lbaf" && / ms:0[^0-9]/ && /lbads:9[^0-9]/ { print $2; exit }' <<<"$idns")"
  [[ -z $idx ]] && idx="$(awk '$1 == "lbaf" && / ms:0[^0-9]/ && /lbads:12[^0-9]/ { print $2; exit }' <<<"$idns")"
  [[ $idx =~ ^[0-9]+$ ]] || idx=0
  say "  存储空间 $zns 容量显示为 0，换成标准扇区格式（格式 $idx）重新格式化……"
  out="$(nv format "$dev" -n "$nsid" --lbaf="$idx" --ses=1 --force 2>&1)"
  grep -q 'Success formatting' <<<"$out" || out="$(nv format "$dev" -n "$nsid" --lbaf="$idx" --ses=0 --force 2>&1)"
  printf '\n$ nvme format %s -n %s --lbaf=%s\n%s\n' "$dev" "$nsid" "$idx" "$out" >> "$REPORT"
  nv ns-rescan "$dev" >> "$REPORT" 2>&1
  sleep 3
  if first_ns "${dev##*/}" >/dev/null; then
    good "存储空间恢复了正常容量"
    return 0
  fi
  return 1
}

# 存储空间丢了（容量 0 / 看不到 nvme0n1）：先试着挂回已有的，不行再按总容量重建一个
fix_namespace() {
  local dev="$1" name="${1##*/}" idc oacs tnvmcap unvmcap cap all id out nsid blocks lbads lbsz
  idc="$(nv id-ctrl "$dev" 2>&1)"
  printf '\n$ nvme id-ctrl %s\n%s\n' "$dev" "$idc" >> "$REPORT"
  oacs="$(idval "$idc" oacs)"
  tnvmcap="$(idval "$idc" tnvmcap)"
  unvmcap="$(idval "$idc" unvmcap)"
  all="$(nv list-ns "$dev" --all 2>>"$REPORT" | sed -nE 's/^\[ *[0-9]+\]:(0x[0-9a-fA-F]+).*/\1/p')"
  if [[ -n $all ]]; then
    say "  固态里还有存储空间，只是没挂上，试着挂回去……"
    for id in $all; do
      nv attach-ns "$dev" -n "$id" >> "$REPORT" 2>&1
    done
    nv ns-rescan "$dev" >> "$REPORT" 2>&1
    sleep 2
    if first_ns "$name" >/dev/null; then
      good "已经把存储空间挂回来了"
      return 0
    fi
  fi
  if ! isnum "$oacs" || (( (oacs & 8) == 0 )); then
    bad "这块固态不支持重建存储空间（没有命名空间管理功能）"
    return 1
  fi
  # 优先用“未分配容量”，读不到再用总容量
  cap=0
  isnum "$unvmcap" && cap=$(( unvmcap ))
  if (( cap <= 0 )) && isnum "$tnvmcap"; then cap=$(( tnvmcap )); fi
  if (( cap <= 0 )); then
    bad "读不到固态的可用容量，没法重建存储空间"
    return 1
  fi
  # 格式 0 的扇区大小（一般 512 字节）
  lbads="$(nv id-ns "$dev" -n 0xffffffff 2>/dev/null | awk '$1 == "lbaf" && $2 == "0" { for (i = 1; i <= NF; i++) if ($i ~ /^lbads:/) { sub(/lbads:/, "", $i); print $i; exit } }')"
  if ! [[ $lbads =~ ^[0-9]+$ ]] || (( lbads < 9 || lbads > 16 )); then lbads=9; fi
  lbsz=$(( 1 << lbads ))
  blocks=$(( cap / lbsz ))
  say "  按可用容量 $(human "$cap") 重建存储空间……"
  out="$(nv create-ns "$dev" --nsze="$blocks" --ncap="$blocks" --flbas=0 2>&1)"
  printf '\n$ nvme create-ns\n%s\n' "$out" >> "$REPORT"
  nsid="$(sed -nE 's/^nsid[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$out" | head -n1)"
  nv attach-ns "$dev" -n "${nsid:-1}" >> "$REPORT" 2>&1
  nv ns-rescan "$dev" >> "$REPORT" 2>&1
  sleep 2
  if first_ns "$name" >/dev/null; then
    good "存储空间已重建"
    return 0
  fi
  bad "重建存储空间失败"
  return 1
}

# 在全盘均匀分布的若干处各写一段随机数据，绕过缓存读回来逐段比对（会覆盖这些位置的数据）
write_verify() {
  local t="$1" size total_mb n="$DR_REGIONS" chunk="$DR_CHUNK_MB" i off pat got nfail=0 failed_at=""
  local -a offs=() sums=()
  size="$(blockdev --getsize64 "$t" 2>/dev/null || echo 0)"
  total_mb=$(( size / 1048576 ))
  (( total_mb / chunk < n )) && n=$(( total_mb / chunk ))
  (( n >= 2 )) || n=2
  if (( total_mb <= chunk * 2 )); then
    bad "容量太小（$(human "$size")），没法做写读校验"
    return 1
  fi
  pat="$(mktemp /tmp/ssdpat.XXXXXX)"
  for (( i = 0; i < n; i++ )); do
    off=$(( (total_mb - chunk) * i / (n - 1) ))
    offs+=("$off")
    printf '\r  写入 %d/%d ' "$(( i + 1 ))" "$n"
    head -c $(( chunk * 1048576 )) /dev/urandom > "$pat"
    sums+=("$(md5sum < "$pat" | cut -d' ' -f1)")
    if ! dd if="$pat" of="$t" bs=1M seek="$off" count="$chunk" oflag=direct conv=fsync status=none 2>>"$REPORT"; then
      nfail=$(( nfail + 1 ))
      failed_at+=" 写@$(( off / 1024 ))GB"
    fi
  done
  rm -f "$pat"
  blockdev --flushbufs "$t" 2>/dev/null
  for (( i = 0; i < n; i++ )); do
    printf '\r  读回比对 %d/%d ' "$(( i + 1 ))" "$n"
    got="$(dd if="$t" bs=1M skip="${offs[$i]}" count="$chunk" iflag=direct status=none 2>>"$REPORT" | md5sum | cut -d' ' -f1)"
    if [[ $got != "${sums[$i]}" ]]; then
      nfail=$(( nfail + 1 ))
      failed_at+=" 读@$(( offs[i] / 1024 ))GB"
    fi
  done
  printf '\r%*s\r' 40 ''
  if (( nfail == 0 )); then
    good "全盘 $n 处、每处 ${chunk} MB 写入后读回完全一致"
    return 0
  fi
  failed_at="$(tr ' ' '\n' <<<"${failed_at# }" | head -n 6 | paste -sd' ' -)"
  bad "写读校验有 $nfail 处出错（例如：$failed_at）"
  return 1
}

do_deep_repair() {
  if ! have nvme; then
    warn "没有 nvme 命令（SystemRescue 自带；Ubuntu 可以 apt install nvme-cli）"
    return
  fi
  local -a ctrls=()
  local c name dev ns zns model serial size ans n ok=1 state smart cw bdf bootsrc out i
  for c in "$NVME_CLASS"/nvme*; do
    [[ -e $c ]] || continue
    c="${c##*/}"
    [[ $c =~ ^nvme[0-9]+$ ]] && ctrls+=("$c")
  done
  if (( ${#ctrls[@]} == 0 )); then
    bad "系统里一块 NVMe 固态都没有，没法深度修复。"
    say "  说明主板根本没连上固态（硬件层）：断电放电、拆后盖重新插紧固态、换另一个 M.2 槽后再试；"
    say "  还是没有就是主控坏了，软件修不了，找售后。"
    return
  fi
  if (( ${#ctrls[@]} == 1 )); then
    name="${ctrls[0]}"
  else
    say "找到多块 NVMe 固态："
    for n in "${!ctrls[@]}"; do
      say "  $(( n + 1 ))) /dev/${ctrls[$n]}  $(ctrl_attr "${ctrls[$n]}" model)"
    done
    read -rp "要修哪一块（输入序号）：" ans
    if ! [[ $ans =~ ^[0-9]+$ ]] || (( ans < 1 || ans > ${#ctrls[@]} )); then
      say "已取消。"
      return
    fi
    name="${ctrls[$(( ans - 1 ))]}"
  fi
  dev="/dev/$name"
  model="$(ctrl_attr "$name" model)"
  serial="$(ctrl_attr "$name" serial)"
  bdf="$(readlink -f "$NVME_CLASS/$name/device" 2>/dev/null)"
  bdf="${bdf##*/}"
  ns="$(first_ns "$name")"
  # 修复盘自己如果是 NVMe（雷电硬盘盒），绝不能动它
  bootsrc="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)"
  if [[ -n $bootsrc && $bootsrc == "/dev/$name"* ]]; then
    bad "$dev 是修复盘本身所在的盘，拒绝修复它。"
    return
  fi
  size=""
  [[ -n $ns ]] && size="$(human "$(blockdev --getsize64 "$ns")")"

  section "深度修复固态"
  say "  固态：$dev   型号 ${model:-未知}   序列号 ${serial:-未知}   容量 ${size:-读不到（存储空间丢了）}"
  say "  会依次做：复位主控 → 找回/重建存储空间 → 安全擦除重置内部映射表"
  say "            → 全盘写入读回校验 → 固态自检 → 写空白分区表。一般 3~10 分钟。"
  printf '%s%s%s\n' "$C_R" "  !!! 固态上的所有数据都会被永久清除，没法恢复 !!!" "$C_N"
  read -rp "确认开始请输入大写 YES：" ans
  if [[ $ans != YES ]]; then
    say "已取消，没有做任何修改。"
    return
  fi
  printf '\n[深度修复] 用户确认：%s %s %s\n' "$dev" "$model" "$serial" >> "$REPORT"

  # 1 复位
  say ""
  say "[1/6] 复位固态主控……"
  if nv reset "$dev" >> "$REPORT" 2>&1; then
    good "主控复位完成"
  else
    warn "复位命令没成功（有的固态不支持），继续"
  fi
  state=""
  for (( i = 0; i < 10; i++ )); do
    sleep 1
    if [[ ! -e $NVME_CLASS/$name ]]; then state="消失"; break; fi
    state="$(ctrl_attr "$name" state)"
    [[ $state == live ]] && break
  done
  if [[ $state != live ]]; then
    warn "主控状态是「${state:-未知}」，让主板重新识别它……"
    if pci_reenum "$bdf"; then
      name="$DR_NAME"
      dev="/dev/$name"
      good "重新识别成功：$dev"
    else
      bad "主控重新识别失败 → 硬件或固件问题，软件修不了"
      dr_verdict 0 "$model"
      return
    fi
  fi

  # 2 存储空间
  say "[2/6] 检查存储空间……"
  ns="$(first_ns "$name")"
  zns="$(zero_ns "$name")"
  if [[ -n $ns ]]; then
    good "存储空间正常：$ns，$(human "$(blockdev --getsize64 "$ns")")"
  elif [[ -n $zns ]] && fix_zero_ns "$dev" "$zns"; then
    ns="$(first_ns "$name")"
  elif fix_namespace "$dev"; then
    ns="$(first_ns "$name")"
  else
    dr_verdict 0 "$model"
    return
  fi
  if [[ -z $ns || ! -b $ns ]]; then
    dr_verdict 0 "$model"
    return
  fi
  release_holders "$ns"
  if ! release_disk "$ns"; then
    dr_verdict 2 "$model"
    return
  fi

  # 3 安全擦除
  say "[3/6] 安全擦除，重置固态内部映射表（一般几秒到几分钟，期间不要关机）……"
  out="$(nv format "$ns" --ses=1 --force 2>&1)"
  printf '\n$ nvme format %s --ses=1\n%s\n' "$ns" "$out" >> "$REPORT"
  if grep -q 'Success formatting' <<<"$out"; then
    good "安全擦除完成"
  else
    out+=$'\n'"$(nv format "$ns" --ses=0 --force 2>&1)"
    printf '%s\n' "$out" >> "$REPORT"
    if grep -q 'Success formatting' <<<"$out"; then
      good "格式化完成（这块固态不支持安全擦除，用的是普通格式化，同样会重置映射表）"
    elif grep -qi 'busy' <<<"$out"; then
      dr_verdict 2 "$model"
      return
    else
      bad "固态拒绝了格式化命令（可能处于只读保护或固件异常），继续检查读写"
      ok=0
    fi
  fi
  nv ns-rescan "$dev" >> "$REPORT" 2>&1
  blockdev --rereadpt "$ns" 2>/dev/null
  sleep 2

  # 4 写读校验
  say "[4/6] 全盘写入 + 读回校验……"
  write_verify "$ns" || ok=0

  # 5 自检
  say "[5/6] 固态自检……"
  do_selftest "$dev"
  [[ $ST_RESULT == fail ]] && ok=0

  # 6 空白分区表
  say "[6/6] 写入空白 GPT 分区表……"
  if make_empty_gpt "$ns"; then
    good "分区表已写好，Windows 安装程序可以直接用"
  else
    bad "写分区表失败"
    ok=0
  fi

  # 修完再看一眼健康信息：只读保护 / 可靠性下降都算没修好
  smart="$(nv smart-log "$dev" 2>&1)"
  printf '\n$ nvme smart-log %s（修复后）\n%s\n' "$dev" "$smart" >> "$REPORT"
  cw="$(getval "$smart" critical_warning)"
  if isnum "$cw" && (( cw & 12 )); then
    bad "修复后固态仍然报告严重警告（$cw）：只读保护或可靠性下降"
    ok=0
  fi
  dr_verdict "$ok" "$model"
}

dr_verdict() {
  section "深度修复结果"
  if (( $1 == 2 )); then
    warn "没能开始修复：固态正被系统里的程序占用（不是固态坏了）。"
    say "  重启电脑、重新从修复盘启动，桌面出来后直接输入 9 再试一次。"
    return
  fi
  if (( $1 )); then
    good "修好了：固态能正常写入、读回，内部映射表已重置，分区表是空白 GPT。"
    say "  接下来：关机，拔掉这个修复盘，插上 Windows 安装 U 盘装系统，"
    say "  选安装位置时选这块固态的“未分配的空间”，点“下一步”就行。"
    (( F_VMD )) && say "  注意：BIOS 里 VMD 还开着，装系统前先关掉（见 使用说明.txt 第四节）。"
  else
    bad "没修好：固态在上面某一步出错，这是硬件或固件层面的问题，软件修不了。"
    say "  建议找电脑厂商或固态厂商售后，固态型号：${2:-未知}。"
    say "  把这个报告文件一起给售后看：$REPORT"
  fi
}

# ---------------------------------------------------------------------
# 不用安装盘重建 Windows 启动文件（相当于 Windows 的 bcdboot）：
#   1 从 Windows 分区的 \Windows\Boot\EFI 等目录把启动文件拷回 EFI 分区
#   2 用 U 盘里的启动配置模板（bcd/BCD，在另一台 Windows 电脑上用 bcdedit 生成），
#     把模板里那台电脑的磁盘 / 分区编号换成这块固态的，写成 \EFI\Microsoft\Boot\BCD
#   3 放一份通用启动文件 \EFI\Boot\bootx64.efi
#   改动前会把整个 EFI 分区打包备份到 U 盘
# ---------------------------------------------------------------------
rebuild_win_boot() {
  local tpl="$HERE/bcd/BCD" gfile="$HERE/bcd/guids.txt" win esp disk edisk dpt wpu epu wm em src mgr dst d loc out rc=1 eown=0
  if [[ ! -f $tpl || ! -f $gfile ]]; then
    bad "修复盘里缺少启动配置模板（usb-ssd-fix/bcd），没法重建"
    return 1
  fi
  have python3 || { bad "没有 python3，没法重建"; return 1; }
  win="${WIN_PARTS[0]}"
  esp="${ESP_DEVS[0]}"
  disk="$(lsblk -ndo PKNAME "$win" 2>/dev/null | trim)"
  edisk="$(lsblk -ndo PKNAME "$esp" 2>/dev/null | trim)"
  if [[ -z $disk || $disk != "$edisk" ]]; then
    bad "EFI 分区和 Windows 不在同一块盘上，没法自动重建"
    return 1
  fi
  disk="/dev/$disk"
  dpt="$(pinfo "$disk" PTUUID)"
  wpu="$(pinfo "$win" PART_ENTRY_UUID)"
  epu="$(pinfo "$esp" PART_ENTRY_UUID)"
  if [[ -z $dpt || -z $wpu || -z $epu ]]; then
    bad "读不到磁盘 / 分区编号，没法重建"
    return 1
  fi
  say "  Windows 分区：$win    EFI 分区：$esp"

  wm="$(mktemp -d /tmp/ssdwin.XXXXXX)"
  if ! mount -o ro "$win" "$wm" 2>>"$REPORT"; then
    bad "Windows 分区挂载不上"
    rmdir "$wm"
    return 1
  fi
  em="$(findmnt -nro TARGET -S "$esp" 2>/dev/null | head -n1)"
  if [[ -n $em ]]; then
    mount -o remount,rw "$em" 2>>"$REPORT"
  else
    em="$(mktemp -d /tmp/ssdesp.XXXXXX)"
    eown=1
    if ! mount "$esp" "$em" 2>>"$REPORT"; then
      bad "EFI 分区挂载不上（可能损坏）"
      rmdir "$em"
      umount "$wm"; rmdir "$wm"
      return 1
    fi
  fi

  while :; do
    src="$(ci_path "$wm" Windows Boot EFI)" || { bad "Windows 分区里找不到 \\Windows\\Boot\\EFI"; break; }
    mgr="$(ci_path "$src" bootmgfw.efi)" || { bad "Windows 分区里找不到 bootmgfw.efi"; break; }
    if tar -C "$em" -czf "$SAVE_DIR/esp_backup_$STAMP.tgz" . 2>>"$REPORT"; then
      say "  已把原来的 EFI 分区备份到：$SAVE_DIR/esp_backup_$STAMP.tgz"
    fi
    dst="$em/EFI/Microsoft/Boot"
    mkdir -p "$dst" || { bad "EFI 分区写不进去"; break; }
    cp -r "$src"/. "$dst"/ 2>>"$REPORT" || { bad "拷贝启动文件失败"; break; }
    if d="$(ci_path "$wm" Windows Boot Fonts)"; then mkdir -p "$dst/Fonts"; cp -r "$d"/. "$dst/Fonts"/ 2>>"$REPORT"; fi
    if d="$(ci_path "$wm" Windows Boot Resources)"; then mkdir -p "$dst/Resources"; cp -r "$d"/. "$dst/Resources"/ 2>>"$REPORT"; fi
    # 启动菜单语言：有中文资源就用中文，没有就用英文
    loc=zh-CN
    if ! ci_path "$src" zh-CN >/dev/null && ci_path "$src" en-US >/dev/null; then loc=en-US; fi
    out="$(python3 - "$tpl" "$gfile" "$dst/BCD" "$dpt" "$wpu" "$epu" "$loc" 2>&1 <<'PY'
import sys, uuid
tpl, gfile, out, disk, win, esp, loc = sys.argv[1:]
g = dict(l.strip().lstrip('\ufeff').split('=', 1) for l in open(gfile, encoding='utf-8-sig') if '=' in l)
data = bytearray(open(tpl, 'rb').read())
if data[:4] != b'regf':
    sys.exit('模板不是有效的 BCD 文件')
le = lambda s: uuid.UUID(s).bytes_le
# 模板里：磁盘编号出现 3 次（启动管理器 1 + Windows 2），Windows 分区 2 次，EFI 分区 1 次
plan = [(le(g['disk']), le(disk), 3), (le(g['win']), le(win), 2), (le(g['esp']), le(esp), 1)]
for old, new, want in plan:
    n = data.count(old)
    if n != want:
        sys.exit('模板里编号出现次数不对：%d（应该是 %d）' % (n, want))
for old, new, _ in plan:
    data = data.replace(old, new)
for old, new, _ in plan:
    if data.count(new) != _:
        sys.exit('替换后核对失败')
if loc != 'zh-CN':
    data = data.replace('zh-CN'.encode('utf-16-le'), loc.encode('utf-16-le'))
open(out, 'wb').write(data)
print('OK')
PY
)"
    printf '\n[重建启动] BCD：%s\n' "$out" >> "$REPORT"
    if [[ $out != OK ]]; then
      bad "生成启动配置失败：$out"
      break
    fi
    mkdir -p "$em/EFI/Boot"
    if [[ -e $em/EFI/Boot/bootx64.efi ]] && ! cmp -s "$mgr" "$em/EFI/Boot/bootx64.efi"; then
      mv -f "$em/EFI/Boot/bootx64.efi" "$em/EFI/Boot/bootx64.efi.bak_$STAMP"
    fi
    cp "$mgr" "$em/EFI/Boot/bootx64.efi" 2>>"$REPORT"
    sync
    if [[ -f $dst/bootmgfw.efi && -f $dst/BCD && -f $em/EFI/Boot/bootx64.efi ]]; then
      good "Windows 启动文件已经重建好（启动语言 $loc）"
      rc=0
    else
      bad "重建后核对文件失败"
    fi
    break
  done
  umount "$wm" 2>/dev/null; rmdir "$wm" 2>/dev/null
  if (( eown )); then umount "$em" 2>/dev/null; rmdir "$em" 2>/dev/null; fi
  return "$rc"
}

# 8) 修复 UEFI 启动项：把检测时在 EFI 分区里找到、但主板里没有登记的启动文件补登记进去
do_bootfix() {
  if [[ ! -d $EFI_DIR ]]; then
    bad "这次 U 盘不是用 UEFI 方式启动的，改不了主板启动项。重启后在启动菜单（华硕 Esc / 联想、戴尔 F12 / 惠普 F9）里选带 UEFI 字样的 U 盘再来。"
    return
  fi
  if ! have efibootmgr; then
    warn "没有 efibootmgr（SystemRescue 和 Ubuntu 都自带）"
    return
  fi
  local hasmgr=0 x confirmed=0
  for x in "${LOADERS[@]}"; do [[ $x == win\|* ]] && hasmgr=1; done
  if (( ! hasmgr && ${#WIN_PARTS[@]} && ${#ESP_DEVS[@]} )); then
    echo
    say "检测到原来的 Windows 还在（${WIN_PARTS[0]}），但 EFI 分区里没有它的启动文件。"
    say "可以直接从 Windows 分区把启动文件重建回来：不删任何数据，也不需要 Windows 安装 U 盘。"
    read -rp "要重建请输入 Y：" x
    if [[ ${x,,} != y ]]; then
      say "已取消。"
      return
    fi
    rebuild_win_boot || return
    confirmed=1   # 已经确认过了，后面登记启动项不再问
    # 重新检查一遍 EFI 分区，拿到新的启动文件，再去主板里登记
    LOADERS=()
    check_boot "/dev/$(lsblk -ndo PKNAME "${ESP_DEVS[0]}" | trim)"
  fi
  if (( ${#LOADERS[@]} == 0 )); then
    warn "EFI 分区里没有可用的启动文件，也没找到能用来重建的 Windows，没法修启动。"
    say "  只能重装系统：Windows 安装 U 盘启动后运行 D:\\fix 选 1。"
    return
  fi
  local ev e kind disk part puuid label path n has_win=0 has_lin=0 want ans num order rest
  local -a todo=()
  ev="$(efibootmgr -v 2>&1)"
  say "主板里现在的启动项："
  efibootmgr 2>&1 | sed 's/^/    /'
  for e in "${LOADERS[@]}"; do
    IFS='|' read -r kind disk part puuid label path <<<"$e"
    [[ $kind == win ]] && has_win=1
    [[ $kind == linux ]] && has_lin=1
    if grep -iF "$puuid" <<<"$ev" | grep -qiF "$path"; then
      say "  已有：$label（$path）"
    else
      todo+=("$e")
    fi
  done

  want=""
  if (( has_win && has_lin )); then
    echo
    echo "这块固态上有双系统。开机默认进哪个？"
    echo "  1) Windows"
    echo "  2) Linux（GRUB 菜单里一般也能选 Windows）"
    echo "  回车) 不改变现在的顺序"
    read -rp "请选择：" ans
    [[ $ans == 1 ]] && want=win
    [[ $ans == 2 ]] && want=linux
  fi
  if (( ${#todo[@]} == 0 )) && [[ -z $want ]]; then
    good "需要的启动项都在，不用修。"
    say "  还是进不了系统的话：进 BIOS 的 Boot 页面，把对应的启动项调到第一位。"
    return
  fi

  if (( ${#todo[@]} )); then
    echo
    say "将要在主板里新增这些启动项（只写主板的启动项列表，不动硬盘上的任何文件）："
    for e in "${todo[@]}"; do
      IFS='|' read -r kind disk part puuid label path <<<"$e"
      say "  + $label  →  $disk 分区 $part  $path"
    done
  fi
  if (( ! confirmed )); then
    read -rp "确认执行请输入 Y：" ans
    if [[ ${ans,,} != y ]]; then say "已取消。"; return; fi
  fi

  n=0
  for e in "${todo[@]}"; do
    IFS='|' read -r kind disk part puuid label path <<<"$e"
    if efibootmgr -c -d "$disk" -p "$part" -L "$label" -l "$path" >> "$REPORT" 2>&1; then
      good "已添加启动项：$label"
      n=$(( n + 1 ))
    else
      bad "添加 $label 失败（详见报告）。可以进 BIOS 手动 Add New Boot Option，文件选 $path"
    fi
  done

  # 按选择把默认系统排到第一位
  if [[ -n $want ]]; then
    ev="$(efibootmgr -v 2>&1)"
    num=""
    for e in "${LOADERS[@]}"; do
      IFS='|' read -r kind disk part puuid label path <<<"$e"
      [[ $kind == "$want" ]] || continue
      num="$(grep -iF "$puuid" <<<"$ev" | grep -iF "$path" | head -n1 | sed -nE 's/^Boot([0-9A-Fa-f]{4}).*/\1/p')"
      [[ -n $num ]] && break
    done
    order="$(efibootmgr 2>/dev/null | sed -nE 's/^BootOrder: *//p')"
    if [[ -n $num ]]; then
      rest="$(tr ',' '\n' <<<"$order" | grep -viFx "$num" | paste -sd, -)"
      if efibootmgr -o "$num${rest:+,$rest}" >> "$REPORT" 2>&1; then
        good "已把 $([[ $want == win ]] && echo Windows || echo Linux) 设为开机默认"
      else
        warn "调整启动顺序失败，可以进 BIOS 的 Boot 页面手动调"
      fi
    fi
  fi

  say ""
  say "修改后的启动项："
  efibootmgr 2>&1 | sed 's/^/    /'
  say "拔掉 U 盘重启试试。如果还是直接进 BIOS，进 BIOS 的 Boot 页面看看新加的启动项是否在第一位。"
}

# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
ensure_tools
run_checks

(( REPORT_ONLY )) && exit 0
[[ -t 0 ]] || exit 0

if (( AUTO )); then
  echo
  printf '%s%s%s\n' "$C_B" "=============================================================" "$C_N"
  if (( F_HASWIN && (F_NOESP || F_BOOTLOST) )) && (( ! F_NOCTRL && ! F_NONS && ! F_FW && ! F_RO && ! F_READ && ! F_HEALTH )); then
    echo "  固态是好的，原来的 Windows 也还在，只是启动文件丢了。"
    echo "      输入 8 回车 → 修复启动（不删数据，不需要安装 U 盘）"
    echo "  修好后关机，拔掉这个 U 盘再开机，就能进原来的 Windows。"
  else
    echo "  上面是检测结果。想修复固态（固态里的数据不要了）："
    echo "      输入 9 回车 → 深度修复固态"
    echo "  修完关机，拔掉这个 U 盘，插上 Windows 安装 U 盘装系统。"
  fi
  printf '%s%s%s\n' "$C_B" "=============================================================" "$C_N"
fi

while true; do
  echo
  echo "${C_B}==================== 修复菜单 ====================${C_N}"
  echo " 1) 备份分区表到 U 盘                （安全，只读固态）"
  echo " 2) 复位 NVMe 控制器 + 重新扫描后再检测（安全）"
  echo " 3) 整盘镜像备份到移动硬盘            （安全，只读固态）"
  echo " 4) 用 testdisk 找回 / 修复分区        （交互式，按 Write 才写入）"
  echo " 5) 清空分区表，新建空白 GPT           （会删除固态全部数据）"
  echo " 6) 重新运行全部检测"
  echo " 7) 让固态做一次短自检                （安全，约 1~3 分钟）"
  echo " 8) 修复启动（开机只能进 BIOS 时用，不删数据，不用安装 U 盘）"
  echo " 9) 深度修复固态                      （会清空固态全部数据，数据不要时用这个）"
  echo " 0) 退出"
  read -rp "请选择：" ch || exit 0
  case "$ch" in
    1) do_backup_pt ;;
    2) do_reset ;;
    3) do_image ;;
    4) do_testdisk ;;
    5) do_wipe ;;
    6) run_checks ;;
    7) do_selftest ;;
    8) do_bootfix ;;
    9) do_deep_repair ;;
    0|q|Q) say "报告：$REPORT"; exit 0 ;;
    *) echo "请输入 0-9" ;;
  esac
done

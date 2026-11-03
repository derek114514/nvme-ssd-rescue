#!/bin/bash
# 修复盘桌面启动后自动调用：运行检测/修复工具（同一时间只开一个）
exec 9>/tmp/ssdfix.lock
flock -n 9 || exit 0
D="$(cd "$(dirname "$0")" && pwd)"
# 修复盘默认只读挂载；改成可写，检测报告才能保存回 U 盘
if [[ $D == /run/archiso/bootmnt/* ]]; then
  mount -o remount,rw /run/archiso/bootmnt 2>/dev/null
fi
bash "$D/ssd_check.sh" --auto
echo
read -rp "按回车关闭这个窗口……" _

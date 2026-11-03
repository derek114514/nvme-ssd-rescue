@echo off
rem Shortcut: in Windows Setup press Shift+F10 and type  D:\fix  (D = your USB drive letter)
if not exist "%~dp0usb-ssd-fix\fix_win.cmd" (
  echo usb-ssd-fix\fix_win.cmd not found next to fix.cmd - copy the whole zip content to the USB root.
  exit /b 1
)
call "%~dp0usb-ssd-fix\fix_win.cmd" %*

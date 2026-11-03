@echo off
rem Double-click to build the NVMe SSD rescue USB (asks for admin rights).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_usb.ps1" %*

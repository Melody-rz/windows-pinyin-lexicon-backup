@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pinyin-watchdog.ps1" -Suspend
pause

# 手动恢复入口 —— 用法: pinyin-restore.ps1 <存档日期，如 2026-11-01 或完整名 2026-11-01_093000>
param([Parameter(Mandatory=$true)][string]$Date)
& (Join-Path $PSScriptRoot 'pinyin-watchdog.ps1') -RestoreFrom $Date

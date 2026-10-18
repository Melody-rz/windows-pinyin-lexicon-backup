#Requires -Version 5.1
# 命令行入口（薄封装）—— 实际逻辑统一在 src\pinyin-gui\engine.psm1
# 用法：
#   pinyin-watchdog.ps1                          登录检查（转发 auto-check.ps1）
#   pinyin-watchdog.ps1 -Backup                  手动备份（不受间隔/去重限制）
#   pinyin-watchdog.ps1 -RestoreFrom <存档名>     恢复到指定存档（精确名；会先保全再确认）
#   pinyin-watchdog.ps1 -Suspend                  挂起值守（主动清词库前用）
#   pinyin-watchdog.ps1 -Resume                   恢复值守
# 保留旧参数是为了兼容既有习惯；所有规则（间隔/去重/保留/校验/回退）只有引擎一份。

param(
    [switch]$Backup,
    [switch]$Suspend,
    [switch]$Resume,
    [string]$RestoreFrom,
    [string]$BaseDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $BaseDir) { $BaseDir = $PSScriptRoot }
$guiDir = Join-Path $PSScriptRoot 'src\pinyin-gui'
Import-Module (Join-Path $guiDir 'gui-config.psm1') -DisableNameChecking
Import-Module (Join-Path $guiDir 'engine.psm1')      -DisableNameChecking

# 测试/隔离支持：BaseDir 下存在 ime-data 时视为测试数据目录
$imeDirArg = ''
$testIme = Join-Path $BaseDir 'ime-data'
if (Test-Path -LiteralPath $testIme -PathType Container) { $imeDirArg = $testIme }

$ctxArgs = @{ BaseDir = $BaseDir }
if ($imeDirArg) { $ctxArgs.ImeDir = $imeDirArg }
$ctx = New-EngineContext @ctxArgs
if (-not $ctx.Ok) {
    Write-Output ($ctx.Errors -join "`n")
    exit 1
}

if ($Suspend) {
    Set-EngineSuspend -Ctx $ctx
    Write-Output '看门狗已挂起（清完词库后运行 -Resume 恢复值守）'
    exit 0
}
if ($Resume) {
    Clear-EngineSuspend -Ctx $ctx
    Write-Output '看门狗已恢复值守'
    exit 0
}
if ($RestoreFrom) {
    # 精确匹配一份存档（不做模糊日期匹配，防止偷偷恢复到另一份）
    $snap = @(Get-EngineSnapshots -Ctx $ctx) | Where-Object { $_.Name -eq $RestoreFrom }
    if (-not $snap) {
        $avail = (@(Get-EngineSnapshots -Ctx $ctx) | Select-Object -First 10 | ForEach-Object { $_.Name }) -join "`n"
        Write-Output "找不到存档（必须是完整存档名，不做模糊匹配）：$RestoreFrom"
        if ($avail) { Write-Output "可用存档（最近 10 份）：`n$avail" }
        exit 1
    }
    $s = $snap[0]
    Write-Output "即将恢复到：$($s.Name)（$($s.Words) 个词组，估算值，$($s.Time)）"
    Write-Output "恢复前会把当前数据完整保全到 quarantine；期间输入法可能闪断几秒。"
    $ans = Read-Host '确认恢复请输入 y，其他任意输入取消'
    if ($ans -ne 'y' -and $ans -ne 'Y') {
        Write-Output '已取消，未做任何改动。'
        exit 0
    }
    $r = Invoke-EngineRestore -Ctx $ctx -SnapshotName $s.Name
    if ($r.Outcome -eq 'success') {
        Write-Output "已恢复到 $($s.Name)；恢复前数据保全在 quarantine\$($r.QuarantineName)。"
        if ($r.RestartErrors) { Write-Output ($r.RestartErrors -join "`n") }
        exit 0
    } else {
        if ($r.RestartErrors) { Write-Output ($r.RestartErrors -join "`n") }
        Write-Output ($r.Errors -join "`n")
        exit 1
    }
}
if ($Backup) {
    $r = Invoke-EngineBackup -Ctx $ctx -Manual
    switch ($r.Outcome) {
        'success' {
            Write-Output "备份完成：$($r.SnapshotName)（$($r.Words) 个词组，估算值）"
            if (@($r.RotationErrors).Count -gt 0) {
                Write-Output "但清理超额旧备份失败（不影响新备份）："
                @($r.RotationErrors) | ForEach-Object { Write-Output "  - $_" }
            }
            exit 0
        }
        'failed' { Write-Output ($r.Errors -join "`n"); exit 1 }
        'busy'   { Write-Output ($r.Errors -join "`n"); exit 1 }
        default  { Write-Output "备份未执行：$($r.Outcome)"; exit 0 }
    }
}

# 默认：登录检查（转发 auto-check.ps1，静默/弹窗规则与计划任务一致）
$forwardArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                 '-File', (Join-Path $guiDir 'auto-check.ps1'),
                 '-BaseDir', $BaseDir)
if ($imeDirArg) { $forwardArgs += @('-ImeDir', $imeDirArg) }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @forwardArgs
exit $LASTEXITCODE

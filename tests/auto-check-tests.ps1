#Requires -Version 5.1
# auto-check.ps1 静默路径验证 —— 全部使用临时目录与虚构数据。
#
# 验证思路：auto-check 的错误提示是阻塞式弹窗（没人点就不会退出）。因此
# 「进程在时限内自行退出 + 退出码 0」本身就证明没有弹出任何窗口；再配合
# 轮询主窗口句柄做双保险。覆盖：首次备份、未到期跳过、重复内容跳过、
# 挂起跳过、操作互斥让位（busy）。
# 运行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\auto-check-tests.ps1

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
$guiDir     = Join-Path $scriptRoot 'src\pinyin-gui'
Import-Module (Join-Path $guiDir 'gui-config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $guiDir 'engine.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $guiDir 'gui-status.psm1')  -Force -DisableNameChecking

$script:PassCount = 0; $script:FailCount = 0; $script:Failures = @()
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:PassCount++; Write-Output "PASS  $Name" }
    else { $script:FailCount++; $script:Failures += "$Name  $Detail"; Write-Output "FAIL  $Name  $Detail" }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("autocheck-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Write-Output "测试目录：$testRoot`n"

$fakeWords = (1..120 | ForEach-Object { '词组样例编号' + $_.ToString('0000') }) -join ''

function New-TestEnv {
    param([string]$Sub)
    $base = Join-Path $testRoot $Sub
    $imeDir = Join-Path $base 'ime-data'
    New-Item -ItemType Directory -Path $imeDir -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $imeDir 'ChsPinyinUDL.dat'), [System.Text.Encoding]::Unicode.GetBytes($fakeWords))
    $cfg = @{ BackupIntervalDays = 7; KeepCount = 30; BackupDir = 'snapshots'
              LoginStart = $false; LoginDelaySeconds = 20; DeduplicateBackup = $true; MaxLogMB = 5 }
    $null = Save-GuiConfig -Path (Join-Path $base 'config.json') -Config $cfg
    return @{ BaseDir = $base; ImeDir = $imeDir }
}

function Invoke-AutoCheck {
    <# 以独立进程运行 auto-check.ps1（隔离环境），验证静默退出。
       返回 @{ ExitCode; HadWindow; TimedOut }。HadWindow 由句柄轮询得出。 #>
    param([string]$BaseDir, [string]$ImeDir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $guiDir 'auto-check.ps1') + """ -BaseDir ""$BaseDir"" -ImeDir ""$ImeDir"""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['TEMP'] = $BaseDir
    $psi.EnvironmentVariables['TMP'] = $BaseDir
    $p = [System.Diagnostics.Process]::Start($psi)
    $hadWindow = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 60) {
        $p.Refresh()
        if ($p.MainWindowHandle -ne 0) { $hadWindow = $true }
        Start-Sleep -Milliseconds 250
    }
    if (-not $p.HasExited) {
        try { $null = $p.Kill() } catch { }
        return @{ ExitCode = $null; HadWindow = $hadWindow; TimedOut = $true }
    }
    $null = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    return @{ ExitCode = $p.ExitCode; HadWindow = $hadWindow; TimedOut = $false }
}

try {
    $env1 = New-TestEnv -Sub 's1'

    # A01 首次运行：健康无存档 → 备份成功，全程静默
    $r1 = Invoke-AutoCheck -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir
    Assert-True 'A01a 首次检查进程自行退出（无阻塞弹窗）' (-not $r1.TimedOut)
    Assert-True 'A01b 首次检查退出码 0' ($r1.ExitCode -eq 0) ("exit=" + $r1.ExitCode)
    Assert-True 'A01c 首次检查全程无窗口' (-not $r1.HadWindow)
    $ctx1 = New-EngineContext -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir -ImeProcessNames @('PinyinFakeIME') -HelperProcessName 'PinyinFakeHelper' -TaskName 'PinyinAutoCheckTest'
    Assert-True 'A01d 首次检查产生了备份' (@(Get-EngineSnapshots -Ctx $ctx1).Count -eq 1)

    # A02 未到期：再次检查 → 静默跳过
    $r2 = Invoke-AutoCheck -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir
    Assert-True 'A02a 未到期检查自行退出' (-not $r2.TimedOut)
    Assert-True 'A02b 未到期退出码 0' ($r2.ExitCode -eq 0)
    Assert-True 'A02c 未到期检查无窗口' (-not $r2.HadWindow)
    $log2 = Get-GuiLogEntries -LogPath $ctx1.Paths.LogFile -MaxCount 0
    $lastLine = $log2.Entries[-1]
    Assert-True 'A02d 日志记录了未到期跳过' ($lastLine.Result -eq 'skip-not-due') ("last=" + $lastLine.Result)

    # A03 到期 + 内容相同 → 去重跳过（静默）
    $snap = @(Get-EngineSnapshots -Ctx $ctx1)[0]
    $metaPath = Join-Path $snap.Dir 'meta.json'
    $m = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $m.time = (Get-Date).AddDays(-9).ToString('yyyy-MM-dd HH:mm:ss')
    $m | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding UTF8
    $r3 = Invoke-AutoCheck -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir
    Assert-True 'A03a 去重跳过自行退出' (-not $r3.TimedOut)
    Assert-True 'A03b 去重跳过退出码 0' ($r3.ExitCode -eq 0)
    Assert-True 'A03c 去重跳过无窗口' (-not $r3.HadWindow)
    $log3 = Get-GuiLogEntries -LogPath $ctx1.Paths.LogFile -MaxCount 0
    Assert-True 'A03d 日志记录了去重跳过' ($log3.Entries[-1].Result -eq 'skip-duplicate')

    # A04 到期 + 内容变化 → 自动备份成功（静默）
    [System.IO.File]::WriteAllBytes($ctx1.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes($fakeWords + '新增内容'))
    $r4 = Invoke-AutoCheck -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir
    Assert-True 'A04a 到期自动备份自行退出' (-not $r4.TimedOut)
    Assert-True 'A04b 到期自动备份退出码 0' ($r4.ExitCode -eq 0)
    Assert-True 'A04c 到期自动备份无窗口' (-not $r4.HadWindow)
    Assert-True 'A04d 自动产生了第二份存档' (@(Get-EngineSnapshots -Ctx $ctx1).Count -eq 2)

    # A05 挂起 → 静默跳过（不检查不备份）
    Set-EngineSuspend -Ctx $ctx1
    [System.IO.File]::WriteAllBytes($ctx1.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes($fakeWords + '挂起期间变化'))
    $before = @(Get-EngineSnapshots -Ctx $ctx1).Count
    $r5 = Invoke-AutoCheck -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir
    Assert-True 'A05a 挂起时检查自行退出' (-not $r5.TimedOut)
    Assert-True 'A05b 挂起时退出码 0' ($r5.ExitCode -eq 0)
    Assert-True 'A05c 挂起时无窗口' (-not $r5.HadWindow)
    Assert-True 'A05d 挂起时未新增备份' (@(Get-EngineSnapshots -Ctx $ctx1).Count -eq $before)
    Clear-EngineSuspend -Ctx $ctx1

    # A06 与手动操作重叠：操作锁被占 → 静默让位（退出 0，无弹窗）
    $holdScript = Join-Path $testRoot 'hold-lock.ps1'
    @'
$m = New-Object System.Threading.Mutex($false, 'Local\PinyinLexiconBackupOp')
$null = $m.WaitOne(5000)
Start-Sleep -Seconds 12
'@ | Set-Content -LiteralPath $holdScript -Encoding ASCII
    $holder = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holdScript) `
        -PassThru -WindowStyle Hidden
    try {
        $deadline = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $deadline -and -not (Test-EngineOpBusy)) { Start-Sleep -Milliseconds 300 }
        Assert-True 'A06a 独立进程已持有操作锁' (Test-EngineOpBusy)
        $r6 = Invoke-AutoCheck -BaseDir $env1.BaseDir -ImeDir $env1.ImeDir
        Assert-True 'A06b 重叠时自动检查静默让位（自行退出）' (-not $r6.TimedOut)
        Assert-True 'A06c 重叠时退出码 0' ($r6.ExitCode -eq 0)
        Assert-True 'A06d 重叠时无窗口' (-not $r6.HadWindow)
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $holder.WaitForExit(5000) | Out-Null } catch { }
        Remove-Item -LiteralPath $holdScript -Force -ErrorAction SilentlyContinue
    }

    # A07 崩溃日志未产生（静默路径不应写 crash log）
    $crashLines = 0
    foreach ($crashLog in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter 'auto-check-crash.log')) {
        $crashLines += @(Get-Content -LiteralPath $crashLog.FullName -Encoding UTF8).Count
    }
    Assert-True 'A07 静默路径未写崩溃日志' ($crashLines -eq 0) ("lines=" + $crashLines)
}
finally {
    try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop } catch { }
}

Write-Output ''
Write-Output ("汇总：通过 {0}，失败 {1}" -f $script:PassCount, $script:FailCount)
if ($script:Failures.Count -gt 0) {
    Write-Output '失败项：'
    $script:Failures | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
exit 0

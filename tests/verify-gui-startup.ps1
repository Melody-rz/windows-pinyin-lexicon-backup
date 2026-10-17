#Requires -Version 5.1
# Automated verification of the fixed GUI startup chain.
#
# ASCII-ONLY ON PURPOSE: Windows PowerShell 5.1 decodes BOM-less .ps1 files as ANSI,
# so any literal non-ASCII text in this file would be misread. Non-ASCII strings that
# must be compared (the window title, Chinese directory names) are built from code points.
#
# Covers:
#   1. Launcher starts the GUI as a standard user; window appears with the correct title
#   2. App-private temp dir is created/reused; launcher.log written; no crash log
#   3. Closing the window really exits the process (no tray residue)
#   4. Relaunch after close works and reuses the temp dir
#   5. Chinese + space paths work (data dir and backup dir)
#   6. Settings save/read back in an isolated directory (fictional data)
#   7. The user's polluted %TEMP%\WPF is no longer used
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-gui-startup.ps1
# Notes: briefly opens the app window and closes it automatically. Uses temp dirs and
# fictional data only. If Windows shows a "Security Warning" for the unsigned exe, it
# must be allowed first, otherwise automation cannot proceed.

param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
$script:Notes = New-Object System.Collections.ArrayList

function Check { param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Output ("  PASS  " + $Name + $(if ($Detail) { "  [" + $Detail + "]" } else { '' })) }
    else     { $script:Fail++; Write-Output ("  FAIL  " + $Name + $(if ($Detail) { "  [" + $Detail + "]" } else { '' })) }
}
function Section { param([string]$T) Write-Output ("`n===== " + $T + " =====") }
function Note { param([string]$T) $null = $script:Notes.Add($T); Write-Output ("  NOTE  " + $T) }

# Expected window title, built from code points so this file stays ASCII.
$expectedTitle = [string]::Concat(
    [char]0x5FAE, [char]0x8F6F, [char]0x62FC, [char]0x97F3, [char]0x8BCD,
    [char]0x5E93, [char]0x5907, [char]0x4EFD)

# ---------------------------------------------------------------------------
# Process tracking
#
# Only processes THIS test starts are ever terminated. We deliberately do NOT scan
# for "any powershell that appeared after the test began": that would also match the
# user's own terminals, editors and other scripts running at the same time, and
# killing them would be harmful.
#   - launcher-started GUI: pid comes from the launcher's own startup log
#   - directly started GUI: the Process object returned by Process.Start
# Recorded start times guard against pid reuse.
$script:Tracked = @{}

function Register-TrackedProcess {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return }
    try { $script:Tracked[[int]$Process.Id] = $Process.StartTime.Ticks } catch { }
    return
}

function Stop-TrackedProcesses {
    foreach ($entry in $script:Tracked.GetEnumerator()) {
        $trackedId = [int]$entry.Key
        $p = Get-Process -Id $trackedId -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        # Guard 1: must still be a powershell process.
        if ($p.ProcessName -ne 'powershell') { continue }
        # Guard 2: must be the very process we registered (pid may have been reused).
        try { if ($p.StartTime.Ticks -ne $entry.Value) { continue } } catch { continue }
        try {
            if (-not $p.HasExited) {
                $null = $p.Kill()
                Write-Output ("    killed tracked process pid " + $trackedId)
            }
        } catch { }
    }
    $script:Tracked.Clear()
}

function Get-TrackedAliveProcesses {
    # NOTE: no comma-wrapping here. `,$alive` around an empty array yields a
    # one-element array once the caller wraps it in @(), which reads as a false leftover.
    $alive = @()
    foreach ($entry in $script:Tracked.GetEnumerator()) {
        $p = Get-Process -Id ([int]$entry.Key) -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) { $alive += $p }
    }
    $alive
}

function Get-NewestLauncherLog {
    # The launcher appends to launcher.log inside whichever temp dir it picks.
    # The user may already have logs in BOTH candidate dirs from earlier runs,
    # so discover the most recently written one instead of guessing by path.
    $logs = @()
    foreach ($dir in @($fallback, $appTemp)) {
        $log = Join-Path $dir 'launcher.log'
        if (Test-Path -LiteralPath $log) { $logs += Get-Item -LiteralPath $log }
    }
    if ($logs.Count -eq 0) { return $null }
    return ($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Get-LauncherLogLineCount {
    # Total lines across both candidate logs. The test never deletes these files:
    # they belong to the user's installation. We only compare counts before/after.
    $total = 0
    foreach ($dir in @($fallback, $appTemp)) {
        $log = Join-Path $dir 'launcher.log'
        if (Test-Path -LiteralPath $log) {
            $total += @(Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue).Count
        }
    }
    return $total
}

function Get-CrashLogLineCount {
    $total = 0
    foreach ($dir in @($fallback, $appTemp)) {
        $log = Join-Path $dir 'pinyin-gui-crash.log'
        if (Test-Path -LiteralPath $log) {
            $total += @(Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue).Count
        }
    }
    return $total
}

function Get-LauncherGuiPid {
    # The launcher logs "started the GUI process pid=<n>"; read the newest entry
    # from the most recently written launcher.log (see Get-NewestLauncherLog).
    $log = Get-NewestLauncherLog
    if (-not $log) { return $null }
    $lines = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'pid=(\d+)') { return [int]$Matches[1] }
    }
    return $null
}

function Start-LauncherAndWaitGui {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Start via .NET with an explicit wait so the launcher's own exit code is observable
    # and the call can never block indefinitely.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $RepoRoot
    $proc = [System.Diagnostics.Process]::Start($psi)
    $launcherExit = $null
    if ($proc.WaitForExit(20000)) { $launcherExit = $proc.ExitCode }
    else { try { $null = $proc.Kill() } catch { }; $launcherExit = 'timeout' }

    $gui = $null
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Milliseconds 400
        $guiId = Get-LauncherGuiPid
        if (-not $guiId) { continue }
        $cand = Get-Process -Id $guiId -ErrorAction SilentlyContinue
        if (-not $cand) { continue }
        $null = Register-TrackedProcess -Process $cand
        if ($cand.HasExited -or $cand.MainWindowHandle -ne 0) { $gui = $cand; break }
    }
    @{ LauncherExit = $launcherExit; Gui = $gui; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$exe      = Join-Path $RepoRoot 'open-gui.exe'
$guiScript = Join-Path $RepoRoot 'src\pinyin-gui\gui-app.ps1'
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $canonical = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\').ToUpperInvariant()
    $instanceKey = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').Substring(0,16)
} finally { $sha.Dispose() }
$appTemp  = Join-Path $env:LOCALAPPDATA ('PinyinLexiconBackup\instances\' + $instanceKey + '\temp')
$fallback = Join-Path $RepoRoot '.pinyin-gui-temp'
$realWpf  = Join-Path $env:TEMP 'WPF'

Section 'ENVIRONMENT'
Write-Output ("  user        : " + $identity.Name)
Write-Output ("  isAdmin     : " + $isAdmin)
Write-Output ("  repo        : " + $RepoRoot)
Write-Output ("  temp (1st)  : " + $appTemp)
Write-Output ("  temp (2nd)  : " + $fallback)
Check 'running without administrator rights' (-not $isAdmin)

$exeBytes = [System.IO.File]::ReadAllBytes($exe)
$peOffset = [BitConverter]::ToInt32($exeBytes, 0x3C)
Check 'launcher is GUI-subsystem (no console window)' ([BitConverter]::ToUInt16($exeBytes, $peOffset + 0x5C) -eq 2)

$guiBytes = [System.IO.File]::ReadAllBytes($guiScript)
Check 'GUI script keeps UTF-8 BOM (Chinese text encoding)' `
      ($guiBytes[0] -eq 0xEF -and $guiBytes[1] -eq 0xBB -and $guiBytes[2] -eq 0xBF)

# Do NOT kill anything at startup. Only report pre-existing instances of this app
# (matched by their command line), because a leftover instance would hold the
# single-instance mutex and skew the run. Reporting only -- never terminating.
$preExisting = @()
try {
    $preExisting = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like '*gui-app.ps1*' } |
        ForEach-Object { [int]$_.ProcessId })
} catch { }
if ($preExisting.Count -gt 0) {
    Note ("pre-existing app processes found (left running, not killed): " + (($preExisting | Sort-Object) -join ', '))
} else {
    Write-Output '  no pre-existing app process'
}
Start-Sleep -Milliseconds 600
# NOTE: deliberately NO cleanup of the user's app temp dirs (.pinyin-gui-temp /
# %LOCALAPPDATA%\PinyinLexiconBackup) here. They belong to the user's installation
# and may contain their launcher.log / crash log. The test verifies behavior by
# comparing log line counts before/after, and every file it creates goes into its
# own uniquely-named temporary folder that is removed at the end.

$wpfBefore = @(Get-ChildItem -LiteralPath $realWpf -Force -ErrorAction SilentlyContinue)
Write-Output ("  %TEMP%\WPF entries=" + $wpfBefore.Count + "  owner=" + (Get-Acl -LiteralPath $realWpf).Owner)

# Baselines measured WITHOUT touching the user's files
$logLinesBefore = Get-LauncherLogLineCount
$crashLinesBefore = Get-CrashLogLineCount
Write-Output ("  launcher.log lines before: " + $logLinesBefore + "   crash log lines before: " + $crashLinesBefore)

# Sentinel: an unrelated PowerShell process that the test must never touch.
# Its command line mentions neither this app nor this verification script.
$sentinelScript = Join-Path $env:TEMP ('unrelated-' + [Guid]::NewGuid().ToString('N') + '.ps1')
Set-Content -LiteralPath $sentinelScript -Value 'Start-Sleep -Seconds 300' -Encoding ASCII
$psiSentinel = New-Object System.Diagnostics.ProcessStartInfo
$psiSentinel.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psiSentinel.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $sentinelScript + '"'
$psiSentinel.UseShellExecute = $false
$psiSentinel.CreateNoWindow = $true
$sentinel = [System.Diagnostics.Process]::Start($psiSentinel)
Write-Output ("  sentinel powershell pid=" + $sentinel.Id + " (unrelated; must survive the run)")

Section 'START 1 (first launch of this run)'
$r1 = Start-LauncherAndWaitGui
Write-Output ("  launcher exit=" + $r1.LauncherExit + "  waited=" + $r1.Seconds + "s")
Check 'launcher exits cleanly (no startup-failure dialog)' ($r1.LauncherExit -eq 0) ("exit=" + $r1.LauncherExit)
Check 'GUI process started' ($null -ne $r1.Gui)

# Which temp dir did THIS run use? Read it from the launcher log that was just
# written -- not by probing paths, which would match the user's older dirs.
$newestLog = Get-NewestLauncherLog
$chosenTemp = if ($newestLog) { $newestLog.DirectoryName } else { $null }
Check 'app-private temp dir in use (launcher.log written this run)' ($null -ne $chosenTemp) ("dir=" + $chosenTemp)
Note ("temp dir used: " + $chosenTemp)

$logLinesAfter1 = Get-LauncherLogLineCount
Check 'launcher.log gained entries for this launch' ($logLinesAfter1 -gt $logLinesBefore) ("before=" + $logLinesBefore + " after=" + $logLinesAfter1)

if ($r1.Gui) {
    Start-Sleep -Seconds 4
    $r1.Gui.Refresh()
    Check 'GUI process still alive after startup (did not crash)' (-not $r1.Gui.HasExited)
    Check 'GUI process is responsive' ($r1.Gui.Responding)
    Write-Output ("  window title: '" + $r1.Gui.MainWindowTitle + "'")
    Check 'window title renders Chinese correctly' ($r1.Gui.MainWindowTitle -eq $expectedTitle)
    Check 'window is visible (has a main window handle)' ($r1.Gui.MainWindowHandle -ne 0)
}

if ($chosenTemp) {
    Check 'WPF cache subdir exists inside the app temp dir' (Test-Path -LiteralPath (Join-Path $chosenTemp 'WPF'))
    if ($newestLog) {
        Write-Output '  launcher.log (last 6 lines):'
        Get-Content -LiteralPath $newestLog.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6 | ForEach-Object { Write-Output ("    " + $_) }
    }
    $crashGrew = ((Get-CrashLogLineCount) -gt $crashLinesBefore)
    if ($crashGrew) {
        Write-Output '  NEW crash log lines this run:'
        foreach ($dir in @($chosenTemp, $fallback, $appTemp)) {
            $cl = Join-Path $dir 'pinyin-gui-crash.log'
            if (Test-Path -LiteralPath $cl) { Get-Content -LiteralPath $cl -Encoding UTF8 | Select-Object -Last 10 | ForEach-Object { Write-Output ("    " + $_) } }
        }
    }
    Check 'no new GUI crash log lines this run' (-not $crashGrown)
}

Section 'SECOND LAUNCH WHILE FIRST IS RUNNING (notify path)'
# The first window is still open. Launch the launcher again: the expected behavior is
# that the SECOND gui process only sends a "please show your window" notification and
# exits by itself, while the FIRST instance stays alive and brings its window forward.
#
# The second instance exits within ~1s, which is faster than any process-polling loop
# can reliably observe -- so presence is proven from the launcher's own log (a NEW pid
# line appears), and its exit is proven by that pid no longer resolving to a process.
if ($r1.Gui -and -not $r1.Gui.HasExited) {
    $firstPid = $r1.Gui.Id
    $pidBefore = Get-LauncherGuiPid

    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $exe
    $psi2.UseShellExecute = $false
    $psi2.WorkingDirectory = $RepoRoot
    $launcher2 = [System.Diagnostics.Process]::Start($psi2)
    $null = $launcher2.WaitForExit(20000)
    Check 'second launcher run exits cleanly' ($launcher2.ExitCode -eq 0) ("exit=" + $launcher2.ExitCode)

    # The new pid the launcher just logged (must differ from the first instance's)
    $secondPid = $null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $logged = Get-LauncherGuiPid
        if ($logged -and $logged -ne $pidBefore) { $secondPid = $logged; break }
        Start-Sleep -Milliseconds 300
    }
    Check 'second gui process started (logged with its own pid)' ($null -ne $secondPid) ("pid=" + $secondPid + " first=" + $firstPid)

    if ($secondPid) {
        # register it for safety-cleanup in case it does NOT exit (broken notify path
        # would leave it stuck on a "stale process" dialog)
        $sp = Get-Process -Id $secondPid -ErrorAction SilentlyContinue
        if ($sp) { $null = Register-TrackedProcess -Process $sp }

        $secondGone = $false
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            $sp = Get-Process -Id $secondPid -ErrorAction SilentlyContinue
            if (-not $sp -or $sp.HasExited) { $secondGone = $true; break }
            Start-Sleep -Milliseconds 400
        }
        if (-not $secondGone) {
            Note 'second instance still alive after 8s (likely stuck on the stale-process dialog); killed'
            try { Stop-Process -Id $secondPid -Force -ErrorAction SilentlyContinue } catch { }
        }
        Check 'second instance exits by itself (notify, no second window)' $secondGone
    } else {
        Check 'second instance exits by itself (notify, no second window)' $false 'never started'
    }

    Start-Sleep -Milliseconds 800
    $r1.Gui.Refresh()
    Check 'first instance still alive after the second launch' (-not $r1.Gui.HasExited) ("first pid=" + $firstPid)
    Check 'first window still present (it received the notification)' ($r1.Gui.MainWindowHandle -ne 0)
} else {
    Check 'second launcher run exits cleanly' $false 'first instance not running'
    Check 'second gui process started (logged with its own pid)' $false
    Check 'second instance exits by itself (notify, no second window)' $false
    Check 'first instance still alive after the second launch' $false
    Check 'first window still present (it received the notification)' $false
}

Section 'CLOSE 1 = REAL EXIT'
if ($r1.Gui -and -not $r1.Gui.HasExited) {
    $r1.Gui.CloseMainWindow() | Out-Null
    $closed = $r1.Gui.WaitForExit(10000)
    Check 'process exits when the window is closed' $closed
    if (-not $closed) { Note 'window close did not exit within 10s; killed instead'; try { $r1.Gui.Kill() } catch { } }
} else {
    Check 'process exits when the window is closed' $false 'no live GUI process'
}
Start-Sleep -Milliseconds 1200
$left = @(Get-TrackedAliveProcesses)
Check 'no process left behind after close' ($left.Count -eq 0) ("leftover=" + $left.Count)
Stop-TrackedProcesses

Section 'START 2 (relaunch after close)'
$r2 = Start-LauncherAndWaitGui
Check 'GUI starts again after a previous run closed' ($null -ne $r2.Gui)
if ($r2.Gui) {
    Start-Sleep -Seconds 3
    $r2.Gui.Refresh()
    Check 'second GUI process alive and responsive' ((-not $r2.Gui.HasExited) -and $r2.Gui.Responding)
    Check 'second window title correct' ($r2.Gui.MainWindowTitle -eq $expectedTitle)
    $r2.Gui.CloseMainWindow() | Out-Null
    $closed2 = $r2.Gui.WaitForExit(10000)
    Check 'second run also exits on close' $closed2
    if (-not $closed2) { try { $r2.Gui.Kill() } catch { } }
}
Start-Sleep -Milliseconds 1000
Stop-TrackedProcesses

if ($chosenTemp) {
    # Three launcher runs so far (first launch + notify-path launch + this relaunch),
    # each appending >= 2 lines. Compare against the pre-run baseline: the user's
    # own historical log lines are none of our business and stay untouched.
    $logLinesTotal = Get-LauncherLogLineCount
    $gained = $logLinesTotal - $logLinesBefore
    Check 'launcher.log records every launch of this run' ($gained -ge 6) ("gained=" + $gained)
    Check 'temp dir still present after all runs' (Test-Path -LiteralPath $chosenTemp)
}

Section 'CHINESE + SPACE PATHS'
$cjkName = [string]::Concat([char]0x4E2D, [char]0x6587) + ' ' + [string]::Concat([char]0x76EE, [char]0x5F55) + ' test'
$cjkRoot = Join-Path $env:TEMP ('verify-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + ' ' + $cjkName)
$null = New-Item -ItemType Directory -Path $cjkRoot -Force
Set-Content -LiteralPath (Join-Path $cjkRoot 'pinyin-backup.log') -Encoding UTF8 -Value '2026-01-01 10:00:00 | backup | success | record A | 1234'
$null = New-Item -ItemType Directory -Path (Join-Path $cjkRoot 'snapshots') -Force
Set-Content -LiteralPath (Join-Path $cjkRoot 'snapshots\snap-20260101.dat') -Encoding UTF8 -Value 'fictional snapshot'
Write-Output ("  data dir: " + $cjkRoot)

$psiCjk = New-Object System.Diagnostics.ProcessStartInfo
$psiCjk.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psiCjk.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $guiScript + '" -DataDir "' + $cjkRoot + '"'
$psiCjk.UseShellExecute = $false
$psiCjk.RedirectStandardOutput = $true
$psiCjk.RedirectStandardError = $true
$psiCjk.CreateNoWindow = $true
$pCjk = [System.Diagnostics.Process]::Start($psiCjk)
Register-TrackedProcess -Process $pCjk | Out-Null
Start-Sleep -Seconds 6
$pCjk.Refresh()
Check 'GUI starts with a Chinese/space data dir' ((-not $pCjk.HasExited) -and $pCjk.Responding) ("hwnd=" + $pCjk.MainWindowHandle)
Check 'Chinese data dir window title correct' ($pCjk.MainWindowTitle -eq $expectedTitle)
if (-not $pCjk.HasExited) {
    $pCjk.CloseMainWindow() | Out-Null
    $closedCjk = $pCjk.WaitForExit(10000)
    Check 'Chinese-path instance exits on close' $closedCjk
    if (-not $closedCjk) { try { $pCjk.Kill() } catch { } }
}

Section 'SETTINGS SAVE (isolated dir, fictional data)'
$modulePath = Join-Path $RepoRoot 'src\pinyin-gui\gui-config.psm1'
$cfgPath = Join-Path $cjkRoot 'config.json'
# Build the Chinese subdirectory name from code points; keep this file ASCII.
$cjkWord = [string]::Concat([char]0x4E2D, [char]0x6587)
$backupTarget = Join-Path $cjkRoot ('backup ' + $cjkWord)

$settingsScript = Join-Path $env:TEMP ('gui-settings-' + [Guid]::NewGuid().ToString('N') + '.ps1')
# Keep the helper script ASCII-only and pass every path as an argument, so Chinese
# paths survive regardless of how PowerShell decodes the temporary script file.
$settingsBody = @"
param([string]`$ModulePath, [string]`$CfgPath, [string]`$BackupDir, [string]`$BaseDir)
Import-Module `$ModulePath -Force -DisableNameChecking
`$draft = @{
  BackupIntervalDays = '7'; KeepCount = '12'; BackupDir = `$BackupDir
  LoginStart = `$false; LoginDelaySeconds = '30'
  DeduplicateBackup = `$true; MaxLogMB = '5'
}
`$check = Test-GuiConfig -Config `$draft
Write-Output ('check.Valid=' + `$check.Valid + '  errors=' + (`$check.Errors -join ';'))
`$dirCheck = Test-GuiBackupDirWritable -BackupDir `$draft.BackupDir -BaseDir `$BaseDir
Write-Output ('dirWritable=' + `$dirCheck.Ok + '  path=' + `$dirCheck.Path)
`$save = Save-GuiConfig -Path `$CfgPath -Config `$draft
Write-Output ('save.Success=' + `$save.Success + '  errors=' + (`$save.Errors -join ';'))
`$read = Read-GuiConfig -Path `$CfgPath -BaseDir `$BaseDir
Write-Output ('readback.KeepCount=' + `$read.Config.KeepCount + '  interval=' + `$read.Config.BackupIntervalDays)
Write-Output ('readback.BackupDir=' + `$read.Config.BackupDir)
"@
Set-Content -LiteralPath $settingsScript -Value $settingsBody -Encoding ASCII

$settingsOut = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $settingsScript -ModulePath $modulePath -CfgPath $cfgPath -BackupDir $backupTarget -BaseDir $cjkRoot 2>&1
Write-Output '  module output:'
($settingsOut | Out-String) -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-Output ("    " + $_.Trim()) }
Check 'settings saved to config.json in a Chinese/space path' (Test-Path -LiteralPath $cfgPath)
if (Test-Path -LiteralPath $cfgPath) {
    $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
    Check 'saved config keeps the modified KeepCount' ($raw -match '"KeepCount"\s*:\s*"?12"?')
    Check 'saved config keeps the Chinese backup path' ($raw -match ([string]::Concat([char]0x4E2D, [char]0x6587)))
}

Section 'RUN GUI SCRIPT DIRECTLY (no launcher)'
$psiRaw = New-Object System.Diagnostics.ProcessStartInfo
$psiRaw.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psiRaw.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $guiScript + '" -DataDir "' + $cjkRoot + '"'
$psiRaw.UseShellExecute = $false
$psiRaw.RedirectStandardOutput = $true
$psiRaw.RedirectStandardError = $true
$psiRaw.CreateNoWindow = $true
$pRaw = [System.Diagnostics.Process]::Start($psiRaw)
Register-TrackedProcess -Process $pRaw | Out-Null
Start-Sleep -Seconds 6
$pRaw.Refresh()
Check 'direct script run also starts (temp-dir self check passes)' ((-not $pRaw.HasExited) -and $pRaw.Responding)
if (-not $pRaw.HasExited) {
    $null = $pRaw.CloseMainWindow()
    $null = $pRaw.WaitForExit(8000)
    if (-not $pRaw.HasExited) { try { $null = $pRaw.Kill() } catch { } }
}

Section 'UNAVAILABLE TEMP DIR -> CLEAR ERROR (no ACL changes)'
# Simulate an unusable temp dir without touching any permission: put a plain FILE where
# the WPF cache DIRECTORY is expected, so creating that directory must fail. The GUI must
# report this in a readable dialog instead of dying with an internal access exception.
$blockedRoot = Join-Path $env:TEMP ('verify-blocked-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $blockedRoot -Force
Set-Content -LiteralPath (Join-Path $blockedRoot 'WPF') -Value 'not a directory'

$psiBlocked = New-Object System.Diagnostics.ProcessStartInfo
$psiBlocked.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psiBlocked.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $guiScript + '" -DataDir "' + $cjkRoot + '"'
$psiBlocked.UseShellExecute = $false
$psiBlocked.CreateNoWindow = $true
$psiBlocked.RedirectStandardOutput = $true
$psiBlocked.RedirectStandardError = $true
$psiBlocked.EnvironmentVariables['TEMP'] = $blockedRoot
$psiBlocked.EnvironmentVariables['TMP'] = $blockedRoot

$pBlocked = [System.Diagnostics.Process]::Start($psiBlocked)
Register-TrackedProcess -Process $pBlocked | Out-Null
Start-Sleep -Seconds 5
$pBlocked.Refresh()
$blockedTitle = $pBlocked.MainWindowTitle
Write-Output ("  temp dir used : " + $blockedRoot)
Write-Output ("  dialog title  : '" + $blockedTitle + "'")
Check 'unusable temp dir gives a readable error dialog (not a silent failure)' `
      ($blockedTitle -eq ($expectedTitle + ' GUI')) ("title='" + $blockedTitle + "'")
if (-not $pBlocked.HasExited) { try { $null = $pBlocked.Kill() } catch { } }
try { Remove-Item -LiteralPath $blockedRoot -Recurse -Force -ErrorAction Stop } catch { }

Section 'REAL %TEMP%\WPF UNTOUCHED'
$wpfAfter = @(Get-ChildItem -LiteralPath $realWpf -Force -ErrorAction SilentlyContinue)
Check 'verification added no entries to %TEMP%\WPF' ($wpfAfter.Count -eq $wpfBefore.Count) `
      ("before=" + $wpfBefore.Count + " after=" + $wpfAfter.Count)

Section 'CLEANUP'
if (Test-Path -LiteralPath $cjkRoot) { try { Remove-Item -LiteralPath $cjkRoot -Recurse -Force -ErrorAction Stop } catch { } }
if ($blockedRoot -and (Test-Path -LiteralPath $blockedRoot)) { try { Remove-Item -LiteralPath $blockedRoot -Recurse -Force -ErrorAction Stop } catch { } }
if (Test-Path -LiteralPath $settingsScript) { try { Remove-Item -LiteralPath $settingsScript -Force } catch { } }
Stop-TrackedProcesses

Section 'NO COLLATERAL DAMAGE'
# The sentinel is an unrelated PowerShell process started before the tests ran and
# deliberately NOT registered for tracking. It must still be alive: this is the
# regression guard for "the test killed somebody else's PowerShell".
if ($sentinel) {
    $sentinel.Refresh()
    Check 'unrelated PowerShell process was not terminated' (-not $sentinel.HasExited) ("sentinel pid=" + $sentinel.Id)
    if (-not $sentinel.HasExited) { try { $null = $sentinel.Kill() } catch { } }
} else {
    Check 'unrelated PowerShell process was not terminated' $false 'sentinel did not start'
}
if ($sentinelScript -and (Test-Path -LiteralPath $sentinelScript)) {
    try { Remove-Item -LiteralPath $sentinelScript -Force } catch { }
}

Section 'RESULT'
Write-Output ("  PASS: " + $script:Pass)
Write-Output ("  FAIL: " + $script:Fail)
foreach ($n in $script:Notes) { Write-Output ("  NOTE: " + $n) }
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }

#Requires -Version 5.1
# 回归：全部使用虚构词库和模拟任务接口；不注册任务、不操作真实输入法。
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'src\pinyin-gui'
Import-Module (Join-Path $app 'gui-config.psm1') -DisableNameChecking
Import-Module (Join-Path $app 'engine.psm1') -DisableNameChecking
$engine = Get-Module engine
& $engine {
    $script:ReviewTaskCalls = @()
    function script:Register-EngineLoginTask {
        param($Ctx)
        $script:ReviewTaskCalls += @{ Delay = $Ctx.Config.LoginDelaySeconds; Dir = $Ctx.Paths.SnapDir; Enabled = $true }
        return @{ Ok = $true; Error = '' }
    }
    function script:Unregister-EngineLoginTask {
        param($Ctx)
        $script:ReviewTaskCalls += @{ Enabled = $false }
        return @{ Ok = $true; Error = '' }
    }
}
$script:Passed = 0
function Check([string]$Name, [bool]$Ok) {
    if (-not $Ok) { throw "FAIL $Name" }
    $script:Passed++
    Write-Output "PASS $Name"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('pinyin-bugfix-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
function New-Fixture([string]$Name) {
    $base = Join-Path $root $Name
    $ime = Join-Path $base 'ime-data'
    $null = New-Item -ItemType Directory -Path $ime -Force
    $text = ((1..120 | ForEach-Object { '词组样例' + $_ }) -join ' ')
    [IO.File]::WriteAllBytes((Join-Path $ime 'ChsPinyinUDL.dat'), [Text.Encoding]::Unicode.GetBytes($text))
    $cfg = Get-GuiConfigDefaults -BaseDir $base
    $s = Save-GuiConfig -Path (Join-Path $base 'config.json') -Config $cfg
    if (-not $s.Success) { throw ($s.Errors -join ';') }
    return @{ BaseDir = $base; ImeDir = $ime; ImeProcessNames = @('PinyinReviewFake'); HelperProcessName = 'PinyinReviewHelper'; TaskName = 'PinyinReviewNoTask' }
}
function Add-FakeSnapshot([string]$Dir, [string]$Name) {
    $target = Join-Path $Dir $Name
    $null = New-Item -ItemType Directory -Path $target -Force
    @{ source = 'manual'; words = 120; time = '2026-01-01 00:00:00' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $target 'meta.json') -Encoding UTF8
}
function Add-Three([string]$Dir) {
    foreach ($day in 1..3) { Add-FakeSnapshot $Dir ('2026-01-0' + $day + '_000000') }
}
function Invoke-IsolatedAuto([string]$Base, [string]$Mode) {
    $program = Join-Path $Base 'app'
    $null = New-Item -ItemType Directory -Path $program -Force
    if ($Mode -ne 'missing-module') {
        Copy-Item (Join-Path $app 'gui-config.psm1'),(Join-Path $app 'engine.psm1') -Destination $program
    }
    $source = Get-Content (Join-Path $app 'auto-check.ps1') -Raw -Encoding UTF8
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    $notify = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CheckAlert' }, $true)
    # 注入记录通知的边界，实际主流程和错误分支仍执行生产脚本。
    $stub = @'
function Show-CheckAlert {
    param($Topic, $Message, $Title, $Buttons, $Icon)
    @{ Topic=$Topic; Message=$Message } | ConvertTo-Json -Compress |
        Add-Content -LiteralPath (Join-Path $BaseDir 'alerts.jsonl') -Encoding UTF8
    return 'No'
}
'@
    $source = $source.Remove($notify.Extent.StartOffset, $notify.Extent.EndOffset - $notify.Extent.StartOffset).Insert($notify.Extent.StartOffset, $stub)
    if ($Mode -eq 'cleanup-failed') {
        $source = $source.Replace('$backup = Invoke-EngineBackup -Ctx $ctx', '$backup = @{ Outcome=''success''; SnapshotName=''test-snapshot''; Errors=@(); RotationErrors=@(''模拟清理失败'') }')
    }
    $path = Join-Path $program 'auto-check.ps1'
    [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($true))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $path + '" -BaseDir "' + $Base + '" -ImeDir "' + (Join-Path $Base 'ime-data') + '" -ImeProcessNames PinyinReviewFake -HelperProcessName PinyinReviewHelper'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.EnvironmentVariables['TEMP'] = $Base
    $psi.EnvironmentVariables['TMP'] = $Base
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(15000)) { $p.Kill(); $p.WaitForExit(); throw 'Isolated auto-check timed out' }
    $stderr = $p.StandardError.ReadToEnd()
    if ($stderr) { throw $stderr }
    $alerts = @()
    $alertPath = Join-Path $Base 'alerts.jsonl'
    if (Test-Path $alertPath) { $alerts = @(Get-Content $alertPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }) }
    return @{ Exit = $p.ExitCode; Alerts = $alerts }
}
try {
    $args1 = New-Fixture 'settings'
    $old = New-EngineContext @args1
    Add-Three $old.Paths.SnapDir
    $draft = $old.Config.Clone()
    $draft.BackupDir = Join-Path $args1.BaseDir 'new-backups'
    $draft.KeepCount = 1
    $draft.LoginStart = $true
    $draft.LoginDelaySeconds = 66
    $result = Set-EngineSettings -ContextArgs $args1 -Draft $draft
    Check 'Settings saved' $result.Success
    Check 'No old backup removed after directory change' (@(Get-EngineSnapshots -Ctx $old).Count -eq 3)
    $task = & $engine { $script:ReviewTaskCalls[-1] }
    Check 'Task receives newly saved delay 66' ($task.Delay -eq 66)
    Check 'Task receives newly saved backup directory' ($task.Dir -eq $draft.BackupDir)

    $args2 = New-Fixture 'cancel'
    $ctx2 = New-EngineContext @args2
    Add-Three $ctx2.Paths.SnapDir
    $draft2 = $ctx2.Config.Clone(); $draft2.KeepCount = 1
    $before = (Get-FileHash $ctx2.Paths.ConfigPath).Hash
    $callCount = & $engine { $script:ReviewTaskCalls.Count }
    $cancelled = Set-EngineSettings -ContextArgs $args2 -Draft $draft2 -ConfirmCleanup { param($plan) $false }
    Check 'Cancellation reported' $cancelled.Cancelled
    Check 'Cancellation leaves config unchanged' ((Get-FileHash $ctx2.Paths.ConfigPath).Hash -eq $before)
    Check 'Cancellation leaves backups unchanged' (@(Get-EngineSnapshots -Ctx $ctx2).Count -eq 3)
    Check 'Cancellation does not call task API' ((& $engine { $script:ReviewTaskCalls.Count }) -eq $callCount)
    $clean = Set-EngineSettings -ContextArgs $args2 -Draft $draft2 -ConfirmCleanup { param($plan) $true }
    Check 'Confirmed cleanup succeeds' ($clean.Success -and $clean.Errors.Count -eq 0)
    Check 'Only confirmed two backups removed' ($clean.Cleaned.Count -eq 2 -and @(Get-EngineSnapshots -Ctx $ctx2).Count -eq 1)

    $args3 = New-Fixture 'changed-plan'
    $ctx3 = New-EngineContext @args3
    Add-Three $ctx3.Paths.SnapDir
    $approved = @((Get-EngineRotationPlan -Ctx $ctx3 -KeepCount 1).Remove | ForEach-Object { $_.Name })
    Add-FakeSnapshot $ctx3.Paths.SnapDir '2099-01-01_000000'
    $changed = Invoke-EngineRotation -Ctx $ctx3 -KeepCount 1 -ApprovedSnapshotNames $approved
    Check 'Changed cleanup range rejected' ($changed.Errors.Count -gt 0)
    Check 'No unapproved backup deletion' (@(Get-EngineSnapshots -Ctx $ctx3).Count -eq 4)

    foreach ($raw in @('{"KeepCount":0}', '{"BackupIntervalDays":-5}', '{"LoginDelaySeconds":99999}', '{"KeepCount":999999999999999999999999999}', 'null', '[]', '[{}]', '42', '{"BackupDir":{}}', '{"MaxLogMB":"NaN"}')) {
        $badArgs = New-Fixture ('bad-' + [guid]::NewGuid().ToString('N'))
        $path = Join-Path $badArgs.BaseDir 'config.json'
        [IO.File]::WriteAllText($path, $raw)
        $bad = New-EngineContext @badArgs
        Check ('Invalid config rejected: ' + $raw) (-not $bad.Ok)
        Check 'Invalid config creates no backup directory' (-not (Test-Path (Join-Path $badArgs.BaseDir 'snapshots')))
    }
    $bounds = Get-GuiConfigDefaults -BaseDir $root
    $bounds.KeepCount = '999999999999999999999999999999'
    $v = Test-GuiConfig -Config $bounds
    Check 'Huge input gives validation result instead of exception' (-not $v.Valid)
    Check 'Validation message shows actual limits' (($v.Errors -join ' ') -like '*1 到 200*')

    $autoArgs = New-Fixture 'auto-cleanup'
    $a = Invoke-IsolatedAuto $autoArgs.BaseDir 'cleanup-failed'
    Check 'Cleanup failure reports handled-error status' ($a.Exit -eq 2)
    Check 'Cleanup failure notifies once' ($a.Alerts.Count -eq 1 -and $a.Alerts[0].Topic -eq 'cleanup-failed')
    Check 'Notification distinguishes backup success from cleanup failure' ($a.Alerts[0].Message -like '*备份成功*清理失败*')
    $missingArgs = New-Fixture 'auto-missing-module'
    $m = Invoke-IsolatedAuto $missingArgs.BaseDir 'missing-module'
    Check 'Missing module handled and reported' ($m.Exit -eq 2 -and $m.Alerts.Count -eq 1)
    $normalArgs = New-Fixture 'auto-normal'
    $n = Invoke-IsolatedAuto $normalArgs.BaseDir 'normal'
    Check 'Normal auto backup remains silent' ($n.Exit -eq 0 -and $n.Alerts.Count -eq 0)
    Check 'Normal auto backup actually creates snapshot' (@(Get-EngineSnapshots -Ctx (New-EngineContext @normalArgs)).Count -eq 1)
    Write-Output ("Passed: " + $script:Passed)
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'pinyin-bugfix-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

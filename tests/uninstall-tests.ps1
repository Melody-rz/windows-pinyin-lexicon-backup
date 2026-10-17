#Requires -Version 5.1
# 临时程序副本、虚构词库和模拟任务；绝不卸载当前工作目录或修改真实任务。
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\pinyin-gui\gui-config.psm1') -DisableNameChecking
$module=Import-Module (Join-Path $repo 'src\pinyin-gui\uninstall-core.psm1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('pinyin-uninstall-tests-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$script:Pass=0
function Check([string]$Name,[bool]$Ok) { if(-not $Ok){throw "FAIL $Name"}; $script:Pass++; Write-Output "PASS $Name" }
& $module {
    $script:ProductionRemove=(Get-Command Remove-UninstallTask).ScriptBlock
    $script:FakeTask=@{Exists=$true;Owned=$true;Running=$false;Enabled=$true;Error=''}
    $script:TaskWrites=0; $script:RemoveFails=$false
    function script:Read-UninstallTask([string]$BaseDir) { return $script:FakeTask.Clone() }
    function script:Remove-UninstallTask([string]$BaseDir) {
        if(-not $script:FakeTask.Owned){return}
        $script:TaskWrites++
        if($script:RemoveFails){throw '模拟任务删除失败'}
        $script:FakeTask.Exists=$false; $script:FakeTask.Owned=$false
    }
}
function Reset-Task {
    & $module { $script:FakeTask=@{Exists=$true;Owned=$true;Running=$false;Enabled=$true;Error=''}; $script:TaskWrites=0; $script:RemoveFails=$false }
}
function New-App([string]$Name) {
    $base=Join-Path $root $Name
    foreach($rel in @('open-gui.exe','silent-check.exe','uninstall.exe','src\pinyin-gui\auto-check.ps1','src\pinyin-gui\engine.psm1','src\pinyin-gui\gui-config.psm1','src\pinyin-gui\gui-app.ps1','src\pinyin-gui\gui-status.psm1','src\pinyin-gui\shell-actions.psm1','src\pinyin-gui\uninstall-core.psm1','src\pinyin-gui\uninstall-app.ps1')) {
        $dest=Join-Path $base $rel; $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $dest)); [IO.File]::Copy((Join-Path $repo $rel),$dest)
    }
    $cfg=Get-GuiConfigDefaults -BaseDir $base; $cfg.LoginStart=$true
    $saved=Save-GuiConfig -Path (Join-Path $base 'config.json') -Config $cfg
    if(-not $saved.Success){throw ($saved.Errors -join ';')}
    return $base
}
try {
    $base=New-App '界面移除 中文 空格'
    $plan=Get-UninstallPlan -BaseDir $base -Mode GuiOnly
    Check 'GUI-only plan valid' $plan.Ok
    Check 'Exactly four GUI-only files removed' ($plan.Files.Count -eq 4)
    $cancelled=Invoke-UninstallPlan -Plan $plan
    Check 'No confirmation means cancelled' $cancelled.Cancelled
    Check 'Cancel preserves GUI' (Test-Path -LiteralPath (Join-Path $base 'open-gui.exe'))
    Check 'Cancel does not write tasks' ((& $module {$script:TaskWrites}) -eq 0)
    $r=Invoke-UninstallPlan -Plan $plan -Confirmed
    Check 'GUI-only executes' $r.Ok
    Check 'GUI exe actually removed' (-not (Test-Path -LiteralPath (Join-Path $base 'open-gui.exe')))
    Check 'GUI-only never modifies task' ((& $module {$script:TaskWrites}) -eq 0)
    foreach($rel in @('silent-check.exe','src\pinyin-gui\auto-check.ps1','src\pinyin-gui\engine.psm1','src\pinyin-gui\gui-config.psm1','config.json','uninstall.exe','src\pinyin-gui\uninstall-app.ps1','src\pinyin-gui\uninstall-core.psm1')) {
        Check ('Preserved dependency: '+$rel) (Test-Path -LiteralPath (Join-Path $base $rel))
    }
    $again=Get-UninstallPlan -BaseDir $base -Mode GuiOnly
    Check 'GUI-only repeat is harmless' ($again.Ok -and $again.Files.Count -eq 0)
    # 真正运行保留下来的 auto-check 与引擎，虚构词库位于测试目录。
    $ime=Join-Path $base 'fake-ime'; $null=[IO.Directory]::CreateDirectory($ime)
    [IO.File]::WriteAllBytes((Join-Path $ime 'ChsPinyinUDL.dat'),[Text.Encoding]::Unicode.GetBytes(((1..160|ForEach-Object{'词组样例'+$_})-join ' ')))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $base 'src\pinyin-gui\auto-check.ps1')+'" -BaseDir "'+$base+'" -ImeDir "'+$ime+'" -ImeProcessNames PinyinUninstallFake -HelperProcessName PinyinUninstallHelper -TaskName PinyinUninstallNoTask'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $child=[Diagnostics.Process]::Start($psi)
    try {
        Check 'Retained automatic check exits without blocking window' ($child.WaitForExit(20000))
        Check 'Retained automatic check exit 0' ($child.ExitCode -eq 0)
    } finally { if(-not $child.HasExited){$child.Kill()}; $child.Dispose() }
    Check 'Retained engine actually backed up fake lexicon' (@(Get-ChildItem -LiteralPath (Join-Path $base 'snapshots') -Filter meta.json -Recurse).Count -eq 1)

    Reset-Task
    $base2=New-App 'full-mode'
    [IO.File]::WriteAllText((Join-Path $base2 'unrelated.txt'),'keep')
    $external=Join-Path $root 'shared-backups'; $snap=Join-Path $external '2026-01-01_000000'
    $null=[IO.Directory]::CreateDirectory($snap)
    [IO.File]::WriteAllText((Join-Path $snap 'meta.json'),'{"source":"manual","words":160}')
    [IO.File]::WriteAllText((Join-Path $snap 'ChsPinyinUDL.dat'),'fake archive')
    [IO.File]::WriteAllText((Join-Path $external 'family-notes.txt'),'keep')
    $cfg=Get-GuiConfigDefaults -BaseDir $base2; $cfg.BackupDir=$external
    $null=Save-GuiConfig -Path (Join-Path $base2 'config.json') -Config $cfg
    $cache=Join-Path $root 'instance-cache'; $null=[IO.Directory]::CreateDirectory($cache)
    [IO.File]::WriteAllText((Join-Path $cache 'cache.bin'),'fake')
    $plan=Get-UninstallPlan -BaseDir $base2 -Mode Full -CacheRoots @($cache)
    Check 'Full plan with external backup is valid' $plan.Ok
    Check 'Unknown external file excluded' ((Join-Path $external 'family-notes.txt') -notin @($plan.Files|ForEach-Object Path))
    & $module {$script:RemoveFails=$true}
    $r=Invoke-UninstallPlan -Plan $plan -Confirmed
    Check 'Task removal failure prevents all file deletion' (-not $r.Ok -and $r.Removed.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $base2 'silent-check.exe')))
    & $module {$script:RemoveFails=$false}
    $r=Invoke-UninstallPlan -Plan $plan -Confirmed
    Check 'Full uninstall executes in fake installation' $r.Ok
    Check 'Current installation task removal requested' ((& $module {$script:TaskWrites}) -eq 2)
    Check 'Runtime removed after task removal' (-not (Test-Path -LiteralPath (Join-Path $base2 'silent-check.exe')))
    Check 'Independent uninstaller removes itself from fixture' (-not (Test-Path -LiteralPath (Join-Path $base2 'uninstall.exe')))
    Check 'Recognized archive removed' (-not (Test-Path -LiteralPath $snap))
    Check 'Instance cache removed' (-not (Test-Path -LiteralPath $cache))
    Check 'Unknown external data preserved' (Test-Path -LiteralPath (Join-Path $external 'family-notes.txt'))
    Check 'Unknown installation file preserved' (Test-Path -LiteralPath (Join-Path $base2 'unrelated.txt'))

    Reset-Task
    $base3=New-App 'failure-cases'
    & $module {$script:FakeTask.Error='模拟任务查询失败'}
    $p=Get-UninstallPlan -BaseDir $base3 -Mode Full -CacheRoots @()
    Check 'Task query failure blocks full uninstall' (-not $p.Ok)
    $p=Get-UninstallPlan -BaseDir $base3 -Mode GuiOnly
    Check 'GUI-only can preserve unknown task state without task modification' $p.Ok
    Reset-Task
    & $module {$script:FakeTask.Running=$true}
    Check 'Running auto check blocks full uninstall' (-not (Get-UninstallPlan -BaseDir $base3 -Mode Full -CacheRoots @()).Ok)
    Reset-Task
    & $module {$script:FakeTask.Owned=$false}
    $p=Get-UninstallPlan -BaseDir $base3 -Mode Full -CacheRoots @()
    Check 'Foreign task is identified for preservation' ($p.Ok -and -not $p.Task.Owned)
    $r=Invoke-UninstallPlan -Plan $p -Confirmed
    Check 'Foreign task unchanged on full uninstall' ($r.Ok -and (& $module {$script:TaskWrites}) -eq 0)

    Reset-Task
    $base4=New-App 'plan-changed'
    $p=Get-UninstallPlan -BaseDir $base4 -Mode Full -CacheRoots @()
    [IO.File]::WriteAllText((Join-Path $base4 'pinyin-backup.log'),'new data after confirmation')
    $r=Invoke-UninstallPlan -Plan $p -Confirmed
    Check 'Expanded plan rejected before deleting files or tasks' (-not $r.Ok -and $r.Removed.Count -eq 0 -and (& $module {$script:TaskWrites}) -eq 0)
    $outside=Join-Path $root 'outside.txt'; [IO.File]::WriteAllText($outside,'keep')
    $unsafe=& $module {param($r,$p) try{$null=Assert-UninstallPath $r $p;return $false}catch{return $true}} $base4 (Join-Path $base4 '..\outside.txt')
    Check 'Path traversal rejected' $unsafe
    $unsafe=& $module {param($r) try{$null=Assert-UninstallPath $r ($r+'\x');return $false}catch{return $true}} ([IO.Path]::GetPathRoot($base4))
    Check 'Disk root rejected' $unsafe
    $link=Join-Path $base4 'linked'
    $null=New-Item -ItemType Junction -Path $link -Target $root
    try {
        $unsafe=& $module {param($r,$p) try{$null=Assert-UninstallPath $r $p;return $false}catch{return $true}} $base4 (Join-Path $link 'outside.txt')
        Check 'Junction traversal rejected' $unsafe
    } finally { [IO.Directory]::Delete($link) }
    Check 'External sentinel never touched' (Test-Path -LiteralPath $outside)
    Reset-Task
    $base5=New-App 'delete-failure'
    $p=Get-UninstallPlan -BaseDir $base5 -Mode Full -CacheRoots @()
    & $module {
        param($base)
        $script:DeleteFailPath=Join-Path $base 'config.json'
        function script:Remove-Item {
            param($LiteralPath,[switch]$Force,$ErrorAction)
            if($LiteralPath -eq $script:DeleteFailPath){throw '模拟无写入权限'}
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        }
    } $base5
    $r=Invoke-UninstallPlan -Plan $p -Confirmed
    Check 'File deletion failure reports error and stops' (-not $r.Ok -and ($r.Errors -join ';').Contains('模拟无写入权限'))
    Check 'Partial failure reports task already removed' $r.TaskRemoved
    Check 'Partial failure keeps runtime for repair' (Test-Path -LiteralPath (Join-Path $base5 'silent-check.exe'))
    Check 'Partial failure keeps independent uninstaller' (Test-Path -LiteralPath (Join-Path $base5 'uninstall.exe'))
    Reset-Task
    & $module {
        $script:ApiCalls=@(); $script:ApiRemoveFails=$false
        function script:Disable-ScheduledTask {
            param($TaskName,$TaskPath,$ErrorAction)
            $script:ApiCalls+=('disable:'+$TaskPath+$TaskName)
            $script:FakeTask.Enabled=$false
        }
        function script:Unregister-ScheduledTask {
            param($TaskName,$TaskPath,$Confirm,$ErrorAction)
            $script:ApiCalls+=('remove:'+$TaskPath+$TaskName)
            if($script:ApiRemoveFails){throw '模拟 API 删除失败'}
            $script:FakeTask.Exists=$false;$script:FakeTask.Owned=$false
        }
        & $script:ProductionRemove 'E:\fixture'
    }
    $calls=@(& $module {$script:ApiCalls})
    Check 'Production task handler disables before removal' (($calls -join ',') -eq 'disable:\PinyinLexiconBackupLogin,remove:\PinyinLexiconBackupLogin')
    Check 'Production task handler never targets old task' (-not (($calls -join ',').Contains(':\PinyinLexiconBackup,')))
    Reset-Task
    & $module {$script:ApiCalls=@();$script:FakeTask.Owned=$false;& $script:ProductionRemove 'E:\fixture'}
    Check 'Production handler makes no write for foreign task' ((& $module {$script:ApiCalls.Count}) -eq 0)
    Reset-Task
    $blocked=& $module { $script:ApiCalls=@();$script:FakeTask.Running=$true;try{& $script:ProductionRemove 'E:\fixture';$false}catch{$true} }
    Check 'Production handler rejects running task without writes' ($blocked -and (& $module {$script:ApiCalls.Count}) -eq 0)
    Reset-Task
    $message=& $module { $script:ApiCalls=@();$script:ApiRemoveFails=$true;try{& $script:ProductionRemove 'E:\fixture';''}catch{$_.Exception.Message} }
    Check 'Task API partial failure explains possibly disabled state' ($message.Contains('可能已经停用') -and $message.Contains('程序文件保留'))
    Write-Output "Passed: $script:Pass"
} finally {
    Remove-Module $module -Force
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}

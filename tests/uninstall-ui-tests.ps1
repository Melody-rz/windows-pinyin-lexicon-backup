#Requires -Version 5.1
# 在临时副本中短暂打开真实卸载窗口；模拟任务查询，自动取消，不执行删除。
param([switch]$FullFixture)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('卸载 界面测试 '+[guid]::NewGuid().ToString('N'))
$ownedChild=$null
try {
    foreach($rel in @('open-gui.exe','silent-check.exe','uninstall.exe','src\pinyin-gui\auto-check.ps1','src\pinyin-gui\engine.psm1','src\pinyin-gui\gui-config.psm1','src\pinyin-gui\uninstall-core.psm1','src\pinyin-gui\uninstall-app.ps1')) {
        $p=Join-Path $root $rel; $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $p)); [IO.File]::Copy((Join-Path $repo $rel),$p)
    }
    $modulePath=Join-Path $root 'src\pinyin-gui\uninstall-core.psm1'
    $source=[IO.File]::ReadAllText($modulePath)
    foreach($fn in @('Read-UninstallTask','Get-UninstallCacheRoots','Remove-UninstallTask')) {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn},$true)
        $replacement=switch($fn){
            'Read-UninstallTask' { 'function Read-UninstallTask { param($BaseDir) return @{Exists=$false;Owned=$false;Enabled=$false;Running=$false;Error=""} }' }
            'Get-UninstallCacheRoots' { 'function Get-UninstallCacheRoots { param($BaseDir) return @() }' }
            'Remove-UninstallTask' { 'function Remove-UninstallTask { throw "UI test must not modify tasks" }' }
        }
        $source=$source.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset).Insert($node.Extent.StartOffset,$replacement)
    }
    [IO.File]::WriteAllText($modulePath,$source,[Text.UTF8Encoding]::new($true))
    $appPath=Join-Path $root 'src\pinyin-gui\uninstall-app.ps1'
    $app=[IO.File]::ReadAllText($appPath)
    if($FullFixture) {
        # 仅测试副本：确认边界预先同意，结果窗口改为文件；不会操作真实安装。
        $confirm='[Windows.Forms.MessageBox]::Show($form,$warning + "`n`n是否执行当前清单？",''最后确认'',''YesNo'',''Warning'',''Button2'')'
        $app=$app.Replace($confirm,'[Windows.Forms.DialogResult]::Yes')
        $result='[Windows.Forms.MessageBox]::Show($form,$message,''卸载结果'',''OK'',$(if ($r.Ok) {''Information''} else {''Warning''}))'
        $app=$app.Replace($result,'[IO.File]::WriteAllText((Join-Path $BaseDir ''full-result.json''),($r | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))')
        $app=$app.Replace('Local\PinyinLexiconGuiMutex',('Local\PinyinUninstallUiFixture-'+[guid]::NewGuid().ToString('N')))
        $source=$source.Replace('function Remove-UninstallTask { throw "UI test must not modify tasks" }','function Remove-UninstallTask { param($BaseDir) }')
        [IO.File]::WriteAllText($modulePath,$source,[Text.UTF8Encoding]::new($true))
    }
    $probe=@'
    $form.add_Shown({
        $checks=@()
        $checks+=@{Name='Default mode is GUI-only';Ok=($gui.Checked -and -not $full.Checked)}
        $checks+=@{Name='GUI-only apply enabled';Ok=$go.Enabled}
        $checks+=@{Name='Preview shows exact installation path';Ok=$preview.Text.Contains($BaseDir)}
        $checks+=@{Name='Preview shows absent task honestly';Ok=$preview.Text.Contains('没有本版本登录任务')}
        $full.Checked=$true
        $checks+=@{Name='Full mode preview works';Ok=($script:CurrentPlan.Ok -and $script:CurrentPlan.Mode -eq 'Full')}
        $gui.Checked=$true
        $checks+=@{Name='Mode can switch back';Ok=($script:CurrentPlan.Mode -eq 'GuiOnly')}
        $checks | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BaseDir 'ui-results.json') -Encoding UTF8
        $script:UiTimer=New-Object Windows.Forms.Timer
        $script:UiTimer.Interval=200
        $script:UiTimer.add_Tick({$script:UiTimer.Stop();$cancel.PerformClick()})
        $script:UiTimer.Start()
    })
'@
    if($FullFixture) {
        $fixtureAction=@'
        $full.Checked=$true
        $script:CurrentPlan.CleanCacheContainers=$false
        $go.PerformClick()
        return
'@
        $probe=$probe.Replace('        $script:UiTimer=New-Object Windows.Forms.Timer', $fixtureAction+"`r`n"+'        $script:UiTimer=New-Object Windows.Forms.Timer')
    }
    $app=$app.Replace('    $null=$form.ShowDialog()', $probe+"`r`n"+'    $null=$form.ShowDialog()')
    [IO.File]::WriteAllText($appPath,$app,[Text.UTF8Encoding]::new($true))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $root 'uninstall.exe'; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $launcher=[Diagnostics.Process]::Start($psi)
    $launcherId=$launcher.Id
    $deadline=(Get-Date).AddSeconds(20)
    $resultFile=Join-Path $root 'ui-results.json'
    do {
        if(-not $ownedChild) {
            $ownedChild=@(Get-CimInstance Win32_Process -Filter ("ParentProcessId="+$launcherId) | Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine.Contains($root)} | ForEach-Object {Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue}) | Select-Object -First 1
        }
        Start-Sleep -Milliseconds 150
    } while(-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline)
    if(-not (Test-Path -LiteralPath $resultFile)){throw '卸载窗口未在时限内完成界面点验。'}
    foreach($r in (Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if(-not $r.Ok){throw ('FAIL '+$r.Name)}; Write-Output ('PASS '+$r.Name)
    }
    if(-not $launcher.WaitForExit(5000) -or $launcher.ExitCode -ne 0){throw 'Native launcher did not exit normally'}
    Write-Output 'PASS Native uninstaller launcher exits normally'
    if($ownedChild -and -not $ownedChild.WaitForExit(5000)){throw 'UI did not exit after Cancel'}
    if($FullFixture) {
        $result=Get-Content -LiteralPath (Join-Path $root 'full-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if(-not $result.Ok){throw ($result.Errors -join ';')}
        foreach($rel in @('uninstall.exe','open-gui.exe','silent-check.exe','src\pinyin-gui\uninstall-app.ps1','src\pinyin-gui\uninstall-core.psm1')) {
            if(Test-Path -LiteralPath (Join-Path $root $rel)){throw ('Full fixture did not remove '+$rel)}
        }
        Write-Output 'PASS Full fixture removes launchers and its own running script'
    } else {
        if(-not (Test-Path -LiteralPath (Join-Path $root 'open-gui.exe'))){throw 'Cancel deleted GUI'}
        Write-Output 'PASS Cancel preserves installation files'
    }
    Write-Output 'Passed: 8'
} finally {
    if($ownedChild -and -not $ownedChild.HasExited){$ownedChild.Kill();$null=$ownedChild.WaitForExit(5000)}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}

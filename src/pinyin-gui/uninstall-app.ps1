#Requires -Version 5.1
# 独立卸载界面不依赖 GUI 文件，移除管理界面后仍可运行。
param([string]$BaseDir = '', [int]$LauncherPid = 0)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
try {
    if (-not $BaseDir) { $BaseDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    Import-Module (Join-Path $PSScriptRoot 'uninstall-core.psm1') -DisableNameChecking
    $form = New-Object Windows.Forms.Form
    $form.Text = '微软拼音词库备份：卸载或移除界面'
    $form.Size = New-Object Drawing.Size(760,620)
    $form.MinimumSize = $form.Size; $form.StartPosition = 'CenterScreen'
    $full = New-Object Windows.Forms.RadioButton
    $full.Text = '完整卸载：停止本版本自动备份，删除程序、配置、备份和恢复前保全数据（不可恢复）'
    $full.SetBounds(18,16,710,38)
    $gui = New-Object Windows.Forms.RadioButton
    $gui.Text = '仅移除管理界面：保留自动备份组件、配置、数据和现有登录任务'
    $gui.SetBounds(18,59,710,30); $gui.Checked = $true
    $notice = New-Object Windows.Forms.Label
    $notice.SetBounds(18,98,710,75)
    $notice.Text = "仅移除界面后，请勿删除或移动整个程序目录；登录时仍需运行其中的自动备份组件。`n未启用、已挂起或失效的任务不会因为移除界面而启用。旧版 PinyinLexiconBackup 任务始终保留。`n重新解压完整发行文件可恢复界面；保留原配置和备份，不覆盖自己的数据。"
    $preview = New-Object Windows.Forms.TextBox
    $preview.SetBounds(18,180,710,340); $preview.Multiline=$true; $preview.ReadOnly=$true
    $preview.ScrollBars='Both'; $preview.WordWrap=$false; $preview.Anchor='Top,Bottom,Left,Right'
    $go = New-Object Windows.Forms.Button
    $go.Text='确认并执行…'; $go.SetBounds(480,535,130,32); $go.Anchor='Bottom,Right'
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='取消'; $cancel.SetBounds(620,535,108,32); $cancel.Anchor='Bottom,Right'
    $script:CurrentPlan=$null
    $refresh = {
        $mode = if ($full.Checked) { 'Full' } else { 'GuiOnly' }
        $script:CurrentPlan = Get-UninstallPlan -BaseDir $BaseDir -Mode $mode
        $plan=$script:CurrentPlan; $go.Enabled=$plan.Ok
        if (-not $plan.Ok) { $preview.Text=$plan.Errors -join "`r`n"; return }
        $taskText = if ($plan.Task.Error) { $plan.Task.Error } elseif (-not $plan.Task.Exists) { '没有本版本登录任务：不会自动创建或启用任务。' } elseif (-not $plan.Task.Owned) { '同名任务属于另一安装目录或用户：将保留。' } elseif (-not $plan.Task.Enabled) { '当前登录任务已禁用。' } else { '当前安装的登录任务已启用。' }
        if (Test-Path -LiteralPath (Join-Path $BaseDir 'suspend.tag')) { $taskText += ' 自动检查已挂起。' }
        $text = @("程序目录：$BaseDir",$taskText,'',"将删除 $($plan.Files.Count) 个文件：")
        $text += @($plan.Files | ForEach-Object Path)
        $text += @('','将保留的项目（未知文件、开发文件不会删除）：') + @($plan.Retained)
        if ($mode -eq 'GuiOnly') { $text += @('','保留：自动备份运行组件、uninstall.exe、配置、备份、日志和计划任务。') }
        else { $text += @('','确认后将移除属于当前安装的登录任务。其他安装、旧任务及真实输入法词库不受影响。','历史版本共用的临时缓存无法确认归属，不会自动删除；未列出的文件同样保留。') }
        $preview.Text=$text -join "`r`n"
    }
    $full.add_CheckedChanged($refresh); $gui.add_CheckedChanged($refresh)
    $cancel.add_Click({ $form.Close() })
    $go.add_Click({
        $p=$script:CurrentPlan
        $warning = if ($p.Mode -eq 'Full') { '即将删除清单中的备份及恢复前保全数据，无法撤销；本版本自动备份将停止。' } else { '即将移除管理界面。自动备份组件和现有任务会保留；不要删除或移动程序目录。' }
        if ([Windows.Forms.MessageBox]::Show($form,$warning + "`n`n是否执行当前清单？",'最后确认','YesNo','Warning','Button2') -ne 'Yes') { return }
        $go.Enabled=$false
        try {
            if ($LauncherPid -gt 0) {
                $launcher = Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue
                if ($launcher -and -not $launcher.WaitForExit(5000)) { throw '卸载启动器仍在运行，请稍后重试。' }
            }
            $gm = New-Object Threading.Mutex($false,'Local\PinyinLexiconGuiMutex'); $got=$false
            try {
                try { $got=$gm.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got=$true }
                if (-not $got) { throw '管理界面仍在运行，请先关闭其他管理窗口，再执行卸载。' }
                $r=Invoke-UninstallPlan -Plan $p -Confirmed
            } finally { if ($got) { $gm.ReleaseMutex() }; $gm.Dispose() }
            $message = if ($r.Ok) { "清单处理完成，已移除 $($r.Removed.Count) 个文件。" } else { "卸载未完全完成，已移除 $($r.Removed.Count) 个文件。`n`n" + ($r.Errors -join "`n") }
            if ($p.Mode -eq 'GuiOnly') { $message += "`n`n自动备份组件、数据和现有登录任务已保留；任务原先未启用或已挂起时仍保持原状态。" }
            if ($r.TaskRemoved) { $message += "`n`n当前安装的登录任务已移除，自动备份已停止。" }
            if ($r.Retained.Count) { $message += "`n`n保留项：`n" + ($r.Retained -join "`n") }
            if ($p.Mode -eq 'Full') { $message += "`n`n未知文件、其他安装的任务和历史共用缓存不在删除范围。" }
            [Windows.Forms.MessageBox]::Show($form,$message,'卸载结果','OK',$(if ($r.Ok) {'Information'} else {'Warning'})) | Out-Null
            $form.Close()
        } catch {
            [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'卸载未执行或未完成','OK','Error') | Out-Null
            & $refresh
        }
    })
    $form.Controls.AddRange(@($full,$gui,$notice,$preview,$go,$cancel))
    & $refresh
    $null=$form.ShowDialog()
    $form.Dispose()
} catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'卸载程序无法启动','OK','Error') | Out-Null; exit 1 }

#Requires -Version 5.1
# 登录静默检查 —— 微软拼音词库备份
#
# 由 silent-check.exe（登录计划任务）启动，也可手动运行：
#   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File src\pinyin-gui\auto-check.ps1
#   -BaseDir <仓库根>        指定程序根目录（默认：脚本所在目录上两级）
#   -ImeDir / -ImeProcessNames / -HelperProcessName / -TaskName   测试注入（虚构数据）
#
# 行为约定（与产品需求一致）：
#   - 读取配置 → 检查词库 → 判断是否到期 → 必要时备份 → 退出。
#   - 正常检查、正常备份、未到期跳过、内容相同跳过：完全静默（无窗口/托盘/气泡）。
#   - 错误按类型弹可理解的窗（说明在做什么、哪一步失败、有没有改动、用户能做什么）；
#     同一轮执行中同一问题只提示一次。
#   - 发现疑似词库丢失只能「建议恢复」：明确确认（是）才执行；否/取消/关闭都不执行。

param(
    [string]$BaseDir = '',
    [string]$ImeDir = '',
    [string[]]$ImeProcessNames = @(),
    [string]$HelperProcessName = '',
    [string]$TaskName = ''
)

$ErrorActionPreference = 'Stop'
$script:AppDir = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

$script:ShownTopics = @{}   # 同一轮执行同一问题只提示一次

function Write-CheckCrashLog {
    <# 尽力写崩溃日志（应用专属临时目录）；失败不影响主流程。 #>
    param([string]$Message)
    try {
        $dir = Join-Path $env:TEMP 'PinyinLexiconBackup'
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Add-Content -LiteralPath (Join-Path $dir 'auto-check-crash.log') `
            -Value "[$(Get-Date -Format s)] $Message" -Encoding UTF8
    } catch { }
}

function Show-CheckAlert {
    <# 错误/异常提示（正常路径不调用）。返回所点按钮。 #>
    param(
        [string]$Topic,                 # 去重键：同一 Topic 本轮只弹一次
        [string]$Message,
        [string]$Title = '微软拼音词库备份',
        [string]$Buttons = 'OK',
        [string]$Icon = 'Warning'
    )
    if ($script:ShownTopics.ContainsKey($Topic)) { return $null }
    $script:ShownTopics[$Topic] = $true
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
    } catch {
        # WPF 渲染不可用时，使用不依赖它的系统窗口，避免错误被静默吞掉。
        Add-Type -AssemblyName System.Windows.Forms
        return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
    }
}

function Get-ConfiguredContext {
    <# 组装上下文；配置无效时弹窗说明并返回 $null（绝不按另一套参数运行）。 #>
    $ctxArgs = @{ BaseDir = $BaseDir }
    if ($ImeDir) { $ctxArgs.ImeDir = $ImeDir }
    if ($ImeProcessNames.Count -gt 0) { $ctxArgs.ImeProcessNames = $ImeProcessNames }
    if ($HelperProcessName) { $ctxArgs.HelperProcessName = $HelperProcessName }
    if ($TaskName) { $ctxArgs.TaskName = $TaskName }

    $ctx = New-EngineContext @ctxArgs
    if (-not $ctx.Ok) {
        Show-CheckAlert -Topic 'config-invalid' -Icon 'Error' -Message (
            "登录自动检查没有执行。`n`n" +
            ($ctx.Errors -join "`n") + "`n`n" +
            "本次未读取词库、未做任何备份或修改。`n" +
            "请打开主程序（双击 open-gui.exe）在『设置』中修正配置后重试。"
        ) | Out-Null
        return $null
    }
    return $ctx
}

try {
    Import-Module (Join-Path $script:AppDir 'gui-config.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $script:AppDir 'engine.psm1') -DisableNameChecking -ErrorAction Stop

    $ctx = Get-ConfiguredContext
    if (-not $ctx) { exit 2 }  # 2 = 已向用户提示，启动器不重复弹窗

    # 挂起状态：用户主动清词库期间，静默退出（这是用户安排，不是错误）
    if (Test-EngineSuspended -Ctx $ctx) {
        Write-EngineLog -Ctx $ctx -Action 'check' -Result 'suspended' -Detail ''
        exit 0
    }

    # ---- 词库读取（暂时被占用 → 少量有上限的重试） ----
    $lex = $null
    $readOk = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lex = Get-EngineLexiconStatus -Ctx $ctx
        if ($lex.State -eq 'ok') { $readOk = $true; break }
        if ($lex.State -ne 'locked') { break }        # missing/malformed 重试无意义
        Start-Sleep -Seconds 2
    }

    if (-not $readOk) {
        switch ($lex.State) {
            'locked' {
                Write-EngineLog -Ctx $ctx -Action 'check' -Result 'locked' -Detail $lex.Note
                Show-CheckAlert -Topic 'lexicon-locked' -Message (
                    "登录检查：无法读取词库文件。`n`n" +
                    "$($lex.Note)`n`n" +
                    "已自动重试 3 次仍被占用（通常是输入法进程正在写入）。`n" +
                    "本次没有做任何备份，也没有修改任何数据；词库本身不受影响。`n" +
                    "下次登录会再次检查；也可打开主程序手动备份。"
                ) | Out-Null
                exit 2
            }
            'missing' {
                Write-EngineLog -Ctx $ctx -Action 'check' -Result 'missing' -Detail $lex.Note
                Show-CheckAlert -Topic 'lexicon-missing' -Message (
                    "登录检查：没有找到词库文件。`n`n" +
                    "$($lex.Note)`n`n" +
                    "可能的原因：词库被手动删除或清空、输入法数据目录变化。`n" +
                    "本次没有做任何修改，也不会用备份覆盖任何数据。`n" +
                    "如果这是你主动清空词库导致的，请在主程序里使用『挂起值守』避免反复提醒；`n" +
                    "如果并非你本人操作，可打开主程序在存档记录中查看并恢复备份。"
                ) | Out-Null
                exit 2
            }
            default {
                Write-EngineLog -Ctx $ctx -Action 'check' -Result "unclear-$($lex.State)" -Detail $lex.Note
                Show-CheckAlert -Topic 'lexicon-unclear' -Message (
                    "登录检查：词库文件内容无法解析（可能损坏）。`n`n" +
                    "$($lex.Note)`n`n" +
                    "本次没有做任何修改。为安全起见，程序不会在无法判断时自动覆盖数据。`n" +
                    "可打开主程序查看存档记录；如需恢复请从列表中选择具体备份。"
                ) | Out-Null
                exit 2
            }
        }
    }

    # ---- 健康判定 ----
    $verdict = Get-EngineHealthVerdict -Ctx $ctx

    if ($verdict.Verdict -eq 'suspect') {
        Write-EngineLog -Ctx $ctx -Action 'check' -Result 'lost-detected' `
            -Detail "词数=$($verdict.Words) 阈值=$($verdict.Threshold) 基线=$($verdict.Baseline)"
        $latest = $verdict.LatestBackup
        if ($latest) {
            $recommend = "推荐从最近一次备份恢复：`n" +
                         "　存档：$($latest.Name)（$($latest.Words) 个词组，估算值，$($latest.Time)）"
        } else {
            $recommend = "（没有找到可用作恢复来源的备份）"
        }
        $choice = Show-CheckAlert -Topic 'lost-suspect' -Buttons 'YesNoCancel' -Message (
            "检测到微软拼音词库疑似被清空。`n`n" +
            "判定依据：$($verdict.Note)`n" +
            "输入法进程在运行、词库目录近期无写入，因此判定为疑似异常（词数为估算值，仅供参考）。`n`n" +
            $recommend + "`n`n" +
            "是 = 立即恢复（会先把当前数据完整保全到 quarantine，再覆盖）`n" +
            "否 = 本次跳过，下次登录再查`n" +
            "取消 = 什么都不做`n`n" +
            "关闭本窗口或选择否/取消都不会执行恢复。"
        )
        if ([string]$choice -eq 'Yes' -and $latest) {
            $rr = Invoke-EngineRestore -Ctx $ctx -SnapshotName $latest.Name
            if ($rr.Outcome -eq 'success') {
                Show-CheckAlert -Topic 'restore-done' -Icon 'Information' -Message (
                    "恢复完成：已从 $($latest.Name) 恢复词库。`n`n" +
                    "恢复前的数据已保全到 quarantine 目录（$($rr.QuarantineName)），确认无误后可在主程序中查看。`n" +
                    "输入法进程已尝试重新启动；如果输入法未恢复工作，请注销重新登录一次。"
                ) | Out-Null
                exit 0
            } else {
                Show-CheckAlert -Topic 'restore-failed' -Icon 'Error' -Message (
                    "恢复没有完成。`n`n" +
                    ($rr.Errors -join "`n") + "`n`n" +
                    "请按上面的恢复或回退结果处理，并保留现场文件；可打开主程序查看日志。"
                ) | Out-Null
                exit 2
            }
        } else {
            Write-EngineLog -Ctx $ctx -Action 'recovery' -Result 'user-skip' -Detail "用户未确认恢复，词数=$($verdict.Words)"
            exit 0
        }
    }

    if ($verdict.Verdict -eq 'unknown') {
        # 无法判断（无基线 / 附加验证不满足）：不是错误，静默记日志退出
        Write-EngineLog -Ctx $ctx -Action 'check' -Result 'unknown' -Detail $verdict.Note
        exit 0
    }

    # ---- 健康 → 按到期规则备份（正常路径全部静默） ----
    $backup = Invoke-EngineBackup -Ctx $ctx
    switch ($backup.Outcome) {
        'success' {
            if (@($backup.RotationErrors).Count -gt 0) {
                Show-CheckAlert -Topic 'cleanup-failed' -Message (
                    "备份成功，但旧备份清理失败。`n`n新备份：$($backup.SnapshotName)`n`n" +
                    (@($backup.RotationErrors) -join "`n") + "`n`n" +
                    "新备份已保留；部分旧备份可能仍占用空间。请打开主程序查看记录并重新确认清理。"
                ) | Out-Null
                exit 2
            }
            exit 0
        }
        'skip-not-due'   { exit 0 }   # 未到期，静默
        'skip-duplicate' { exit 0 }   # 内容相同跳过，静默
        'busy'           { exit 0 }   # 手动操作正在进行（GUI 打开着）：本次让位，静默
        'failed' {
            Show-CheckAlert -Topic 'backup-failed' -Icon 'Error' -Message (
                "登录自动备份没有完成。`n`n" +
                ($backup.Errors -join "`n") + "`n`n" +
                "词库文件本身未被修改；已有的备份不受影响。`n" +
                "下次登录会再次尝试；也可打开主程序手动备份。"
            ) | Out-Null
            exit 2
        }
        default { exit 0 }
    }
}
catch {
    # 兜底：任何未预期异常，说明白在做什么、无数据损坏、怎么处理
    $ctxForLog = $null
    try {
        Write-CheckCrashLog "登录检查异常：$($_.Exception.GetType().FullName)：$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    } catch { }
    Show-CheckAlert -Topic 'unexpected' -Icon 'Error' -Message (
        "登录检查遇到未预期的问题，已停止。`n`n" +
        "$($_.Exception.Message)`n`n" +
        "本次操作未能正常完成。请查看日志确认已经执行到哪一步；若正在恢复，请保留备份和 quarantine 中的数据。`n" +
        "如果反复出现，请打开主程序查看日志，或反馈这个问题。"
    ) | Out-Null
    exit 2
}

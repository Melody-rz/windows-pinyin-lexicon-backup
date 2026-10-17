#Requires -Version 5.1
# GUI 模块单元测试 —— 全部使用临时目录与虚构数据，不接触真实词库与真实备份。
# 运行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# 输出：逐项 PASS/FAIL 与汇总；有失败时退出码为 1。

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSScriptRoot   # 仓库根
$guiDir     = Join-Path $scriptRoot 'src\pinyin-gui'

Import-Module (Join-Path $guiDir 'gui-config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $guiDir 'gui-status.psm1') -Force -DisableNameChecking

# ---------- 极简断言框架 ----------
$script:PassCount = 0
$script:FailCount = 0
$script:Failures  = @()

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:PassCount++
        Write-Output "PASS  $Name"
    } else {
        $script:FailCount++
        $script:Failures += "$Name  $Detail"
        Write-Output "FAIL  $Name  $Detail"
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ("$Expected" -eq "$Actual")
    Assert-True -Name $Name -Condition $ok -Detail ("期望 [{0}] 实际 [{1}]" -f $Expected, $Actual)
}

# ---------- 测试临时目录 ----------
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pinyin-gui-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Write-Output "测试目录：$testRoot`n"

try {
    # ================= 配置模块 =================
    Write-Output '---- gui-config.psm1 ----'

    # T01 默认值
    $def = Get-GuiConfigDefaults -BaseDir $testRoot
    Assert-Equal 'T01a 默认备份间隔为 7'          7      $def['BackupIntervalDays']
    Assert-Equal 'T01b 默认保留份数为 30'         30     $def['KeepCount']
    Assert-Equal 'T01c 空备份位置回退到程序目录下 snapshots' (Join-Path $testRoot 'snapshots') $def['BackupDir']
    Assert-Equal 'T01d 登录启动默认关闭'          'False' $def['LoginStart']

    # T02 无配置文件 → 默认值 + Loaded=false
    $r = Read-GuiConfig -Path (Join-Path $testRoot 'no-such.json') -BaseDir $testRoot
    Assert-True  'T02a 缺失文件时 Loaded=false'   (-not $r.Loaded)
    Assert-Equal 'T02b 缺失文件时间隔用默认 7'     7      $r.Config['BackupIntervalDays']
    Assert-Equal 'T02c 缺失文件时无错误'           0      $r.Errors.Count

    # T03 合法配置文件 → 值被采用
    $cfgPath = Join-Path $testRoot 'config.json'
    @'
{"BackupIntervalDays": 14, "KeepCount": 10, "BackupDir": "E:\\tmp\\fake-snap", "ShowAlertOnLoss": false, "LoginDelaySeconds": 60, "DeduplicateBackup": false, "MaxLogMB": 2}
'@ | Set-Content -Path $cfgPath -Encoding UTF8
    $r = Read-GuiConfig -Path $cfgPath -BaseDir $testRoot
    Assert-True  'T03a 合法文件 Loaded=true'       $r.Loaded
    Assert-Equal 'T03b 间隔读取为 14'              14     $r.Config['BackupIntervalDays']
    Assert-Equal 'T03c 保留份数读取为 10'          10     $r.Config['KeepCount']
    Assert-Equal 'T03d 备份位置读取为指定值'       'E:\tmp\fake-snap' $r.Config['BackupDir']
    Assert-True  'T03e 已移除的开关字段被忽略（不再提供关闭错误提醒的设置）' ($null -eq $r.Config['ShowAlertOnLoss'])
    Assert-Equal 'T03f 缺失字段 LoginStart 沿用默认' 'False' $r.Config['LoginStart']

    # T04 损坏 JSON → 默认值 + 错误说明
    'not-json{{{' | Set-Content -Path $cfgPath -Encoding UTF8
    $r = Read-GuiConfig -Path $cfgPath -BaseDir $testRoot
    Assert-True  'T04a 损坏文件回退默认值'         ($r.Config['BackupIntervalDays'] -eq 7)
    Assert-True  'T04b 损坏文件给出错误说明'       ($r.Errors.Count -ge 1)

    # T05 字段值无法识别 → 该字段回退默认并提示
    '{"BackupIntervalDays": "abc", "KeepCount": 5}' | Set-Content -Path $cfgPath -Encoding UTF8
    $r = Read-GuiConfig -Path $cfgPath -BaseDir $testRoot
    Assert-Equal 'T05a 非法间隔回退默认 7'         7      $r.Config['BackupIntervalDays']
    Assert-Equal 'T05b 合法字段正常读取 5'         5      $r.Config['KeepCount']
    Assert-True  'T05c 非法字段有提示'             ($r.Errors.Count -ge 1)

    # T06 校验：范围与格式
    $bad = Get-GuiConfigDefaults -BaseDir $testRoot
    $bad['BackupIntervalDays'] = 999
    $bad['KeepCount'] = 0
    $bad['MaxLogMB'] = 99
    $c = Test-GuiConfig -Config $bad
    Assert-True 'T06a 超范围数值校验失败'          (-not $c.Valid)
    Assert-True 'T06b 错误里含字段中文名'          (($c.Errors -join ' ') -like '*备份间隔*')

    $bad2 = Get-GuiConfigDefaults -BaseDir $testRoot
    $bad2['BackupDir'] = 'a|b<c>'
    $c2 = Test-GuiConfig -Config $bad2
    Assert-True 'T06c 非法路径字符校验失败'        (-not $c2.Valid)

    $good = Get-GuiConfigDefaults -BaseDir $testRoot
    $good['BackupDir'] = 'snapshots'
    $c3 = Test-GuiConfig -Config $good
    Assert-True 'T06d 默认+相对路径校验通过'       $c3.Valid

    # T07 保存：合法配置写出标准 JSON，可回读
    $savePath = Join-Path $testRoot 'sub\config.json'
    $toSave = Get-GuiConfigDefaults -BaseDir $testRoot
    $toSave['BackupIntervalDays'] = 21
    $toSave['KeepCount'] = 15
    $s = Save-GuiConfig -Path $savePath -Config $toSave
    Assert-True  'T07a 合法配置保存成功'           $s.Success
    Assert-True  'T07b 保存文件存在'               (Test-Path $savePath)
    $back = Read-GuiConfig -Path $savePath -BaseDir $testRoot
    Assert-Equal 'T07c 保存后回读间隔为 21'        21     $back.Config['BackupIntervalDays']
    Assert-Equal 'T07d 保存后回读份数为 15'        15     $back.Config['KeepCount']
    $rawText = Get-Content $savePath -Raw
    Assert-True 'T07e JSON 不含注释符号'           ($rawText -notmatch '//')

    # T08 保存：非法配置失败且旧文件不动
    $before = Get-Content $savePath -Raw
    $badSave = Get-GuiConfigDefaults -BaseDir $testRoot
    $badSave['KeepCount'] = -3
    $s2 = Save-GuiConfig -Path $savePath -Config $badSave
    Assert-True  'T08a 非法配置保存失败'           (-not $s2.Success)
    Assert-Equal 'T08b 旧配置文件未被改动'         $before (Get-Content $savePath -Raw)
    Assert-True  'T08c 残留临时文件已清理'         (-not (Test-Path "$savePath.tmp"))

    # T20 保存成功后留有可回退的旧配置备份（File.Replace 的 .bak）
    $toSaveB = Get-GuiConfigDefaults -BaseDir $testRoot
    $toSaveB['BackupIntervalDays'] = 30
    $toSaveB['KeepCount'] = 40
    $s3 = Save-GuiConfig -Path $savePath -Config $toSaveB
    Assert-True  'T20a 再次保存成功'               $s3.Success
    $bakPath = "$savePath.bak"
    Assert-True  'T20b 旧配置备份文件存在'         (Test-Path $bakPath)
    $bakJson = Get-Content $bakPath -Raw | ConvertFrom-Json
    Assert-Equal 'T20c 备份内容是旧配置（间隔 21）' 21 $bakJson.BackupIntervalDays
    Assert-Equal 'T20d 新配置已生效（间隔 30）'    30 (Read-GuiConfig -Path $savePath -BaseDir $testRoot).Config['BackupIntervalDays']

    # T21 替换失败时旧配置保得住（模拟：目标文件被其他程序占用）
    $lockPath = Join-Path $testRoot 'locked\config.json'
    $first = Get-GuiConfigDefaults -BaseDir $testRoot
    $first['BackupIntervalDays'] = 5
    $first['KeepCount'] = 6
    $null = Save-GuiConfig -Path $lockPath -Config $first
    $toSaveC = Get-GuiConfigDefaults -BaseDir $testRoot
    $toSaveC['BackupIntervalDays'] = 99
    $toSaveC['KeepCount'] = 98
    # 用「允许读、不许写删」的方式占用目标：既模拟别的程序正用着配置文件，
    # 又让本测试还能读回旧内容做断言（完全独占会连读都不行）。
    $lock = [System.IO.File]::Open($lockPath, 'Open', 'Read', 'Read')
    try {
        $s4 = Save-GuiConfig -Path $lockPath -Config $toSaveC
        Assert-True  'T21a 目标被占用时保存失败'    (-not $s4.Success)
        $kept = Read-GuiConfig -Path $lockPath -BaseDir $testRoot
        Assert-Equal 'T21b 旧配置仍在（间隔 5）'    5  $kept.Config['BackupIntervalDays']
        Assert-Equal 'T21c 旧配置仍在（份数 6）'    6  $kept.Config['KeepCount']
    } finally {
        $lock.Dispose()
    }
    Assert-True  'T21d 残留临时文件已清理'         (-not (Test-Path "$lockPath.tmp"))
    $s5 = Save-GuiConfig -Path $lockPath -Config $toSaveC
    Assert-True  'T21e 解除占用后保存成功'         $s5.Success
    Assert-Equal 'T21f 解除占用后新配置生效'       99 (Read-GuiConfig -Path $lockPath -BaseDir $testRoot).Config['BackupIntervalDays']

    # T22 首次保存（无旧文件）走 Move，不需要备份
    $freshPath = Join-Path $testRoot 'fresh\config.json'
    $toSaveD = Get-GuiConfigDefaults -BaseDir $testRoot
    $s6 = Save-GuiConfig -Path $freshPath -Config $toSaveD
    Assert-True  'T22a 首次保存成功'               $s6.Success
    Assert-True  'T22b 首次保存不产生备份文件'     (-not (Test-Path "$freshPath.bak"))
    Assert-True  'T22c 首次保存不留临时文件'       (-not (Test-Path "$freshPath.tmp"))

    # T09 路径解析
    Assert-Equal 'T09a 相对路径拼接到程序目录'     (Join-Path $testRoot 'my-snaps') (Resolve-GuiBackupDir -BackupDir 'my-snaps' -BaseDir $testRoot)
    Assert-Equal 'T09b 绝对路径原样保留'           'D:\x' (Resolve-GuiBackupDir -BackupDir 'D:\x' -BaseDir $testRoot)
    Assert-Equal 'T09c 空路径回退 snapshots'       (Join-Path $testRoot 'snapshots') (Resolve-GuiBackupDir -BackupDir '' -BaseDir $testRoot)

    # T10 目录可写检查：可创建+可写
    $w = Test-GuiBackupDirWritable -BackupDir (Join-Path $testRoot 'new-snaps') -BaseDir $testRoot
    Assert-True  'T10a 新目录创建并检查可写成功'   $w.Ok

    # T10b 目标被同名文件占用 → 检查失败
    $occupied = Join-Path $testRoot 'occupied'
    Set-Content -Path $occupied -Value 'x'
    $w2 = Test-GuiBackupDirWritable -BackupDir $occupied -BaseDir $testRoot
    Assert-True  'T10b 目录被文件占用时检查失败'   (-not $w2.Ok)

    # ================= 状态模块 =================
    Write-Output '---- gui-status.psm1 ----'

    # T11 日志解析（真实格式样例 + 1 行损坏）
    $logPath = Join-Path $testRoot 'pinyin-backup.log'
    $lines = @(
        '{"action":"backup","detail":"存档=2026-10-14_211812 词数=67","result":"success","time":"2026-10-14 21:18:12"}',
        '{"action":"check","detail":"词数=67","result":"healthy","time":"2026-10-14 21:19:40"}',
        'this-line-is-broken',
        '{"action":"backup","detail":"存档=2026-10-14_234346 词数=72","result":"success","time":"2026-10-14 23:43:46"}'
    )
    Set-Content -Path $logPath -Value $lines -Encoding UTF8
    $log = Get-GuiLogEntries -LogPath $logPath -MaxCount 0
    Assert-True  'T11a 日志文件存在被识别'         $log.FileExists
    Assert-Equal 'T11b 有效条目数 3'               3      $log.Entries.Count
    Assert-Equal 'T11c 损坏行跳过计数 1'           1      $log.SkippedLines
    Assert-Equal 'T11d 字段解析 time'              '2026-10-14 21:18:12' $log.Entries[0].Time
    Assert-Equal 'T11e 字段解析 action'            'backup' $log.Entries[0].Action

    # T12 MaxCount 截断保留最后 N 条（最新）
    $log2 = Get-GuiLogEntries -LogPath $logPath -MaxCount 2
    Assert-Equal 'T12a 截断后数量 2'               2      $log2.Entries.Count
    Assert-Equal 'T12b 保留的是最新一条'           '2026-10-14 23:43:46' $log2.Entries[1].Time

    # T13 日志缺失
    $log3 = Get-GuiLogEntries -LogPath (Join-Path $testRoot 'none.log') -MaxCount 10
    Assert-True  'T13a 缺失日志 FileExists=false'  (-not $log3.FileExists)
    Assert-Equal 'T13b 缺失日志条目为空'           0      $log3.Entries.Count

    # T14 最近一次成功备份
    $hit = Get-GuiLatestBackupFromLog -LogPath $logPath
    Assert-Equal 'T14a 找到最近成功备份'           '2026-10-14 23:43:46' $hit.Time
    '{"action":"check","result":"healthy","time":"t1"}' | Set-Content -Path $logPath -Encoding UTF8
    $hit2 = Get-GuiLatestBackupFromLog -LogPath $logPath
    Assert-True  'T14b 无备份记录时返回空'         ($null -eq $hit2)

    # T15 存档列表（含缺 meta 的存档）
    $snapDir = Join-Path $testRoot 'snapshots'
    New-Item -ItemType Directory -Path (Join-Path $snapDir '2026-10-14_234346') -Force | Out-Null
    '{"source":"manual","words":72,"time":"2026-10-14 23:43:46"}' | Set-Content (Join-Path $snapDir '2026-10-14_234346\meta.json') -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $snapDir '2026-10-15_090000') -Force | Out-Null   # 无 meta.json
    $snaps = Get-GuiSnapshotEntries -SnapDir $snapDir -MaxCount 10
    Assert-Equal 'T15a 存档条目数 2'               2      $snaps.Count
    Assert-Equal 'T15b 按名称倒序，最新在前'       '2026-10-15_090000' $snaps[0].Name
    Assert-True  'T15c 缺 meta 的存档标注未知'     ($snaps[0].MetaOk -eq $false -and $snaps[0].Source -eq '未知')
    Assert-Equal 'T15d 完整存档读取来源'           'manual' $snaps[1].Source

    # T16 存档目录不存在 → 空数组
    $snaps2 = Get-GuiSnapshotEntries -SnapDir (Join-Path $testRoot 'no-snap-dir') -MaxCount 10
    Assert-Equal 'T16 缺失存档目录返回空列表'      0      $snaps2.Count

    # ================= 语法检查 =================
    Write-Output '---- 脚本语法检查 ----'
    foreach ($f in @('gui-app.ps1')) {
        $tokens = $null; $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $guiDir $f), [ref]$tokens, [ref]$parseErrors)
        Assert-True "T17 $f 语法解析通过" ($parseErrors.Count -eq 0) (($parseErrors | ForEach-Object { $_.Message }) -join '; ')
    }

    # 启动器与样例配置
    Assert-True 'T18 open-gui.exe 存在'            (Test-Path (Join-Path $scriptRoot 'open-gui.exe'))
    Assert-True 'T18b 启动器源码存在'              (Test-Path (Join-Path $scriptRoot 'src\launcher\open-gui.cs'))
    Assert-True 'T18c 旧 cmd 启动器已移除'         (-not (Test-Path (Join-Path $scriptRoot 'open-gui.cmd')))
    $exampleValid = $false
    try {
        $null = Get-Content (Join-Path $scriptRoot 'config.example.json') -Raw | ConvertFrom-Json
        $exampleValid = $true
    } catch { $exampleValid = $false }
    Assert-True 'T19 config.example.json 为有效 JSON' $exampleValid
}
finally {
    # 清理测试临时目录
    try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Output ''
Write-Output ("汇总：通过 {0}，失败 {1}" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) {
    Write-Output '失败项：'
    $script:Failures | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
exit 0

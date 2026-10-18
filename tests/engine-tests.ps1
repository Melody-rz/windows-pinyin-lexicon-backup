#Requires -Version 5.1
# 引擎场景测试 —— 全部使用临时目录与虚构数据。
#
# 虚构隔离（不接触本机真实环境）：
#   - 词库目录/进程名/任务名全部注入虚构值；进程名使用不存在的名字（不启停任何真实进程）
#   - 计划任务使用带随机后缀的虚构任务名，测试结束删除
# 覆盖：配置读取、备份成功/失败/跳过、半成品隔离、轮转清理、恢复成功/失败/回退/保全失败、
#       并发互斥、挂起恢复、登录任务注册与移除。
# 运行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\engine-tests.ps1

param([switch]$IncludeScheduledTasks)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSScriptRoot
$guiDir     = Join-Path $scriptRoot 'src\pinyin-gui'
Import-Module (Join-Path $guiDir 'gui-config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $guiDir 'engine.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $guiDir 'gui-status.psm1')  -Force -DisableNameChecking

$script:PassCount = 0
$script:FailCount = 0
$script:Failures  = @()
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:PassCount++; Write-Output "PASS  $Name" }
    else { $script:FailCount++; $script:Failures += "$Name  $Detail"; Write-Output "FAIL  $Name  $Detail" }
}
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ("$Expected" -eq "$Actual")
    if ($ok) { $script:PassCount++; Write-Output "PASS  $Name" }
    else { $script:FailCount++; $script:Failures += "$Name  期望 [$Expected] 实际 [$Actual]"; Write-Output "FAIL  $Name  期望 [$Expected] 实际 [$Actual]" }
}

# ---------- 测试环境 ----------
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("engine-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Write-Output "测试目录：$testRoot`n"

# 虚构词库：构造一段含大量连续汉字串的内容（Unicode 编码，模拟真实 UDL.dat 的编码方式）
$fakeWords = (1..120 | ForEach-Object { '词组样例编号' + $_.ToString('0000') }) -join ''
$fakeBytes = [System.Text.Encoding]::Unicode.GetBytes($fakeWords)

function New-FakeIme {
    param([string]$Dir)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $Dir 'ChsPinyinUDL.dat'), $fakeBytes)
    Set-Content -LiteralPath (Join-Path $Dir 'aux-config.dat') -Value 'aux' -Encoding ASCII
}

function New-TestContext {
    param([string]$ImeSub = 'ime', [hashtable]$ConfigOverride = @{})
    $base = Join-Path $testRoot $ImeSub
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $imeDir = Join-Path $base 'ime-data'
    New-FakeIme -Dir $imeDir
    # 写配置
    $cfg = @{
        BackupIntervalDays = 7; KeepCount = 30; BackupDir = 'snapshots'
        LoginStart = $false; LoginDelaySeconds = 20; DeduplicateBackup = $true; MaxLogMB = 5
    }
    foreach ($k in $ConfigOverride.Keys) { $cfg[$k] = $ConfigOverride[$k] }
    $null = Save-GuiConfig -Path (Join-Path $base 'config.json') -Config $cfg
    return New-EngineContext -BaseDir $base -ImeDir $imeDir `
        -ImeProcessNames @('PinyinFakeIME') -HelperProcessName 'PinyinFakeHelper' `
        -TaskName ('PinyinEngineTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

try {
    # ================= 上下文 =================
    Write-Output '---- New-EngineContext ----'

    $ctx = New-TestContext -ImeSub 'c1'
    Assert-True  'E01 上下文创建成功（配置合法）' $ctx.Ok
    Assert-Equal 'E02 词库路径注入生效' (Join-Path $ctx.BaseDir 'ime-data') $ctx.Paths.ImeDir
    Assert-True  'E03 测试模式下进程名为虚构名' ($ctx.ImeProcessNames -contains 'PinyinFakeIME')

    # 配置损坏 → 拒绝执行
    $badBase = Join-Path $testRoot 'c-bad'
    New-Item -ItemType Directory -Path $badBase -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $badBase 'config.json') -Value '{ not valid json' -Encoding UTF8
    $badCtx = New-EngineContext -BaseDir $badBase -ImeDir (Join-Path $badBase 'ime') -ImeProcessNames @('PinyinFakeIME') -HelperProcessName 'PinyinFakeHelper'
    Assert-True  'E04 配置损坏时上下文拒绝执行（Ok=false）' (-not $badCtx.Ok)
    Assert-True  'E05 配置损坏的错误说明包含路径' ($badCtx.Errors[0] -like "*config.json*")

    # ================= 词库状态 =================
    Write-Output ''
    Write-Output '---- Get-EngineLexiconStatus ----'

    $lex = Get-EngineLexiconStatus -Ctx $ctx
    Assert-Equal 'E06 虚构词库可读' 'ok' $lex.State
    Assert-True  'E07 估算词数 > 0' ($lex.Words -gt 0)

    $missCtx = New-EngineContext -BaseDir (Join-Path $testRoot 'c-miss') -ImeDir (Join-Path $testRoot 'c-miss\none') -ImeProcessNames @('PinyinFakeIME') -HelperProcessName 'PinyinFakeHelper'
    $miss = Get-EngineLexiconStatus -Ctx $missCtx
    Assert-Equal 'E08 词库缺失判定 missing' 'missing' $miss.State

    # ================= 手动备份 =================
    Write-Output ''
    Write-Output '---- Invoke-EngineBackup (manual) ----'

    $r1 = Invoke-EngineBackup -Ctx $ctx -Manual
    Assert-Equal 'E10 手动备份成功' 'success' $r1.Outcome
    Assert-True  'E11 存档目录已生成' (Test-Path (Join-Path $ctx.Paths.SnapDir $r1.SnapshotName))
    Assert-True  'E12 存档含 meta.json' (Test-Path (Join-Path (Join-Path $ctx.Paths.SnapDir $r1.SnapshotName) 'meta.json'))
    $snap1 = Get-EngineSnapshots -Ctx $ctx
    Assert-Equal 'E13 快照枚举包含新存档' 1 @($snap1).Count
    Assert-Equal 'E14 存档来源标记 manual' 'manual' $snap1[0].Source

    # 半成品与无 meta 目录不参与枚举
    $null = New-Item -ItemType Directory -Path (Join-Path $ctx.Paths.SnapDir '.pending-xxxx') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $ctx.Paths.SnapDir '2020-01-01_000000') -Force
    $snapDirty = Get-EngineSnapshots -Ctx $ctx
    Assert-Equal 'E15 半成品与无 meta 目录不被枚举' 1 @($snapDirty).Count

    # 自动备份：未到期 → skip-not-due
    $r2 = Invoke-EngineBackup -Ctx $ctx
    Assert-Equal 'E16 未到期自动备份跳过' 'skip-not-due' $r2.Outcome

    # 到期 + 内容相同 → skip-duplicate
    $metaPath = Join-Path (Join-Path $ctx.Paths.SnapDir $r1.SnapshotName) 'meta.json'
    $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $meta.time = (Get-Date).AddDays(-9).ToString('yyyy-MM-dd HH:mm:ss')
    $meta | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding UTF8
    $r3 = Invoke-EngineBackup -Ctx $ctx
    Assert-Equal 'E17 到期但内容相同跳过（去重）' 'skip-duplicate' $r3.Outcome

    # 到期 + 内容变化 → 新备份
    [System.IO.File]::WriteAllBytes($ctx.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes($fakeWords + '新增词组内容测试'))
    $r4 = Invoke-EngineBackup -Ctx $ctx
    Assert-Equal 'E18 到期且内容变化自动备份成功' 'success' $r4.Outcome
    Assert-Equal 'E19 现有存档两份' 2 @(Get-EngineSnapshots -Ctx $ctx).Count

    # 词库缺失 → failed
    $r5 = Invoke-EngineBackup -Ctx $missCtx -Manual
    Assert-Equal 'E20 词库缺失备份失败' 'failed' $r5.Outcome
    Assert-True  'E21 缺失错误含建议' ($r5.Errors[0] -like '*未做任何修改*')

    # 词库被占用 → failed
    $lockBase = Join-Path $testRoot 'c-lock'
    $lockCtx = New-TestContext -ImeSub 'c-lock'
    $fsLock = [System.IO.File]::Open($lockCtx.Paths.UdlFile, 'Open', 'Read', 'None')
    try {
        $r6 = Invoke-EngineBackup -Ctx $lockCtx -Manual
        Assert-Equal 'E22 词库被占用备份失败' 'failed' $r6.Outcome
    } finally { $fsLock.Dispose() }

    # 目标不可写（SnapDir 被同名文件占用）→ failed
    $occBase = Join-Path $testRoot 'c-occ'
    $occCtx = New-TestContext -ImeSub 'c-occ'
    Set-Content -LiteralPath $occCtx.Paths.SnapDir -Value 'not a dir'   # 占位文件
    $r7 = Invoke-EngineBackup -Ctx $occCtx -Manual
    Assert-Equal 'E23 备份目标不可写失败' 'failed' $r7.Outcome

    # 并发互斥：用独立进程持锁再调备份 → busy
    # （Mutex 是可重入锁：同一线程再次 WaitOne 会成功，所以必须跨进程模拟并发）
    $holdScript = Join-Path $testRoot 'hold-lock.ps1'
    @'
$m = New-Object System.Threading.Mutex($false, 'Local\PinyinLexiconBackupOp')
$null = $m.WaitOne(5000)
Start-Sleep -Seconds 10
'@ | Set-Content -LiteralPath $holdScript -Encoding ASCII
    $holder = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holdScript) `
        -PassThru -WindowStyle Hidden
    try {
        $deadline = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $deadline -and -not (Test-EngineOpBusy)) { Start-Sleep -Milliseconds 300 }
        Assert-True  'E24a 独立进程已持有操作锁' (Test-EngineOpBusy)
        $r8 = Invoke-EngineBackup -Ctx $ctx -Manual
        Assert-Equal 'E24 操作期间另一备份被拒（busy）' 'busy' $r8.Outcome
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $holder.WaitForExit(5000) | Out-Null } catch { }
        Remove-Item -LiteralPath $holdScript -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
    Assert-True  'E25 锁释放后不再显示忙' (-not (Test-EngineOpBusy))

    # ================= 轮转清理 =================
    Write-Output ''
    Write-Output '---- Rotation ----'

    $rotCtx = New-TestContext -ImeSub 'c-rot'
    for ($i = 1; $i -le 3; $i++) {
        [System.IO.File]::WriteAllBytes($rotCtx.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes($fakeWords + "第${i}轮差异"))
        $rb = Invoke-EngineBackup -Ctx $rotCtx -Manual
        if ($rb.Outcome -ne 'success') { throw "轮转准备失败：$($rb.Errors -join ';')" }
        Start-Sleep -Milliseconds 1100   # 保证存档名（秒级时间戳）不同
    }
    Assert-Equal 'E30 轮转前存档三份' 3 @(Get-EngineSnapshots -Ctx $rotCtx).Count

    $plan = Get-EngineRotationPlan -Ctx $rotCtx -KeepCount 2
    Assert-Equal 'E31 清理计划列出 1 份' 1 $plan.Remove.Count
    Assert-True  'E32 计划不删最新两份' ($plan.Keep.Count -eq 2)

    $rot = Invoke-EngineRotation -Ctx $rotCtx -KeepCount 2
    Assert-True  'E33 清理执行成功' ($rot.Errors.Count -eq 0)
    Assert-Equal 'E34 清理后存档两份' 2 @(Get-EngineSnapshots -Ctx $rotCtx).Count

    # recovery 存档不参与清理
    $recDir = Join-Path $rotCtx.Paths.SnapDir 'recovery-2020-01-01_000000'
    $null = New-Item -ItemType Directory -Path $recDir -Force
    @{ source = 'recovery'; words = 50; time = '2020-01-01 00:00:00' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $recDir 'meta.json') -Encoding UTF8
    $rot2 = Invoke-EngineRotation -Ctx $rotCtx -KeepCount 1
    Assert-True  'E35 清理成功且 recovery 存档保留' ((Test-Path $recDir) -and $rot2.Errors.Count -eq 0)
    Assert-Equal 'E36 普通存档只剩 1 份' 1 @((Get-EngineSnapshots -Ctx $rotCtx) | Where-Object { $_.Source -in @('auto','manual') }).Count

    # 备份时按配置 KeepCount 自动清理（参数生效）
    $kcCtx = New-TestContext -ImeSub 'c-kc' -ConfigOverride @{ KeepCount = 2 }
    for ($i = 1; $i -le 3; $i++) {
        [System.IO.File]::WriteAllBytes($kcCtx.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes($fakeWords + "配置第${i}轮"))
        $null = Invoke-EngineBackup -Ctx $kcCtx -Manual
        Start-Sleep -Milliseconds 1100
    }
    $kcNormal = @((Get-EngineSnapshots -Ctx $kcCtx) | Where-Object { $_.Source -in @('auto','manual') })
    Assert-Equal 'E37 配置 KeepCount=2 备份后自动清理到 2 份' 2 $kcNormal.Count

    # ================= 恢复 =================
    Write-Output ''
    Write-Output '---- Invoke-EngineRestore ----'

    # 准备：两份内容不同的存档
    $resCtx = New-TestContext -ImeSub 'c-res'
    [System.IO.File]::WriteAllBytes($resCtx.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes($fakeWords))
    $ra = Invoke-EngineBackup -Ctx $resCtx -Manual
    Start-Sleep -Milliseconds 1100
    $contentB = [System.Text.Encoding]::Unicode.GetBytes($fakeWords + '第二份内容差异')
    [System.IO.File]::WriteAllBytes($resCtx.Paths.UdlFile, $contentB)
    $rb2 = Invoke-EngineBackup -Ctx $resCtx -Manual
    Assert-Equal 'E40 恢复准备完成（两份存档）' 2 @(Get-EngineSnapshots -Ctx $resCtx).Count

    # 恢复到第一份：当前词库内容应等于第一份
    $rr = Invoke-EngineRestore -Ctx $resCtx -SnapshotName $ra.SnapshotName
    Assert-Equal 'E41 恢复成功' 'success' $rr.Outcome
    $afterHash = (Get-FileHash -LiteralPath $resCtx.Paths.UdlFile).Hash
    $snapHash  = (Get-FileHash -LiteralPath (Join-Path (Join-Path $resCtx.Paths.SnapDir $ra.SnapshotName) 'ChsPinyinUDL.dat')).Hash
    Assert-Equal 'E42 恢复后内容与所选存档一致（哈希核对）' $snapHash $afterHash
    Assert-True  'E43 恢复前现场已保全' (Test-Path (Join-Path $resCtx.Paths.QuarDir $rr.QuarantineName))
    $recSnaps = @((Get-EngineSnapshots -Ctx $resCtx) | Where-Object { $_.Source -eq 'recovery' })
    Assert-Equal 'E44 生成 recovery 存档' 1 $recSnaps.Count

    # recovery 存档不能作为恢复来源
    $rrBad = Invoke-EngineRestore -Ctx $resCtx -SnapshotName $recSnaps[0].Name
    Assert-Equal 'E45 recovery 存档拒绝恢复' 'failed' $rrBad.Outcome

    # 模糊/错误名 → failed
    $rrMiss = Invoke-EngineRestore -Ctx $resCtx -SnapshotName '2020'
    Assert-Equal 'E46 模糊名拒绝恢复' 'failed' $rrMiss.Outcome
    Assert-True  'E47 模糊名错误说明精确匹配要求' ($rrMiss.Errors[0] -like '*完整存档名*')

    # 存档损坏 → 校验失败，词库不动
    $beforeHash = (Get-FileHash -LiteralPath $resCtx.Paths.UdlFile).Hash
    $arcUdl = Join-Path (Join-Path $resCtx.Paths.SnapDir $rb2.SnapshotName) 'ChsPinyinUDL.dat'
    [System.IO.File]::WriteAllBytes($arcUdl, [System.Text.Encoding]::Unicode.GetBytes('被篡改的内容'))
    $rrCorrupt = Invoke-EngineRestore -Ctx $resCtx -SnapshotName $rb2.SnapshotName
    Assert-Equal 'E48 存档损坏恢复失败' 'failed' $rrCorrupt.Outcome
    Assert-Equal 'E49 词库未被修改' $beforeHash (Get-FileHash -LiteralPath $resCtx.Paths.UdlFile).Hash

    # 保全失败（当前词库文件被独占锁）→ 立即停止，词库未动
    $qsCtx = New-TestContext -ImeSub 'c-qsave'
    $null = Invoke-EngineBackup -Ctx $qsCtx -Manual
    [System.IO.File]::WriteAllBytes($qsCtx.Paths.UdlFile, $contentB)
    $fsQ = [System.IO.File]::Open($qsCtx.Paths.UdlFile, 'Open', 'Read', 'None')
    try {
        $qBefore = (Get-Item -LiteralPath $qsCtx.Paths.UdlFile).Length
        $rrQ = Invoke-EngineRestore -Ctx $qsCtx -SnapshotName @((Get-EngineSnapshots -Ctx $qsCtx) | Where-Object Source -in @('auto','manual'))[0].Name
        Assert-Equal 'E50 保全失败恢复拒绝执行' 'failed' $rrQ.Outcome
        Assert-True  'E51 保全/读取失败说明恢复未执行' ($rrQ.Errors[0] -like '*词库未被修改*')
        Assert-Equal 'E52 词库文件未被修改' $qBefore (Get-Item -LiteralPath $qsCtx.Paths.UdlFile).Length
    } finally { $fsQ.Dispose() }

    # 覆盖失败 → 回退到操作前状态
    # 构造「可读但不可删」：子目录里放被锁文件。保全阶段只需读（可过），
    # 清空阶段需要删（失败）→ 触发真实的覆盖失败→回退路径。
    # （直接锁顶层文件不行：连读都会失败，流程会在保全阶段就安全停止。）
    $ovCtx = New-TestContext -ImeSub 'c-overwrite'
    $null = Invoke-EngineBackup -Ctx $ovCtx -Manual
    $ovBefore = (Get-FileHash -LiteralPath $ovCtx.Paths.UdlFile).Hash
    $lockedSub = Join-Path $ovCtx.Paths.ImeDir 'locked-sub'
    $null = New-Item -ItemType Directory -Path $lockedSub -Force
    $lockedExtra = Join-Path $lockedSub 'locked-extra.dat'
    Set-Content -LiteralPath $lockedExtra -Value 'locked' -Encoding ASCII
    $fsOv = [System.IO.File]::Open($lockedExtra, 'Open', 'Read', [System.IO.FileShare]::Read)
    try {
        $rrOv = Invoke-EngineRestore -Ctx $ovCtx -SnapshotName @((Get-EngineSnapshots -Ctx $ovCtx) | Where-Object Source -in @('auto','manual'))[0].Name
        Assert-Equal 'E53 覆盖失败返回 failed' 'failed' $rrOv.Outcome
        Assert-True  'E54 覆盖失败报告了回退' ($rrOv.Errors[0] -like '*回退*')
        Assert-Equal 'E55 主词库内容回到操作前' $ovBefore (Get-FileHash -LiteralPath $ovCtx.Paths.UdlFile).Hash
    } finally { $fsOv.Dispose() }

    # Issue 4：日期交错、未知来源、超过十份恢复产物，普通备份仍优先。
    $listCtx = New-TestContext -ImeSub 'c-list'
    $null = New-Item -ItemType Directory -Path $listCtx.Paths.SnapDir -Force
    $fixtures = @(
        @{ Name='2026-01-01_000000'; Source='manual' },
        @{ Name='2026-01-03_000000'; Source='auto' },
        @{ Name='2026-01-02_000000'; Source='manual' },
        @{ Name='2099-01-01_000000'; Source='unknown' },
        @{ Name='recovery-2025-12-31_000000'; Source='recovery' }
    )
    foreach ($day in 1..12) { $fixtures += @{ Name=('recovery-2026-02-{0:00}_000000' -f $day); Source='recovery' } }
    foreach ($f in $fixtures) {
        $dir = Join-Path $listCtx.Paths.SnapDir $f.Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        @{ source=$f.Source; words=120; time='2026-01-01 00:00:00' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8
    }
    $shown = @(Get-EngineSnapshots -Ctx $listCtx -MaxCount 10)
    Assert-Equal 'I4 截断十份' 10 $shown.Count
    Assert-Equal 'I4 普通备份按目录时间从新到旧' '2026-01-03_000000,2026-01-02_000000,2026-01-01_000000' (($shown | Select-Object -First 3 | ForEach-Object Name) -join ',')
    Assert-Equal 'I4 健康基线仍为普通备份' '2026-01-03_000000' (Get-EngineLatestBackup -Ctx $listCtx).Name
    Assert-True 'I4 时间交错的恢复产物全部在普通备份之后' (@((Get-EngineSnapshots -Ctx $listCtx | Select-Object -Skip 3) | Where-Object Source -in @('auto','manual')).Count -eq 0)
    $plan = Get-EngineRotationPlan -Ctx $listCtx -KeepCount 1
    Assert-True 'I4 清理只包含旧的两份普通备份' ($plan.Remove.Count -eq 2 -and @($plan.Remove | Where-Object Source -notin @('auto','manual')).Count -eq 0)
    foreach ($f in @($fixtures | Where-Object Source -in @('auto','manual'))) {
        Remove-Item -LiteralPath (Join-Path $listCtx.Paths.SnapDir $f.Name) -Recurse -Force
    }
    $onlyRecovery = @(Get-EngineSnapshots -Ctx $listCtx -MaxCount 10)
    Assert-Equal 'I4 无普通备份仍显示其他记录' 10 $onlyRecovery.Count
    Assert-True 'I4 无普通备份无健康基线' ($null -eq (Get-EngineLatestBackup -Ctx $listCtx))
    Assert-Equal 'I4 恢复产物仍拒绝恢复' 'failed' (Invoke-EngineRestore -Ctx $listCtx -SnapshotName 'recovery-2026-02-12_000000').Outcome

    # Issue 2：模块内部模拟所有进程边界，禁止启动或停止真实进程。
    $engine = Get-Module engine
    $paths = & $engine {
        $ctx = @{ TestMode=$false }
        return @((Get-EngineProcessPath -Ctx $ctx -Name 'ChsIME'), (Get-EngineProcessPath -Ctx $ctx -Name 'ctfmon'))
    }
    Assert-Equal 'I2 微软拼音系统路径' (Join-Path $env:windir 'System32\InputMethod\CHS\ChsIME.exe') $paths[0]
    Assert-Equal 'I2 辅助进程系统路径' (Join-Path $env:windir 'System32\ctfmon.exe') $paths[1]
    Assert-True 'I2 测试上下文不解析真实程序' ($null -eq (& $engine { Get-EngineProcessPath -Ctx @{ TestMode=$true } -Name 'ChsIME' }))
    $restartCtx = New-TestContext -ImeSub 'c-restart'
    $restartBackup = Invoke-EngineBackup -Ctx $restartCtx -Manual
    & $engine {
        $script:SavedResolver = ${function:Get-EngineProcessPath}
        $script:MockStarts = @(); $script:MockStops = @(); $script:MockFail = $false; $script:MockRunning = $true
        function script:Get-Process {
            param($Name, $ErrorAction)
            $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
            # 当前会话与其他会话各一份；停止后只剩其他会话。
            if ($script:MockRunning) { [pscustomobject]@{ Id=123; SessionId=$session } }
            [pscustomobject]@{ Id=456; SessionId=($session + 1) }
        }
        function script:Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:MockStops += $Id; $script:MockRunning = $false }
        function script:Start-Process {
            param($FilePath, $ErrorAction)
            $script:MockStarts += $FilePath
            if ($script:MockFail) { throw '模拟启动失败' }
        }
        function script:Get-EngineProcessPath { param($Ctx, $Name) return $script:MockPath }
    }
    try {
        $mockExe = Join-Path $testRoot 'mock program.exe'
        Set-Content -LiteralPath $mockExe -Value 'fake executable; never executed'
        & $engine { param($path) $script:MockPath=$path } $mockExe
        $restored = Invoke-EngineRestore -Ctx $restartCtx -SnapshotName $restartBackup.SnapshotName
        Assert-Equal 'I2 数据恢复成功' 'success' $restored.Outcome
        Assert-Equal 'I2 重启单独报告成功' 'success' $restored.RestartOutcome
        $calls = & $engine { return @{ Starts=@($script:MockStarts); Stops=@($script:MockStops) } }
        Assert-Equal 'I2 传入明确路径（含空格）' $mockExe $calls.Starts[0]
        Assert-Equal 'I2 只停止当前会话进程' '123' ($calls.Stops -join ',')
        & $engine { $script:MockStarts=@(); $script:MockFail=$true; $script:MockRunning=$true }
        $restored = Invoke-EngineRestore -Ctx $restartCtx -SnapshotName $restartBackup.SnapshotName
        Assert-Equal 'I2 启动失败不改变数据恢复成功结果' 'success' $restored.Outcome
        Assert-True 'I2 启动失败单独报告' ($restored.RestartOutcome -eq 'failed' -and $restored.RestartErrors.Count -gt 0)
        $log = Get-Content -LiteralPath $restartCtx.Paths.LogFile -Raw
        Assert-True 'I2 日志包含程序路径与启动失败原因' ($log.Contains($mockExe.Replace('\','\\')) -and $log.Contains('模拟启动失败'))
        $missing = & $engine { param($ctx) $script:MockPath='Z:\missing.exe'; Restart-EngineProcesses -Ctx $ctx -Names @('PinyinFakeIME') } $restartCtx
        Assert-True 'I2 程序缺失被报告' ($missing.Errors.Count -eq 1 -and $missing.Errors[0] -like '*不存在*')
        $noRestart = & $engine { param($ctx) $script:MockStarts=@(); Restart-EngineProcesses -Ctx $ctx -Names @() } $restartCtx
        Assert-Equal 'I2 原先未运行无需重启' 'not-needed' $noRestart.Outcome
        Assert-Equal 'I2 无需重启没有启动调用' 0 (& $engine { $script:MockStarts.Count })
        $alreadyRunning = & $engine { param($ctx) $script:MockRunning=$true; Restart-EngineProcesses -Ctx $ctx -Names @('PinyinFakeIME') } $restartCtx
        Assert-Equal 'I2 系统已重启则不重复启动' 0 (& $engine { $script:MockStarts.Count })
    } finally {
        & $engine {
            Remove-Item Function:script:Get-Process,Function:script:Stop-Process,Function:script:Start-Process,Function:script:Get-EngineProcessPath
            Set-Item Function:script:Get-EngineProcessPath $script:SavedResolver
        }
    }

    # ================= 挂起 =================
    Write-Output ''
    Write-Output '---- Suspend ----'
    Set-EngineSuspend -Ctx $ctx
    Assert-True  'E60 挂起后状态可查询' (Test-EngineSuspended -Ctx $ctx)
    Clear-EngineSuspend -Ctx $ctx
    Assert-True  'E61 恢复值守后状态清除' (-not (Test-EngineSuspended -Ctx $ctx))

    # ================= 日志 =================
    $logResult = Get-GuiLogEntries -LogPath $ctx.Paths.LogFile -MaxCount 0
    Assert-True 'E62 引擎日志已写入并可解析' ($logResult.Entries.Count -ge 3)

    # ================= 登录任务（虚构任务名） =================
    Write-Output ''
    Write-Output '---- Login task (fictional task name) ----'
    $taskCtx = New-TestContext -ImeSub 'c-task' -ConfigOverride @{ LoginDelaySeconds = 25 }
    $silentExe = Join-Path $scriptRoot 'silent-check.exe'
    if ($IncludeScheduledTasks -and (Test-Path -LiteralPath $silentExe)) {
        $taskCtx.Paths.SilentCheckExe = $silentExe
        try {
            $reg = Register-EngineLoginTask -Ctx $taskCtx
            Assert-True  'E70 登录任务注册成功' $reg.Ok $reg.Error
            $st = Get-EngineTaskStatus -Ctx $taskCtx
            Assert-True  'E71 任务实际已存在' $st.Registered
            Assert-Equal 'E72 任务延迟与配置一致' 25 $st.DelaySeconds

            # 更新延迟（Force 覆盖）
            $taskCtx.Config.LoginDelaySeconds = 66
            $null = Register-EngineLoginTask -Ctx $taskCtx
            $st2 = Get-EngineTaskStatus -Ctx $taskCtx
            Assert-Equal 'E73 任务延迟更新生效' 66 $st2.DelaySeconds

            $un = Unregister-EngineLoginTask -Ctx $taskCtx
            Assert-True  'E74 任务移除成功' $un.Ok $un.Error
            $st3 = Get-EngineTaskStatus -Ctx $taskCtx
            Assert-True  'E75 移除后任务不存在' (-not $st3.Registered)
        } finally {
            # 兜底清理：只删本测试的虚构任务
            try { Unregister-ScheduledTask -TaskName $taskCtx.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        }
    } else {
        Write-Output 'SKIP  E70-E75 实际任务注册测试（默认跳过；仅在明确授权后使用 -IncludeScheduledTasks）'
    }

    # ================= 健康判定 =================
    Write-Output ''
    Write-Output '---- Health verdict ----'
    $h1 = Get-EngineHealthVerdict -Ctx $resCtx
    Assert-True  'E80 有基线时给出判定' ($h1.Verdict -in @('healthy','suspect','unknown'))
    Assert-True  'E81 判定说明标注估算' ($h1.Note -like '*估算*')

    $emptyCtx = New-TestContext -ImeSub 'c-empty'
    [System.IO.File]::WriteAllBytes($emptyCtx.Paths.UdlFile, [System.Text.Encoding]::Unicode.GetBytes('少'))
    $h2 = Get-EngineHealthVerdict -Ctx $emptyCtx
    Assert-Equal 'E82 无基线低词数判 unknown（不冒充确信异常）' 'unknown' $h2.Verdict
    Assert-True  'E83 unknown 说明提到无历史基线' ($h2.Note -like '*没有*' -or $h2.Note -like '*历史*')
}
finally {
    # ---------- 清理：只删本测试创建的目录 ----------
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

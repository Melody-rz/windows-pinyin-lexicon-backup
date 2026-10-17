#Requires -Version 5.1
# 统一执行逻辑（引擎）—— 设置读取 / 词库检查 / 备份 / 恢复 / 清理 / 登录任务
#
# 定位与边界（务必遵守）：
#   - 本模块只做操作并返回结构化结果，绝不弹窗；弹窗由 GUI（gui-app.ps1）
#     与登录检查（auto-check.ps1）负责。
#   - 备份 / 恢复 / 清理内部用命名互斥体（Local\PinyinLexiconBackupOp）互斥：
#     同一时间只能有一个此类操作，避免 GUI、自动检查、命令行并发写入。
#     不通过扫描或结束其他进程解决并发。
#   - 恢复来源只允许 source 为 auto/manual 的存档；recovery（恢复产物）与
#     无 meta 的目录永不作为恢复来源、基线或普通清理对象。
#   - 所有可写路径（词库目录、进程名、任务名）支持注入，测试模式传入虚构值，
#     不接触本机真实词库、不停真实输入法、不注册真实计划任务。
#   - 词组数量是估算值：以字节流中连续汉字串的匹配数估算，不是精确解析。

# 依赖 gui-config.psm1 的配置读写。注意不用 -Force：强制重载会把调用方已加载的
# 同名模块重新装载成本模块的私有依赖，导致调用方（GUI / 测试）失去那些函数。
Import-Module (Join-Path $PSScriptRoot 'gui-config.psm1') -DisableNameChecking

$script:OpMutexName = 'Local\PinyinLexiconBackupOp'

# ============ 上下文 ============
function New-EngineContext {
    <# 组装一次操作所需的全部路径与配置。
       返回 @{ Ok; Errors; Config; Paths; TestMode }。
       配置文件存在但损坏/非法时 Ok=$false（调用方必须提示，不得按另一套参数运行）；
       配置文件不存在 = 首次使用，用默认值（合法）。 #>
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        # 以下参数仅供测试注入；留空即用生产默认值
        [string]$ImeDir = '',
        [string[]]$ImeProcessNames = @(),
        [string]$HelperProcessName = '',
        [string]$TaskName = '',
        [string]$UserName = '',
        [hashtable]$ConfigOverride
    )

    $testMode = -not [string]::IsNullOrWhiteSpace($ImeDir)

    if ([string]::IsNullOrWhiteSpace($ImeDir)) {
        $ImeDir = Join-Path $env:APPDATA 'Microsoft\InputMethod\CHS'
    }
    if ($ImeProcessNames.Count -eq 0) { $ImeProcessNames = @('ChsIME') }
    if ([string]::IsNullOrWhiteSpace($HelperProcessName)) { $HelperProcessName = 'ctfmon' }
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = 'PinyinLexiconBackupLogin' }
    if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = "$env:USERDOMAIN\$env:USERNAME" }

    $configPath = Join-Path $BaseDir 'config.json'
    $cfgResult = if ($PSBoundParameters.ContainsKey('ConfigOverride')) {
        @{ Config = $ConfigOverride.Clone(); Errors = @() }
    } else {
        Read-GuiConfig -Path $configPath -BaseDir $BaseDir
    }
    $validation = Test-GuiConfig -Config $cfgResult.Config
    if (-not $validation.Valid) { $cfgResult.Errors += @($validation.Errors) }

    # 区分「首次使用（无文件）」与「配置无效（文件存在但读不懂/字段非法）」
    $invalid = ($cfgResult.Errors.Count -gt 0)
    if ($invalid) {
        return @{
            Ok = $false
            Errors = @("配置文件无效（$configPath）：`n" + ($cfgResult.Errors -join "`n") +
                       "`n为避免按错误的参数运行，本次操作未执行。请在 GUI 设置中修正后重试。")
            Config = $null; BaseDir = $BaseDir; TestMode = $testMode
        }
    }

    $cfg = $cfgResult.Config
    $snapDir = Resolve-GuiBackupDir -BackupDir $cfg.BackupDir -BaseDir $BaseDir

    $silentCheckExe = Join-Path $BaseDir 'silent-check.exe'
    if (-not (Test-Path -LiteralPath $silentCheckExe)) { $silentCheckExe = $null }

    return @{
        Ok = $true
        Errors = @()
        Config = $cfg
        BaseDir = $BaseDir
        TestMode = $testMode
        Paths = @{
            ImeDir        = $ImeDir
            UdlFile       = Join-Path $ImeDir 'ChsPinyinUDL.dat'
            SnapDir       = $snapDir
            QuarDir       = Join-Path $BaseDir 'quarantine'
            LogFile       = Join-Path $BaseDir 'pinyin-backup.log'
            SuspendFile   = Join-Path $BaseDir 'suspend.tag'
            ConfigPath    = $configPath
            SilentCheckExe = $silentCheckExe
        }
        ImeProcessNames  = $ImeProcessNames
        HelperProcessName = $HelperProcessName
        TaskName  = $TaskName
        UserName  = $UserName
    }
}

# ============ 日志 ============
function Write-EngineLog {
    <# 统一写流水日志（JSON 行）。超限截断由 MaxLogMB 控制。写失败时吞掉并返回 $false。 #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Detail = ''
    )
    try {
        $logFile = $Ctx.Paths.LogFile
        $maxMb = [int]$Ctx.Config.MaxLogMB
        if ($maxMb -lt 1) { $maxMb = 1 }
        if ((Test-Path -LiteralPath $logFile) -and ((Get-Item -LiteralPath $logFile).Length -gt ($maxMb * 1MB))) {
            Set-Content -LiteralPath $logFile -Value "[$(Get-Date -Format s)] 日志超 $maxMb MB 已截断" -Encoding UTF8
        }
        $entry = @{
            time   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            action = $Action
            result = $Result
            detail = $Detail
        } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $logFile -Value $entry -Encoding UTF8
    } catch {
        # 日志写失败不中断操作。注意：绝不能 return 布尔值——调用处都不接返回值，
        # 任何返回值都会混进调用函数的输出流，污染结构化结果（教训：曾把
        # Invoke-EngineBackup 的返回 hashtable 变成 object[2]，下游 .Errors 全乱）。
    }
}

# ============ 词库状态 ============
function Get-EngineLexiconStatus {
    <# 读取词库并返回 @{ State = ok|missing|locked|malformed; Words; Note }。
       Words 为估算词组数（连续汉字串匹配数），仅 State=ok 时有效。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)

    $udl = $Ctx.Paths.UdlFile
    if (-not (Test-Path -LiteralPath $udl -PathType Leaf)) {
        return @{ State = 'missing'; Words = -1; Note = "词库文件不存在：$udl" }
    }
    $bytes = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($udl)
    } catch {
        return @{ State = 'locked'; Words = -1; Note = "词库文件暂时无法读取（可能被输入法进程占用）：$udl" }
    }
    try {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes)
        $count = [regex]::Matches($text, '[\u4e00-\u9fff]{2,}').Count
        return @{ State = 'ok'; Words = $count; Note = "估算词组数 $count" }
    } catch {
        return @{ State = 'malformed'; Words = -1; Note = "词库文件内容无法解析（可能损坏）：$udl" }
    }
}

# ============ 存档枚举 ============
function Get-EngineSnapshots {
    <# 列出 SnapDir 下的正式存档（含有效 meta.json），按名称倒序（新→旧）。
       .pending-* 半成品目录与无 meta 目录不返回（它们不是成功备份）。 #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [int]$MaxCount = 0    # 0 = 全部
    )
    $snapDir = $Ctx.Paths.SnapDir
    if (-not (Test-Path -LiteralPath $snapDir -PathType Container)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem -LiteralPath $snapDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if ($d.Name -like '.pending-*') { continue }
        $metaPath = Join-Path $d.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) { continue }
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # pscustomobject：hashtable 会被 @() 展开成键值对（单元素时 Count 变成键数），
            # 且不支持 .属性 访问；pscustomobject 两者都正常。
            $out += [pscustomobject]@{
                Name   = $d.Name
                Source = [string]$meta.source
                Words  = [int]$meta.words
                Time   = [string]$meta.time
                Dir    = $d.FullName
            }
        } catch { continue }
    }
    if ($MaxCount -gt 0 -and $out.Count -gt $MaxCount) {
        return @($out | Select-Object -First $MaxCount)
    }
    return $out
}

function Get-EngineLatestBackup {
    <# 最近一次普通备份（source=auto/manual）。恢复产物（recovery）不作为基线。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    $normal = @()
    foreach ($s in (Get-EngineSnapshots -Ctx $Ctx)) {
        if ($s.Source -in @('auto', 'manual')) { $normal += $s }
    }
    if ($normal.Count -eq 0) { return $null }
    return $normal[0]
}

# ============ 工具：带重试的文件操作 ============
function Invoke-EngineWithRetry {
    <# 对「暂时被占用」的文件操作做少量有上限的重试。
       $Script 是形如 { param($d) ... } 的脚本块，操作目标经 $Data 传入。
       必须显式传参：scriptblock 不是闭包，块内直接引用调用方变量会解析失败。
       （实测教训：简单函数对未知命名参数会静默忽略——调用方改了 -Data 而函数
       没同步加参数时不报错，只会让脚本块拿到空值。签名与调用必须一起改。） #>
    param(
        [scriptblock]$Script,
        $Data = $null,
        [int]$Attempts = 3,
        [int]$DelayMs = 500,
        [string]$StepName = '操作'
    )
    $lastErr = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            & $Script $Data
            return @{ Ok = $true; Error = $null }
        } catch {
            $lastErr = $_.Exception.Message
            if ($i -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    return @{ Ok = $false; Error = "重试 $Attempts 次仍失败：$lastErr" }
}

function Get-EngineFileMap {
    <# 枚举目录下全部文件，返回 @{ 文件相对名 = @{ Length; Hash } }。失败返回 $null。 #>
    param([Parameter(Mandatory = $true)][string]$Dir)
    try {
        $map = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction Stop)) {
            $rel = $f.FullName.Substring($Dir.Length).TrimStart('\')
            $map[$rel] = @{ Length = $f.Length; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        }
        return $map
    } catch {
        return $null
    }
}

# ============ 操作锁 ============
function New-EngineOpMutex {
    <# 返回操作互斥体（未持有）。调用方 WaitOne(0) / Release / Dispose。 #>
    return (New-Object System.Threading.Mutex($false, $script:OpMutexName))
}

function Test-EngineOpBusy {
    <# 快速判断是否有操作正在进行（用于 GUI 灰按钮或提示）。不持有锁。 #>
    $m = New-Object System.Threading.Mutex($false, $script:OpMutexName)
    try {
        $got = $m.WaitOne(0)
        if ($got) { $null = $m.ReleaseMutex() }
        return (-not $got)
    } catch {
        return $false
    } finally {
        $m.Dispose()
    }
}

# ============ 备份 ============
function Invoke-EngineBackup {
    <# 备份词库目录。返回结构化结果（不弹窗）：
         Outcome = success | skip-duplicate | skip-not-due | failed | busy
       半成品写到 SnapDir\.pending-* 目录，完整性校验通过后才转正（原子改名）。
       清理失败不影响备份成功标记，通过 Rotation* 字段单独报告。 #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [switch]$Manual    # 手动备份：跳过到期与去重检查
    )

    $mutex = New-EngineOpMutex
    $got = $false
    try {
        $got = $mutex.WaitOne(0)
        if (-not $got) {
            return @{ Outcome = 'busy'; SnapshotName = $null; Words = -1
                      Errors = @('另一个备份/恢复/清理操作正在进行，本次未执行。请稍后重试。')
                      RotationErrors = @() }
        }
        return (Invoke-EngineBackupInner -Ctx $Ctx -Manual:$Manual)
    } finally {
        if ($got) { try { $null = $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-EngineBackupInner {
    param([hashtable]$Ctx, [switch]$Manual)

    $imeDir = $Ctx.Paths.ImeDir
    $snapDir = $Ctx.Paths.SnapDir

    # 1) 词库必须可读
    $lex = Get-EngineLexiconStatus -Ctx $Ctx
    if ($lex.State -ne 'ok') {
        $advice = switch ($lex.State) {
            'missing'   { '词库文件不存在：可能被手动删除、清空或路径变化。本次未做任何修改；请确认情况后再操作（若你刚主动清空过词库，请先用挂起功能，避免误报）。' }
            'locked'    { '词库文件暂时被占用（通常是输入法正在写入）。本次未做任何修改；稍后重试即可。' }
            'malformed' { '词库文件内容无法解析。本次未做任何修改；不会用它覆盖任何数据。' }
        }
        Write-EngineLog -Ctx $Ctx -Action 'backup' -Result "lexicon-$($lex.State)" -Detail $lex.Note
        return @{ Outcome = 'failed'; SnapshotName = $null; Words = -1
                  Errors = @("备份未执行：$($lex.Note)`n$advice"); RotationErrors = @() }
    }

    # 2) 到期与去重（仅自动备份判断；手动备份跳过）
    $latest = Get-EngineLatestBackup -Ctx $Ctx
    if (-not $Manual) {
        $intervalDays = [int]$Ctx.Config.BackupIntervalDays
        if ($intervalDays -lt 1) { $intervalDays = 1 }
        if ($latest) {
            $ageDays = ((Get-Date) - [datetime]$latest.Time).TotalDays
            if ($ageDays -lt $intervalDays) {
                Write-EngineLog -Ctx $Ctx -Action 'backup' -Result 'skip-not-due' -Detail "词数=$($lex.Words) 距上次 $($latest.Name) $([math]::Round($ageDays,1)) 天 < 间隔 $intervalDays 天"
                return @{ Outcome = 'skip-not-due'; SnapshotName = $null; Words = $lex.Words; Errors = @(); RotationErrors = @() }
            }
        }
        if ($Ctx.Config.DeduplicateBackup -and $latest) {
            $srcHash = (Get-FileHash -LiteralPath $Ctx.Paths.UdlFile -ErrorAction SilentlyContinue).Hash
            $latestUdl = Join-Path $latest.Dir 'ChsPinyinUDL.dat'
            $dstHash = $null
            if (Test-Path -LiteralPath $latestUdl) {
                $dstHash = (Get-FileHash -LiteralPath $latestUdl -ErrorAction SilentlyContinue).Hash
            }
            if ($srcHash -and $dstHash -and ($srcHash -eq $dstHash)) {
                Write-EngineLog -Ctx $Ctx -Action 'backup' -Result 'skip-duplicate' -Detail "词数=$($lex.Words) 与 $($latest.Name) 内容一致"
                return @{ Outcome = 'skip-duplicate'; SnapshotName = $null; Words = $lex.Words; Errors = @(); RotationErrors = @() }
            }
        }
    }

    # 3) 执行备份：先写半成品，校验后转正
    try {
        if (-not (Test-Path -LiteralPath $imeDir -PathType Container)) {
            throw "词库目录不存在：$imeDir"
        }
        if (-not (Test-Path -LiteralPath $snapDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $snapDir -Force
        }

        $pendingName = '.pending-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + ([Guid]::NewGuid().ToString('N').Substring(0, 6))
        $pendingDir = Join-Path $snapDir $pendingName
        $null = New-Item -ItemType Directory -Path $pendingDir -Force

        # 复制前源状态
        $srcBefore = Get-EngineFileMap -Dir $imeDir
        if ($null -eq $srcBefore) { throw "无法读取词库目录内容：$imeDir" }
        if ($srcBefore.Count -eq 0) { throw "词库目录为空：$imeDir（没有可备份的文件）" }

        foreach ($f in (Get-ChildItem -LiteralPath $imeDir -Recurse -File)) {
            $rel = $f.FullName.Substring($imeDir.Length).TrimStart('\')
            $dst = Join-Path $pendingDir $rel
            $dstSub = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstSub)) { $null = New-Item -ItemType Directory -Path $dstSub -Force }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        }

        # 完整性校验：副本 == 复制前的源
        $copyMap = Get-EngineFileMap -Dir $pendingDir
        if ($null -eq $copyMap) { throw "无法读取备份副本内容：$pendingDir" }
        $mismatch = @()
        foreach ($rel in $srcBefore.Keys) {
            if (-not $copyMap.ContainsKey($rel)) { $mismatch += "缺少文件：$rel"; continue }
            if ($copyMap[$rel].Length -ne $srcBefore[$rel].Length) { $mismatch += "大小不一致：$rel" }
            elseif ($copyMap[$rel].Hash -ne $srcBefore[$rel].Hash) { $mismatch += "内容不一致：$rel" }
        }
        if ($mismatch.Count -gt 0) { throw ("备份副本完整性校验未通过：`n" + ($mismatch -join "`n")) }

        # 源是否在备份期间变化
        $srcAfter = Get-EngineFileMap -Dir $imeDir
        if ($null -eq $srcAfter) { throw "备份后无法重新读取词库目录：$imeDir" }
        $changed = @()
        foreach ($rel in $srcBefore.Keys) {
            if (-not $srcAfter.ContainsKey($rel)) { $changed += $rel; continue }
            if ($srcAfter[$rel].Hash -ne $srcBefore[$rel].Hash) { $changed += $rel }
        }
        if ($changed.Count -gt 0) {
            throw ("词库在备份期间发生了变化（可能输入法正在写入），本次备份已丢弃，未产生半成品记录：`n" + ($changed -join "`n"))
        }

        # 写 meta 并转正（同卷改名是原子操作）
        $finalName = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        while (Test-Path -LiteralPath (Join-Path $snapDir $finalName)) {
            $finalName = $finalName + 'x'
        }
        $filesMeta = @{}
        foreach ($rel in $copyMap.Keys) { $filesMeta[$rel] = $copyMap[$rel].Hash }
        $meta = @{
            source = $(if ($Manual) { 'manual' } else { 'auto' })
            words  = $lex.Words
            time   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            files  = $filesMeta
        }
        $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $pendingDir 'meta.json') -Encoding UTF8
        Rename-Item -LiteralPath $pendingDir -NewName $finalName
        $finalDir = Join-Path $snapDir $finalName

        # 转正后再核对一次（防改名过程意外）
        $verify = Get-EngineFileMap -Dir $finalDir
        $verifyOk = $false
        if ($null -ne $verify) {
            $verifyOk = $true
            foreach ($rel in $copyMap.Keys) {
                if (-not $verify.ContainsKey($rel) -or $verify[$rel].Hash -ne $copyMap[$rel].Hash) { $verifyOk = $false; break }
            }
        }
        if (-not $verifyOk) {
            throw "备份转正后复核失败：$finalDir（该目录已保留供检查，不会作为恢复来源参与自动推荐）"
        }

        Write-EngineLog -Ctx $Ctx -Action 'backup' -Result 'success' -Detail "存档=$finalName 词数=$($lex.Words)（估算） 来源=$(if($Manual){'手动'}else{'自动'})"

        # 4) 轮转清理（只清普通备份；失败单独报告，不影响成功标记）
        $rotation = Invoke-EngineRotationInner -Ctx $Ctx

        return @{ Outcome = 'success'; SnapshotName = $finalName; Words = $lex.Words
                  FinalDir = $finalDir; Errors = @(); RotationErrors = $rotation.Errors }
    } catch {
        # 半成品清理（尽力）
        if ($pendingDir -and (Test-Path -LiteralPath $pendingDir)) {
            try { Remove-Item -LiteralPath $pendingDir -Recurse -Force -ErrorAction Stop } catch { }
        }
        Write-EngineLog -Ctx $Ctx -Action 'backup' -Result 'failed' -Detail $_.Exception.Message
        return @{ Outcome = 'failed'; SnapshotName = $null; Words = $lex.Words
                  Errors = @("备份失败：$($_.Exception.Message)`n词库文件未被修改；已产生的半成品已丢弃。"); RotationErrors = @() }
    }
}

# ============ 清理（保留份数） ============
function Get-EngineRotationPlan {
    <# 计算若保留 $KeepCount 份普通备份，将清理哪些存档。只读，不删除。
       恢复产物（recovery）与无 meta 目录永不参与。 #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [Parameter(Mandatory = $true)][int]$KeepCount
    )
    $normal = @()
    foreach ($s in (Get-EngineSnapshots -Ctx $Ctx)) {
        if ($s.Source -in @('auto', 'manual')) { $normal += $s }
    }
    $keep = @($normal | Select-Object -First $KeepCount)
    $remove = @()
    if ($normal.Count -gt $KeepCount) {
        $remove = @($normal | Select-Object -Skip $KeepCount)
    }
    return @{ Keep = $keep; Remove = $remove; Total = $normal.Count }
}

function Invoke-EngineRotation {
    <# 执行保留份数清理（带操作锁）。只删除计划内、且删除前重新核对归属的普通备份。 #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [Parameter(Mandatory = $true)][int]$KeepCount,
        [string[]]$ApprovedSnapshotNames
    )
    $mutex = New-EngineOpMutex
    $got = $false
    try {
        $got = $mutex.WaitOne(0)
        if (-not $got) {
            return @{ Cleaned = @(); Errors = @('另一个操作正在进行，清理未执行。') }
        }
        $rotationArgs = @{ Ctx = $Ctx; KeepCount = $KeepCount }
        if ($PSBoundParameters.ContainsKey('ApprovedSnapshotNames')) {
            $rotationArgs.ApprovedSnapshotNames = $ApprovedSnapshotNames
        }
        return (Invoke-EngineRotationInner @rotationArgs)
    } finally {
        if ($got) { try { $null = $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-EngineRotationInner {
    <# 清理内部实现（假定调用方已持锁，或同线程重入）。 #>
    param(
        [hashtable]$Ctx,
        [int]$KeepCount = 0,    # 0 = 用配置值
        [string[]]$ApprovedSnapshotNames
    )
    if ($KeepCount -le 0) { $KeepCount = [int]$Ctx.Config.KeepCount }
    if ($KeepCount -lt 1) { $KeepCount = 1 }

    $plan = Get-EngineRotationPlan -Ctx $Ctx -KeepCount $KeepCount
    if ($PSBoundParameters.ContainsKey('ApprovedSnapshotNames')) {
        $unapproved = @($plan.Remove | Where-Object { $_.Name -notin $ApprovedSnapshotNames })
        if ($unapproved.Count -gt 0) {
            return @{ Cleaned = @(); Errors = @('备份列表在确认后发生变化，清理未执行。请重新检查并确认清理范围。') }
        }
    }
    $errors = @()
    $cleaned = @()
    foreach ($s in $plan.Remove) {
        # 删除前重新核对：目录还在、meta 还有效、来源仍是普通备份
        $stillNormal = $false
        try {
            $metaPath = Join-Path $s.Dir 'meta.json'
            if ((Test-Path -LiteralPath $s.Dir -PathType Container) -and (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
                $m = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$m.source -in @('auto', 'manual')) { $stillNormal = $true }
            }
        } catch { }
        if (-not $stillNormal) { $errors += "跳过 $($s.Name)：删除前核对时该目录不再是可确认归属的普通备份"; continue }

        $r = Invoke-EngineWithRetry -Script { param($d) Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop } -Data $s.Dir -StepName "清理 $($s.Name)"
        if ($r.Ok) { $cleaned += $s.Name }
        else { $errors += "清理 $($s.Name) 失败：$($r.Error)" }
    }
    if ($errors.Count -gt 0) {
        Write-EngineLog -Ctx $Ctx -Action 'cleanup' -Result 'partial-failed' -Detail ($errors -join '；')
    } elseif ($cleaned.Count -gt 0) {
        Write-EngineLog -Ctx $Ctx -Action 'cleanup' -Result 'success' -Detail "清理 $($cleaned.Count) 份超额旧备份：$($cleaned -join '、')"
    }
    return @{ Cleaned = $cleaned; Errors = $errors }
}

# ============ 恢复 ============
function Invoke-EngineRestore {
    <# 恢复到指定存档（必须精确存档名）。返回结构化结果（不弹窗）。
       流程：定位并校验存档 → 保全当前数据（校验保全副本）→ 记录进程状态 →
       停相关进程（仅当前用户）→ 覆盖 → 按文件哈希核对 → 成功记录 / 失败回退。
       用户确认由调用方（GUI / 命令行）负责，本函数不弹窗、不询问。 #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )

    $mutex = New-EngineOpMutex
    $got = $false
    try {
        $got = $mutex.WaitOne(0)
        if (-not $got) {
            return @{ Outcome = 'busy'; SnapshotName = $SnapshotName
                      Errors = @('另一个备份/恢复/清理操作正在进行，本次恢复未执行。请稍后重试。') }
        }
        return (Invoke-EngineRestoreInner -Ctx $Ctx -SnapshotName $SnapshotName)
    } finally {
        if ($got) { try { $null = $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-EngineRestoreInner {
    param([hashtable]$Ctx, [string]$SnapshotName)

    $imeDir = $Ctx.Paths.ImeDir
    $quarDir = $Ctx.Paths.QuarDir

    $fail = {
        param([string]$Reason, [string]$Detail, [string]$Impact)
        Write-EngineLog -Ctx $Ctx -Action 'recovery' -Result 'failed' -Detail "$Reason $Detail"
        return @{ Outcome = 'failed'; SnapshotName = $SnapshotName; QuarantineName = $null
                  Errors = @("$Reason`n$Detail`n$Impact") }
    }

    # 1) 定位存档（精确名，不做前缀匹配）
    $snap = $null
    foreach ($s in (Get-EngineSnapshots -Ctx $Ctx)) {
        if ($s.Name -eq $SnapshotName) { $snap = $s; break }
    }
    if (-not $snap) {
        return (& $fail '未找到指定的存档：' "存档名 $SnapshotName（必须是完整存档名，不支持模糊匹配）" '词库未被修改；没有任何数据被覆盖。')
    }
    if ($snap.Source -notin @('auto', 'manual')) {
        return (& $fail '该存档不能用作恢复来源：' "$SnapshotName 的来源是 $($snap.Source)（恢复产物永不作为恢复来源，防止坏结果污染基准）" '词库未被修改。')
    }

    # 2) 校验存档完整性（按 meta 记录的文件哈希核对当前文件）
    $arcMap = Get-EngineFileMap -Dir $snap.Dir
    if ($null -eq $arcMap) {
        return (& $fail '存档读取失败：' "无法读取 $($snap.Dir)" '词库未被修改。')
    }
    $metaFiles = $null
    try {
        $meta = Get-Content -LiteralPath (Join-Path $snap.Dir 'meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $metaFiles = $meta.files
    } catch { }
    $arcBad = @()
    if ($metaFiles) {
        foreach ($p in $metaFiles.PSObject.Properties) {
            if (-not $arcMap.ContainsKey($p.Name)) { $arcBad += "存档缺少文件：$($p.Name)" }
            elseif ($arcMap[$p.Name].Hash -ne [string]$p.Value) { $arcBad += "存档文件已损坏：$($p.Name)" }
        }
    } else {
        $arcBad += '存档缺少文件清单（meta.json 无 files 字段），无法校验完整性'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $snap.Dir 'ChsPinyinUDL.dat') -PathType Leaf)) {
        $arcBad += '存档缺少主词库文件 ChsPinyinUDL.dat'
    }
    if ($arcBad.Count -gt 0) {
        return (& $fail '存档完整性校验未通过：' ($arcBad -join "`n") '词库未被修改；请换一份存档。')
    }

    # 3) 保全当前数据（保全副本必须校验通过，否则立即停止）
    if (-not (Test-Path -LiteralPath $imeDir -PathType Container)) {
        return (& $fail '词库目录不存在：' $imeDir '恢复未执行；请先确认词库目录情况。')
    }
    $curMap = Get-EngineFileMap -Dir $imeDir
    if ($null -eq $curMap) {
        return (& $fail '无法读取当前词库目录：' $imeDir '恢复未执行，词库未被修改。')
    }
    if (-not (Test-Path -LiteralPath $quarDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $quarDir -Force
    }
    $qName = 'q-' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    $qPath = Join-Path $quarDir $qName
    $quarantineFailed = $null
    try {
        $null = New-Item -ItemType Directory -Path $qPath -Force
        foreach ($f in (Get-ChildItem -LiteralPath $imeDir -Recurse -File)) {
            $rel = $f.FullName.Substring($imeDir.Length).TrimStart('\')
            $dst = Join-Path $qPath $rel
            $dstSub = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstSub)) { $null = New-Item -ItemType Directory -Path $dstSub -Force }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop
        }
    } catch {
        $quarantineFailed = $_.Exception.Message
    }
    if (-not $quarantineFailed) {
        $qMap = Get-EngineFileMap -Dir $qPath
        if ($null -ne $qMap -and $qMap.Count -eq $curMap.Count) {
            foreach ($rel in $curMap.Keys) {
                if ($qMap.ContainsKey($rel) -and $qMap[$rel].Hash -eq $curMap[$rel].Hash) { continue }
                $quarantineFailed = "保全副本与当前数据不一致：$rel"
                break
            }
        } else {
            $quarantineFailed = '保全副本文件数与当前数据不一致'
        }
    }
    if ($quarantineFailed) {
        return (& $fail '当前数据保全失败，恢复立即停止：' "保全目录 $qPath`n原因：$quarantineFailed" '词库未被修改；保全副本已保留供检查。')
    }

    # 4) 记录进程状态（仅当前用户会话内、与输入法相关的进程）
    $mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $wasRunning = @()
    foreach ($pn in (@($Ctx.ImeProcessNames) + @($Ctx.HelperProcessName))) {
        foreach ($p in (Get-Process -Name $pn -ErrorAction SilentlyContinue)) {
            if ($p.SessionId -eq $mySession) { $wasRunning += $pn; break }
        }
    }

    # 5) 停进程 → 覆盖 → 核对（任何失败 → 回退）
    $restoreErr = $null
    try {
        foreach ($pn in @($Ctx.ImeProcessNames)) {
            foreach ($p in (Get-Process -Name $pn -ErrorAction SilentlyContinue)) {
                if ($p.SessionId -eq $mySession) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
            }
        }
        Start-Sleep -Milliseconds 800

        # 覆盖：先清空（带重试），再从存档复制
        $clear = Invoke-EngineWithRetry -StepName '清空词库目录' -Data $imeDir -Script {
            param($d)
            Get-ChildItem -LiteralPath $d -Force -ErrorAction Stop | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            }
        }
        if (-not $clear.Ok) { throw "清空词库目录失败：$($clear.Error)" }

        foreach ($rel in $arcMap.Keys) {
            if ($rel -eq 'meta.json') { continue }
            $src = Join-Path $snap.Dir $rel
            $dst = Join-Path $imeDir $rel
            $dstSub = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstSub)) { $null = New-Item -ItemType Directory -Path $dstSub -Force }
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        }

        # 核对：恢复后的每个文件 == 存档里的对应文件（按内容哈希，不是词数）
        $afterMap = Get-EngineFileMap -Dir $imeDir
        if ($null -eq $afterMap) { throw '恢复后无法读取词库目录' }
        $bad = @()
        foreach ($rel in $arcMap.Keys) {
            if ($rel -eq 'meta.json') { continue }
            if (-not $afterMap.ContainsKey($rel)) { $bad += "恢复后缺少文件：$rel" }
            elseif ($afterMap[$rel].Hash -ne $arcMap[$rel].Hash) { $bad += "恢复后内容与存档不一致：$rel" }
        }
        if ($bad.Count -gt 0) { throw ("恢复结果核对未通过：`n" + ($bad -join "`n")) }

        # 成功：尽力重启输入法（原在跑的），记录 recovery 存档
        foreach ($pn in ($wasRunning | Select-Object -Unique)) {
            try {
                if ($pn -eq $Ctx.HelperProcessName) { Start-Process "$($pn).exe" -ErrorAction SilentlyContinue }
                else { Start-Process "$($pn).exe" -ErrorAction SilentlyContinue }
            } catch { }
        }
        $lexAfter = Get-EngineLexiconStatus -Ctx $Ctx
        $recMeta = @{
            source = 'recovery'
            words  = $lexAfter.Words
            time   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            from   = $snap.Name
        }
        $recName = 'recovery-' + (Get-Date -Format 'yyyy-MM-dd_HHmmss')
        $recDir = Join-Path $Ctx.Paths.SnapDir $recName
        if (-not (Test-Path -LiteralPath $recDir)) {
            $null = New-Item -ItemType Directory -Path $recDir -Force
            foreach ($f in (Get-ChildItem -LiteralPath $imeDir -Recurse -File)) {
                $rel = $f.FullName.Substring($imeDir.Length).TrimStart('\')
                $dst = Join-Path $recDir $rel
                $dstSub = Split-Path -Parent $dst
                if (-not (Test-Path -LiteralPath $dstSub)) { $null = New-Item -ItemType Directory -Path $dstSub -Force }
                Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            }
            $recMeta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recDir 'meta.json') -Encoding UTF8
        }
        Write-EngineLog -Ctx $Ctx -Action 'recovery' -Result 'success' -Detail "从 $SnapshotName（$($snap.Words) 词，估算）恢复成功，现 $($lexAfter.Words) 词（估算）；恢复前现场保全在 $qName"
        return @{ Outcome = 'success'; SnapshotName = $snap.Name; QuarantineName = $qName
                  WordsAfter = $lexAfter.Words; Errors = @() }
    } catch {
        $restoreErr = $_.Exception.Message
        # 6) 回退：从保全副本恢复（尽力），回退失败单独报告
        $rollbackErr = $null
        try {
            Get-ChildItem -LiteralPath $imeDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Get-ChildItem -LiteralPath $qPath -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($qPath.Length).TrimStart('\')
                $dst = Join-Path $imeDir $rel
                $dstSub = Split-Path -Parent $dst
                if (-not (Test-Path -LiteralPath $dstSub)) { $null = New-Item -ItemType Directory -Path $dstSub -Force }
                Copy-Item -LiteralPath $_.FullName -Destination $dst -Force -ErrorAction Stop
            }
            $rbMap = Get-EngineFileMap -Dir $imeDir
            $rbOk = $false
            if ($null -ne $rbMap -and $rbMap.Count -eq $curMap.Count) {
                $rbOk = $true
                foreach ($rel in $curMap.Keys) {
                    if (-not $rbMap.ContainsKey($rel) -or $rbMap[$rel].Hash -ne $curMap[$rel].Hash) { $rbOk = $false; break }
                }
            }
            if (-not $rbOk) { $rollbackErr = '回退后核对未通过：当前词库内容与恢复前不完全一致。' }
        } catch {
            $rollbackErr = "回退过程出错：$($_.Exception.Message)"
        }
        # 尽力重启输入法（不能只在成功路径重启）
        foreach ($pn in ($wasRunning | Select-Object -Unique)) {
            try { Start-Process "$($pn).exe" -ErrorAction SilentlyContinue } catch { }
        }
        if ($rollbackErr) {
            Write-EngineLog -Ctx $Ctx -Action 'recovery' -Result 'failed-rollback-failed' -Detail "覆盖失败：$restoreErr；$rollbackErr 现场保全在 $qName"
            return @{ Outcome = 'failed'; SnapshotName = $snap.Name; QuarantineName = $qName
                      Errors = @("恢复失败：$restoreErr`n`n回退也未完全成功：$rollbackErr`n`n恢复前现场已保留：$qPath`n所用存档未受影响：$($snap.Dir)`n请勿删除保全目录，可据此手工处理。") }
        }
        Write-EngineLog -Ctx $Ctx -Action 'recovery' -Result 'failed-rollback' -Detail "覆盖失败：$restoreErr；已回退，现场保全在 $qName"
        return @{ Outcome = 'failed'; SnapshotName = $snap.Name; QuarantineName = $qName
                  Errors = @("恢复失败：$restoreErr`n`n已用恢复前的数据回退，词库回到操作前状态。`n恢复前现场另存一份：$qPath（确认无误后可删除）") }
    }
}

# ============ 挂起 / 恢复值守 ============
function Set-EngineSuspend {
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    Set-Content -LiteralPath $Ctx.Paths.SuspendFile -Value (Get-Date -Format s) -Encoding UTF8
    Write-EngineLog -Ctx $Ctx -Action 'suspend' -Result 'ok' -Detail ''
}
function Clear-EngineSuspend {
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    Remove-Item -LiteralPath $Ctx.Paths.SuspendFile -Force -ErrorAction SilentlyContinue
    Write-EngineLog -Ctx $Ctx -Action 'resume' -Result 'ok' -Detail ''
}
function Test-EngineSuspended {
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    return (Test-Path -LiteralPath $Ctx.Paths.SuspendFile -PathType Leaf)
}

# ============ 登录计划任务 ============
function Get-EngineTaskStatus {
    <# 查询登录任务实际状态：@{ Registered; State; DelaySeconds; Error }。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    try {
        $t = Get-ScheduledTask -TaskName $Ctx.TaskName -ErrorAction SilentlyContinue
        if (-not $t) { return @{ Registered = $false; State = ''; DelaySeconds = $null; Error = '' } }
        $delay = $null
        try {
            # 任务计划程序把延迟存成 ISO8601 时长：PT30S、PT1M6S、PT1H2M3S 都可能出现
            # （例如 66 秒会被规范化为 PT1M6S），统一换算成秒数。
            $d = [string]$t.Triggers[0].Delay
            if ($d -match '^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$') {
                $h = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
                $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
                $s = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
                $delay = $h * 3600 + $m * 60 + $s
            }
        } catch { }
        return @{ Registered = $true; State = [string]$t.State; DelaySeconds = $delay; Error = '' }
    } catch {
        return @{ Registered = $false; State = ''; DelaySeconds = $null; Error = $_.Exception.Message }
    }
}

function Register-EngineLoginTask {
    <# 为当前用户注册（或更新）登录检查任务。延迟由任务调度承担。
       返回 @{ Ok; Error }。失败时不算已启用。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    try {
        if (-not $Ctx.Paths.SilentCheckExe) {
            return @{ Ok = $false; Error = '未找到 silent-check.exe（登录检查的启动器）。请先运行 src\launcher\build-launcher.ps1 编译。' }
        }
        $action = New-ScheduledTaskAction -Execute $Ctx.Paths.SilentCheckExe
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Ctx.UserName
        $delaySec = [int]$Ctx.Config.LoginDelaySeconds
        if ($delaySec -lt 5) { $delaySec = 5 }
        $trigger.Delay = 'PT' + $delaySec + 'S'
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable
        Register-ScheduledTask -TaskName $Ctx.TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        # 注册后核对
        $st = Get-EngineTaskStatus -Ctx $Ctx
        if (-not $st.Registered) {
            return @{ Ok = $false; Error = '任务注册后核对失败：任务列表中未找到本应用的任务。' }
        }
        return @{ Ok = $true; Error = '' }
    } catch {
        return @{ Ok = $false; Error = "登录任务注册失败：$($_.Exception.Message)`n配置已保存，但登录自动检查未启用。" }
    }
}

function Unregister-EngineLoginTask {
    <# 只移除本应用对应的任务。返回 @{ Ok; Error }。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)
    try {
        $t = Get-ScheduledTask -TaskName $Ctx.TaskName -ErrorAction SilentlyContinue
        if (-not $t) { return @{ Ok = $true; Error = '' } }   # 本来就没有 = 目标状态达成
        Unregister-ScheduledTask -TaskName $Ctx.TaskName -Confirm:$false
        $st = Get-EngineTaskStatus -Ctx $Ctx
        if ($st.Registered) {
            return @{ Ok = $false; Error = '任务移除后核对失败：任务仍存在于任务列表。' }
        }
        return @{ Ok = $true; Error = '' }
    } catch {
        return @{ Ok = $false; Error = "登录任务移除失败：$($_.Exception.Message)`n配置已保存，但系统里仍留有本应用的登录任务。" }
    }
}

# ============ 设置保存与应用（GUI 与回归测试共用） ============
function Set-EngineSettings {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ContextArgs,
        [Parameter(Mandatory = $true)][hashtable]$Draft,
        [scriptblock]$ConfirmCleanup
    )
    $saved = $false
    $mutex = New-EngineOpMutex
    $got = $false
    try {
        $got = $mutex.WaitOne(0)
        if (-not $got) {
            return @{ Success = $false; Cancelled = $false; Errors = @('另一个操作正在进行，设置未保存。请稍后重试。'); Cleaned = @() }
        }
        # 预览只使用草稿位置，不读取旧配置，也不删除或搬迁旧位置的数据。
        $previewArgs = $ContextArgs.Clone()
        $previewArgs.ConfigOverride = $Draft
        $previewCtx = New-EngineContext @previewArgs
        if (-not $previewCtx.Ok) {
            return @{ Success = $false; Cancelled = $false; Errors = $previewCtx.Errors; Cleaned = @() }
        }
        $plan = Get-EngineRotationPlan -Ctx $previewCtx -KeepCount ([int]$Draft.KeepCount)
        $approved = @($plan.Remove | ForEach-Object { $_.Name })
        if ($approved.Count -gt 0 -and (-not $ConfirmCleanup -or -not (& $ConfirmCleanup $plan))) {
            return @{ Success = $false; Cancelled = $true; Errors = @(); Cleaned = @() }
        }
        $writable = Test-GuiBackupDirWritable -BackupDir $Draft.BackupDir -BaseDir $previewCtx.BaseDir
        if (-not $writable.Ok) {
            return @{ Success = $false; Cancelled = $false; Errors = @($writable.Message); Cleaned = @() }
        }
        $save = Save-GuiConfig -Path $previewCtx.Paths.ConfigPath -Config $Draft
        if (-not $save.Success) {
            return @{ Success = $false; Cancelled = $false; Errors = $save.Errors; Cleaned = @() }
        }
        $saved = $true
        # 任务和清理必须使用刚保存的有效配置，而非预览前的旧上下文。
        $ctx = New-EngineContext @ContextArgs
        if (-not $ctx.Ok) {
            return @{ Success = $true; Cancelled = $false; Errors = $ctx.Errors; Cleaned = @() }
        }
        $errors = @()
        $taskResult = if ($ctx.Config.LoginStart) { Register-EngineLoginTask -Ctx $ctx } else { Unregister-EngineLoginTask -Ctx $ctx }
        if (-not $taskResult.Ok) { $errors += $taskResult.Error }
        $cleaned = @()
        if ($approved.Count -gt 0) {
            $rotation = Invoke-EngineRotation -Ctx $ctx -KeepCount ([int]$ctx.Config.KeepCount) -ApprovedSnapshotNames $approved
            $errors += @($rotation.Errors)
            $cleaned = @($rotation.Cleaned)
        }
        return @{ Success = $true; Cancelled = $false; Errors = $errors; Cleaned = $cleaned }
    } catch {
        return @{ Success = $saved; Cancelled = $false; Errors = @("设置应用失败：$($_.Exception.Message)"); Cleaned = @() }
    } finally {
        if ($got) { try { $null = $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

# ============ 疑似异常判定（供自动检查与 GUI 共用） ============
function Get-EngineHealthVerdict {
    <# 综合词库状态与基线，返回判定（不弹窗、不恢复）：
         Verdict = healthy | suspect | unknown | unreadable | missing | suspended(由调用方先查)
         附带依据与建议文案材料。词数仅是估算，低词数只作为疑似依据。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx)

    $lex = Get-EngineLexiconStatus -Ctx $Ctx
    if ($lex.State -ne 'ok') {
        return @{ Verdict = $lex.State; Words = $lex.Words; Baseline = $null
                  Threshold = $null; HasBaseline = $false; Note = $lex.Note }
    }
    $latest = Get-EngineLatestBackup -Ctx $Ctx
    $lockAbsolute = 40
    $lockRatio = 0.70
    if (-not $latest) {
        # 首次使用：没有历史基线，无法判断"变少"，只有绝对下限参考
        if ($lex.Words -lt $lockAbsolute) {
            return @{ Verdict = 'unknown'; Words = $lex.Words; Baseline = $null
                      Threshold = $lockAbsolute; HasBaseline = $false
                      Note = "估算词组数 $($lex.Words) 低于参考下限 $lockAbsolute，且没有任何历史备份可比较。可能是你刚清空过词库，也可能词库异常；无法自动判断。" }
        }
        return @{ Verdict = 'healthy'; Words = $lex.Words; Baseline = $null
                  Threshold = $lockAbsolute; HasBaseline = $false; Note = "估算词组数 $($lex.Words)（首次使用，无历史基线）" }
    }
    $baseline = $latest.Words
    $threshold = [math]::Max($lockAbsolute, [math]::Ceiling($baseline * $lockRatio))
    if ($lex.Words -lt $threshold) {
        # 附加验证：输入法进程活着 且 词库目录最近 2 分钟无写入（引擎正在写时不动）
        $imeAlive = $false
        foreach ($pn in @($Ctx.ImeProcessNames) + @($Ctx.HelperProcessName)) {
            if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $imeAlive = $true; break }
        }
        $dirQuiet = $true
        if (Test-Path -LiteralPath $Ctx.Paths.ImeDir) {
            $dirQuiet = (((Get-Date) - (Get-Item -LiteralPath $Ctx.Paths.ImeDir).LastWriteTime).TotalMinutes -gt 2)
        }
        if ($imeAlive -and $dirQuiet) {
            return @{ Verdict = 'suspect'; Words = $lex.Words; Baseline = $baseline
                      Threshold = [int]$threshold; HasBaseline = $true; LatestBackup = $latest
                      Note = "估算词组数 $($lex.Words)，低于健康线 $([int]$threshold)（基线 $($latest.Name) = $baseline 词，估算）。输入法进程在运行、词库目录近期无写入——疑似词库被清空。" }
        }
        return @{ Verdict = 'unknown'; Words = $lex.Words; Baseline = $baseline
                  Threshold = [int]$threshold; HasBaseline = $true
                  Note = "估算词组数 $($lex.Words) 低于健康线 $([int]$threshold)，但暂不判定异常（输入法进程状态或词库目录写入时间不满足确认条件）。稍后会再次检查。" }
    }
    return @{ Verdict = 'healthy'; Words = $lex.Words; Baseline = $baseline
              Threshold = [int]$threshold; HasBaseline = $true
              Note = "估算词组数 $($lex.Words)（健康线 $([int]$threshold)）" }
}

Export-ModuleMember -Function @(
    'New-EngineContext',
    'Write-EngineLog',
    'Get-EngineLexiconStatus',
    'Get-EngineSnapshots',
    'Get-EngineLatestBackup',
    'Invoke-EngineWithRetry',
    'New-EngineOpMutex',
    'Test-EngineOpBusy',
    'Invoke-EngineBackup',
    'Get-EngineRotationPlan',
    'Invoke-EngineRotation',
    'Invoke-EngineRestore',
    'Set-EngineSuspend',
    'Clear-EngineSuspend',
    'Test-EngineSuspended',
    'Get-EngineTaskStatus',
    'Register-EngineLoginTask',
    'Unregister-EngineLoginTask',
    'Set-EngineSettings',
    'Get-EngineHealthVerdict'
)

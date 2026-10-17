#Requires -Version 5.1
# GUI 状态模块 —— 只读展示日志与存档列表
# 说明：本模块只读两类数据：流水日志（JSON 行）与存档目录 meta.json。
#       不读取真实词库，不做任何健康判定，不做任何写操作。

function Get-GuiLogEntries {
    <# 读取日志文件，返回 @{ FileExists; Entries = @(); SkippedLines = int }。
       Entries 按文件顺序（旧→新）返回，调用方可自行倒序展示。
       单行解析失败时跳过并计数，不中断。 #>
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [int]$MaxCount = 20
    )

    $result = @{ FileExists = $false; Entries = @(); SkippedLines = 0 }
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $result }
    $result.FileExists = $true

    $lines = Get-Content -LiteralPath $LogPath -Encoding UTF8
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            $entries.Add(@{
                Time   = [string]$obj.time
                Action = [string]$obj.action
                Result = [string]$obj.result
                Detail = [string]$obj.detail
            })
        } catch {
            $result.SkippedLines++
        }
    }
    if ($MaxCount -gt 0 -and $entries.Count -gt $MaxCount) {
        $start = $entries.Count - $MaxCount
        $result.Entries = @($entries.GetRange($start, $MaxCount))
    } else {
        $result.Entries = @($entries.GetRange(0, $entries.Count))
    }
    return $result
}

function Get-GuiSnapshotEntries {
    <# 列出存档目录（只读），返回条目数组：Name / Source / Words / Time / MetaOk。
       目录不存在返回空数组；单份存档缺 meta.json 时标注“未知”，不报错。 #>
    param(
        [Parameter(Mandatory = $true)][string]$SnapDir,
        [int]$MaxCount = 10
    )

    if (-not (Test-Path -LiteralPath $SnapDir -PathType Container)) { return @() }
    $dirs = Get-ChildItem -LiteralPath $SnapDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    if (-not $dirs) { return @() }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($d in ($dirs | Select-Object -First $MaxCount)) {
        $metaPath = Join-Path $d.FullName 'meta.json'
        $entry = @{ Name = $d.Name; Source = '未知'; Words = '未知'; Time = '未知'; MetaOk = $false }
        if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
            try {
                $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $entry.Source = [string]$meta.source
                $entry.Words  = [string]$meta.words
                $entry.Time   = [string]$meta.time
                $entry.MetaOk = $true
            } catch { }
        }
        $entries.Add($entry)
    }
    if ($entries.Count -eq 0) { return @() }
    return @($entries.GetRange(0, $entries.Count))
}

function Get-GuiLatestBackupFromLog {
    <# 从日志找出最近一次 result=success 的 backup 记录。
       没有则返回 $null（界面据此显示“暂无记录”）。 #>
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $log = Get-GuiLogEntries -LogPath $LogPath -MaxCount 0
    if (-not $log.FileExists) { return $null }
    $hit = $null
    for ($i = $log.Entries.Count - 1; $i -ge 0; $i--) {
        $e = $log.Entries[$i]
        if ($e.Action -eq 'backup' -and $e.Result -eq 'success') { $hit = $e; break }
    }
    return $hit
}

Export-ModuleMember -Function @(
    'Get-GuiLogEntries', 'Get-GuiSnapshotEntries', 'Get-GuiLatestBackupFromLog'
)

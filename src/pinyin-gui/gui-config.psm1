#Requires -Version 5.1
# GUI 配置模块 —— 默认值 / 读取 / 校验 / 保存
# 说明：本模块只负责配置文件本身。执行逻辑（备份/恢复/清理）见 engine.psm1，
#       两边共用同一份 schema，GUI、登录检查、命令行入口读同一份 config.json。
#       注意：不设『词库异常时弹窗提醒』开关——错误与异常提醒是内置保证，
#       不允许被任何设置整体关闭。

$script:GuiConfigSchema = @(
    @{ Key = 'BackupIntervalDays'; Type = 'int';    Min = 1;  Max = 365; Default = 7;      Kind = 'common';   Label = '备份间隔（天）' }
    @{ Key = 'KeepCount';          Type = 'int';    Min = 1;  Max = 200; Default = 30;     Kind = 'common';   Label = '保留份数' }
    @{ Key = 'BackupDir';          Type = 'dir';    Min = 0;  Max = 0;   Default = '';     Kind = 'common';   Label = '备份位置' }
    @{ Key = 'LoginStart';         Type = 'bool';   Min = 0;  Max = 0;   Default = $false; Kind = 'common';   Label = '登录时启动' }
    @{ Key = 'LoginDelaySeconds';  Type = 'int';    Min = 5;  Max = 300; Default = 20;     Kind = 'advanced'; Label = '登录后检查延迟（秒）' }
    @{ Key = 'DeduplicateBackup';  Type = 'bool';   Min = 0;  Max = 0;   Default = $true;  Kind = 'advanced'; Label = '内容相同不重复备份' }
    @{ Key = 'MaxLogMB';           Type = 'number'; Min = 1;  Max = 50;  Default = 5;      Kind = 'advanced'; Label = '日志上限（MB）' }
)

function Get-GuiConfigSchema {
    return $script:GuiConfigSchema
}

function Get-GuiConfigDefaults {
    <# 返回默认配置。BackupDir 为空时由调用方结合程序目录填充。 #>
    param([string]$BaseDir = '')

    $cfg = @{}
    foreach ($item in $script:GuiConfigSchema) { $cfg[$item.Key] = $item.Default }
    if (-not $cfg['BackupDir'] -and $BaseDir) {
        $cfg['BackupDir'] = Join-Path $BaseDir 'snapshots'
    }
    return $cfg
}

function ConvertTo-GuiConfigValue {
    <# 把 JSON 里读到的任意值转换为字段要求的类型；失败返回 $null。 #>
    param([string]$Type, $Value)

    try {
        switch ($Type) {
            'int' {
                if ($Value -is [int] -or $Value -is [long]) { return [int]$Value }
                if ($Value -is [string] -and $Value -match '^-?\d+$') { return [int]$Value }
                return $null
            }
            'number' {
                if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [double]$Value }
                if ($Value -is [string] -and $Value -match '^-?\d+(\.\d+)?$') { return [double]$Value }
                return $null
            }
            'bool' {
                if ($Value -is [bool]) { return $Value }
                if ($Value -is [string]) {
                    if ($Value -eq 'true')  { return $true }
                    if ($Value -eq 'false') { return $false }
                }
                return $null
            }
            'dir' {
                if ($Value -isnot [string]) { return $null }
                return $Value
            }
            default { return $null }
        }
    } catch {
        return $null
    }
}

function Read-GuiConfig {
    <# 读取配置文件并合并默认值。
       返回 @{ Config = hashtable; Loaded = $bool; Errors = @() }。
       文件缺失或整文件损坏时返回默认值（Loaded=$false），不抛异常。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BaseDir = ''
    )

    $cfg = Get-GuiConfigDefaults -BaseDir $BaseDir
    $result = @{ Config = $cfg; Loaded = $false; Errors = @() }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        $result.Errors += "无法读取配置文件：$($_.Exception.Message)"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.Errors += '配置文件为空，已回退到默认值'
        return $result
    }
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        $result.Errors += "配置文件不是有效 JSON（$($_.Exception.Message)），已回退到默认值"
        return $result
    }

    if (-not $raw.TrimStart().StartsWith('{') -or $json -isnot [pscustomobject]) {
        $result.Errors += '配置文件必须是 JSON 对象，不能是 null、数组或单个数值'
        return $result
    }

    foreach ($item in $script:GuiConfigSchema) {
        $present = $json.PSObject.Properties[$item.Key]
        if (-not $present) { continue }   # 缺失字段沿用默认值
        $converted = ConvertTo-GuiConfigValue -Type $item.Type -Value $present.Value
        if ($null -eq $converted) {
            $result.Errors += "字段 $($item.Key) 的值无法识别，已按默认值处理"
            continue
        }
        $result.Config[$item.Key] = $converted
    }
    $validation = Test-GuiConfig -Config $result.Config
    $result.Errors += @($validation.Errors)
    $result.Loaded = $true
    return $result
}

function Resolve-GuiBackupDir {
    <# 把备份位置解析为绝对路径：相对路径相对于程序目录。 #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$BackupDir,
        [Parameter(Mandatory = $true)][string]$BaseDir
    )
    if ([string]::IsNullOrWhiteSpace($BackupDir)) {
        return (Join-Path $BaseDir 'snapshots')
    }
    if ([System.IO.Path]::IsPathRooted($BackupDir)) { return $BackupDir }
    return Join-Path $BaseDir $BackupDir
}

function Test-GuiConfig {
    <# 校验配置，返回 @{ Valid = $bool; Errors = @(面向用户的错误列表) }。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $errors = @()
    foreach ($item in $script:GuiConfigSchema) {
        $value = $Config[$item.Key]
        switch ($item.Type) {
            'int' {
                $number = ConvertTo-GuiConfigValue -Type 'int' -Value $value
                if ($null -eq $number -or $number -lt $item.Min -or $number -gt $item.Max) {
                    $errors += "$($item.Label)：需要 $($item.Min) 到 $($item.Max) 之间的整数（当前值：$value）"
                }
            }
            'number' {
                $num = ConvertTo-GuiConfigValue -Type 'number' -Value $value
                if ($null -eq $num -or [double]::IsNaN($num) -or [double]::IsInfinity($num) -or $num -lt $item.Min -or $num -gt $item.Max) {
                    $errors += "$($item.Label)：需要 $($item.Min) 到 $($item.Max) 之间的数字（当前值：$value）"
                }
            }
            'bool' {
                if ($value -isnot [bool]) {
                    $errors += "$($item.Label)：需要是开或关（当前值：$value）"
                }
            }
            'dir' {
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                    $errors += "$($item.Label)：不能为空"
                } elseif ($value.Length -gt 240) {
                    $errors += "$($item.Label)：路径过长"
                } elseif ($value -match '[*?"<>|]') {
                    $errors += "$($item.Label)：路径包含不允许的字符"
                }
            }
        }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = $errors }
}

function ConvertTo-GuiConfigJson {
    <# 输出标准 JSON（无注释），字段顺序与 schema 一致。 #>
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $ordered = [ordered]@{}
    foreach ($item in $script:GuiConfigSchema) {
        $value = $Config[$item.Key]
        $value = ConvertTo-GuiConfigValue -Type $item.Type -Value $value
        $ordered[$item.Key] = $value
    }
    return ($ordered | ConvertTo-Json)
}

function Save-GuiConfig {
    <# 保存配置：检查输入 → 新配置完整写入临时文件 → 原子替换旧配置并留备份。
       顺序上保证任何一步失败，旧配置文件都保持原样：
         1) 先把新配置完整写入同目录下的 .tmp 临时文件（写不进就失败，旧文件没动过）
         2) 用 File.Replace 做"替换"：这是系统级的一次性动作，旧内容自动留作 .bak
            备份；替换失败（比如旧文件正被别的程序占用）时旧文件原封不动
         3) 首次保存没有旧文件可替换，退化为 Move（放入新文件，同样不存在
            "先删旧的、新的没放进去"的空档）
       返回 @{ Success = $bool; Errors = @() }。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )

    $check = Test-GuiConfig -Config $Config
    if (-not $check.Valid) { return @{ Success = $false; Errors = $check.Errors } }

    $tmp = "$Path.tmp"
    $bak = "$Path.bak"
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        [System.IO.File]::WriteAllText($tmp, (ConvertTo-GuiConfigJson -Config $Config) + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        if (Test-Path -LiteralPath $Path) {
            # 备份文件已存在时 File.Replace 会失败；.bak 只是上上次的备份，不是当前配置，可安全覆盖
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
            [System.IO.File]::Replace($tmp, $Path, $bak)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
        return @{ Success = $true; Errors = @() }
    } catch {
        # 走到这里 = 写临时文件或替换那一步失败；旧配置文件没有被改动
        return @{ Success = $false; Errors = @("保存失败：$($_.Exception.Message)") }
    } finally {
        # 清掉可能残留的临时文件（只删 .tmp，不碰配置和备份）
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-GuiBackupDirWritable {
    <# 检查备份目录可用性：不存在则尝试创建；用探针文件验证可写。
       返回 @{ Ok = $bool; Path = 解析后的绝对路径; Message = 提示 }。 #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$BackupDir,
        [Parameter(Mandatory = $true)][string]$BaseDir
    )

    $full = Resolve-GuiBackupDir -BackupDir $BackupDir -BaseDir $BaseDir
    try {
        if (-not (Test-Path -LiteralPath $full)) {
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
        $probe = Join-Path $full ('.gui-write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
        [System.IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force
        return @{ Ok = $true; Path = $full; Message = '目录可用' }
    } catch {
        return @{ Ok = $false; Path = $full; Message = "目录不可用：$($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function @(
    'Get-GuiConfigSchema', 'Get-GuiConfigDefaults', 'Read-GuiConfig',
    'Resolve-GuiBackupDir', 'Test-GuiConfig', 'ConvertTo-GuiConfigJson',
    'Save-GuiConfig', 'Test-GuiBackupDirWritable', 'ConvertTo-GuiConfigValue'
)

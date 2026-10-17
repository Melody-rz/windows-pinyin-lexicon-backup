#Requires -Version 5.1
# 卸载只删除经确认的文件清单；不递归删除程序根或用户选择的备份根。
Import-Module (Join-Path $PSScriptRoot 'gui-config.psm1') -DisableNameChecking

function Get-UninstallFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw '需要本地磁盘上的绝对路径。' }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Assert-UninstallPath([string]$Root, [string]$Path) {
    $r = Get-UninstallFullPath $Root
    $p = Get-UninstallFullPath $Path
    $forbidden = @([IO.Path]::GetPathRoot($r).TrimEnd('\'), $env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA)
    if ($forbidden -contains $r -or -not $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "拒绝不安全的删除范围：$p" }
    $walk = $p
    while ($walk) {
        if (Test-Path -LiteralPath $walk) {
            if ((Get-Item -LiteralPath $walk -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "不跟随目录链接：$walk" }
        }
        $parent = [IO.Path]::GetDirectoryName($walk)
        if ($parent -eq $walk) { break }; $walk = $parent
    }
    return $p
}
function Get-UninstallInstanceKey([string]$BaseDir) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-UninstallFullPath $BaseDir).ToUpperInvariant())))).Replace('-', '').Substring(0,16) }
    finally { $sha.Dispose() }
}
function Get-UninstallCacheRoots([string]$BaseDir) {
    $key = Get-UninstallInstanceKey $BaseDir
    return @((Join-Path $env:LOCALAPPDATA "PinyinLexiconBackup\instances\$key"), (Join-Path $BaseDir '.pinyin-gui-temp'), (Join-Path ([IO.Path]::GetTempPath()) "PinyinLexiconBackup\$key")) | Select-Object -Unique
}
function Read-UninstallTask([string]$BaseDir) {
    $service = $null; $folder = $null; $task = $null
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder = $service.GetFolder('\')
        try { $task = $folder.GetTask('PinyinLexiconBackupLogin') }
        catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            if ($e.HResult -in @(-2147024894, -2147024893)) { return @{ Exists=$false; Owned=$false; Running=$false; Enabled=$false; Error='' } }
            throw
        }
        $xml = New-Object Xml.XmlDocument; $xml.XmlResolver = $null; $xml.LoadXml($task.Xml)
        $commands = @($xml.GetElementsByTagName('Command'))
        $users = @($xml.GetElementsByTagName('UserId'))
        $owned = $false
        if ($commands.Count -eq 1 -and $users.Count -eq 1) {
            $account = New-Object Security.Principal.NTAccount($users[0].InnerText)
            $sid = if ($users[0].InnerText -like 'S-1-*') { $users[0].InnerText } else { $account.Translate([Security.Principal.SecurityIdentifier]).Value }
            $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $exe = Get-UninstallFullPath ([Environment]::ExpandEnvironmentVariables($commands[0].InnerText.Trim('"')))
            $owned = ($exe -ieq (Join-Path $BaseDir 'silent-check.exe') -and $sid -eq $current)
        }
        return @{ Exists=$true; Owned=$owned; Running=([int]$task.State -eq 4); Enabled=[bool]$task.Enabled; Error='' }
    } catch { return @{ Exists=$false; Owned=$false; Running=$false; Enabled=$false; Error="无法核实登录任务：$($_.Exception.Message)" } }
    finally {
        foreach ($com in @($task,$folder,$service)) { if ($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)) { try { $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($com) } catch {} } }
    }
}
function Remove-UninstallTask([string]$BaseDir) {
    $now = Read-UninstallTask $BaseDir
    if ($now.Error) { throw $now.Error }
    if (-not $now.Exists) { return }
    if (-not $now.Owned) { return } # 其他安装的任务不属于本次卸载。
    if ($now.Running) { throw '登录检查仍在运行，卸载停止。' }
    try {
    Disable-ScheduledTask -TaskName 'PinyinLexiconBackupLogin' -TaskPath '\' -ErrorAction Stop | Out-Null
    $disabled=Read-UninstallTask $BaseDir
    if($disabled.Error -or -not $disabled.Exists -or -not $disabled.Owned -or $disabled.Running){throw '登录任务可能已停用，但无法确认已停止或归属未变；未删除程序文件，请稍后重新检查。'}
    Unregister-ScheduledTask -TaskName 'PinyinLexiconBackupLogin' -TaskPath '\' -Confirm:$false -ErrorAction Stop
    $after = Read-UninstallTask $BaseDir
    if ($after.Error -or $after.Exists) { throw '未能确认登录任务已经移除，未删除程序文件。' }
    } catch { throw "登录任务处理未完成（可能已经停用，但尚未确认移除），程序文件保留。原因：$($_.Exception.Message)" }
}
function Get-UninstallPlan {
    param([string]$BaseDir, [ValidateSet('GuiOnly','Full')][string]$Mode, [string[]]$CacheRoots)
    $files = @(); $dirs = @(); $retained = @(); $errors = @(); $roots = @()
    try {
        $base = Get-UninstallFullPath $BaseDir
        $null = Assert-UninstallPath $base (Join-Path $base 'open-gui.exe')
        # 必须识别出本应用，不能把任意文件夹当作安装目录。
        foreach ($rel in @('silent-check.exe','src\pinyin-gui\auto-check.ps1','src\pinyin-gui\engine.psm1','src\pinyin-gui\gui-config.psm1')) {
            $null = Assert-UninstallPath $base (Join-Path $base $rel)
            if (-not (Test-Path -LiteralPath (Join-Path $base $rel) -PathType Leaf)) { throw "程序文件不完整，无法安全规划卸载：$rel。请重新解压完整发行文件后重试。" }
        }
        $task = Read-UninstallTask $base
        if ($Mode -eq 'Full' -and ($task.Error -or ($task.Owned -and $task.Running))) { throw ($task.Error + ' 登录检查正在运行时，请待其结束再卸载。') }
        $guiFiles = @('open-gui.exe','src\pinyin-gui\gui-app.ps1','src\pinyin-gui\gui-status.psm1','src\pinyin-gui\shell-actions.psm1')
        $program = $guiFiles
        if ($Mode -eq 'Full') {
            $program += @('silent-check.exe','uninstall.exe','pinyin-watchdog.ps1','pinyin-restore.ps1','run-backup.cmd','挂起看门狗.cmd','恢复看门狗.cmd','config.example.json','README.md','参数列表.md','排查指南.txt',
                'src\pinyin-gui\auto-check.ps1','src\pinyin-gui\engine.psm1','src\pinyin-gui\gui-config.psm1','src\pinyin-gui\uninstall-core.psm1','src\pinyin-gui\uninstall-app.ps1',
                'src\launcher\open-gui.cs','src\launcher\silent-check.cs','src\launcher\uninstall.cs','src\launcher\build-launcher.ps1','config.json','config.json.bak','config.json.tmp','pinyin-backup.log','suspend.tag')
        }
        foreach ($rel in $program) {
            $path = Assert-UninstallPath $base (Join-Path $base $rel)
            if (Test-Path -LiteralPath $path) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "预期的程序文件实际是目录：$path" }
                $files += [pscustomobject]@{ Root=$base; Path=$path }
            }
        }
        $roots = @($base)
        if ($Mode -eq 'Full') {
            $cfg = Read-GuiConfig -Path (Join-Path $base 'config.json') -BaseDir $base
            if ($cfg.Errors.Count) { throw ('配置无效，无法确认外部备份位置：' + ($cfg.Errors -join '；')) }
            $snapRoot = Get-UninstallFullPath (Resolve-GuiBackupDir -BackupDir $cfg.Config.BackupDir -BaseDir $base)
            # 严禁把系统/用户根当成可清理的数据范围，即使配置允许作为备份位置。
            $null = Assert-UninstallPath $snapRoot (Join-Path $snapRoot '__probe__')
            foreach ($dataRoot in @($snapRoot,(Join-Path $base 'quarantine'))) {
                $roots += $dataRoot
                if (-not (Test-Path -LiteralPath $dataRoot)) { continue }
                $null = Assert-UninstallPath $dataRoot (Join-Path $dataRoot '__probe__')
                foreach ($entry in Get-ChildItem -LiteralPath $dataRoot -Force -ErrorAction Stop) {
                    $owned = $false
                    if ($entry.PSIsContainer -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        if ($dataRoot -ieq $snapRoot -and $entry.Name -match '^(?:\d{4}-\d{2}-\d{2}_\d{6}x*|recovery-\d{4}-\d{2}-\d{2}_\d{6})$') {
                            try { $meta = Get-Content -LiteralPath (Join-Path $entry.FullName 'meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json; $owned = $meta.source -in @('auto','manual','recovery') } catch {}
                        } elseif ($dataRoot -ine $snapRoot -and $entry.Name -match '^q-\d{8}_\d{6}$') {
                            $owned = Test-Path -LiteralPath (Join-Path $entry.FullName 'ChsPinyinUDL.dat') -PathType Leaf
                        }
                    }
                    if (-not $owned) { $retained += $entry.FullName; continue }
                    $tree = Get-UninstallTree -Root $dataRoot -Directory $entry.FullName
                    $files += $tree.Files; $dirs += $tree.Directories
                }
            }
            if (-not $PSBoundParameters.ContainsKey('CacheRoots')) {
                $CacheRoots = @(Get-UninstallCacheRoots $base)
                $legacy=Join-Path $env:LOCALAPPDATA 'PinyinLexiconBackup\temp'
                if(Test-Path -LiteralPath $legacy){$retained+=$legacy}
            }
            foreach ($cache in $CacheRoots) {
                $cache = Get-UninstallFullPath $cache; $roots += $cache
                if (Test-Path -LiteralPath $cache) {
                    $tree = Get-UninstallTree -Root $cache -Directory $cache
                    $files += $tree.Files; $dirs += $tree.Directories
                }
            }
        }
        # 所有程序目录里的未知文件，包括开发仓库、协作记录，均不进入删除计划。
        $known = @($files | ForEach-Object Path)
        $retained += @(Get-ChildItem -LiteralPath $base -Force -ErrorAction Stop | Where-Object { $_.FullName -notin $known -and $_.FullName -notin $roots -and $_.Name -ne 'src' } | ForEach-Object FullName)
        return [pscustomobject]@{ Ok=$true; BaseDir=$base; Mode=$Mode; Files=@($files | Sort-Object Path -Unique); Directories=@($dirs | Sort-Object -Unique); Roots=@($roots | Select-Object -Unique); Retained=@($retained | Select-Object -Unique); Task=$task; CleanCacheContainers=(-not $PSBoundParameters.ContainsKey('CacheRoots')); Errors=@() }
    } catch { return [pscustomobject]@{ Ok=$false; Errors=@($_.Exception.Message) } }
}
function Get-UninstallTree([string]$Root, [string]$Directory) {
    $files = @(); $dirs = @()
    $queue = New-Object 'Collections.Generic.Queue[string]'; $queue.Enqueue($Directory)
    while ($queue.Count) {
        $dir = $queue.Dequeue()
        $null = Assert-UninstallPath $Root (Join-Path $dir '__probe__')
        $dirs += $dir
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) {
            $null = Assert-UninstallPath $Root $item.FullName
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
            else { $files += [pscustomobject]@{ Root=$Root; Path=$item.FullName } }
        }
    }
    return @{ Files=$files; Directories=$dirs }
}
function Invoke-UninstallPlan {
    param([Parameter(Mandatory=$true)]$Plan, [switch]$Confirmed)
    if (-not $Confirmed) { return @{ Ok=$false; Cancelled=$true; Errors=@(); Removed=@() } }
    $removed=@(); $errors=@(); $held=$false; $mutex=$null; $taskRemoved=$false
    try {
        if (-not $Plan.Ok) { throw '卸载计划无效。' }
        $mutex = New-Object Threading.Mutex($false, 'Local\PinyinLexiconBackupOp')
        try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw '备份或恢复正在进行，请稍后重试。' }
        # 再次规划；文件增减均要求用户重新确认，不能扩大已确认范围。
        $fresh = Get-UninstallPlan -BaseDir $Plan.BaseDir -Mode $Plan.Mode -CacheRoots @()
        if (-not $fresh.Ok) { throw ($fresh.Errors -join '；') }
        if ($Plan.Mode -eq 'Full' -and ($fresh.Task.Exists -ne $Plan.Task.Exists -or $fresh.Task.Owned -ne $Plan.Task.Owned)) { throw '登录任务发生变化，请重新确认。' }
        foreach ($f in $Plan.Files) { $null=Assert-UninstallPath $f.Root $f.Path }
        # 比较非缓存文件；缓存将在本进程退出后自然不再写入，新增内容只保留。
        $planned = @($Plan.Files | ForEach-Object Path)
        $newFiles = @($fresh.Files | Where-Object { $_.Path -notin $planned })
        if ($newFiles.Count) { throw '卸载范围发生变化，请重新打开卸载窗口确认。' }
        foreach ($f in $Plan.Files) {
            if (-not (Test-Path -LiteralPath $f.Path -PathType Leaf)) { throw '卸载文件发生变化，请重新确认。' }
        }
        if ($Plan.Mode -eq 'Full') { Remove-UninstallTask $Plan.BaseDir; $taskRemoved=($Plan.Task.Exists -and $Plan.Task.Owned) }
        # 先删数据和非必要文件；最后才移除引擎与卸载入口，便于失败后重试。
        $ordered = @($Plan.Files | Sort-Object @{Expression={ if ($_.Path -match '(silent-check\.exe|engine\.psm1|gui-config\.psm1|uninstall[^\\]*)$') { 1 } else { 0 } }},Path)
        foreach ($file in $ordered) {
            try { Remove-Item -LiteralPath $file.Path -Force -ErrorAction Stop; $removed += $file.Path }
            catch { $errors += "$($file.Path)：$($_.Exception.Message)"; break }
        }
        $dirs = @($Plan.Directories) + @((Join-Path $Plan.BaseDir 'src\pinyin-gui'),(Join-Path $Plan.BaseDir 'src\launcher'),(Join-Path $Plan.BaseDir 'src'))
        if ($Plan.Mode -eq 'Full') { $dirs += @($Plan.Roots) }
        foreach ($dir in @($dirs | Select-Object -Unique | Sort-Object Length -Descending)) {
            try {
                $null=Assert-UninstallPath $dir (Join-Path $dir '__probe__')
                if ((Test-Path -LiteralPath $dir -PathType Container) -and @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop).Count -eq 0) { [IO.Directory]::Delete($dir) }
            } catch { $errors += "未能移除空目录 $($dir)：$($_.Exception.Message)" }
        }
        $left=@($Plan.Retained | Where-Object { Test-Path -LiteralPath $_ })
        foreach($root in $Plan.Roots) {
            if(Test-Path -LiteralPath $root -PathType Container) {
                $left+=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
            }
        }
        # 只移除本应用命名空间中已经空了的容器；有历史缓存或其他安装时保留。
        if($Plan.Mode -eq 'Full' -and $Plan.CleanCacheContainers) {
            foreach($parent in @((Join-Path $env:LOCALAPPDATA 'PinyinLexiconBackup\instances'),(Join-Path $env:LOCALAPPDATA 'PinyinLexiconBackup'))) {
                try {
                    $null=Assert-UninstallPath $parent (Join-Path $parent '__probe__')
                    if((Test-Path -LiteralPath $parent -PathType Container) -and @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop).Count -eq 0){[IO.Directory]::Delete($parent)}
                } catch { $left+=$parent }
            }
        }
        return @{ Ok=($errors.Count -eq 0); Cancelled=$false; Removed=$removed; Errors=$errors; Retained=@($left | Select-Object -Unique); TaskRemoved=$taskRemoved }
    } catch { return @{ Ok=$false; Cancelled=$false; Removed=$removed; Errors=@($_.Exception.Message); Retained=@(); TaskRemoved=$taskRemoved } }
    finally { if ($held) { try { $mutex.ReleaseMutex() } catch {} }; if ($mutex) { $mutex.Dispose() } }
}
Export-ModuleMember -Function Get-UninstallPlan,Invoke-UninstallPlan,Get-UninstallInstanceKey

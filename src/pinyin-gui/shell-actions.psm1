#Requires -Version 5.1
# 目录交给 Windows Shell 打开，避免从 GUI 派生 explorer.exe 子进程。
function New-FolderShell {
    New-Object -ComObject Shell.Application -ErrorAction Stop
}

function Open-BackupFolder {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Path)

    $shell = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw '备份位置为空，请先在设置中指定备份位置。' }
        $folder = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $folder.PSIsContainer -or $folder.PSProvider.Name -ne 'FileSystem') {
            throw '备份位置不是文件系统中的文件夹。'
        }
        $shell = New-FolderShell
        # 路径作为完整字符串传给 Shell，不拼接命令行、不执行路径中的内容。
        $null = $shell.Explore($folder.FullName)
        # Explore 无返回值：只能确认请求已提交，不能据此断言窗口已显示。
        return [pscustomobject]@{ Ok = $true; Path = $folder.FullName; Message = '' }
    } catch {
        return [pscustomobject]@{
            Ok = $false
            Path = $Path
            Message = "无法打开备份文件夹：`n$Path`n`n原因：$($_.Exception.Message)`n`n请检查该目录是否存在、是否可以访问；也可复制上面的路径到资源管理器地址栏。"
        }
    } finally {
        if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            try { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }
}

Export-ModuleMember -Function Open-BackupFolder

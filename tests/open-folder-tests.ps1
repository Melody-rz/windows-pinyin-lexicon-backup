#Requires -Version 5.1
# 仅用临时目录和 Shell 替身；不启动资源管理器，不读取真实备份。
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '..\src\pinyin-gui\shell-actions.psm1') -Force -PassThru
$testRoot = Join-Path $PSScriptRoot ('.open-folder-test-' + [guid]::NewGuid().ToString('N'))
$script:Pass = 0
function Assert($Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL $Name" }
    $script:Pass++
    Write-Output "PASS $Name"
}
try {
    $null = [IO.Directory]::CreateDirectory($testRoot)
    & $module {
        $script:Calls = 0
        $script:FactoryFails = $false
        $script:ExploreFails = $false
        $script:Paths = @()
        $script:FakeShell = [pscustomobject]@{}
        $script:FakeShell | Add-Member ScriptMethod Explore {
            param($folderPath)
            if ($script:ExploreFails) { throw '模拟 Shell 打开失败' }
            $script:Paths += $folderPath
        }
        function script:New-FolderShell {
            $script:Calls++
            if ($script:FactoryFails) { throw '模拟 Shell 初始化失败' }
            return $script:FakeShell
        }
    }
    $special = Join-Path $testRoot '中文 备份 [一] & 文档'
    $null = [IO.Directory]::CreateDirectory($special)
    $r = Open-BackupFolder $special
    Assert '中文、空格、方括号及 & 路径成功提交' $r.Ok
    Assert '路径原样传给 Shell' ((& $module { $script:Paths[-1] }) -ceq $special)
    Assert '结果返回规范目录路径' ($r.Path -ceq $special)

    foreach ($bad in @('', '   ', (Join-Path $testRoot '不存在'))) {
        $before = & $module { $script:Calls }
        $r = Open-BackupFolder $bad
        Assert '无效目录给出失败说明' (-not $r.Ok -and $r.Message.Contains('原因：'))
        Assert '无效目录不调用 Shell' ((& $module { $script:Calls }) -eq $before)
    }
    $file = Join-Path $testRoot 'file.txt'
    [IO.File]::WriteAllText($file, 'test')
    $r = Open-BackupFolder $file
    Assert '拒绝普通文件' (-not $r.Ok)
    Assert '错误包含目标路径' ($r.Message.Contains($file))

    & $module { $script:FactoryFails = $true }
    $r = Open-BackupFolder $special
    Assert 'Shell 初始化失败被捕获并说明' (-not $r.Ok -and $r.Message.Contains('模拟 Shell 初始化失败'))
    & $module { $script:FactoryFails = $false; $script:ExploreFails = $true }
    $r = Open-BackupFolder $special
    Assert 'Shell 打开失败被捕获并说明' (-not $r.Ok -and $r.Message.Contains('模拟 Shell 打开失败'))
    & $module { $script:ExploreFails = $false }
    $r = Open-BackupFolder $special
    Assert '失败后仍可重试' $r.Ok
    Write-Output "通过 $script:Pass 项；未打开真实目录窗口。"
} finally {
    Remove-Module $module -Force
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
